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

    private var reloadGeneration = 0

    func reload() async {
        reloadGeneration += 1
        let generation = reloadGeneration
        let latest = await FinanceData.load(notices: GmailSync.recentNotices())
        guard generation == reloadGeneration else { return }
        data = latest
        if let latest { FinanceData.publishWidget(latest.widgetSnapshot) }
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

    /// Fetches new bank emails, if Gmail is set up.
    func syncGmail() async {
        guard !syncing, GmailSync.clientID != nil, (try? GmailSync.hasCredentials()) == true else { return }
        syncing = true
        defer { syncing = false }
        do {
            let fresh = try await GmailSync.run(updateWidget: false)
            syncMessage = fresh.isEmpty ? "Up to date" : "\(fresh.count) new bank emails"
            await reload()
            if data == nil { GmailSync.publishNoticeWidget(with: GmailSync.recentNotices()) }
        } catch is CancellationError {
            return
        } catch {
            syncMessage = "Gmail: " + error.localizedDescription
        }
    }
}
