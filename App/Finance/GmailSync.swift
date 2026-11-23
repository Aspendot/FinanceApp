import CryptoKit
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
    private nonisolated static let clientIDKey = "googleClientID"
    private static let transport = URLSessionHTTPTransport(session: URLSession(configuration: .ephemeral))

    nonisolated static var clientID: String? {
        let value = UserDefaults.standard.string(forKey: clientIDKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    nonisolated static func hasCredentials() throws -> Bool {
        try KeychainTokenStore().load() != nil
    }

    nonisolated static func hasDriveScope() -> Bool {
        guard let tokens = try? KeychainTokenStore().load() else { return false }
        return tokens.hasScope(GoogleOAuth.driveAppDataScope)
    }

    /// Runs Google's sign-in sheet and stores the OAuth tokens.
    static func signIn(
        clientID input: String,
        scopes: [String] = [GoogleOAuth.gmailReadOnlyScope],
        includeGrantedScopes: Bool = false
    ) async throws {
        try await SyncEngine.shared.withSignIn {
            try await authorize(
                clientID: input,
                scopes: scopes,
                includeGrantedScopes: includeGrantedScopes
            )
        }
    }

    private static func authorize(
        clientID input: String,
        scopes: [String],
        includeGrantedScopes: Bool
    ) async throws {
        try Task.checkCancellation()
        let requestedID = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestedID.isEmpty else { throw SyncProblem.noClientID }
        let store = KeychainTokenStore()
        let currentID = clientID
        let currentTokens = try store.load()
        if currentTokens != nil, let currentID, currentID != requestedID {
            throw SyncProblem.signOutBeforeChangingClientID
        }
        var currentMailbox = currentTokens?.mailboxFingerprint
        if currentMailbox == nil, let currentTokens, let currentID {
            let client = GmailClient(
                clientID: currentID,
                tokenStore: InMemoryTokenStore(tokens: currentTokens),
                transport: transport
            )
            do {
                currentMailbox = try await mailboxFingerprint(client: client)
            } catch let error as GmailClientError where error.requiresSignInAgain {
                // Older versions did not store a mailbox binding.
            }
        }
        let pkce = try PKCE.generate()
        let state = GoogleOAuth.generateState()
        let url = try GoogleOAuth.authorizationURL(
            clientID: requestedID,
            pkce: pkce,
            state: state,
            scopes: scopes,
            includeGrantedScopes: includeGrantedScopes
        )
        let callback = try await WebAuthenticator().authenticate(
            authURL: url,
            callbackScheme: try GoogleOAuth.reversedClientID(for: requestedID)
        )
        let code = try GoogleOAuth.parseCallback(callback, expectedState: state)
        let exchanged = try await GoogleOAuth.exchangeAuthorizationCode(
            clientID: requestedID,
            code: code,
            codeVerifier: pkce.verifier,
            redirectURI: try GoogleOAuth.redirectURI(for: requestedID),
            transport: transport
        )
        let candidate = InMemoryTokenStore(tokens: exchanged)
        let client = GmailClient(
            clientID: requestedID,
            tokenStore: candidate,
            transport: transport
        )
        let mailbox = try await mailboxFingerprint(client: client)
        if let currentMailbox, currentMailbox != mailbox {
            throw SyncProblem.signOutBeforeChangingMailbox
        }
        var tokens = try await candidate.load() ?? exchanged
        try Task.checkCancellation()
        if currentTokens == nil {
            try SyncStorage.clearState()
        }
        if tokens.refreshToken == nil, currentMailbox == mailbox {
            tokens.refreshToken = currentTokens?.refreshToken
        }
        if tokens.scope == nil, currentMailbox == mailbox {
            tokens.scope = currentTokens?.scope
        }
        tokens.mailboxFingerprint = mailbox
        UserDefaults.standard.set(requestedID, forKey: clientIDKey)
        try store.save(tokens)
    }

    static func signOut() async throws {
        try await SyncEngine.shared.clearForSignOut()
    }

    nonisolated static func mailboxFingerprint(client: GmailClient) async throws -> String {
        let address = try await client.profileEmail()
        return Data(SHA256.hash(data: Data(address.lowercased().utf8))).base64EncodedString()
    }

    nonisolated static func recentNotices() -> [Notice] {
        guard (try? hasCredentials()) == true else { return [] }
        return (try? SyncStorage.loadState().notices) ?? []
    }

    enum SyncProblem: LocalizedError, Sendable {
        case noClientID
        case busy
        case signOutBeforeChangingClientID
        case signOutBeforeChangingMailbox

        var errorDescription: String? {
            switch self {
            case .noClientID: return "Paste the Google iOS client ID first."
            case .busy: return "Wait for the current Gmail operation to finish."
            case .signOutBeforeChangingClientID: return "Sign out before changing the Google client ID."
            case .signOutBeforeChangingMailbox: return "Sign out before switching Gmail accounts."
            }
        }
    }
}
