import Foundation
#if canImport(Security)
import Security
#endif

/// Authentication method used to reach Money Forward Cloud APIs.
public enum MoneyForwardAuthMode: String, Codable, Equatable, Sendable {
    case apiKey
    case oauth
}

/// Stored API-key credentials for Money Forward Cloud (App Portal API key + optional
/// office code + cached short-lived 1-hour JWT from `POST /auth/exchange`).
public struct MoneyForwardAPIKeyCredentials: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    /// Long-lived API key issued in Money Forward App Portal (`mf_api_pro_...`).
    public var apiKey: String
    /// Target office code (`XXXX-XXXX`), required for Accounting API calls except `/accessible_offices`.
    public var officeCode: String?
    /// Short-lived JWT obtained from `POST https://api.biz.moneyforward.com/auth/exchange`.
    public var cachedJWT: String?
    /// Expiration time of `cachedJWT`.
    public var jwtExpiresAt: Date?

    public init(
        apiKey: String,
        officeCode: String? = nil,
        cachedJWT: String? = nil,
        jwtExpiresAt: Date? = nil
    ) {
        self.apiKey = apiKey
        self.officeCode = officeCode
        self.cachedJWT = cachedJWT
        self.jwtExpiresAt = jwtExpiresAt
    }

    /// Returns `true` when the cached JWT is present and has at least `leeway` seconds left.
    /// Money Forward's tutorial recommends refreshing 5 minutes (300 s) before expiry.
    public func hasValidJWT(at now: Date = Date(), leeway: TimeInterval = 300) -> Bool {
        guard let jwt = cachedJWT, !jwt.isEmpty, let expiresAt = jwtExpiresAt else {
            return false
        }
        return now.addingTimeInterval(leeway) < expiresAt
    }

    public var description: String {
        "MoneyForwardAPIKeyCredentials(hasOffice: \(officeCode != nil), hasJWT: \(cachedJWT != nil), apiKey: <redacted>)"
    }

    public var debugDescription: String {
        description
    }
}

/// OAuth 2.0 client configuration registered in Money Forward App Portal.
public struct MoneyForwardOAuthConfig: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var clientID: String
    public var clientSecret: String
    public var redirectURI: String

    public init(clientID: String, clientSecret: String, redirectURI: String) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.redirectURI = redirectURI
    }

    public var description: String {
        "MoneyForwardOAuthConfig(clientID: \(clientID), redirectURI: \(redirectURI), clientSecret: <redacted>)"
    }

    public var debugDescription: String {
        description
    }
}

/// Stored Money Forward OAuth 2.0 tokens.
public struct MoneyForwardOAuthTokens: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date
    public var scope: String?
    public var tokenType: String

    public init(
        accessToken: String,
        refreshToken: String? = nil,
        expiresAt: Date,
        scope: String? = nil,
        tokenType: String = "Bearer"
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scope = scope
        self.tokenType = tokenType
    }

    public func isExpired(at now: Date = Date(), leeway: TimeInterval = 60) -> Bool {
        now.addingTimeInterval(leeway) >= expiresAt
    }

    public var description: String {
        "MoneyForwardOAuthTokens(tokenType: \(tokenType), expiresAt: \(expiresAt.timeIntervalSince1970), hasRefreshToken: \(refreshToken != nil), accessToken: <redacted>)"
    }

    public var debugDescription: String {
        description
    }
}

/// Unified credentials stored in the Keychain for Money Forward Cloud.
public struct MoneyForwardCredentials: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var mode: MoneyForwardAuthMode
    public var apiKey: MoneyForwardAPIKeyCredentials?
    public var oauthConfig: MoneyForwardOAuthConfig?
    public var oauthTokens: MoneyForwardOAuthTokens?

    public init(apiKey: MoneyForwardAPIKeyCredentials) {
        self.mode = .apiKey
        self.apiKey = apiKey
        self.oauthConfig = nil
        self.oauthTokens = nil
    }

    public init(oauthConfig: MoneyForwardOAuthConfig, oauthTokens: MoneyForwardOAuthTokens) {
        self.mode = .oauth
        self.apiKey = nil
        self.oauthConfig = oauthConfig
        self.oauthTokens = oauthTokens
    }

    public var description: String {
        "MoneyForwardCredentials(mode: \(mode.rawValue), apiKey: \(apiKey != nil ? "<present>" : "nil"), oauth: \(oauthTokens != nil ? "<present>" : "nil"))"
    }

    public var debugDescription: String {
        description
    }
}

/// Persistent or transient storage for Money Forward credentials.
public protocol MoneyForwardCredentialStore: Sendable {
    func load() async throws -> MoneyForwardCredentials?
    func save(_ credentials: MoneyForwardCredentials) async throws
    func clear() async throws
}

/// In-memory credential store for unit tests.
public actor InMemoryMoneyForwardCredentialStore: MoneyForwardCredentialStore {
    private var credentials: MoneyForwardCredentials?

    public init(credentials: MoneyForwardCredentials? = nil) {
        self.credentials = credentials
    }

    public func load() async throws -> MoneyForwardCredentials? {
        credentials
    }

    public func save(_ credentials: MoneyForwardCredentials) async throws {
        self.credentials = credentials
    }

    public func clear() async throws {
        credentials = nil
    }
}

#if canImport(Security)
/// Apple Keychain store for Money Forward credentials using
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` so background sync can run while locked.
public struct KeychainMoneyForwardCredentialStore: MoneyForwardCredentialStore, Sendable {
    public let service: String
    public let account: String
    public let accessGroup: String?

    public init(
        service: String = "FinanceApp.MoneyForward",
        account: String = "default",
        accessGroup: String? = nil
    ) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
    }

    public func load() throws -> MoneyForwardCredentials? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw TokenStoreError.keychainFailure(operation: "read", status: status)
        }
        guard let data = item as? Data else {
            throw TokenStoreError.decodingFailed
        }
        do {
            return try JSONDecoder().decode(MoneyForwardCredentials.self, from: data)
        } catch {
            throw TokenStoreError.decodingFailed
        }
    }

    public func save(_ credentials: MoneyForwardCredentials) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(credentials)
        } catch {
            throw TokenStoreError.encodingFailed
        }

        var addQuery = baseQuery()
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecSuccess {
            return
        }
        guard addStatus == errSecDuplicateItem else {
            throw TokenStoreError.keychainFailure(operation: "save", status: addStatus)
        }

        let updateAttributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(baseQuery() as CFDictionary, updateAttributes as CFDictionary)
        guard updateStatus == errSecSuccess else {
            throw TokenStoreError.keychainFailure(operation: "update", status: updateStatus)
        }
    }

    public func clear() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TokenStoreError.keychainFailure(operation: "delete", status: status)
        }
    }

    private func baseQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }
}
#endif

/// Pure-Foundation helpers for Money Forward Cloud API-key JWT exchange and OAuth 2.0 (PKCE).
public enum MoneyForwardAuth {
    /// API key -> 1-hour JWT exchange endpoint.
    public static let exchangeEndpoint = URL(string: "https://api.biz.moneyforward.com/auth/exchange")!
    /// OAuth 2.0 authorization endpoint.
    public static let authorizationEndpoint = URL(string: "https://api.biz.moneyforward.com/authorize")!
    /// OAuth 2.0 token and refresh endpoint.
    public static let tokenEndpoint = URL(string: "https://api.biz.moneyforward.com/token")!

    /// Narrowest read-only OAuth scopes needed to read offices, connected accounts and transactions.
    public static let readOnlyScopes: [String] = [
        "mfc/accounting/offices.read",
        "mfc/accounting/connected_account.read",
        "mfc/accounting/transaction.read",
    ]

    /// Custom URL scheme usable with `ASWebAuthenticationSession` without Associated Domains.
    public static let defaultCallbackScheme = "io.github.aspendot.financeapp"
    /// Absolute redirect URI without fragment matching Money Forward App Portal's requirement.
    public static let defaultRedirectURI = "io.github.aspendot.financeapp:/mfcallback"

    /// Builds `POST /auth/exchange` to exchange an App Portal API key for a 1-hour JWT.
    public static func exchangeAPIKeyRequest(
        apiKey: String,
        endpoint: URL = exchangeEndpoint
    ) throws -> HTTPRequest {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MoneyForwardClientError.invalidCredentials
        }
        return HTTPRequest(
            method: "POST",
            url: endpoint,
            headers: [
                "Authorization": "Bearer \(trimmed)",
                "Accept": "application/json",
            ]
        )
    }

    /// Exchanges an API key for a short-lived JWT (typically valid for 3600 seconds).
    public static func exchangeAPIKey(
        _ apiKey: String,
        transport: any HTTPTransport,
        endpoint: URL = exchangeEndpoint,
        now: Date = Date()
    ) async throws -> (accessToken: String, expiresAt: Date) {
        let request = try exchangeAPIKeyRequest(apiKey: apiKey, endpoint: endpoint)
        let response: HTTPResponse
        do {
            response = try await transport.send(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MoneyForwardClientError.networkError("the request could not complete.")
        }

        return try decodeAPIKeyExchange(response, now: now, attempts: 1)
    }

    static func decodeAPIKeyExchange(
        _ response: HTTPResponse, now: Date, attempts: Int
    ) throws -> (accessToken: String, expiresAt: Date) {
        if response.statusCode == 401 {
            throw MoneyForwardClientError.invalidCredentials
        }
        guard (200...299).contains(response.statusCode) else {
            throw MoneyForwardClient.requestError(status: response.statusCode, attempts: attempts)
        }

        let decoded: JWTExchangeResponse
        do {
            decoded = try JSONDecoder().decode(JWTExchangeResponse.self, from: response.body)
        } catch {
            throw MoneyForwardClientError.invalidResponse("could not decode API key exchange JSON.")
        }
        guard !decoded.accessToken.isEmpty else {
            throw MoneyForwardClientError.invalidResponse("API key exchange returned an empty access_token.")
        }
        let lifetime = decoded.expiresIn ?? 3600
        guard lifetime > 0 else {
            throw MoneyForwardClientError.invalidResponse("API key exchange returned an expired token.")
        }
        return (decoded.accessToken, now.addingTimeInterval(TimeInterval(lifetime)))
    }

    /// Builds the Money Forward OAuth 2.0 authorization URL with PKCE (S256).
    public static func authorizationURL(
        clientID: String,
        redirectURI: String = defaultRedirectURI,
        pkce: PKCE,
        state: String,
        scopes: [String] = readOnlyScopes,
        endpoint: URL = authorizationEndpoint
    ) throws -> URL {
        let trimmedClient = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRedirect = redirectURI.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedClient.isEmpty else {
            throw OAuthError.invalidTokenRequest("client_id is empty.")
        }
        guard !trimmedRedirect.isEmpty, !trimmedRedirect.contains("#"),
              let parsedRedirect = URL(string: trimmedRedirect), parsedRedirect.scheme != nil
        else {
            throw OAuthError.invalidTokenRequest("redirect_uri must be an absolute URI without a fragment.")
        }
        guard !state.isEmpty else {
            throw OAuthError.invalidState
        }
        let cleanedScopes = scopes.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !cleanedScopes.isEmpty else {
            throw OAuthError.emptyScopes
        }
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw OAuthError.invalidTokenRequest("could not construct Money Forward authorization URL.")
        }
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: trimmedClient),
            URLQueryItem(name: "redirect_uri", value: trimmedRedirect),
            URLQueryItem(name: "scope", value: cleanedScopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: PKCE.challengeMethod),
            URLQueryItem(name: "state", value: state),
        ]
        guard let url = components.url else {
            throw OAuthError.invalidTokenRequest("could not construct Money Forward authorization URL.")
        }
        return url
    }

    /// Validates the OAuth callback URL against `expectedState` and returns the authorization code.
    public static func parseCallback(_ url: URL, expectedState: String) throws -> String {
        try GoogleOAuth.parseCallback(url, expectedState: expectedState)
    }

    /// Builds `POST /token` for exchanging an authorization code using `CLIENT_SECRET_BASIC` and PKCE.
    public static func authorizationCodeTokenRequest(
        config: MoneyForwardOAuthConfig,
        code: String,
        codeVerifier: String,
        endpoint: URL = tokenEndpoint
    ) throws -> HTTPRequest {
        guard !config.clientID.isEmpty, !config.clientSecret.isEmpty else {
            throw OAuthError.invalidTokenRequest("client_id and client_secret are required.")
        }
        guard !code.isEmpty else {
            throw OAuthError.invalidTokenRequest("authorization code is empty.")
        }
        guard PKCE.isValidVerifier(codeVerifier) else {
            throw OAuthError.invalidPKCEVerifier
        }
        let body = FormURLEncoder.encode([
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", config.redirectURI),
            ("code_verifier", codeVerifier),
        ])
        return HTTPRequest(
            method: "POST",
            url: endpoint,
            headers: [
                "Authorization": basicAuthHeader(clientID: config.clientID, clientSecret: config.clientSecret),
                "Content-Type": "application/x-www-form-urlencoded; charset=utf-8",
                "Accept": "application/json",
            ],
            body: body
        )
    }

    /// Builds `POST /token` for refreshing an OAuth access token using `CLIENT_SECRET_BASIC`.
    public static func refreshTokenRequest(
        config: MoneyForwardOAuthConfig,
        refreshToken: String,
        endpoint: URL = tokenEndpoint
    ) throws -> HTTPRequest {
        guard !config.clientID.isEmpty, !config.clientSecret.isEmpty else {
            throw OAuthError.invalidTokenRequest("client_id and client_secret are required.")
        }
        guard !refreshToken.isEmpty else {
            throw OAuthError.invalidTokenRequest("refresh token is empty.")
        }
        let body = FormURLEncoder.encode([
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
        ])
        return HTTPRequest(
            method: "POST",
            url: endpoint,
            headers: [
                "Authorization": basicAuthHeader(clientID: config.clientID, clientSecret: config.clientSecret),
                "Content-Type": "application/x-www-form-urlencoded; charset=utf-8",
                "Accept": "application/json",
            ],
            body: body
        )
    }

    public static func exchangeAuthorizationCode(
        config: MoneyForwardOAuthConfig,
        code: String,
        codeVerifier: String,
        transport: any HTTPTransport,
        endpoint: URL = tokenEndpoint,
        now: Date = Date()
    ) async throws -> MoneyForwardOAuthTokens {
        let request = try authorizationCodeTokenRequest(
            config: config,
            code: code,
            codeVerifier: codeVerifier,
            endpoint: endpoint
        )
        return try await performOAuthTokenRequest(request, transport: transport, fallbackRefreshToken: nil, now: now)
    }

    public static func refreshAccessToken(
        config: MoneyForwardOAuthConfig,
        refreshToken: String,
        transport: any HTTPTransport,
        endpoint: URL = tokenEndpoint,
        now: Date = Date()
    ) async throws -> MoneyForwardOAuthTokens {
        let request = try refreshTokenRequest(
            config: config,
            refreshToken: refreshToken,
            endpoint: endpoint
        )
        return try await performOAuthTokenRequest(request, transport: transport, fallbackRefreshToken: refreshToken, now: now)
    }

    private static func performOAuthTokenRequest(
        _ request: HTTPRequest,
        transport: any HTTPTransport,
        fallbackRefreshToken: String?,
        now: Date
    ) async throws -> MoneyForwardOAuthTokens {
        let response: HTTPResponse
        do {
            response = try await transport.send(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MoneyForwardClientError.networkError("the request could not complete.")
        }

        if response.statusCode == 401 || response.statusCode == 403 {
            throw MoneyForwardClientError.invalidCredentials
        }
        if response.statusCode == 429 {
            throw MoneyForwardClientError.rateLimited(statusCode: 429, attempts: 1)
        }
        if (500...599).contains(response.statusCode) {
            throw MoneyForwardClientError.maintenanceOrServerError(statusCode: response.statusCode)
        }
        guard (200...299).contains(response.statusCode) else {
            if let oauthErr = GoogleOAuth.decodeErrorResponse(response.body) {
                let code = oauthErr.error.lowercased()
                if code == "invalid_grant" || code == "invalid_client" || code == "unauthorized_client" {
                    throw MoneyForwardClientError.invalidCredentials
                }
            }
            throw MoneyForwardClientError.httpError(statusCode: response.statusCode)
        }

        let tokenResponse: OAuthTokenResponse
        do {
            tokenResponse = try GoogleOAuth.decodeTokenResponse(response.body)
        } catch {
            throw MoneyForwardClientError.invalidResponse("could not decode Money Forward OAuth token JSON.")
        }
        return MoneyForwardOAuthTokens(
            accessToken: tokenResponse.accessToken,
            refreshToken: tokenResponse.refreshToken ?? fallbackRefreshToken,
            expiresAt: now.addingTimeInterval(TimeInterval(tokenResponse.expiresIn)),
            scope: tokenResponse.scope,
            tokenType: tokenResponse.tokenType
        )
    }

    private static func basicAuthHeader(clientID: String, clientSecret: String) -> String {
        let encodedID = FormURLEncoder.percentEncode(clientID)
        let encodedSecret = FormURLEncoder.percentEncode(clientSecret)
        let raw = Data("\(encodedID):\(encodedSecret)".utf8).base64EncodedString()
        return "Basic \(raw)"
    }
}

private struct JWTExchangeResponse: Decodable {
    let accessToken: String
    let tokenType: String?
    let expiresIn: Int?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
    }
}
