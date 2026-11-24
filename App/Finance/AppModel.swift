import FinanceCore
import SwiftUI

/// The app's state: the data on the phone, local modifications, notification prefs,
/// and the latest import and sync results.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var data: FinanceData?
    @Published private(set) var importMessage: String?
    @Published private(set) var syncMessage: String?
    @Published private(set) var syncing = false
    @Published private(set) var checkingInbox = false
    @Published private(set) var runLog: [SyncRunRecord] = SyncStorage.loadRunLog()
    @Published private(set) var moneyForwardState: MoneyForwardState = (try? MoneyForwardStore.loadState()) ?? MoneyForwardState()
    @Published private(set) var driveState: DriveSyncState = (try? DriveSyncStore.loadState()) ?? DriveSyncState()
    @Published private(set) var localModifications: LocalModifications = LocalDataStore.loadModifications()
    @Published private(set) var notificationPreferences: NotificationPreferences = LocalDataStore.loadNotificationPreferences()
    @Published private(set) var gmailConnected: Bool = (try? GmailSync.hasCredentials()) == true
    @Published private(set) var gmailLastSyncAt: Date? = (try? SyncStorage.loadState().syncState.lastSyncAt) ?? nil
    @Published private(set) var moneyForwardConnected: Bool = MoneyForwardSync.hasCredentials()
    @Published private(set) var driveKeyPaired: Bool = DriveSync.hasKey()
    @Published private(set) var driveScopeGranted: Bool = GmailSync.hasDriveScope()

    private var reloadGeneration = 0

    func reload() async {
        reloadGeneration += 1
        let generation = reloadGeneration
        let notices = GmailSync.recentNotices()
        let mfState = (try? MoneyForwardStore.loadState()) ?? MoneyForwardState()
        let mods = LocalDataStore.loadModifications()
        let prefs = LocalDataStore.loadNotificationPreferences()
        let latest = await FinanceData.load(
            notices: notices,
            bankTransactions: mfState.transactions,
            accountMapping: mfState.accountMapping,
            localModifications: mods
        )
        guard generation == reloadGeneration else { return }
        localModifications = mods
        notificationPreferences = prefs
        data = latest
        refreshConnectionStates()
        try? await SyncEngine.shared.publishCurrentWidget()
        if let latest {
            await BillReminderScheduler.sync(timeline: latest.timeline, preferences: prefs)
        }
    }

    func refreshRunLog() {
        runLog = SyncStorage.loadRunLog()
        refreshConnectionStates()
    }

    func refreshConnectionStates() {
        runLog = SyncStorage.loadRunLog()
        moneyForwardState = (try? MoneyForwardStore.loadState()) ?? MoneyForwardState()
        driveState = (try? DriveSyncStore.loadState()) ?? DriveSyncState()
        gmailConnected = (try? GmailSync.hasCredentials()) == true
        gmailLastSyncAt = try? SyncStorage.loadState().syncState.lastSyncAt
        moneyForwardConnected = MoneyForwardSync.hasCredentials()
        driveKeyPaired = DriveSync.hasKey()
        driveScopeGranted = GmailSync.hasDriveScope()
    }

    var gmailStatusLine: String {
        guard gmailConnected else { return "Not connected" }
        if let latestRun = runLog.first, latestRun.outcome == .signInRequired {
            return "Sign in again"
        }
        if let last = gmailLastSyncAt {
            return "Connected · updated \(SyncStorage.formatCheckTime(last))"
        }
        return "Connected"
    }

    var moneyForwardStatusLine: String {
        guard moneyForwardConnected else { return "Not connected" }
        if moneyForwardState.reconnectRequired {
            return "Reconnect Money Forward"
        }
        if let refused = moneyForwardState.accessRefusedMessage, !refused.isEmpty {
            return "Access refused"
        }
        if moneyForwardState.officeCode == nil, moneyForwardState.availableOffices.count > 1 {
            return "Choose an office"
        }
        if let last = moneyForwardState.lastSyncAt {
            return "Connected · updated \(SyncStorage.formatCheckTime(last))"
        }
        return "Connected"
    }

    var driveStatusLine: String {
        guard gmailConnected else { return "Not connected" }
        if driveState.needsDriveConsent || !driveScopeGranted {
            return driveKeyPaired ? "Turn on Drive access" : "Not connected"
        }
        guard driveKeyPaired else { return "Needs pairing key" }
        if let last = driveState.lastCheckedAt {
            return "Connected · updated \(SyncStorage.formatCheckTime(last))"
        }
        return "Connected"
    }

    // MARK: - Local entries, CSV import, overrides, checkoffs, reminders, two-way Drive push

    private func persistModificationsAndPush(_ mutate: (inout LocalModifications) -> Void) async throws {
        var mods = LocalDataStore.loadModifications()
        mutate(&mods)
        mods.updatedAt = Date()
        try LocalDataStore.saveModifications(mods)
        await reload()
        scheduleBackgroundPhoneEditsPush()
    }

    private func scheduleBackgroundPhoneEditsPush() {
        guard gmailConnected && driveKeyPaired && driveScopeGranted else { return }
        Task.detached(priority: .utility) {
            _ = await SyncEngine.shared.pushLocalModificationsNow(force: false)
            await MainActor.run {
                self.refreshConnectionStates()
            }
        }
    }

    func pushPhoneEditsNow() async -> String {
        let result = await SyncEngine.shared.pushLocalModificationsNow(force: true)
        refreshConnectionStates()
        switch result {
        case .success(.pushed(let bytes)):
            return "Synced phone edits to Drive (\(bytes.formatted()) B)"
        case .success(.unchanged):
            return "Phone edits already up to date"
        case .success(.needsConsent):
            return "Grant Google Drive access first"
        case .failure(let error):
            return DriveSync.diagnostic(for: error)
        }
    }

    func addManualEntry(_ entry: ManualEntry) async throws {
        let config = data?.bundle.layerConfig ?? LayerConfig()
        let layers = data?.bundle.layers ?? []
        let fp = CategoryOverride.transactionFingerprint(for: entry.asBudgetItem(config: config, layers: layers))
        try await persistModificationsAndPush { mods in
            mods.deletedEntryFingerprints.remove(fp)
            mods.manualEntries.insert(entry, at: 0)
        }
    }

    func addManualEntries(_ entries: [ManualEntry]) async throws {
        guard !entries.isEmpty else { return }
        let config = data?.bundle.layerConfig ?? LayerConfig()
        let layers = data?.bundle.layers ?? []
        let fps = entries.map { CategoryOverride.transactionFingerprint(for: $0.asBudgetItem(config: config, layers: layers)) }
        try await persistModificationsAndPush { mods in
            for fp in fps { mods.deletedEntryFingerprints.remove(fp) }
            mods.manualEntries.insert(contentsOf: entries, at: 0)
        }
    }

    func deleteLocalEntry(id: UUID) async throws {
        let config = data?.bundle.layerConfig ?? LayerConfig()
        let layers = data?.bundle.layers ?? []
        try await persistModificationsAndPush { mods in
            let targets = mods.manualEntries.filter { $0.id == id } + mods.importedEntries.filter { $0.id == id }
            for entry in targets {
                let fp = CategoryOverride.transactionFingerprint(for: entry.asBudgetItem(config: config, layers: layers))
                mods.deletedEntryFingerprints.insert(fp)
            }
            mods.manualEntries.removeAll { $0.id == id }
            mods.importedEntries.removeAll { $0.id == id }
        }
    }

    func importPayPayCSV(url: URL) async throws -> PayPayImportResult {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let rawData = try Data(contentsOf: url)
        guard let text = String(data: rawData, encoding: .utf8)
                ?? String(data: rawData, encoding: .shiftJIS)
        else {
            throw PayPayCSVError.emptyFile
        }
        return try await importPayPayCSV(text: text)
    }

    func importPayPayCSV(text: String) async throws -> PayPayImportResult {
        let currentMods = LocalDataStore.loadModifications()
        let categorizer = Categorizer(rules: data?.bundle.rules ?? RuleSet())
        let existingItems = data?.allItems ?? []
        let existingIDs = Set(currentMods.importedEntries.compactMap(\.externalID))
        let peopleGroup = data?.bundle.layerConfig.peopleGroup ?? "People"

        let result = try PayPayCSVParser.parse(
            csvText: text,
            categorizer: categorizer,
            existingItems: existingItems,
            existingExternalIDs: existingIDs,
            peopleGroup: peopleGroup
        )
        if !result.entries.isEmpty {
            try await persistModificationsAndPush { mods in
                mods.importedEntries.append(contentsOf: result.entries)
            }
        }
        return result
    }

    func setCategoryOverride(
        for item: BudgetItem,
        group: String,
        category: String,
        applyToAllFromMerchant: Bool
    ) async throws {
        let folded = TextFold.key(item.merchant)
        let fp = CategoryOverride.transactionFingerprint(for: item)
        try await persistModificationsAndPush { mods in
            if applyToAllFromMerchant {
                mods.categoryOverrides.removeAll {
                    if case .merchant(let key, _) = $0.scope { return key == folded }
                    return false
                }
                mods.categoryOverrides.append(CategoryOverride(
                    scope: .merchant(foldedKey: folded, displayMerchant: item.merchant),
                    group: group,
                    category: category
                ))
            } else {
                mods.categoryOverrides.removeAll {
                    if case .transaction(let existingFP, _, _, _) = $0.scope { return existingFP == fp }
                    return false
                }
                mods.categoryOverrides.append(CategoryOverride(
                    scope: .transaction(
                        fingerprint: fp,
                        displayMerchant: item.merchant,
                        date: item.date,
                        amount: item.amount
                    ),
                    group: group,
                    category: category
                ))
            }
        }
    }

    func excludeAsNonSpending(item: BudgetItem, categoryLabel: String = "Excluded") async throws {
        let excludedGroup = data?.bundle.layerConfig.resolvedExcludedGroup ?? "Excluded"
        try await setCategoryOverride(
            for: item,
            group: excludedGroup,
            category: categoryLabel,
            applyToAllFromMerchant: false
        )
    }

    func tagAsWorkExpense(item: BudgetItem, categoryLabel: String = "Work expense") async throws {
        let workGroup = data?.bundle.layerConfig.resolvedWorkGroup ?? "Work"
        try await setCategoryOverride(
            for: item,
            group: workGroup,
            category: categoryLabel,
            applyToAllFromMerchant: false
        )
    }

    func removeCategoryOverride(id: UUID) async throws {
        try await persistModificationsAndPush { mods in
            mods.categoryOverrides.removeAll { $0.id == id }
        }
    }

    func setTargetOverride(category: String, target: Int?) async throws {
        try await persistModificationsAndPush { mods in
            if let target {
                mods.targetOverrides[category] = max(0, target)
            } else {
                mods.targetOverrides.removeValue(forKey: category)
            }
        }
    }

    func setDebtBalanceOverride(debtName: String, balance: Int?) async throws {
        try await persistModificationsAndPush { mods in
            if let balance {
                mods.debtBalanceOverrides[debtName] = max(0, balance)
            } else {
                mods.debtBalanceOverrides.removeValue(forKey: debtName)
            }
        }
    }

    func addCustomReminder(_ reminder: CustomReminder) async throws {
        try await persistModificationsAndPush { mods in
            mods.customReminders.append(reminder)
        }
    }

    func removeCustomReminder(id: UUID) async throws {
        try await persistModificationsAndPush { mods in
            mods.customReminders.removeAll { $0.id == id }
        }
    }

    func markReviewed(keys: [String]) async {
        guard !keys.isEmpty else { return }
        try? await persistModificationsAndPush { mods in
            for k in keys {
                mods.reviewedItemKeys.insert(k)
            }
        }
    }

    func toggleBillCheckoff(for entry: TimelineEntry) async {
        let key = BillCheckoff.key(for: entry)
        try? await persistModificationsAndPush { mods in
            if mods.billCheckoffs.contains(where: { $0.key == key }) {
                mods.billCheckoffs.removeAll { $0.key == key }
            } else {
                mods.billCheckoffs.append(BillCheckoff(key: key))
            }
        }
    }

    func dismissAlert(id: String) async {
        try? await persistModificationsAndPush { mods in
            mods.dismissedAlertIDs.insert(id)
        }
    }

    func restoreDismissedAlerts() async {
        try? await persistModificationsAndPush { mods in
            mods.dismissedAlertIDs.removeAll()
        }
    }

    func updateNotificationPreferences(_ prefs: NotificationPreferences) async {
        notificationPreferences = prefs
        try? LocalDataStore.saveNotificationPreferences(prefs)
        if let data {
            await BillReminderScheduler.sync(timeline: data.timeline, preferences: prefs)
        }
    }

    func exportEncryptedBackup(passphrase: String) throws -> Data {
        let mods = LocalDataStore.loadModifications()
        return try LocalBackupCodec.seal(mods, passphrase: passphrase)
    }

    func restoreEncryptedBackup(from url: URL, passphrase: String) async throws -> LocalModifications {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let bytes = try Data(contentsOf: url)
        let restored = try LocalBackupCodec.open(bytes, passphrase: passphrase)
        try LocalDataStore.saveModifications(restored)
        await reload()
        scheduleBackgroundPhoneEditsPush()
        return restored
    }

    func exportLocalChangesJSON() throws -> Data {
        let mods = LocalDataStore.loadModifications()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(mods)
    }

    /// Takes in a data file dropped into Documents as a manual fallback, if there is a new one.
    func checkInbox() async {
        guard !checkingInbox else { return }
        checkingInbox = true
        defer { checkingInbox = false }
        let outcome = await Task.detached(priority: .utility) { await BundleInbox.check() }.value
        switch outcome {
        case .imported(let generatedAt, let items, let cleanupFailed):
            importMessage = "Imported \(items) payments from the file made "
                + String(generatedAt.prefix(16)).replacingOccurrences(of: "T", with: " ")
                + (cleanupFailed ? ". Remove the remaining copy from Finance’s Documents folder." : "")
        case .rejected(let reason):
            importMessage = "Not imported: " + reason
        case .nothingNew:
            break
        }
        await reload()
    }

    /// Runs the full sync pipeline (Drive bundle, Gmail notices, Money Forward) through `SyncEngine`.
    func syncGmail(userInitiated: Bool = false) async {
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }

        let report = await BackgroundAssertion.run(name: "FinanceForegroundSync") {
            await SyncEngine.shared.run(trigger: .app, minimumInterval: 0, timeLimit: 45)
        }

        switch report.outcome {
        case .updated:
            var parts: [String] = []
            if report.driveImported {
                parts.append("new data file")
            }
            if report.newBankTransactions > 0 {
                let word = report.newBankTransactions == 1 ? "bank transaction" : "bank transactions"
                parts.append("\(report.newBankTransactions) \(word)")
            }
            if report.newPayments > 0 {
                let word = report.newPayments == 1 ? "payment" : "payments"
                parts.append("\(report.newPayments) new \(word)")
            } else if report.newNotices > 0 {
                let word = report.newNotices == 1 ? "email" : "emails"
                parts.append("\(report.newNotices) new bank \(word)")
            }
            if !parts.isEmpty {
                syncMessage = parts.joined(separator: " · ")
            } else if let warning = report.errorMessage, !warning.isEmpty {
                syncMessage = warning
            } else {
                syncMessage = "Up to date"
            }
        case .skipped:
            syncMessage = "Up to date"
        case .busy:
            syncMessage = "Sync already running"
        case .notSignedIn:
            if userInitiated {
                syncMessage = "No accounts connected"
            }
        case .signInRequired:
            syncMessage = "Sign in to Gmail again"
        case .timedOut:
            syncMessage = "Time limit reached; progress saved"
        case .cancelled:
            refreshConnectionStates()
            return
        case .failed:
            syncMessage = report.errorMessage ?? "Sync failed"
        }

        await reload()
    }
}
