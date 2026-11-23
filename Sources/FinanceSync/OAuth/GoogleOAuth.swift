import Foundation

/// Errors thrown while building OAuth requests, validating callbacks, or exchanging tokens.
public enum OAuthError: Error, LocalizedError, Equatable, Sendable {
    /// The Google iOS client ID did not match `<id>.apps.googleusercontent.com`.
    case invalidClientID(String)
    /// The PKCE code verifier did not meet RFC 7636 rules.
    case invalidPKCEVerifier
    /// The OAuth state parameter was empty.
    case invalidState
    /// No OAuth scopes were provided.
    case emptyScopes
    /// The callback URL could not be parsed.
    case invalidCallbackURL
    /// The callback state was missing or did not match the expected state.
    case stateMismatch
    /// Google redirected back with an OAuth error parameter.
    case authorizationFailed(code: String, description: String?)
    /// The callback URL contained neither an authorization code nor an error.
    case missingAuthorizationCode
    /// A required input to a token request was empty or invalid.
    case invalidTokenRequest(String)
    /// The token endpoint response could not be decoded.
    case invalidTokenResponse(String)
    /// The token endpoint returned a non-2xx HTTP status.
    case tokenEndpointError(statusCode: Int, code: String?, description: String?)

    public var errorDescription: String? {
        switch self {
        case .invalidClientID(let reason):
            return "Invalid Google OAuth client ID: \(reason)"
        case .invalidPKCEVerifier:
            return "PKCE code verifier must be 43 to 128 unreserved ASCII characters."
        case .invalidState:
            return "OAuth state must not be empty."
        case .emptyScopes:
            return "At least one OAuth scope is required."
        case .invalidCallbackURL:
            return "Could not parse the OAuth callback URL."
        case .stateMismatch:
            return "OAuth callback state did not match the expected value."
        case .authorizationFailed(let code, let description):
            if let description, !description.isEmpty {
                return "Google sign-in failed (\(code)): \(description)"
            }
            return "Google sign-in failed (\(code))."
        case .missingAuthorizationCode:
            return "OAuth callback did not contain an authorization code."
        case .invalidTokenRequest(let reason):
            return "Invalid OAuth token request: \(reason)"
        case .invalidTokenResponse(let reason):
            return "Could not decode Google token response: \(reason)"
        case .tokenEndpointError(let statusCode, let code, let description):
            if let code, let description, !description.isEmpty {
                return "Google token request failed with HTTP \(statusCode) (\(code)): \(description)"
            }
            if let code {
                return "Google token request failed with HTTP \(statusCode) (\(code))."
            }
            return "Google token request failed with HTTP \(statusCode)."
        }
    }
}

/// Raw JSON payload returned by Google's OAuth 2.0 token endpoint.
public struct OAuthTokenResponse: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    /// Bearer access token.
    public var accessToken: String
    /// Lifetime of the access token in seconds.
    public var expiresIn: Int
    /// Refresh token, present on initial authorization and omitted on most refreshes.
    public var refreshToken: String?
    /// Space-delimited scopes granted by Google.
    public var scope: String?
    /// Token type, normally `"Bearer"`.
    public var tokenType: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case scope
        case tokenType = "token_type"
    }

    public init(
        accessToken: String,
        expiresIn: Int,
        refreshToken: String? = nil,
        scope: String? = nil,
        tokenType: String = "Bearer"
    ) {
        self.accessToken = accessToken
        self.expiresIn = expiresIn
        self.refreshToken = refreshToken
        self.scope = scope
        self.tokenType = tokenType
    }

    public var description: String {
        "OAuthTokenResponse(tokenType: \(tokenType), expiresIn: \(expiresIn), hasRefreshToken: \(refreshToken != nil), accessToken: <redacted>)"
    }

    public var debugDescription: String {
        description
    }
}

/// Error JSON payload returned by Google's OAuth 2.0 token endpoint.
public struct OAuthErrorResponse: Codable, Equatable, Sendable {
    public var error: String
    public var errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }

    public init(error: String, errorDescription: String? = nil) {
        self.error = error
        self.errorDescription = errorDescription
    }
}

/// Stored OAuth credentials with an absolute expiration timestamp.
public struct OAuthTokens: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    /// Current Bearer access token.
    public var accessToken: String
    /// Long-lived refresh token, if available.
    public var refreshToken: String?
    /// Absolute date when the access token expires.
    public var expiresAt: Date
    /// Granted scope string, if reported by Google.
    public var scope: String?
    /// Token type, normally `"Bearer"`.
    public var tokenType: String
    /// Optional app-owned binding to the mailbox that authorized these credentials.
    public var mailboxFingerprint: String? = nil

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

    /// Creates stored tokens from a token endpoint response, keeping `fallbackRefreshToken`
    /// when the response omits a new refresh token.
    public init(
        response: OAuthTokenResponse,
        now: Date = Date(),
        fallbackRefreshToken: String? = nil
    ) {
        self.accessToken = response.accessToken
        self.refreshToken = response.refreshToken ?? fallbackRefreshToken
        self.expiresAt = now.addingTimeInterval(TimeInterval(response.expiresIn))
        self.scope = response.scope
        self.tokenType = response.tokenType
    }

    /// Returns `true` if the access token has expired or will expire within `leeway` seconds.
    public func isExpired(at now: Date = Date(), leeway: TimeInterval = 60) -> Bool {
        now.addingTimeInterval(leeway) >= expiresAt
    }

    /// Returns `true` if `scope` lists `requiredScope` as a space-delimited token.
    public func hasScope(_ requiredScope: String) -> Bool {
        guard let scope else { return false }
        return scope.split(whereSeparator: \.isWhitespace).contains { String($0) == requiredScope }
    }

    public var description: String {
        "OAuthTokens(tokenType: \(tokenType), expiresAt: \(expiresAt.timeIntervalSince1970), hasRefreshToken: \(refreshToken != nil), accessToken: <redacted>)"
    }

    public var debugDescription: String {
        description
    }
}

/// Pure-Foundation helpers for Google OAuth 2.0 with PKCE for iOS clients.
public enum GoogleOAuth {
    /// Google OAuth 2.0 authorization endpoint.
    public static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    /// Google OAuth 2.0 token endpoint.
    public static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    /// Read-only Gmail scope.
    public static let gmailReadOnlyScope = "https://www.googleapis.com/auth/gmail.readonly"
    /// Hidden per-app Google Drive `appDataFolder` scope.
    public static let driveAppDataScope = "https://www.googleapis.com/auth/drive.appdata"

    private static let clientIDSuffix = ".apps.googleusercontent.com"
    private static let reversedClientIDPrefix = "com.googleusercontent.apps."

    /// Generates a random URL-safe state string using the system CSPRNG.
    public static func generateState(byteCount: Int = 24) -> String {
        Base64URLEncoder.encode(RandomBytes.generate(count: max(16, byteCount)))
    }

    /// Derives the reversed iOS URL scheme (`com.googleusercontent.apps.<id>`)
    /// from a Google client ID (`<id>.apps.googleusercontent.com`).
    public static func reversedClientID(for clientID: String) throws -> String {
        guard !clientID.isEmpty else {
            throw OAuthError.invalidClientID("client ID is empty.")
        }
        guard clientID.lowercased().hasSuffix(clientIDSuffix) else {
            throw OAuthError.invalidClientID("must end with '\(clientIDSuffix)'.")
        }
        let idPart = String(clientID.dropLast(clientIDSuffix.count))
        guard !idPart.isEmpty else {
            throw OAuthError.invalidClientID("missing identifier before '\(clientIDSuffix)'.")
        }
        guard isValidSchemeSegment(idPart) else {
            throw OAuthError.invalidClientID("identifier contains invalid characters.")
        }
        return reversedClientIDPrefix + idPart
    }

    /// Derives the iOS redirect URI (`<reversed client ID>:/oauth2redirect`) for a Google client ID.
    public static func redirectURI(for clientID: String) throws -> String {
        let reversed = try reversedClientID(for: clientID)
        return "\(reversed):/oauth2redirect"
    }

    /// Builds the Google OAuth authorization URL for an iOS client using PKCE (S256).
    ///
    /// Omits `access_type`, which is not needed for iOS clients. Pass
    /// `includeGrantedScopes: true` for incremental authorization (e.g. adding Drive `appDataFolder`).
    public static func authorizationURL(
        clientID: String,
        pkce: PKCE,
        state: String,
        scopes: [String] = [gmailReadOnlyScope],
        includeGrantedScopes: Bool = false
    ) throws -> URL {
        guard !state.isEmpty else {
            throw OAuthError.invalidState
        }
        let cleanedScopes = scopes.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !cleanedScopes.isEmpty else {
            throw OAuthError.emptyScopes
        }
        let redirect = try redirectURI(for: clientID)

        guard var components = URLComponents(url: authorizationEndpoint, resolvingAgainstBaseURL: false) else {
            throw OAuthError.invalidClientID("could not construct authorization URL.")
        }
        var queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: cleanedScopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: PKCE.challengeMethod),
            URLQueryItem(name: "state", value: state),
        ]
        if includeGrantedScopes {
            queryItems.append(URLQueryItem(name: "include_granted_scopes", value: "true"))
            queryItems.append(URLQueryItem(name: "prompt", value: "consent"))
        }
        components.queryItems = queryItems
        guard let url = components.url else {
            throw OAuthError.invalidClientID("could not construct authorization URL.")
        }
        return url
    }

    /// Validates the OAuth redirect callback URL against `expectedState` and returns the authorization code.
    public static func parseCallback(_ url: URL, expectedState: String) throws -> String {
        guard !expectedState.isEmpty else {
            throw OAuthError.invalidState
        }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw OAuthError.invalidCallbackURL
        }
        let items = components.queryItems ?? []
        let actualState = items.first(where: { $0.name == "state" })?.value
        guard actualState == expectedState else {
            throw OAuthError.stateMismatch
        }
        if let error = items.first(where: { $0.name == "error" })?.value, !error.isEmpty {
            let description = items.first(where: { $0.name == "error_description" })?.value
            throw OAuthError.authorizationFailed(code: error, description: description)
        }
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw OAuthError.missingAuthorizationCode
        }
        return code
    }

    /// Builds a POST request to exchange an authorization code and PKCE verifier for tokens.
    ///
    /// Does not include a client secret, as required for public iOS clients.
    public static func authorizationCodeTokenRequest(
        clientID: String,
        code: String,
        codeVerifier: String,
        redirectURI: String? = nil
    ) throws -> HTTPRequest {
        let resolvedRedirect = try redirectURI ?? Self.redirectURI(for: clientID)
        guard !code.isEmpty else {
            throw OAuthError.invalidTokenRequest("authorization code is empty.")
        }
        guard PKCE.isValidVerifier(codeVerifier) else {
            throw OAuthError.invalidPKCEVerifier
        }
        let body = FormURLEncoder.encode([
            ("grant_type", "authorization_code"),
            ("client_id", clientID),
            ("code", code),
            ("redirect_uri", resolvedRedirect),
            ("code_verifier", codeVerifier),
        ])
        return HTTPRequest(
            method: "POST",
            url: tokenEndpoint,
            headers: [
                "Content-Type": "application/x-www-form-urlencoded; charset=utf-8",
                "Accept": "application/json",
            ],
            body: body
        )
    }

    /// Builds a POST request to refresh an access token using a refresh token.
    ///
    /// Does not include a client secret, as required for public iOS clients.
    public static func refreshTokenRequest(
        clientID: String,
        refreshToken: String
    ) throws -> HTTPRequest {
        _ = try reversedClientID(for: clientID)
        guard !refreshToken.isEmpty else {
            throw OAuthError.invalidTokenRequest("refresh token is empty.")
        }
        let body = FormURLEncoder.encode([
            ("grant_type", "refresh_token"),
            ("client_id", clientID),
            ("refresh_token", refreshToken),
        ])
        return HTTPRequest(
            method: "POST",
            url: tokenEndpoint,
            headers: [
                "Content-Type": "application/x-www-form-urlencoded; charset=utf-8",
                "Accept": "application/json",
            ],
            body: body
        )
    }

    /// Decodes a JSON response body from Google's token endpoint.
    public static func decodeTokenResponse(_ data: Data) throws -> OAuthTokenResponse {
        let decoded: OAuthTokenResponse
        do {
            decoded = try JSONDecoder().decode(OAuthTokenResponse.self, from: data)
        } catch {
            throw OAuthError.invalidTokenResponse("JSON did not match expected token fields.")
        }
        guard !decoded.accessToken.isEmpty else {
            throw OAuthError.invalidTokenResponse("access_token was empty.")
        }
        return decoded
    }

    /// Attempts to decode an OAuth error response body, returning `nil` if it does not match.
    public static func decodeErrorResponse(_ data: Data) -> OAuthErrorResponse? {
        try? JSONDecoder().decode(OAuthErrorResponse.self, from: data)
    }

    /// Exchanges an authorization code for OAuth tokens over `transport`.
    public static func exchangeAuthorizationCode(
        clientID: String,
        code: String,
        codeVerifier: String,
        redirectURI: String? = nil,
        transport: any HTTPTransport,
        now: Date = Date()
    ) async throws -> OAuthTokens {
        let request = try authorizationCodeTokenRequest(
            clientID: clientID,
            code: code,
            codeVerifier: codeVerifier,
            redirectURI: redirectURI
        )
        let response = try await transport.send(request)
        guard (200...299).contains(response.statusCode) else {
            let errorPayload = decodeErrorResponse(response.body)
            throw OAuthError.tokenEndpointError(
                statusCode: response.statusCode,
                code: errorPayload?.error,
                description: errorPayload?.errorDescription
            )
        }
        let tokenResponse = try decodeTokenResponse(response.body)
        return OAuthTokens(response: tokenResponse, now: now)
    }

    /// Refreshes an access token over `transport`, preserving `refreshToken` if Google omits a new one.
    public static func refreshAccessToken(
        clientID: String,
        refreshToken: String,
        transport: any HTTPTransport,
        now: Date = Date()
    ) async throws -> OAuthTokens {
        let request = try refreshTokenRequest(clientID: clientID, refreshToken: refreshToken)
        let response = try await transport.send(request)
        guard (200...299).contains(response.statusCode) else {
            let errorPayload = decodeErrorResponse(response.body)
            throw OAuthError.tokenEndpointError(
                statusCode: response.statusCode,
                code: errorPayload?.error,
                description: errorPayload?.errorDescription
            )
        }
        let tokenResponse = try decodeTokenResponse(response.body)
        return OAuthTokens(response: tokenResponse, now: now, fallbackRefreshToken: refreshToken)
    }

    private static func isValidSchemeSegment(_ segment: String) -> Bool {
        if segment.hasPrefix(".") || segment.hasSuffix(".") || segment.contains("..") {
            return false
        }
        for scalar in segment.unicodeScalars {
            switch scalar.value {
            case 0x41...0x5A, // A-Z
                 0x61...0x7A, // a-z
                 0x30...0x39, // 0-9
                 0x2D,        // -
                 0x2E:        // .
                continue
            default:
                return false
            }
        }
        return true
    }
}
