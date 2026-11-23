import FinanceCore
import SwiftUI

/// The app's state: the data on the phone, plus the latest import and Gmail results.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var data: FinanceData?
    @Published private(set) var importMessage: String?
    @Published private(set) var syncMessage: String?
    @Published private(set) var syncing = false
    @Published private(set) var checkingInbox = false
    @Published private(set) var runLog: [SyncRunRecord] = SyncStorage.loadRunLog()

    private var reloadGeneration = 0

    func reload() async {
        reloadGeneration += 1
        let generation = reloadGeneration
        let notices = GmailSync.recentNotices()
        let latest = await FinanceData.load(notices: notices)
        guard generation == reloadGeneration else { return }
        data = latest
        runLog = SyncStorage.loadRunLog()
        try? await SyncEngine.shared.publishCurrentWidget()
    }

    func refreshRunLog() {
        runLog = SyncStorage.loadRunLog()
    }

    /// Takes in a data file dropped into Documents, if there is a new one.
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

    /// Fetches new bank emails through `SyncEngine`.
    func syncGmail(userInitiated: Bool = false) async {
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }

        let report = await BackgroundAssertion.run(name: "FinanceForegroundSync") {
            await SyncEngine.shared.run(trigger: .app, minimumInterval: 0, timeLimit: 45)
        }

        switch report.outcome {
        case .updated:
            if report.newPayments > 0 {
                let word = report.newPayments == 1 ? "payment" : "payments"
                syncMessage = "\(report.newPayments) new \(word)"
            } else if report.newNotices > 0 {
                let word = report.newNotices == 1 ? "email" : "emails"
                syncMessage = "\(report.newNotices) new bank \(word)"
            } else {
                syncMessage = "Up to date"
            }
        case .skipped:
            syncMessage = "Up to date"
        case .busy:
            syncMessage = "Already checking Gmail"
        case .notSignedIn:
            if userInitiated {
                syncMessage = "Not signed in to Gmail"
            }
        case .signInRequired:
            syncMessage = "Sign in to Gmail again"
        case .timedOut:
            syncMessage = "Time limit reached; progress saved"
        case .cancelled:
            runLog = SyncStorage.loadRunLog()
            return
        case .failed:
            syncMessage = "Gmail: " + (report.errorMessage ?? "Sync failed")
        }

        await reload()
    }
}
