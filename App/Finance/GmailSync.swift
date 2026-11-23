import FinanceCore
import FinanceSync
import Foundation

/// Gmail sign-in and sign-out on the phone.
///
/// The OAuth refresh token lives in the app's own Keychain with
/// `AfterFirstUnlockThisDeviceOnly` so background runs can use it while locked.
/// Incremental syncs run through `SyncEngine`.
@MainActor
enum GmailSync {
    private static let clientIDKey = "googleClientID"
    private static var busy = false
    private static let transport = URLSessionHTTPTransport(session: URLSession(configuration: .ephemeral))

    nonisolated static var clientID: String? {
        let value = UserDefaults.standard.string(forKey: clientIDKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    nonisolated static func hasCredentials() throws -> Bool {
        try KeychainTokenStore().load() != nil
    }

    /// Runs Google's sign-in sheet and stores the OAuth tokens.
    static func signIn(clientID input: String) async throws {
        guard !busy, !(await SyncEngine.shared.isBusy()) else { throw SyncProblem.busy }
        try Task.checkCancellation()
        busy = true
        defer { busy = false }

        let requestedID = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestedID.isEmpty else { throw SyncProblem.noClientID }
        let store = KeychainTokenStore()
        let currentID = clientID
        if try store.load() != nil, let currentID, currentID != requestedID {
            throw SyncProblem.signOutBeforeChangingClientID
        }
        let pkce = try PKCE.generate()
        let state = GoogleOAuth.generateState()
        let url = try GoogleOAuth.authorizationURL(clientID: requestedID, pkce: pkce, state: state)
        let callback = try await WebAuthenticator().authenticate(
            authURL: url,
            callbackScheme: try GoogleOAuth.reversedClientID(for: requestedID)
        )
        let code = try GoogleOAuth.parseCallback(callback, expectedState: state)
        let tokens = try await GoogleOAuth.exchangeAuthorizationCode(
            clientID: requestedID,
            code: code,
            codeVerifier: pkce.verifier,
            redirectURI: try GoogleOAuth.redirectURI(for: requestedID),
            transport: transport
        )
        try Task.checkCancellation()
        // Re-signing in with the same client ID (for example after invalid_grant)
        // preserves previously stored notices.
        if currentID != requestedID {
            SyncStorage.clearState()
        }
        UserDefaults.standard.set(requestedID, forKey: clientIDKey)
        try store.save(tokens)
    }

    static func signOut() async throws {
        guard !busy else { throw SyncProblem.busy }
        busy = true
        defer { busy = false }
        try await SyncEngine.shared.clearForSignOut()
    }

    nonisolated static func recentNotices() -> [Notice] {
        SyncStorage.loadState().notices
    }

    enum SyncProblem: LocalizedError, Sendable {
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
