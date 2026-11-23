import FinanceCore
import FinanceSync
import Foundation
import WidgetKit

/// Gmail on the phone: read-only sign-in, then incremental syncs of bank notices.
/// Only parsed notices are kept, never email bodies. The refresh token lives in the
/// app's own Keychain (no shared access group), readable after the first unlock so a
/// background refresh can use it while the phone is locked.
@MainActor
enum GmailSync {
    private static let clientIDKey = "googleClientID"
    private static let stateKey = "gmailSyncState"
    private static let noticesKey = "recentNotices"
    private static let cacheKey = "gmailSyncCache"
    private static var busy = false
    private static let transport = URLSessionHTTPTransport(session: URLSession(configuration: .ephemeral))

    private struct Cache: Codable {
        var state: SyncState
        var notices: [Notice]
    }

    static var clientID: String? {
        let value = UserDefaults.standard.string(forKey: clientIDKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    static func hasCredentials() throws -> Bool {
        try KeychainTokenStore().load() != nil
    }

    /// Runs Google's sign-in sheet and stores the tokens.
    static func signIn(clientID input: String) async throws {
        try begin()
        defer { busy = false }
        let requestedID = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestedID.isEmpty else { throw SyncProblem.noClientID }
        let store = KeychainTokenStore()
        if try store.load() != nil, let currentID = clientID, currentID != requestedID {
            throw SyncProblem.signOutBeforeChangingClientID
        }
        let pkce = try PKCE.generate()
        let state = GoogleOAuth.generateState()
        let url = try GoogleOAuth.authorizationURL(clientID: requestedID, pkce: pkce, state: state)
        let callback = try await WebAuthenticator().authenticate(authURL: url, callbackScheme: try GoogleOAuth.reversedClientID(for: requestedID))
        let code = try GoogleOAuth.parseCallback(callback, expectedState: state)
        let tokens = try await GoogleOAuth.exchangeAuthorizationCode(
            clientID: requestedID, code: code, codeVerifier: pkce.verifier,
            redirectURI: try GoogleOAuth.redirectURI(for: requestedID), transport: transport)
        try Task.checkCancellation()
        clearCache()
        UserDefaults.standard.set(requestedID, forKey: clientIDKey)
        try store.save(tokens)
    }

    static func signOut() throws {
        guard !busy else { throw SyncProblem.busy }
        try KeychainTokenStore().clear()
        clearCache()
    }

    /// Fetches recent bank notices, keeps new notices and updates the widget.
    @discardableResult
    static func run() async throws -> [Notice] {
        try begin()
        defer { busy = false }
        guard let clientID else { throw SyncProblem.noClientID }
        let client = GmailClient(clientID: clientID, tokenStore: KeychainTokenStore(), transport: transport)
        let cache = loadCache()
        let result = try await NoticeSync.sync(client: client, state: cache.state, lookbackDays: 7)
        try Task.checkCancellation()

        let fresh = result.items.compactMap(\.notice)
        var seen = Set<String>()
        let all = (fresh + cache.notices)
            .filter { seen.insert($0.messageID).inserted }
            .sorted { $0.receivedAt > $1.receivedAt }
        let updated = Cache(state: result.state, notices: Array(all.prefix(300)))
        let data = try JSONEncoder().encode(updated)
        UserDefaults.standard.set(data, forKey: cacheKey)
        removeLegacyCache()
        updateWidget(with: all)
        return fresh
    }

    static func recentNotices() -> [Notice] {
        loadCache().notices
    }

    /// With a data file, the widget shows what's left until payday; without one, the
    /// total of the last week's card notices.
    private static func updateWidget(with notices: [Notice]) {
        if BundleInbox.storedData() != nil {
            FinanceData.refreshWidget()
            return
        }
        let now = Date()
        let since = JST.timestamp(now.addingTimeInterval(-7 * 86_400))
        let amounts = notices.filter {
            $0.receivedAt >= since && [.purchase, .refund, .settlement, .cancellation].contains($0.kind)
        }.compactMap(\.amount)
        SharedStore.write(WidgetSnapshot(
            title: "Card notices, 7 days",
            value: "¥" + amounts.reduce(0, +).formatted(),
            detail: "\(amounts.count) notices · " + now.formatted(date: .abbreviated, time: .shortened),
            updatedAt: now))
        WidgetCenter.shared.reloadAllTimelines()
    }

    private static func begin() throws {
        guard !busy else { throw SyncProblem.busy }
        try Task.checkCancellation()
        busy = true
    }

    private static func loadCache() -> Cache {
        let defaults = UserDefaults.standard
        let decoder = JSONDecoder()
        if let data = defaults.data(forKey: cacheKey),
           let cache = try? decoder.decode(Cache.self, from: data) {
            return cache
        }
        let state = defaults.data(forKey: stateKey).flatMap { try? decoder.decode(SyncState.self, from: $0) }
        let notices = defaults.data(forKey: noticesKey).flatMap { try? decoder.decode([Notice].self, from: $0) }
        return Cache(state: state ?? SyncState(), notices: notices ?? [])
    }

    private static func removeLegacyCache() {
        UserDefaults.standard.removeObject(forKey: stateKey)
        UserDefaults.standard.removeObject(forKey: noticesKey)
    }

    private static func clearCache() {
        removeLegacyCache()
        UserDefaults.standard.removeObject(forKey: cacheKey)
        SharedStore.write(.placeholder)
        WidgetCenter.shared.reloadAllTimelines()
    }

    enum SyncProblem: LocalizedError {
        case noClientID
        case busy
        case signOutBeforeChangingClientID

        var errorDescription: String? {
            switch self {
            case .noClientID: return "Paste the Google iOS client ID first."
            case .busy: return "Wait for the current Gmail operation to finish."
            case .signOutBeforeChangingClientID: return "Sign out before changing the Google client ID."
            }
        }
    }
}
