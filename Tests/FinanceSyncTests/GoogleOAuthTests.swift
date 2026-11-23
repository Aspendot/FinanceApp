import Foundation
import Testing
@testable import FinanceSync

@Suite("GoogleOAuth and PKCE")
struct GoogleOAuthTests {
    // Clearly invented client ID that does not match real Google OAuth client ID patterns.
    private let sampleClientID = "12345-sample.apps.googleusercontent.com"
    private let sampleReversed = "com.googleusercontent.apps.12345-sample"

    @Test("PKCE S256 challenge matches RFC 7636 Appendix B test vector")
    func pkceMatchesRFC7636Vector() throws {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let expectedChallenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        let pkce = try PKCE(verifier: verifier)
        #expect(pkce.verifier == verifier)
        #expect(pkce.challenge == expectedChallenge)
        #expect(PKCE.challengeMethod == "S256")
    }

    @Test("PKCE generation creates a valid verifier within RFC 7636 bounds")
    func pkceGenerateProducesValidVerifier() throws {
        let first = try PKCE.generate()
        let second = try PKCE.generate()
        #expect(first.verifier.count == 43)
        #expect(PKCE.isValidVerifier(first.verifier))
        #expect(first.verifier != second.verifier)
        #expect(!first.challenge.contains("="))
        #expect(!first.challenge.contains("+"))
        #expect(!first.challenge.contains("/"))
    }

    @Test("PKCE rejects verifiers that are too short, too long, or have invalid characters")
    func pkceRejectsInvalidVerifiers() {
        #expect(throws: OAuthError.invalidPKCEVerifier) {
            _ = try PKCE(verifier: String(repeating: "a", count: 42))
        }
        #expect(throws: OAuthError.invalidPKCEVerifier) {
            _ = try PKCE(verifier: String(repeating: "a", count: 129))
        }
        #expect(throws: OAuthError.invalidPKCEVerifier) {
            _ = try PKCE(verifier: String(repeating: "a", count: 42) + "+")
        }
    }

    @Test("Reversed client ID and redirect URI are derived from Google client ID")
    func reversedClientIDAndRedirectURI() throws {
        #expect(try GoogleOAuth.reversedClientID(for: sampleClientID) == sampleReversed)
        #expect(try GoogleOAuth.redirectURI(for: sampleClientID) == "\(sampleReversed):/oauth2redirect")

        #expect(throws: OAuthError.self) {
            _ = try GoogleOAuth.reversedClientID(for: "not-a-google-client-id.example.com")
        }
        #expect(throws: OAuthError.self) {
            _ = try GoogleOAuth.reversedClientID(for: ".apps.googleusercontent.com")
        }
    }

    @Test("Authorization URL includes PKCE, reversed redirect URI, scope, state, and omits access_type")
    func authorizationURLBuilder() throws {
        let pkce = try PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        let url = try GoogleOAuth.authorizationURL(
            clientID: sampleClientID,
            pkce: pkce,
            state: "sample-state-1"
        )
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "https")
        #expect(components.host == "accounts.google.com")
        #expect(components.path == "/o/oauth2/v2/auth")

        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(query["client_id"] == sampleClientID)
        #expect(query["redirect_uri"] == "\(sampleReversed):/oauth2redirect")
        #expect(query["response_type"] == "code")
        #expect(query["scope"] == "https://www.googleapis.com/auth/gmail.readonly")
        #expect(query["code_challenge"] == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        #expect(query["code_challenge_method"] == "S256")
        #expect(query["state"] == "sample-state-1")
        #expect(query["access_type"] == nil)
    }

    @Test("Callback parser returns code on matching state and throws on mismatch or error")
    func callbackParsing() throws {
        let okURL = try #require(URL(string: "\(sampleReversed):/oauth2redirect?state=state-1&code=sample-code-1"))
        #expect(try GoogleOAuth.parseCallback(okURL, expectedState: "state-1") == "sample-code-1")

        let wrongStateURL = try #require(URL(string: "\(sampleReversed):/oauth2redirect?state=other-state&code=sample-code-1"))
        #expect(throws: OAuthError.stateMismatch) {
            _ = try GoogleOAuth.parseCallback(wrongStateURL, expectedState: "state-1")
        }

        let missingStateURL = try #require(URL(string: "\(sampleReversed):/oauth2redirect?code=sample-code-1"))
        #expect(throws: OAuthError.stateMismatch) {
            _ = try GoogleOAuth.parseCallback(missingStateURL, expectedState: "state-1")
        }

        let errorURL = try #require(URL(string: "\(sampleReversed):/oauth2redirect?state=state-1&error=access_denied&error_description=User%20cancelled"))
        #expect(throws: OAuthError.authorizationFailed(code: "access_denied", description: "User cancelled")) {
            _ = try GoogleOAuth.parseCallback(errorURL, expectedState: "state-1")
        }
    }

    @Test("Token request builders use POST form body without client_secret")
    func tokenRequestBuilders() throws {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let authReq = try GoogleOAuth.authorizationCodeTokenRequest(
            clientID: sampleClientID,
            code: "code+with/special=chars",
            codeVerifier: verifier
        )
        #expect(authReq.method == "POST")
        #expect(authReq.url == GoogleOAuth.tokenEndpoint)
        #expect(authReq.headers["Content-Type"] == "application/x-www-form-urlencoded; charset=utf-8")

        let authBody = String(decoding: try #require(authReq.body), as: UTF8.self)
        let authParams = parseForm(authBody)
        #expect(authParams["grant_type"] == "authorization_code")
        #expect(authParams["client_id"] == sampleClientID)
        #expect(authParams["code"] == "code+with/special=chars")
        #expect(authParams["redirect_uri"] == "\(sampleReversed):/oauth2redirect")
        #expect(authParams["code_verifier"] == verifier)
        #expect(authParams["client_secret"] == nil)
        #expect(authBody.contains("code%2Bwith%2Fspecial%3Dchars"))

        let refreshReq = try GoogleOAuth.refreshTokenRequest(
            clientID: sampleClientID,
            refreshToken: "sample-refresh-1"
        )
        #expect(refreshReq.method == "POST")
        #expect(refreshReq.url == GoogleOAuth.tokenEndpoint)
        let refreshParams = parseForm(String(decoding: try #require(refreshReq.body), as: UTF8.self))
        #expect(refreshParams["grant_type"] == "refresh_token")
        #expect(refreshParams["client_id"] == sampleClientID)
        #expect(refreshParams["refresh_token"] == "sample-refresh-1")
        #expect(refreshParams["client_secret"] == nil)
    }

    @Test("Token response decoding handles initial and refresh responses and redacts descriptions")
    func tokenResponseDecodingAndRedaction() throws {
        let initialJSON = Data("""
        {
          "access_token": "sample-access-token",
          "expires_in": 3599,
          "refresh_token": "sample-refresh-token",
          "scope": "https://www.googleapis.com/auth/gmail.readonly",
          "token_type": "Bearer"
        }
        """.utf8)
        let decoded = try GoogleOAuth.decodeTokenResponse(initialJSON)
        #expect(decoded.accessToken == "sample-access-token")
        #expect(decoded.expiresIn == 3599)
        #expect(decoded.refreshToken == "sample-refresh-token")
        #expect(decoded.tokenType == "Bearer")
        #expect(!String(describing: decoded).contains("sample-access-token"))
        #expect(!String(describing: decoded).contains("sample-refresh-token"))

        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let refreshedJSON = Data("""
        {
          "access_token": "sample-access-token-2",
          "expires_in": 3600,
          "token_type": "Bearer"
        }
        """.utf8)
        let refreshed = try GoogleOAuth.decodeTokenResponse(refreshedJSON)
        let merged = OAuthTokens(response: refreshed, now: now, fallbackRefreshToken: "sample-refresh-token")
        #expect(merged.accessToken == "sample-access-token-2")
        #expect(merged.refreshToken == "sample-refresh-token")
        #expect(merged.expiresAt == now.addingTimeInterval(3600))
        #expect(!merged.isExpired(at: now))
        #expect(merged.isExpired(at: now.addingTimeInterval(3545)))
        #expect(!String(describing: merged).contains("sample-access-token-2"))
        #expect(!String(describing: merged).contains("sample-refresh-token"))
    }

    @Test("InMemoryTokenStore saves, loads, and clears tokens")
    func inMemoryTokenStoreLifecycle() async throws {
        let store = InMemoryTokenStore()
        #expect(try await store.load() == nil)

        let tokens = OAuthTokens(
            accessToken: "sample-access-1",
            refreshToken: "sample-refresh-1",
            expiresAt: Date(timeIntervalSince1970: 1_760_003_600)
        )
        try await store.save(tokens)
        #expect(try await store.load() == tokens)

        try await store.clear()
        #expect(try await store.load() == nil)
    }

    private func parseForm(_ body: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in body.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2,
               let key = parts[0].removingPercentEncoding,
               let value = parts[1].removingPercentEncoding
            {
                result[key] = value
            }
        }
        return result
    }
}
