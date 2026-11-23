import FinanceCore
import FinanceSync
import Foundation
import UserNotifications

extension Notification.Name {
    static let backgroundGmailSyncUpdated = Notification.Name("backgroundGmailSyncUpdated")
}

/// Local notifications for newly seen pending payments and confirmed bank deposits.
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
        if alert.isDecline == true {
            let amountLabel = alert.amount == 0 ? "Payment declined" : "Declined · \(amount)"
            content.title = hasShop ? "\(amountLabel) · \(alert.merchant)" : "\(amountLabel) · \(alert.sourceLabel)"
            content.body = "\(alert.sourceLabel) · payment could not go through"
            return request(id: "decline-\(alert.messageID)", content: content)
        }
        if alert.isConfirmed == true {
            if alert.isDiscreet || !hasShop {
                content.title = "\(amount) · \(alert.sourceLabel)"
                content.body = "Received"
            } else {
                content.title = "\(amount) · \(alert.merchant)"
                content.body = alert.sourceLabel
            }
            return request(id: "bank-\(alert.messageID)", content: content)
        }
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

/// Serializes all syncs in the app process (foreground, BGAppRefresh and Shortcuts):
/// encrypted Google Drive bundle check, Gmail notices, and Money Forward bank transactions.
actor SyncEngine {
    static let shared = SyncEngine()

    private static let lookbackDays = 7
    private static let batchSize = 8
    private static let noticeHistoryLimit = 300
    private static let maxDetailedAlerts = 300
    private static let defaultMoneyForwardLookbackDays = 30

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
            let prefs = LocalDataStore.loadNotificationPreferences()
            // An incomplete initial scan remains a silent baseline across runs.
            if storeState.syncState.lastSyncAt != nil, let bundle, let categorizer, !newlySeenIDs.isEmpty {
                var queuedIDs = Set(nextState.alertQueue.map(\.messageID))
                if prefs.paymentAlertsEnabled {
                    let pending = PendingBuilder.build(
                        notices: keptNotices,
                        bundle: bundle,
                        categorizer: categorizer,
                        config: bundle.layerConfig
                    )
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
                            isDiscreet: isDiscreet,
                            isConfirmed: false
                        ))
                        addedPayments += 1
                    }
                }
                if prefs.declineAlertsEnabled {
                    for notice in freshNotices where notice.kind == .decline && queuedIDs.insert(notice.messageID).inserted {
                        let sourceLabel = bundle.sourceLabels[notice.source.rawValue] ?? notice.source.rawValue
                        nextState.alertQueue.append(PendingPaymentAlert(
                            messageID: notice.messageID,
                            amount: notice.amount ?? 0,
                            merchant: notice.merchant ?? "",
                            sourceLabel: sourceLabel,
                            isDiscreet: false,
                            isConfirmed: false,
                            isDecline: true
                        ))
                        addedPayments += 1
                    }
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

        /// Enqueues notifications for newly confirmed Money Forward money-in transactions (e.g. salary).
        func enqueueConfirmedBankMoneyIn(_ alerts: [PendingPaymentAlert]) throws {
            guard !alerts.isEmpty else { return }
            var nextState = storeState
            var queuedKeys = Set(nextState.alertQueue.map { "\($0.isConfirmed == true ? "b" : "p"):\($0.messageID)" })
            var added = 0
            for alert in alerts {
                let key = "b:\(alert.messageID)"
                guard queuedKeys.insert(key).inserted else { continue }
                nextState.alertQueue.append(alert)
                added += 1
            }
            guard added > 0 else { return }
            let overflow = nextState.alertQueue.count - SyncEngine.maxDetailedAlerts
            if overflow > 0 {
                nextState.alertQueue.removeFirst(overflow)
                nextState.overflowAlertCount = (nextState.overflowAlertCount ?? 0) + overflow
            }
            try save(nextState)
            newPaymentsCount += added
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
            let mfState = (try? MoneyForwardStore.loadState()) ?? MoneyForwardState()
            let layered = BankLayering.build(
                bundle: latest,
                bankTransactions: mfState.transactions,
                accountMapping: mfState.accountMapping,
                notices: storeState.notices,
                categorizer: Categorizer(rules: latest.rules),
                config: latest.layerConfig
            )
            let confirmedIDs = Set(layered.bankTransactionIDs)
            let itemsByID = Dictionary(
                zip(layered.pendingNoticeIDs, layered.pendingItems),
                uniquingKeysWith: { first, _ in first }
            )
            let discreet = Set((latest.discreetCategories ?? []).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            })
            var nextState = storeState
            let cachedIDs = Set(storeState.notices.map(\.messageID))
            nextState.alertQueue = storeState.alertQueue.compactMap { alert -> PendingPaymentAlert? in
                if alert.isDecline == true {
                    return alert
                }
                if alert.isConfirmed == true {
                    return confirmedIDs.contains(alert.messageID) ? alert : nil
                }
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

    func withSignIn<T: Sendable>(_ operation: @MainActor @Sendable () async throws -> T) async throws -> T {
        guard !inFlight else { throw GmailSync.SyncProblem.busy }
        inFlight = true
        defer { inFlight = false }
        return try await operation()
    }

    /// Clears Google Keychain tokens, stored Gmail sync state and widget data during sign-out.
    func clearForSignOut() async throws {
        guard !inFlight else { throw GmailSync.SyncProblem.busy }
        inFlight = true
        defer { inFlight = false }
        try KeychainTokenStore().clear()
        FinanceData.publishWidget(.placeholder, force: true)
        await PaymentNotifications.clear()
        try SyncStorage.clearState()
        try DriveSyncStore.clearState()
    }

    func publishCurrentWidget() throws {
        let hasCredentials = try GmailSync.hasCredentials()
        let notices = hasCredentials ? try SyncStorage.loadState().notices : []
        let mfState = (try? MoneyForwardStore.loadState()) ?? MoneyForwardState()
        let localMods = LocalDataStore.loadModifications()
        let now = Date()
        if let bytes = try BundleInbox.readStoredData() {
            let bundle = try DataBundle.decode(from: bytes)
            let finance = FinanceData(
                bundle: bundle,
                notices: notices,
                bankTransactions: mfState.transactions,
                accountMapping: mfState.accountMapping,
                localModifications: localMods,
                today: JST.day(now)
            )
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
            newBankTransactions: Int = 0,
            driveImported: Bool = false,
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
                errorMessage: errorMessage,
                newBankTransactions: newBankTransactions,
                driveImported: driveImported
            )
            SyncStorage.appendRunRecord(report.record)
            if trigger != .app, outcome != .busy && outcome != .notSignedIn && outcome != .skipped {
                NotificationCenter.default.post(name: .backgroundGmailSyncUpdated, object: nil)
            }
            return report
        }

        guard !inFlight else { return record(outcome: .busy) }
        inFlight = true
        defer { inFlight = false }

        let deadline = timeLimit.map { start.advanced(by: .seconds($0)) }
        if Task.isCancelled { return record(outcome: .cancelled) }

        let clientID = GmailSync.clientID
        let tokenStore = KeychainTokenStore()
        let mfCredentialStore = KeychainMoneyForwardCredentialStore()

        let google = Result { clientID != nil ? try tokenStore.load() : nil }
        let moneyForward = Result { try mfCredentialStore.load() }
        let drive = Result { try DriveSync.loadKey() }
        let googleTokens = try? google.get()
        let mfCredentials = try? moneyForward.get()
        let driveKey = try? drive.get()
        var storeState: SyncStoreState
        do {
            storeState = try SyncStorage.loadState()
        } catch {
            return record(outcome: .failed, errorMessage: Self.diagnostic(for: error))
        }

        let hasGmail = clientID != nil && googleTokens != nil
        let hasMoneyForward = mfCredentials != nil
        let hasDrive = hasGmail && driveKey != nil
            && (googleTokens?.scope == nil || googleTokens?.hasScope(GoogleOAuth.driveAppDataScope) == true)
        let shouldSyncMoneyForward = hasMoneyForward && !MoneyForwardClient.isInNightlyMaintenance(at: startedAt)

        var credentialErrors: [String] = []
        if case .failure = google { credentialErrors.append("Could not load Google credentials.") }
        if case .failure = moneyForward { credentialErrors.append("Could not load Money Forward credentials.") }
        if case .failure = drive { credentialErrors.append("Could not load the Drive pairing key.") }
        guard hasGmail || hasMoneyForward else {
            if let error = credentialErrors.first { return record(outcome: .failed, errorMessage: error) }
            return record(outcome: .notSignedIn)
        }

        let mfStateSnapshot = (try? MoneyForwardStore.loadState()) ?? MoneyForwardState()
        let driveStateSnapshot = (try? DriveSyncStore.loadState()) ?? DriveSyncState()
        var lastChecks: [Date?] = []
        if hasGmail { lastChecks.append(storeState.syncState.lastSyncAt) }
        if hasDrive { lastChecks.append(driveStateSnapshot.lastCheckedAt) }
        if shouldSyncMoneyForward { lastChecks.append(mfStateSnapshot.lastSyncAt) }
        let lastShortcut = trigger == .shortcut ? storeState.lastShortcutAttempt : nil
        func isRecent(_ date: Date?) -> Bool {
            date.map { (0..<minimumInterval).contains(startedAt.timeIntervalSince($0)) } ?? false
        }
        if minimumInterval > 0, isRecent(lastShortcut) || lastChecks.allSatisfy(isRecent) {
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

        if trigger == .shortcut {
            do {
                storeState.lastShortcutAttempt = startedAt
                try SyncStorage.saveState(storeState)
            } catch {
                return record(outcome: .failed, errorMessage: Self.diagnostic(for: error))
            }
        }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = min(15, timeLimit ?? 15)
        config.timeoutIntervalForResource = timeLimit ?? 45
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let transport = URLSessionHTTPTransport(session: session)
        let retryPolicy: RetryPolicy = timeLimit != nil
            ? RetryPolicy(maxRetries: 1, initialDelay: .seconds(1), maxDelay: .seconds(2))
            : RetryPolicy(maxRetries: 2, initialDelay: .seconds(1), maxDelay: .seconds(4))

        var remainingStages = [hasDrive, hasGmail, shouldSyncMoneyForward].filter { $0 }.count
        func nextStageDeadline() -> ContinuousClock.Instant? {
            defer { remainingStages -= 1 }
            guard let deadline else { return nil }
            let workEnd = deadline.advanced(by: .seconds(-2))
            let now = ContinuousClock.now
            return now.advanced(by: max(.zero, now.duration(to: workEnd)) / remainingStages)
        }

        var driveImported = false
        var hitHardTimeout = false
        var nonFatalErrors = credentialErrors

        // 1. Encrypted Google Drive bundle sync (runs first so Gmail & Money Forward see fresh coverage/rules).
        if hasDrive, let clientID, let driveKey, !Task.isCancelled, !Self.isPast(deadline) {
            let stageDeadline = nextStageDeadline()
            let driveClient = GoogleDriveClient(
                clientID: clientID,
                tokenStore: tokenStore,
                transport: transport,
                retryPolicy: retryPolicy
            )
            do {
                let outcome = try await Self.runWithDeadline(stageDeadline) {
                    try await DriveSync.checkAndImport(client: driveClient, key: driveKey, now: Date())
                }
                if let outcome {
                    if case .imported = outcome {
                        driveImported = true
                    }
                } else {
                    hitHardTimeout = true
                }
            } catch is CancellationError {
                // Handled below.
            } catch {
                nonFatalErrors.append("Drive: \(DriveSync.diagnostic(for: error))")
            }
        }

        // Load latest bundle (including any update just imported from Google Drive).
        let bundle: DataBundle?
        do {
            bundle = try BundleInbox.readStoredData().map { try DataBundle.decode(from: $0) }
        } catch {
            return record(outcome: .failed, driveImported: driveImported, errorMessage: Self.diagnostic(for: error))
        }
        let committer = BatchCommitter(storeState: storeState, bundle: bundle)

        // 2. Gmail notice sync.
        var syncResult: SyncResult?
        var gmailError: Error?

        if hasGmail, let clientID, let tokens = googleTokens, !Task.isCancelled, !Self.isPast(deadline) {
            let stageDeadline = nextStageDeadline()
            let softDeadline = Self.wallDeadline(stageDeadline, margin: 0.5)
            let gmailClient = GmailClient(
                clientID: clientID,
                tokenStore: tokenStore,
                transport: transport,
                retryPolicy: retryPolicy
            )
            let initialSyncState = storeState.syncState
            do {
                let outcome = try await Self.runWithDeadline(stageDeadline) {
                    if tokens.mailboxFingerprint == nil {
                        let fingerprint = try await GmailSync.mailboxFingerprint(client: gmailClient)
                        try Task.checkCancellation()
                        if var latest = try tokenStore.load() {
                            latest.mailboxFingerprint = fingerprint
                            try tokenStore.save(latest)
                        }
                    }
                    return try await NoticeSync.sync(
                        client: gmailClient,
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
                gmailError = error
            }

            if let syncResult, !syncResult.reachedDeadline, !Task.isCancelled {
                do {
                    try await committer.finalizeComplete(syncResult.state)
                } catch {
                    gmailError = error
                }
            }
        }

        // 3. Money Forward bank transaction sync (always after Gmail, within the same deadline).
        var newBankTransactions = 0
        var mfTimedOut = false
        var mfStateChanged = false
        var mfError: Error?

        if shouldSyncMoneyForward, !Task.isCancelled, !Self.isPast(deadline) {
            let stageDeadline = nextStageDeadline()
            let outcome = await runMoneyForwardSync(
                credentialStore: mfCredentialStore,
                transport: transport,
                retryPolicy: retryPolicy,
                bundle: bundle,
                committer: committer,
                startedAt: startedAt,
                deadline: stageDeadline,
                softDeadline: Self.wallDeadline(stageDeadline, margin: 0.5)
            )
            newBankTransactions = outcome.newTransactions
            mfTimedOut = outcome.timedOut
            mfStateChanged = outcome.stateChanged
            mfError = outcome.error
        }

        let committedNotices = await committer.newNoticesCount
        let committedPayments = await committer.newPaymentsCount
        let committedAny = await committer.committedAnyBatch
        var postProcessingError: String?
        if syncResult != nil || committedAny || mfStateChanged || driveImported {
            do {
                try publishCurrentWidget()
            } catch {
                postProcessingError = "Could not update the widget snapshot."
            }
            if let bundle {
                let mfState = (try? MoneyForwardStore.loadState()) ?? MoneyForwardState()
                let localMods = LocalDataStore.loadModifications()
                let notices = await committer.storeState.notices
                let finance = FinanceData(
                    bundle: bundle,
                    notices: notices,
                    bankTransactions: mfState.transactions,
                    accountMapping: mfState.accountMapping,
                    localModifications: localMods,
                    today: JST.day(Date())
                )
                await BillReminderScheduler.sync(
                    timeline: finance.timeline,
                    preferences: LocalDataStore.loadNotificationPreferences()
                )
            }
        }
        do {
            try await committer.deliverAlerts(until: deadline)
        } catch {
            postProcessingError = "Could not deliver or save payment alerts."
        }
        let notifiedCount = await committer.postedAlertCount

        if Task.isCancelled || gmailError is CancellationError || mfError is CancellationError {
            return record(
                outcome: .cancelled,
                newNotices: committedNotices,
                newPayments: committedPayments,
                notifiedCount: notifiedCount,
                newBankTransactions: newBankTransactions,
                driveImported: driveImported
            )
        }

        if let error = gmailError {
            if let clientError = error as? GmailClientError, clientError.requiresSignInAgain {
                return record(
                    outcome: .signInRequired,
                    newNotices: committedNotices,
                    newPayments: committedPayments,
                    notifiedCount: notifiedCount,
                    newBankTransactions: newBankTransactions,
                    driveImported: driveImported,
                    errorMessage: "Sign in to Gmail again"
                )
            }
            return record(
                outcome: .failed,
                newNotices: committedNotices,
                newPayments: committedPayments,
                notifiedCount: notifiedCount,
                newBankTransactions: newBankTransactions,
                driveImported: driveImported,
                errorMessage: Self.diagnostic(for: error)
            )
        }

        if let error = mfError {
            let mfMessage = Self.moneyForwardDiagnostic(for: error)
            if !hasGmail {
                return record(
                    outcome: .failed,
                    newNotices: committedNotices,
                    newPayments: committedPayments,
                    notifiedCount: notifiedCount,
                    newBankTransactions: newBankTransactions,
                    driveImported: driveImported,
                    errorMessage: mfMessage
                )
            }
            nonFatalErrors.append(mfMessage)
        }

        if hitHardTimeout || syncResult?.reachedDeadline == true || mfTimedOut || Self.isPast(deadline) {
            let message = postProcessingError ?? nonFatalErrors.first ?? "Time limit reached; progress saved"
            return record(
                outcome: .timedOut,
                newNotices: committedNotices,
                newPayments: committedPayments,
                notifiedCount: notifiedCount,
                newBankTransactions: newBankTransactions,
                driveImported: driveImported,
                errorMessage: message
            )
        }

        let summaryError = ([postProcessingError].compactMap { $0 } + nonFatalErrors).first
        return record(
            outcome: .updated,
            newNotices: committedNotices,
            newPayments: committedPayments,
            notifiedCount: notifiedCount,
            newBankTransactions: newBankTransactions,
            driveImported: driveImported,
            errorMessage: summaryError
        )
    }

    private struct MoneyForwardRunOutcome: Sendable {
        var newTransactions: Int = 0
        var timedOut: Bool = false
        var stateChanged: Bool = false
        var error: (any Error)? = nil
    }

    private actor BankPages {
        private(set) var transactions: [BankTransaction] = []

        func append(_ rows: [BankTransaction]) {
            transactions.append(contentsOf: rows)
        }
    }

    private func runMoneyForwardSync(
        credentialStore: KeychainMoneyForwardCredentialStore,
        transport: any HTTPTransport,
        retryPolicy: RetryPolicy,
        bundle: DataBundle?,
        committer: BatchCommitter,
        startedAt: Date,
        deadline: ContinuousClock.Instant?,
        softDeadline: Date?
    ) async -> MoneyForwardRunOutcome {
        var mfState: MoneyForwardState
        do {
            mfState = try MoneyForwardStore.loadState()
            if let creds = try credentialStore.load(), creds.mode == .apiKey,
               creds.apiKey?.officeCode != mfState.officeCode {
                // Recover from interruption between the credential and office-state writes.
                let selectedCode = creds.apiKey?.officeCode
                let offices = mfState.availableOffices
                mfState = MoneyForwardState(officeCode: selectedCode,
                                             officeName: offices.first { $0.code == selectedCode }?.name,
                                             availableOffices: offices)
                try MoneyForwardStore.saveState(mfState)
            }
        } catch {
            return MoneyForwardRunOutcome(error: error)
        }
        let today = JST.day(startedAt)
        let startDate = Self.moneyForwardStartDate(bundle: bundle, mapping: mfState.accountMapping, today: today)
        let client = MoneyForwardClient(
            credentialStore: credentialStore,
            transport: transport,
            retryPolicy: retryPolicy
        )

        let pages = BankPages()
        var completed = false
        var timedOut = false
        var failure: (any Error)?
        do {
            let result = try await Self.runWithDeadline(deadline) {
                try await client.fetchAllTransactions(
                    startDate: startDate,
                    endDate: today,
                    perPage: 500,
                    order: "desc",
                    deadline: softDeadline,
                    onPage: { await pages.append($0) }
                )
            }
            completed = result?.reachedDeadline == false
            timedOut = !completed
        } catch MoneyForwardClientError.nightlyMaintenance {
            // The window opened after this run started. Preserve completed pages.
        } catch MoneyForwardClientError.maintenanceOrServerError(statusCode: 503)
            where Self.isNearNightlyMaintenance(at: Date()) {
            // Money Forward can return 503 just before the scheduled window.
        } catch {
            failure = error
        }

        let fetched = await pages.transactions
        if let error = failure as? MoneyForwardClientError {
            if error.requiresReconnect { mfState.reconnectRequired = true }
            if case .forbidden = error { mfState.accessRefusedMessage = error.localizedDescription }
            mfState.lastErrorMessage = Self.moneyForwardDiagnostic(for: error)
        } else if let failure, !(failure is CancellationError) {
            mfState.lastErrorMessage = Self.moneyForwardDiagnostic(for: failure)
        } else if completed {
            mfState.reconnectRequired = false
            mfState.accessRefusedMessage = nil
            mfState.lastErrorMessage = nil
        }

        let previouslySeen = mfState.seenTransactionIDs
        let existing = completed
            ? mfState.transactions.filter { $0.date < startDate || $0.date > today }
            : mfState.transactions
        let notices = await committer.storeState.notices
        let merged = MoneyForwardStore.merge(
            existing: existing, fetched: fetched, bundle: bundle,
            mapping: mfState.accountMapping, notices: notices, today: today
        )
        let changed = merged != mfState.transactions
        let newlySeenIDs = Set(fetched.map(\.id)).subtracting(previouslySeen)

        let wasInitialized = mfState.hasCompletedInitialSync
        mfState.transactions = merged
        // Keep IDs of rows removed from the feed so a later reappearance stays silent.
        mfState.seenTransactionIDs.formUnion(fetched.map(\.id))
        if completed {
            mfState.lastSyncAt = Date()
            mfState.hasCompletedInitialSync = true
        }

        // Silent first sync; afterwards notify on newly confirmed money-in bank items (e.g. salary).
        if wasInitialized,
           LocalDataStore.loadNotificationPreferences().paymentAlertsEnabled,
           let bundle, !newlySeenIDs.isEmpty {
            let layered = BankLayering.build(
                bundle: bundle,
                bankTransactions: merged,
                accountMapping: mfState.accountMapping,
                notices: notices,
                categorizer: Categorizer(rules: bundle.rules),
                config: bundle.layerConfig
            )
            let discreet = Set((bundle.discreetCategories ?? []).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            })
            var moneyInAlerts: [PendingPaymentAlert] = []
            for (item, txID) in zip(layered.bankItems, layered.bankTransactionIDs)
            where newlySeenIDs.contains(txID) && item.amount < 0 {
                let isDiscreet = discreet.contains(
                    item.category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                )
                moneyInAlerts.append(PendingPaymentAlert(
                    messageID: txID,
                    amount: item.amount,
                    merchant: isDiscreet ? "" : item.merchant,
                    sourceLabel: item.source,
                    isDiscreet: isDiscreet,
                    isConfirmed: true
                ))
            }
            do {
                try await committer.enqueueConfirmedBankMoneyIn(moneyInAlerts)
            } catch {
                return MoneyForwardRunOutcome(error: error)
            }
        }

        do {
            try MoneyForwardStore.saveState(mfState)
        } catch {
            return MoneyForwardRunOutcome(error: error)
        }
        return MoneyForwardRunOutcome(
            newTransactions: newlySeenIDs.count,
            timedOut: timedOut,
            stateChanged: changed,
            error: failure
        )
    }

    private static func moneyForwardStartDate(
        bundle: DataBundle?,
        mapping: [String: String],
        today: String
    ) -> String {
        let mappedSources = Set(mapping.values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        let coverageStarts: [String]
        if let bundle {
            let candidateSources = mappedSources.isEmpty ? Set(bundle.coverage.keys) : mappedSources
            coverageStarts = candidateSources.compactMap { source in
                JST.addingDays(-7, to: bundle.coverage[source]?.end ?? bundle.asOf)
            }
        } else {
            coverageStarts = []
        }

        if let earliest = coverageStarts.min() { return min(earliest, today) }
        if let bundle { return min(bundle.asOf, today) }
        return JST.addingDays(-defaultMoneyForwardLookbackDays, to: today) ?? today
    }

    private static func isNearNightlyMaintenance(at date: Date) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = JST.timeZone
        let comps = calendar.dateComponents([.hour, .minute], from: date)
        let minutes = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        // 00:55–06:05 JST
        return (55...365).contains(minutes)
    }

    private static func wallDeadline(_ deadline: ContinuousClock.Instant?, margin: TimeInterval) -> Date? {
        guard let deadline else { return nil }
        let remaining = ContinuousClock.now.duration(to: deadline).components
        return Date().addingTimeInterval(
            Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18 - margin
        )
    }

    private static func isPast(_ deadline: ContinuousClock.Instant?) -> Bool {
        guard let deadline else { return false }
        return ContinuousClock.now >= deadline
    }

    // The run log stays local and never persists raw server text or request URLs.
    private static func diagnostic(for error: any Error) -> String {
        guard let error = error as? GmailClientError else {
            return "Could not read or save sync data."
        }
        switch error {
        case .httpError(let status, _): return "Gmail request failed (HTTP \(status))."
        case .tokenRefreshFailed: return "Could not refresh the Google access token."
        case .networkError: return "Could not reach Gmail."
        default: return error.localizedDescription
        }
    }

    private static func moneyForwardDiagnostic(for error: any Error) -> String {
        guard let mfError = error as? MoneyForwardClientError else {
            return "Money Forward sync failed."
        }
        switch mfError {
        case .invalidCredentials, .unauthorized:
            return "Reconnect Money Forward"
        case .forbidden:
            return "Money Forward refused access (plan or permission, HTTP 403)"
        case .maintenanceOrServerError(let status):
            return "Money Forward unavailable (HTTP \(status))."
        case .rateLimited(let status, _):
            return "Money Forward rate limit reached (HTTP \(status))."
        case .httpError(let status):
            return "Money Forward request failed (HTTP \(status))."
        case .networkError:
            return "Could not reach Money Forward."
        default:
            return mfError.localizedDescription
        }
    }

    private static func runWithDeadline<T: Sendable>(
        _ deadline: ContinuousClock.Instant?,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T? {
        guard let deadline else { return try await operation() }
        let first = await withTaskGroup(of: RaceOutcome<T>.self, returning: RaceOutcome<T>?.self) { group in
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

            let first: RaceOutcome<T>? = await group.next()
            group.cancelAll()
            // Join the cancelled child before returning, so no later run can race a
            // late batch commit or token refresh.
            let second: RaceOutcome<T>? = await group.next()
            if case .some(.timedOut) = first, case .some(.finished(.success(let value))) = second {
                return RaceOutcome<T>.finished(.success(value))
            }
            return first
        }
        switch first {
        case .timedOut:
            try Task.checkCancellation()
            return nil
        case .finished(let result): return try result.get()
        case nil: throw CancellationError()
        }
    }
}
