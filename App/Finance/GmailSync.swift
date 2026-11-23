import FinanceCore
import FinanceSync
import Foundation
import WidgetKit

/// Gmail on the phone: read-only sign-in, then incremental syncs of bank notices.
/// Only parsed notices are kept, never email bodies. The refresh token lives in the
/// app's own Keychain (no shared access group), readable after the first unlock so a
/// background refresh can use it while the phone is locked.
enum GmailSync {
    private static let clientIDKey = "googleClientID"
    private static let stateKey = "gmailSyncState"
    private static let noticesKey = "recentNotices"

    static var clientID: String? {
        let value = UserDefaults.standard.string(forKey: clientIDKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    static func setClientID(_ value: String) {
        UserDefaults.standard.set(value.trimmingCharacters(in: .whitespacesAndNewlines), forKey: clientIDKey)
    }

    static var isSignedIn: Bool {
        ((try? KeychainTokenStore().load()) ?? nil) != nil
    }

    /// Runs Google's sign-in sheet and stores the tokens.
    @MainActor
    static func signIn() async throws {
        guard let clientID else { throw SyncProblem.noClientID }
        let pkce = try PKCE.generate()
        let state = GoogleOAuth.generateState()
        let url = try GoogleOAuth.authorizationURL(clientID: clientID, pkce: pkce, state: state)
        let callback = try await WebAuthenticator().authenticate(authURL: url, callbackScheme: try GoogleOAuth.reversedClientID(for: clientID))
        let code = try GoogleOAuth.parseCallback(callback, expectedState: state)
        let tokens = try await GoogleOAuth.exchangeAuthorizationCode(
            clientID: clientID, code: code, codeVerifier: pkce.verifier,
            redirectURI: try GoogleOAuth.redirectURI(for: clientID), transport: URLSessionHTTPTransport())
        try KeychainTokenStore().save(tokens)
    }

    static func signOut() {
        try? KeychainTokenStore().clear()
        UserDefaults.standard.removeObject(forKey: stateKey)
    }

    /// Fetches bank notices from the last `days` days that weren't seen before, keeps
    /// them, and updates the widget. Returns only the new notices.
    @discardableResult
    static func run(days: Int) async throws -> [Notice] {
        guard let clientID else { throw SyncProblem.noClientID }
        let client = GmailClient(clientID: clientID, tokenStore: KeychainTokenStore())
        let result = try await NoticeSync.sync(client: client, state: loadState(), lookbackDays: days)
        save(result.state, forKey: stateKey)
        let fresh = result.items.compactMap(\.notice)
        let all = (fresh + recentNotices()).sorted { $0.receivedAt > $1.receivedAt }
        save(Array(all.prefix(300)), forKey: noticesKey)
        updateWidget(with: all)
        return fresh
    }

    static func recentNotices() -> [Notice] {
        guard let data = UserDefaults.standard.data(forKey: noticesKey) else { return [] }
        return (try? JSONDecoder().decode([Notice].self, from: data)) ?? []
    }

    /// Card spending in the last 7 days, as the widget shows it. Declines, top-ups,
    /// bills, card checks and account moves are not spending.
    static func weekSpending(_ notices: [Notice], now: Date = Date()) -> (total: Int, count: Int) {
        let since = JST.timestamp(now.addingTimeInterval(-7 * 86_400))
        let spending = notices.filter { [.purchase, .refund, .settlement, .cancellation].contains($0.kind) && $0.receivedAt >= since }
        return (spending.compactMap(\.amount).reduce(0, +), spending.count)
    }

    static func updateWidget(with notices: [Notice]) {
        let week = weekSpending(notices)
        SharedStore.write(WidgetSnapshot(
            title: "Card spending, 7 days",
            value: "¥" + week.total.formatted(),
            detail: "\(week.count) payments · " + Date().formatted(date: .omitted, time: .shortened),
            updatedAt: Date()))
        WidgetCenter.shared.reloadAllTimelines()
    }

    private static func loadState() -> SyncState {
        guard let data = UserDefaults.standard.data(forKey: stateKey) else { return SyncState() }
        return (try? JSONDecoder().decode(SyncState.self, from: data)) ?? SyncState()
    }

    private static func save<T: Encodable>(_ value: T, forKey key: String) {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    enum SyncProblem: LocalizedError {
        case noClientID
        var errorDescription: String? { "Paste the Google iOS client ID first." }
    }
}
