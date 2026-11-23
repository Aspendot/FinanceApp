import FinanceCore
import FinanceSync
import Foundation
import UserNotifications

extension Notification.Name {
    static let backgroundGmailSyncUpdated = Notification.Name("backgroundGmailSyncUpdated")
}

/// Local notifications for newly seen pending payments.
enum PaymentNotifications {
    static let categoryIdentifier = "finance.payment"
    static let threadIdentifier = "payments"
    static let summaryThreshold = 4

    static func registerCategory() {
        let category = UNNotificationCategory(
            identifier: categoryIdentifier,
            actions: [],
            intentIdentifiers: [],
            hiddenPreviewsBodyPlaceholder: "New payment",
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    static func isAuthorized() async -> Bool {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        default: return false
        }
    }

    static func request(for alert: PendingPaymentAlert) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        let hasShop = !alert.merchant.isEmpty && alert.merchant != PendingBuilder.missingMerchantPlaceholder
        let amount = Money.payment(alert.amount)
        if alert.isDiscreet || !hasShop {
            content.title = "\(amount) · \(alert.sourceLabel)"
            content.body = "Pending"
        } else {
            content.title = "\(amount) · \(alert.merchant)"
            content.body = "\(alert.sourceLabel) · pending"
        }
        return request(id: "payment-\(alert.messageID)", content: content)
    }

    static func request(for summary: PendingPaymentSummary) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = summary.count == 1 ? "1 new payment" : "\(summary.count) new payments"
        content.body = "Open Finance to review."
        return request(id: "payment-summary-\(summary.id)", content: content)
    }

    private static func request(id: String, content: UNMutableNotificationContent) -> UNNotificationRequest {
        content.sound = .default
        content.threadIdentifier = threadIdentifier
        content.categoryIdentifier = categoryIdentifier
        return UNNotificationRequest(identifier: id, content: content, trigger: nil)
    }

    static func outstandingIDs() async -> Set<String> {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let delivered = await center.deliveredNotifications()
        return Set((pending + delivered.map(\.request))
            .filter { $0.content.categoryIdentifier == categoryIdentifier }
            .map(\.identifier))
    }

    static func clear() async {
        let ids = Array(await outstandingIDs())
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }
}

/// Serializes all Gmail syncs in the app process (foreground, BGAppRefresh and Shortcuts).
actor SyncEngine {
    static let shared = SyncEngine()

    private static let lookbackDays = 7
    private static let batchSize = 8
    private static let noticeHistoryLimit = 300
    private static let maxDetailedAlerts = 300

    private var inFlight = false

    private enum RaceOutcome<T: Sendable>: Sendable {
        case finished(Result<T, any Error>)
        case timedOut
    }

    /// Commits each finished `NoticeSync` batch atomically with notices and queued alerts.
    private actor BatchCommitter {
        private(set) var storeState: SyncStoreState
        private let bundle: DataBundle?
        private let categorizer: Categorizer?
        private let discreetCategories: Set<String>
        private(set) var newNoticesCount = 0
        private(set) var newPaymentsCount = 0
        private(set) var committedAnyBatch = false
        private(set) var postedAlertCount = 0

        init(storeState: SyncStoreState, bundle: DataBundle?) {
            self.storeState = storeState
            self.bundle = bundle
            self.categorizer = bundle.map { Categorizer(rules: $0.rules) }
            self.discreetCategories = Set((bundle?.discreetCategories ?? []).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            })
        }

        func commit(_ batch: SyncBatch) throws {
            let freshNotices = batch.items.compactMap(\.notice)
            let newlySeenIDs = Set(freshNotices.map(\.messageID))

            var seen = Set<String>()
            let merged = (freshNotices + storeState.notices)
                .filter { seen.insert($0.messageID).inserted }
                .sorted { ($0.receivedAt, $0.messageID) > ($1.receivedAt, $1.messageID) }
            let keptNotices = PendingBuilder.retainNotices(
                merged, bundle: bundle, historyLimit: SyncEngine.noticeHistoryLimit
            )

            var nextState = storeState
            nextState.syncState = batch.state
            nextState.notices = keptNotices

            var addedPayments = 0
            // An incomplete initial scan remains a silent baseline across runs.
            if storeState.syncState.lastSyncAt != nil, let bundle, let categorizer, !newlySeenIDs.isEmpty {
                let pending = PendingBuilder.build(
                    notices: keptNotices,
                    bundle: bundle,
                    categorizer: categorizer,
                    config: bundle.layerConfig
                )
                var queuedIDs = Set(nextState.alertQueue.map(\.messageID))
                for (item, messageID) in zip(pending.items, pending.noticeIDs)
                where newlySeenIDs.contains(messageID) && queuedIDs.insert(messageID).inserted {
                    let isDiscreet = discreetCategories.contains(
                        item.category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    )
                    nextState.alertQueue.append(PendingPaymentAlert(
                        messageID: messageID,
                        amount: item.amount,
                        merchant: isDiscreet ? "" : item.merchant,
                        sourceLabel: item.source,
                        isDiscreet: isDiscreet
                    ))
                    addedPayments += 1
                }
            }

            let overflow = nextState.alertQueue.count - SyncEngine.maxDetailedAlerts
            if overflow > 0 {
                nextState.alertQueue.removeFirst(overflow)
                nextState.overflowAlertCount = (nextState.overflowAlertCount ?? 0) + overflow
            }
            try save(nextState)
            newNoticesCount += freshNotices.count
            newPaymentsCount += addedPayments
            committedAnyBatch = true
        }

        func finalizeComplete(_ completedSyncState: SyncState) throws {
            var nextState = storeState
            nextState.syncState = completedSyncState
            try save(nextState)
        }

        private func save(_ state: SyncStoreState) throws {
            try SyncStorage.saveState(state)
            storeState = state
        }

        func deliverAlerts(until deadline: ContinuousClock.Instant?) async throws {
            guard storeState.pendingSummary != nil || storeState.overflowAlertCount != nil
                    || !storeState.alertQueue.isEmpty,
                  Self.canDeliver(until: deadline),
                  await PaymentNotifications.isAuthorized()
            else { return }

            PaymentNotifications.registerCategory()
            let outstanding = await PaymentNotifications.outstandingIDs()
            guard Self.canDeliver(until: deadline) else { return }
            let center = UNUserNotificationCenter.current()
            try reconcileQueue()
            var failedAlerts = Set<String>()
            var deliveryError: (any Error)?
            while Self.canDeliver(until: deadline) {
                var nextState = storeState
                let overflow = nextState.overflowAlertCount ?? 0
                let summaryCount = overflow + nextState.alertQueue.count
                if nextState.pendingSummary == nil, overflow > 0 || summaryCount > PaymentNotifications.summaryThreshold {
                    nextState.pendingSummary = PendingPaymentSummary(count: summaryCount)
                    nextState.overflowAlertCount = nil
                    nextState.alertQueue = []
                    // Persist the request identifier before the system can accept it.
                    try save(nextState)
                }

                let request: UNNotificationRequest
                let alertID: String?
                if let summary = nextState.pendingSummary {
                    request = PaymentNotifications.request(for: summary)
                    alertID = nil
                    nextState.pendingSummary = nil
                } else if let index = nextState.alertQueue.firstIndex(where: { !failedAlerts.contains($0.messageID) }) {
                    let alert = nextState.alertQueue.remove(at: index)
                    request = PaymentNotifications.request(for: alert)
                    alertID = alert.messageID
                } else {
                    break
                }

                if !outstanding.contains(request.identifier) {
                    do {
                        try await center.add(request)
                        postedAlertCount += 1
                    } catch {
                        guard let alertID else { throw error }
                        failedAlerts.insert(alertID)
                        deliveryError = error
                        continue
                    }
                }
                // Acknowledge each success, including an earlier system acceptance.
                try save(nextState)
            }
            if let deliveryError { throw deliveryError }
        }

        private static func canDeliver(until deadline: ContinuousClock.Instant?) -> Bool {
            !Task.isCancelled && (deadline.map { ContinuousClock.now < $0 } ?? true)
        }

        private func reconcileQueue() throws {
            guard !storeState.alertQueue.isEmpty,
                  let bytes = try BundleInbox.readStoredData() else { return }
            let latest = try DataBundle.decode(from: bytes)
            let pending = PendingBuilder.build(
                notices: storeState.notices,
                bundle: latest,
                categorizer: Categorizer(rules: latest.rules),
                config: latest.layerConfig
            )
            let itemsByID = Dictionary(zip(pending.noticeIDs, pending.items), uniquingKeysWith: { first, _ in first })
            let discreet = Set((latest.discreetCategories ?? []).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            })
            var nextState = storeState
            let cachedIDs = Set(storeState.notices.map(\.messageID))
            nextState.alertQueue = storeState.alertQueue.compactMap { alert -> PendingPaymentAlert? in
                // An evicted notice can no longer be re-evaluated.
                guard cachedIDs.contains(alert.messageID) else { return alert }
                guard let item = itemsByID[alert.messageID] else { return nil }
                var updated = alert
                updated.amount = item.amount
                updated.sourceLabel = item.source
                updated.isDiscreet = alert.isDiscreet || discreet.contains(
                    item.category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                )
                if updated.isDiscreet { updated.merchant = "" }
                return updated
            }
            if nextState != storeState { try save(nextState) }
        }
    }

    func withSignIn(_ operation: @MainActor @Sendable () async throws -> Void) async throws {
        guard !inFlight else { throw GmailSync.SyncProblem.busy }
        inFlight = true
        defer { inFlight = false }
        try await operation()
    }

    /// Clears Keychain tokens, stored sync state and widget data during sign-out.
    func clearForSignOut() async throws {
        guard !inFlight else { throw GmailSync.SyncProblem.busy }
        inFlight = true
        defer { inFlight = false }
        try KeychainTokenStore().clear()
        FinanceData.publishWidget(.placeholder, force: true)
        await PaymentNotifications.clear()
        try SyncStorage.clearState()
    }

    func publishCurrentWidget() throws {
        let hasCredentials = try GmailSync.hasCredentials()
        let notices = hasCredentials ? try SyncStorage.loadState().notices : []
        let now = Date()
        if let bytes = try BundleInbox.readStoredData() {
            let bundle = try DataBundle.decode(from: bytes)
            let finance = FinanceData(bundle: bundle, notices: notices, today: JST.day(now))
            FinanceData.publishWidget(finance.widgetSnapshot)
        } else if hasCredentials {
            FinanceData.publishWidget(FinanceData.noticeOnlySnapshot(notices: notices, now: now))
        }
    }

    func run(
        trigger: SyncTrigger,
        minimumInterval: TimeInterval,
        timeLimit: TimeInterval? = nil
    ) async -> SyncReport {
        let start = ContinuousClock.now
        let startedAt = Date()

        func record(
            outcome: SyncOutcome,
            newNotices: Int = 0,
            newPayments: Int = 0,
            notifiedCount: Int = 0,
            errorMessage: String? = nil
        ) -> SyncReport {
            let report = SyncReport(
                trigger: trigger,
                startedAt: startedAt,
                durationSeconds: max(0, Date().timeIntervalSince(startedAt)),
                outcome: outcome,
                newNotices: newNotices,
                newPayments: newPayments,
                notifiedCount: notifiedCount,
                errorMessage: errorMessage
            )
            SyncStorage.appendRunRecord(report.record)
            if trigger != .app, outcome == .updated || newNotices > 0 {
                NotificationCenter.default.post(name: .backgroundGmailSyncUpdated, object: nil)
            }
            return report
        }

        guard !inFlight else { return record(outcome: .busy) }
        inFlight = true
        defer { inFlight = false }

        let deadline = timeLimit.map { start.advanced(by: .seconds($0)) }
        if Task.isCancelled { return record(outcome: .cancelled) }
        guard let clientID = GmailSync.clientID else { return record(outcome: .notSignedIn) }

        let tokenStore = KeychainTokenStore()
        let tokens: OAuthTokens
        var storeState: SyncStoreState
        do {
            guard let stored = try tokenStore.load() else { return record(outcome: .notSignedIn) }
            tokens = stored
            storeState = try SyncStorage.loadState()
        } catch {
            return record(outcome: .failed, errorMessage: Self.diagnostic(for: error))
        }

        let lastAttempt = trigger == .shortcut ? storeState.lastShortcutAttempt : nil
        let lastCheck = [storeState.syncState.lastSyncAt, lastAttempt]
            .compactMap { $0 }.filter { $0 <= startedAt }.max()
        if minimumInterval > 0, let lastCheck,
           (0..<minimumInterval).contains(startedAt.timeIntervalSince(lastCheck))
        {
            let committer = BatchCommitter(storeState: storeState, bundle: nil)
            var alertError: String?
            do {
                try await committer.deliverAlerts(until: deadline)
            } catch {
                alertError = "Could not deliver or save payment alerts."
            }
            let outcome: SyncOutcome = Task.isCancelled ? .cancelled : .skipped
            return record(outcome: outcome, notifiedCount: await committer.postedAlertCount, errorMessage: alertError)
        }

        let bundle: DataBundle?
        do {
            bundle = try BundleInbox.readStoredData().map { try DataBundle.decode(from: $0) }
            if trigger == .shortcut {
                // Throttle attempts, including timeouts and transient Gmail failures.
                storeState.lastShortcutAttempt = startedAt
                try SyncStorage.saveState(storeState)
            }
        } catch {
            return record(outcome: .failed, errorMessage: Self.diagnostic(for: error))
        }
        let committer = BatchCommitter(storeState: storeState, bundle: bundle)

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = min(15, timeLimit ?? 15)
        config.timeoutIntervalForResource = timeLimit ?? 45
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let transport = URLSessionHTTPTransport(session: session)
        let retryPolicy: RetryPolicy = timeLimit != nil
            ? RetryPolicy(maxRetries: 1, initialDelay: .seconds(1), maxDelay: .seconds(2))
            : RetryPolicy(maxRetries: 2, initialDelay: .seconds(1), maxDelay: .seconds(4))
        let client = GmailClient(
            clientID: clientID,
            tokenStore: tokenStore,
            transport: transport,
            retryPolicy: retryPolicy
        )

        // Leave a small margin before hard cancellation so the final batch, snapshot
        // and notifications can finish cleanly.
        let softDeadline = timeLimit.map { limit in
            startedAt.addingTimeInterval(max(1, limit - 3))
        }

        let initialSyncState = storeState.syncState
        var syncResult: SyncResult?
        var syncError: Error?
        var hitHardTimeout = false

        do {
            let outcome = try await Self.runWithDeadline(deadline) {
                if tokens.mailboxFingerprint == nil {
                    let fingerprint = try await GmailSync.mailboxFingerprint(client: client)
                    try Task.checkCancellation()
                    if var latest = try tokenStore.load() {
                        latest.mailboxFingerprint = fingerprint
                        try tokenStore.save(latest)
                    }
                }
                return try await NoticeSync.sync(
                    client: client,
                    state: initialSyncState,
                    lookbackDays: Self.lookbackDays,
                    batchSize: Self.batchSize,
                    deadline: softDeadline,
                    onBatch: { batch in
                        try await committer.commit(batch)
                    }
                )
            }
            if let completed = outcome {
                syncResult = completed
            } else {
                hitHardTimeout = true
            }
        } catch {
            syncError = error
        }

        if let syncResult, !syncResult.reachedDeadline, !Task.isCancelled {
            do {
                try await committer.finalizeComplete(syncResult.state)
            } catch {
                syncError = error
            }
        }

        let committedNotices = await committer.newNoticesCount
        let committedPayments = await committer.newPaymentsCount
        let committedAny = await committer.committedAnyBatch
        var postProcessingError: String?
        if !Task.isCancelled, (syncResult != nil || committedAny) {
            do {
                try publishCurrentWidget()
            } catch {
                postProcessingError = "Could not update the widget snapshot."
            }
        }
        do {
            try await committer.deliverAlerts(until: deadline)
        } catch {
            postProcessingError = "Could not deliver or save payment alerts."
        }
        let notifiedCount = await committer.postedAlertCount

        if Task.isCancelled || syncError is CancellationError {
            return record(
                outcome: .cancelled,
                newNotices: committedNotices,
                newPayments: committedPayments,
                notifiedCount: notifiedCount
            )
        }
        if let error = syncError {
            if let clientError = error as? GmailClientError, clientError.requiresSignInAgain {
                return record(
                    outcome: .signInRequired,
                    newNotices: committedNotices,
                    newPayments: committedPayments,
                    notifiedCount: notifiedCount,
                    errorMessage: "Sign in to Gmail again"
                )
            }
            return record(
                outcome: .failed,
                newNotices: committedNotices,
                newPayments: committedPayments,
                notifiedCount: notifiedCount,
                errorMessage: Self.diagnostic(for: error)
            )
        }

        if hitHardTimeout || syncResult?.reachedDeadline == true || deadline.map({ ContinuousClock.now >= $0 }) == true {
            let message = postProcessingError ?? "Time limit reached; progress saved"
            return record(
                outcome: .timedOut,
                newNotices: committedNotices,
                newPayments: committedPayments,
                notifiedCount: notifiedCount,
                errorMessage: message
            )
        }

        return record(
            outcome: .updated,
            newNotices: committedNotices,
            newPayments: committedPayments,
            notifiedCount: notifiedCount,
            errorMessage: postProcessingError
        )
    }

    // The run log stays local and never persists raw server text or request URLs.
    private static func diagnostic(for error: any Error) -> String {
        guard let error = error as? GmailClientError else {
            return "Could not read or save Gmail sync data."
        }
        switch error {
        case .httpError(let status, _): return "Gmail request failed (HTTP \(status))."
        case .tokenRefreshFailed: return "Could not refresh the Google access token."
        case .networkError: return "Could not reach Gmail."
        default: return error.localizedDescription
        }
    }

    private static func runWithDeadline<T: Sendable>(
        _ deadline: ContinuousClock.Instant?,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T? {
        guard let deadline else { return try await operation() }
        let first = await withTaskGroup(of: RaceOutcome<T>.self) { group in
            group.addTask {
                do {
                    return .finished(.success(try await operation()))
                } catch {
                    return .finished(.failure(error))
                }
            }
            group.addTask {
                do {
                    try await Task.sleep(until: deadline, clock: .continuous)
                    return .timedOut
                } catch {
                    return .finished(.failure(CancellationError()))
                }
            }

            let first = await group.next()
            group.cancelAll()
            // The task group joins the cancelled child before returning. No
            // subsequent run can race a late batch commit or token refresh.
            return first
        }
        try Task.checkCancellation()
        switch first {
        case .timedOut: return nil
        case .finished(let result): return try result.get()
        case nil: throw CancellationError()
        }
    }
}
