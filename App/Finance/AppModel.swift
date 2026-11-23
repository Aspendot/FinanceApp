import FinanceCore
import SwiftUI

/// The app's state: the data on the phone, plus the latest import and Gmail results.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var data: FinanceData?
    @Published private(set) var importMessage: String?
    @Published private(set) var syncMessage: String?
    @Published private(set) var syncing = false

    init() {
        data = FinanceData.load()
    }

    func reload() {
        data = FinanceData.load()
        FinanceData.refreshWidget()
    }

    /// Takes in a data file dropped into Documents, if there is a new one.
    func checkInbox() {
        switch BundleInbox.check() {
        case .imported(let generatedAt, let items):
            importMessage = "Imported \(items) payments from the file made "
                + String(generatedAt.prefix(16)).replacingOccurrences(of: "T", with: " ")
            reload()
        case .rejected(let reason):
            importMessage = "Not imported: " + reason
        case .nothingNew:
            break
        }
    }

    /// Fetches new bank emails, if Gmail is set up.
    func syncGmail() async {
        guard !syncing, GmailSync.clientID != nil, (try? GmailSync.hasCredentials()) == true else { return }
        syncing = true
        defer { syncing = false }
        do {
            let fresh = try await GmailSync.run()
            syncMessage = fresh.isEmpty ? "Up to date" : "\(fresh.count) new bank emails"
            reload()
        } catch is CancellationError {
            return
        } catch {
            syncMessage = "Gmail: " + error.localizedDescription
        }
    }
}
