import FinanceCore
import FinanceSync
import Foundation
import UserNotifications

/// Local notifications for newly seen pending payments.
enum PaymentNotifications {
    static let categoryIdentifier = "finance.payment"
    static let threadIdentifier = "payments"
    static let summaryThreshold = 4

    struct DeliveryResult: Sendable {
        var remaining: [PendingPaymentAlert]
        var postedCount: Int
        var errorMessage: String?
    }

    /// Registers the payment category with a privacy-safe lock screen placeholder.
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

    /// Delivers queued payment alerts when notifications are authorized.
    /// An alert is removed from the returned `remaining` queue only after
    /// `UNUserNotificationCenter.add` succeeds.
    static func deliver(queue: [PendingPaymentAlert]) async -> DeliveryResult {
        guard !queue.isEmpty else {
            return DeliveryResult(remaining: [], postedCount: 0, errorMessage: nil)
        }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            break
        default:
            // Notifications are not authorized; drop stale queued alerts rather than
            // holding them indefinitely.
            return DeliveryResult(remaining: [], postedCount: 0, errorMessage: nil)
        }

        registerCategory()

        if queue.count > summaryThreshold {
            let content = UNMutableNotificationContent()
            content.title = "\(queue.count) new payments"
            content.body = "Open Finance to review."
            content.sound = .default
            content.threadIdentifier = threadIdentifier
            content.categoryIdentifier = categoryIdentifier

            let anchor = queue.map(\.messageID).sorted().first ?? "batch"
            let request = UNNotificationRequest(
                identifier: "payment-summary-\(anchor)",
                content: content,
                trigger: nil
            )
            do {
                try await center.add(request)
                return DeliveryResult(remaining: [], postedCount: 1, errorMessage: nil)
            } catch {
                return DeliveryResult(
                    remaining: queue,
                    postedCount: 0,
                    errorMessage: "Notification failed: " + error.localizedDescription
                )
            }
        }

        var remaining: [PendingPaymentAlert] = []
        var posted = 0
        var firstError: String?

        for alert in queue {
            let content = UNMutableNotificationContent()
            let hasShop = !alert.merchant.isEmpty && alert.merchant != PendingBuilder.missingMerchantPlaceholder
            let amountText = Money.payment(alert.amount)

            if alert.isDiscreet || !hasShop {
                content.title = "\(amountText) · \(alert.sourceLabel)"
                content.body = "Pending"
            } else {
                content.title = "\(amountText) · \(alert.merchant)"
                content.body = "\(alert.sourceLabel) · pending"
            }
            content.sound = .default
            content.threadIdentifier = threadIdentifier
            content.categoryIdentifier = categoryIdentifier

            let request = UNNotificationRequest(
                identifier: "payment-\(alert.messageID)",
                content: content,
                trigger: nil
            )
            do {
                try await center.add(request)
                posted += 1
            } catch {
                remaining.append(alert)
                if firstError == nil {
                    firstError = "Notification failed: " + error.localizedDescription
                }
            }
        }
        return DeliveryResult(remaining: remaining, postedCount: posted, errorMessage: firstError)
    }
}

/// Serializes all Gmail syncs in the app process (foreground, BGAppRefresh and Shortcuts).
actor SyncEngine {
    static let shared = SyncEngine()

    private static let lookbackDays = 7
    private static let batchSize = 8
    private static let maxCachedNotices = 300

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
                .sorted { $0.receivedAt > $1.receivedAt }
            let keptNotices = Array(merged.prefix(SyncEngine.maxCachedNotices))

            var nextState = storeState
            nextState.syncState = batch.state
            nextState.notices = keptNotices

            var addedPayments = 0
            if let bundle, let categorizer, !newlySeenIDs.isEmpty {
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
                        merchant: item.merchant,
                        sourceLabel: item.source,
                        category: item.category,
                        isDiscreet: isDiscreet
                    ))
                    addedPayments += 1
                }
            }

            try SyncStorage.saveState(nextState)
            storeState = nextState
            newNoticesCount += freshNotices.count
            newPaymentsCount += addedPayments
            committedAnyBatch = true
        }

        func finalizeComplete(_ completedSyncState: SyncState) throws {
            var nextState = storeState
            nextState.syncState = completedSyncState
            try SyncStorage.saveState(nextState)
            storeState = nextState
        }

        func updateAlertQueue(_ remaining: [PendingPaymentAlert]) {
            guard storeState.alertQueue != remaining else { return }
            var nextState = storeState
            nextState.alertQueue = remaining
            if (try? SyncStorage.saveState(nextState)) != nil {
                storeState = nextState
            }
        }
    }

    func isBusy() -> Bool {
        inFlight
    }

    /// Clears Keychain tokens, stored sync state and widget data during sign-out.
    func clearForSignOut() throws {
        guard !inFlight else { throw GmailSync.SyncProblem.busy }
        try KeychainTokenStore().clear()
        SyncStorage.clearState()
        FinanceData.publishWidget(.placeholder, force: true)
    }

    func run(
        trigger: SyncTrigger,
        minimumInterval: TimeInterval,
        timeLimit: TimeInterval? = nil
    ) async -> SyncReport {
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
            return report
        }

        guard !inFlight else {
            return record(outcome: .busy)
        }
        inFlight = true
        defer { inFlight = false }

        if Task.isCancelled {
            return record(outcome: .cancelled)
        }

        guard let clientID = GmailSync.clientID else {
            return record(outcome: .notSignedIn)
        }

        let tokenStore = KeychainTokenStore()
        do {
            guard try tokenStore.load() != nil else {
                return record(outcome: .notSignedIn)
            }
        } catch {
            return record(outcome: .failed, errorMessage: error.localizedDescription)
        }

        var storeState = SyncStorage.loadState()
        if minimumInterval > 0,
           let lastSync = storeState.syncState.lastSyncAt,
           startedAt.timeIntervalSince(lastSync) < minimumInterval
        {
            // Still retry any undelivered alerts from a previous run.
            var notified = 0
            var alertError: String?
            if !storeState.alertQueue.isEmpty {
                let delivery = await PaymentNotifications.deliver(queue: storeState.alertQueue)
                notified = delivery.postedCount
                alertError = delivery.errorMessage
                if delivery.remaining != storeState.alertQueue {
                    storeState.alertQueue = delivery.remaining
                    try? SyncStorage.saveState(storeState)
                }
            }
            return record(outcome: .skipped, notifiedCount: notified, errorMessage: alertError)
        }

        let bundle = BundleInbox.storedData().flatMap { try? DataBundle.decode(from: $0) }
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
            let outcome = try await runWithTimeLimit(timeLimit) {
                try await NoticeSync.sync(
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

        if let syncResult, !syncResult.reachedDeadline {
            do {
                try await committer.finalizeComplete(syncResult.state)
            } catch {
                syncError = error
            }
        }

        let committedNotices = await committer.newNoticesCount
        let committedPayments = await committer.newPaymentsCount
        let committedAny = await committer.committedAnyBatch
        let latestState = await committer.storeState

        // Refresh the widget snapshot when a sync completed or committed batches.
        let shouldPublishWidget = (syncResult != nil && syncError == nil) || committedAny
        if shouldPublishWidget {
            let now = Date()
            if let bundle {
                let finance = FinanceData(bundle: bundle, notices: latestState.notices, today: JST.day(now))
                FinanceData.publishWidget(finance.widgetSnapshot, force: true)
            } else {
                FinanceData.publishWidget(
                    FinanceData.noticeOnlySnapshot(notices: latestState.notices, now: now),
                    force: true
                )
            }
        }

        // Deliver queued alerts after commit (skipping only if externally cancelled).
        var notifiedCount = 0
        var notificationError: String?
        if !(syncError is CancellationError) && !latestState.alertQueue.isEmpty {
            let delivery = await PaymentNotifications.deliver(queue: latestState.alertQueue)
            notifiedCount = delivery.postedCount
            notificationError = delivery.errorMessage
            await committer.updateAlertQueue(delivery.remaining)
        }

        if let error = syncError {
            if error is CancellationError {
                return record(
                    outcome: .cancelled,
                    newNotices: committedNotices,
                    newPayments: committedPayments,
                    notifiedCount: notifiedCount
                )
            }
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
                errorMessage: error.localizedDescription
            )
        }

        if hitHardTimeout || syncResult?.reachedDeadline == true {
            let message = notificationError ?? "Time limit reached; progress saved"
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
            errorMessage: notificationError
        )
    }

    private static func runWithTimeLimit<T: Sendable>(
        _ timeLimit: TimeInterval?,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T? {
        guard let timeLimit, timeLimit > 0 else {
            return try await operation()
        }
        return try await withTaskGroup(of: RaceOutcome<T>.self) { group in
            group.addTask {
                do {
                    return .finished(.success(try await operation()))
                } catch {
                    return .finished(.failure(error))
                }
            }
            group.addTask {
                do {
                    try await Task.sleep(for: .seconds(timeLimit))
                    return .timedOut
                } catch {
                    return .finished(.failure(CancellationError()))
                }
            }

            guard let first = await group.next() else {
                throw CancellationError()
            }
            group.cancelAll()
            _ = await group.next()

            switch first {
            case .timedOut:
                return nil
            case .finished(.success(let value)):
                return value
            case .finished(.failure(let error)):
                throw error
            }
        }
    }
}
