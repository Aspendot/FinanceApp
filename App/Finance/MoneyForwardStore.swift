import FinanceCore
import FinanceSync
import Foundation

/// Persisted Money Forward transactions, connected accounts, account-to-source mapping and sync state.
struct MoneyForwardState: Codable, Equatable, Sendable {
    var transactions: [BankTransaction] = []
    var connectedAccounts: [MoneyForwardConnectedAccount] = []
    /// Maps a Money Forward sub-account ID or connected account ID to a bundle source key.
    /// Omitted or empty entries are ignored.
    var accountMapping: [String: String] = [:]
    var officeCode: String? = nil
    var officeName: String? = nil
    var availableOffices: [MoneyForwardOffice] = []
    var lastSyncAt: Date? = nil
    var seenTransactionIDs: Set<String> = []
    var hasCompletedInitialSync: Bool = false
    var reconnectRequired: Bool = false
    var accessRefusedMessage: String? = nil
    var lastErrorMessage: String? = nil
}

/// App-local atomic storage for Money Forward transactions and mappings.
///
/// Secrets (API key, JWT, OAuth client secret and tokens) live exclusively in the Keychain
/// via `KeychainMoneyForwardCredentialStore`, never here or in `UserDefaults`.
enum MoneyForwardStore {
    static let retentionDays = 120

    private static var dataDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FinanceData", isDirectory: true)
    }

    private static var stateURL: URL {
        dataDirectory.appendingPathComponent("moneyforward-state.json")
    }

    static func loadState() throws -> MoneyForwardState {
        do {
            let data = try Data(contentsOf: stateURL)
            return try JSONDecoder().decode(MoneyForwardState.self, from: data)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return MoneyForwardState()
        }
    }

    static func saveState(_ state: MoneyForwardState) throws {
        var folder = dataDirectory
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        let data = try JSONEncoder().encode(state)
        try data.write(to: stateURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func clearState() throws {
        do {
            try FileManager.default.removeItem(at: stateURL)
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            // Nothing stored yet.
        }
    }

    /// Retains recent rows and any mapped bank history still ahead of the bundle.
    static func merge(
        existing: [BankTransaction],
        fetched: [BankTransaction],
        bundle: DataBundle?,
        mapping: [String: String],
        notices: [Notice],
        today: String
    ) -> [BankTransaction] {
        let cutoff = JST.addingDays(-retentionDays, to: today)
        var oldestCrossSourceNotice: [String: String] = [:]
        if let bundle, let matches = bundle.noticeSourceMatches {
            for notice in notices where notice.amount != nil {
                let source = notice.source.rawValue
                if let coverage = bundle.coverage[source], notice.day < coverage.end { continue }
                for target in matches[source] ?? [] {
                    oldestCrossSourceNotice[target] = min(oldestCrossSourceNotice[target] ?? notice.day, notice.day)
                }
            }
        }
        var byID: [String: BankTransaction] = [:]
        for tx in existing {
            byID[tx.id] = tx
        }
        for tx in fetched {
            byID[tx.id] = tx
        }
        return byID.values
            .filter { tx in
                guard let cutoff, tx.date < cutoff else { return true }
                guard let bundle, let source = tx.mappedSource(using: mapping) else { return false }
                if let oldest = oldestCrossSourceNotice[source], tx.date >= oldest { return true }
                return tx.date > (bundle.coverage[source]?.end ?? bundle.asOf)
            }
            .sorted { ($0.date, $0.id) > ($1.date, $1.id) }
    }
}

/// Manages connecting, office selection, account mapping and disconnecting Money Forward.
@MainActor
enum MoneyForwardSync {
    private static let transport = URLSessionHTTPTransport(session: URLSession(configuration: .ephemeral))

    nonisolated static func hasCredentials() -> Bool {
        (try? KeychainMoneyForwardCredentialStore().load()) != nil
    }

    nonisolated static func currentAuthMode() -> MoneyForwardAuthMode? {
        (try? KeychainMoneyForwardCredentialStore().load())?.mode
    }

    /// Connects with an App Portal API key, auto-discovering accessible offices via
    /// `GET /api/v3/accessible_offices`.
    ///
    /// When exactly one office is returned, it is selected automatically and its
    /// connected accounts are fetched right away. When several offices are returned,
    /// they are stored so the owner can pick one.
    static func connectAPIKey(_ rawKey: String) async throws -> [MoneyForwardOffice] {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw Problem.emptyAPIKey }

        return try await SyncEngine.shared.withSignIn {
            let tempStore = InMemoryMoneyForwardCredentialStore(
                credentials: MoneyForwardCredentials(
                    apiKey: MoneyForwardAPIKeyCredentials(apiKey: key)
                )
            )
            let client = MoneyForwardClient(credentialStore: tempStore, transport: transport)
            let offices = try await client.listAccessibleOffices()
            guard !offices.isEmpty else { throw Problem.noAccessibleOffices }

            var creds = try await tempStore.load()
                ?? MoneyForwardCredentials(apiKey: MoneyForwardAPIKeyCredentials(apiKey: key))
            var state = (try? MoneyForwardStore.loadState()) ?? MoneyForwardState()
            state.availableOffices = offices
            state.reconnectRequired = false
            state.accessRefusedMessage = nil
            state.lastErrorMessage = nil

            if offices.count == 1, let only = offices.first {
                if state.officeCode != only.code { state = MoneyForwardState(availableOffices: offices) }
                creds.apiKey?.officeCode = only.code
                try await tempStore.save(creds)
                let accounts = try await client.listConnectedAccounts(officeCode: only.code)
                state.officeCode = only.code
                state.officeName = only.name
                state.connectedAccounts = accounts
            } else if let existingCode = state.officeCode,
                      let matched = offices.first(where: { $0.code == existingCode })
            {
                creds.apiKey?.officeCode = matched.code
                try await tempStore.save(creds)
                let accounts = try await client.listConnectedAccounts(officeCode: matched.code)
                state.officeName = matched.name
                state.connectedAccounts = accounts
            } else {
                state = MoneyForwardState(availableOffices: offices)
            }

            let finalCreds = try await tempStore.load() ?? creds
            try saveConnection(finalCreds, state: state)
            return offices
        }
    }

    /// Selects one office from `availableOffices` (for multi-office API keys) and loads its accounts.
    static func selectOffice(_ office: MoneyForwardOffice) async throws {
        try await SyncEngine.shared.withSignIn {
            let keychain = KeychainMoneyForwardCredentialStore()
            guard var creds = try keychain.load(), creds.mode == .apiKey, creds.apiKey != nil else {
                throw MoneyForwardClientError.notConnected
            }
            creds.apiKey?.officeCode = office.code
            let tempStore = InMemoryMoneyForwardCredentialStore(credentials: creds)
            let client = MoneyForwardClient(credentialStore: tempStore, transport: transport)
            let accounts = try await client.listConnectedAccounts(officeCode: office.code)

            var state = try MoneyForwardStore.loadState()
            if state.officeCode != office.code { state = MoneyForwardState(availableOffices: state.availableOffices) }
            state.officeCode = office.code
            state.officeName = office.name
            state.connectedAccounts = accounts
            state.reconnectRequired = false
            state.accessRefusedMessage = nil
            state.lastErrorMessage = nil
            let updated = try await tempStore.load() ?? creds
            try saveConnection(updated, state: state)
        }
    }

    private static func saveConnection(_ creds: MoneyForwardCredentials, state: MoneyForwardState) throws {
        let keychain = KeychainMoneyForwardCredentialStore()
        let previous = try keychain.load()
        try keychain.save(creds)
        do {
            try MoneyForwardStore.saveState(state)
        } catch {
            if let previous { try keychain.save(previous) } else { try keychain.clear() }
            throw error
        }
    }

    /// Optional OAuth 2.0 sign-in using `ASWebAuthenticationSession` with a custom scheme and PKCE.
    static func connectOAuth(
        clientID rawClientID: String,
        clientSecret rawSecret: String,
        redirectURI rawRedirect: String = MoneyForwardAuth.defaultRedirectURI
    ) async throws {
        let clientID = rawClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = rawSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        let redirect = rawRedirect.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty, !secret.isEmpty else {
            throw Problem.missingOAuthCredentials
        }
        guard let parsedRedirect = URL(string: redirect), let scheme = parsedRedirect.scheme, !scheme.isEmpty else {
            throw Problem.invalidRedirectURI
        }

        try await SyncEngine.shared.withSignIn {
            let pkce = try PKCE.generate()
            let stateToken = GoogleOAuth.generateState()
            let authURL = try MoneyForwardAuth.authorizationURL(
                clientID: clientID,
                redirectURI: redirect,
                pkce: pkce,
                state: stateToken
            )
            let callback = try await WebAuthenticator().authenticate(
                authURL: authURL,
                callbackScheme: scheme
            )
            let code = try MoneyForwardAuth.parseCallback(callback, expectedState: stateToken)
            let config = MoneyForwardOAuthConfig(
                clientID: clientID,
                clientSecret: secret,
                redirectURI: redirect
            )
            let tokens = try await MoneyForwardAuth.exchangeAuthorizationCode(
                config: config,
                code: code,
                codeVerifier: pkce.verifier,
                transport: transport
            )
            let creds = MoneyForwardCredentials(oauthConfig: config, oauthTokens: tokens)
            let tempStore = InMemoryMoneyForwardCredentialStore(credentials: creds)
            let client = MoneyForwardClient(credentialStore: tempStore, transport: transport)
            let accounts = try await client.listConnectedAccounts()
            let office = try? await client.currentOffice()

            let finalCreds = try await tempStore.load() ?? creds
            var state = try MoneyForwardStore.loadState()
            if office == nil || state.officeCode != office?.code { state = MoneyForwardState() }
            state.officeCode = office?.code
            state.officeName = office?.name
            state.availableOffices = office.map { [$0] } ?? []
            state.connectedAccounts = accounts
            state.reconnectRequired = false
            state.accessRefusedMessage = nil
            state.lastErrorMessage = nil
            try saveConnection(finalCreds, state: state)
        }
    }

    /// Refreshes the list of connected accounts from Money Forward without wiping stored data.
    static func refreshConnectedAccounts() async throws {
        try await SyncEngine.shared.withSignIn {
            let keychain = KeychainMoneyForwardCredentialStore()
            let client = MoneyForwardClient(credentialStore: keychain, transport: transport)
            do {
                let accounts = try await client.listConnectedAccounts()
                var state = (try? MoneyForwardStore.loadState()) ?? MoneyForwardState()
                state.connectedAccounts = accounts
                state.reconnectRequired = false
                state.accessRefusedMessage = nil
                state.lastErrorMessage = nil
                try MoneyForwardStore.saveState(state)
            } catch let error as MoneyForwardClientError {
                var state = (try? MoneyForwardStore.loadState()) ?? MoneyForwardState()
                if error.requiresReconnect {
                    state.reconnectRequired = true
                    state.lastErrorMessage = "Reconnect Money Forward"
                } else if case .forbidden = error {
                    state.accessRefusedMessage = error.localizedDescription
                    state.lastErrorMessage = error.localizedDescription
                } else {
                    state.lastErrorMessage = error.localizedDescription
                }
                try? MoneyForwardStore.saveState(state)
                throw error
            }
        }
    }

    /// Saves a single account-to-source mapping entry:
    /// - `nil` removes the key (sub-accounts inherit their parent mapping).
    /// - `""` stores an explicit ignore entry so a sub-account does not fall back to its parent.
    static func setMapping(accountID: String, sourceKey: String?) async throws {
        try await SyncEngine.shared.withSignIn {
            var state = (try? MoneyForwardStore.loadState()) ?? MoneyForwardState()
            if let sourceKey {
                state.accountMapping[accountID] = sourceKey.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                state.accountMapping.removeValue(forKey: accountID)
            }
            try MoneyForwardStore.saveState(state)
        }
    }

    /// Removes Money Forward credentials from the Keychain and clears local Money Forward state.
    static func disconnect() async throws {
        try await SyncEngine.shared.withSignIn {
            try KeychainMoneyForwardCredentialStore().clear()
            try MoneyForwardStore.clearState()
        }
    }

    enum Problem: LocalizedError, Sendable {
        case emptyAPIKey
        case noAccessibleOffices
        case missingOAuthCredentials
        case invalidRedirectURI

        var errorDescription: String? {
            switch self {
            case .emptyAPIKey:
                return "Paste your Money Forward API key first."
            case .noAccessibleOffices:
                return "No accessible Money Forward office was found for this API key."
            case .missingOAuthCredentials:
                return "Enter both the OAuth client ID and client secret."
            case .invalidRedirectURI:
                return "Enter a valid redirect URI."
            }
        }
    }
}
