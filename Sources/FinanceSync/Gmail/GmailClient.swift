import FinanceCore
import Foundation

/// Minimal message entry returned by Gmail's `users.messages.list` endpoint.
public struct GmailMessageStub: Codable, Equatable, Sendable {
    /// Gmail message identifier.
    public var id: String
    /// Gmail thread identifier, when present.
    public var threadId: String?

    public init(id: String, threadId: String? = nil) {
        self.id = id
        self.threadId = threadId
    }
}

/// One page returned by Gmail's `users.messages.list` endpoint.
public struct GmailMessageList: Codable, Equatable, Sendable {
    /// Matching message stubs on this page. Empty when no messages matched.
    public var messages: [GmailMessageStub]
    /// Token to pass to `listMessageIDs(pageToken:)` for the next page, if any.
    public var nextPageToken: String?
    /// Approximate total number of matching messages reported by Gmail.
    public var resultSizeEstimate: Int?

    enum CodingKeys: String, CodingKey {
        case messages
        case nextPageToken
        case resultSizeEstimate
    }

    public init(
        messages: [GmailMessageStub] = [],
        nextPageToken: String? = nil,
        resultSizeEstimate: Int? = nil
    ) {
        self.messages = messages
        self.nextPageToken = nextPageToken
        self.resultSizeEstimate = resultSizeEstimate
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.messages = try container.decodeIfPresent([GmailMessageStub].self, forKey: .messages) ?? []
        self.nextPageToken = try container.decodeIfPresent(String.self, forKey: .nextPageToken)
        self.resultSizeEstimate = try container.decodeIfPresent(Int.self, forKey: .resultSizeEstimate)
    }
}

/// Backoff configuration for retrying rate-limited Gmail API requests.
public struct RetryPolicy: Sendable, Equatable {
    /// Maximum number of retries after the initial attempt.
    public var maxRetries: Int
    /// Delay before the first retry when no `Retry-After` header is present.
    public var initialDelay: Duration
    /// Upper bound on any single retry delay.
    public var maxDelay: Duration
    /// Exponential multiplier applied to each consecutive retry attempt.
    public var backoffMultiplier: Double

    /// Default policy: up to 3 retries starting at 1 second, doubling up to 32 seconds.
    public static let `default` = RetryPolicy()

    public init(
        maxRetries: Int = 3,
        initialDelay: Duration = .seconds(1),
        maxDelay: Duration = .seconds(32),
        backoffMultiplier: Double = 2.0
    ) {
        self.maxRetries = max(0, maxRetries)
        self.initialDelay = initialDelay
        self.maxDelay = maxDelay
        self.backoffMultiplier = max(1.0, backoffMultiplier)
    }

    /// Computes the sleep duration for a zero-based retry attempt, honoring
    /// an integer `Retry-After` header (in seconds) when provided.
    public func delay(forAttempt attempt: Int, retryAfterHeader: String?) -> Duration {
        let maxSeconds = Self.seconds(from: maxDelay)
        if let raw = retryAfterHeader?.trimmingCharacters(in: .whitespacesAndNewlines),
           let retryAfterSeconds = Double(raw),
           retryAfterSeconds > 0
        {
            return .seconds(min(retryAfterSeconds, maxSeconds))
        }
        let baseSeconds = Self.seconds(from: initialDelay)
        var computed = baseSeconds
        if attempt > 0 {
            for _ in 0..<attempt {
                computed = min(computed * backoffMultiplier, maxSeconds)
                if computed >= maxSeconds {
                    break
                }
            }
        }
        return .seconds(min(computed, maxSeconds))
    }

    private static func seconds(from duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000.0
    }
}

/// Errors thrown by `GmailClient`, all phrased in plain English without leaking tokens.
public enum GmailClientError: Error, LocalizedError, Equatable, Sendable {
    /// No OAuth tokens are present in the token store.
    case notSignedIn
    /// The access token expired or was rejected and no refresh token is stored.
    case missingRefreshToken
    /// Google rejected the refresh token (`invalid_grant`, expired, or revoked).
    case invalidGrant
    /// Refreshing the access token failed.
    case tokenRefreshFailed(String)
    /// Gmail rejected the access token even after refreshing once.
    case unauthorized
    /// Gmail rate or quota limits persisted after all retry attempts.
    case rateLimited(statusCode: Int, attempts: Int)
    /// Gmail returned a non-2xx HTTP status that was not recoverable.
    case httpError(statusCode: Int, message: String?)
    /// A message ID was empty or contained invalid path characters.
    case invalidMessageID
    /// A response body could not be decoded as expected Gmail JSON.
    case invalidResponse(String)
    /// The underlying HTTP transport threw an error.
    case networkError(String)

    /// True when the stored OAuth session can no longer be used without signing in again.
    public var requiresSignInAgain: Bool {
        switch self {
        case .invalidGrant, .missingRefreshToken, .unauthorized:
            return true
        default:
            return false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "No Google account is signed in."
        case .missingRefreshToken:
            return "The Google session expired and cannot be refreshed. Sign in again."
        case .invalidGrant:
            return "Sign in to Gmail again"
        case .tokenRefreshFailed(let detail):
            return "Could not refresh the Google access token: \(detail)"
        case .unauthorized:
            return "Gmail rejected the access token after refreshing. Sign in again."
        case .rateLimited(let statusCode, let attempts):
            return "Gmail rate limit reached (HTTP \(statusCode)) after \(attempts) attempts."
        case .httpError(let statusCode, let message):
            if let message, !message.isEmpty {
                return "Gmail request failed with HTTP \(statusCode): \(message)"
            }
            return "Gmail request failed with HTTP \(statusCode)."
        case .invalidMessageID:
            return "The Gmail message ID is empty or invalid."
        case .invalidResponse(let detail):
            return "Gmail returned an unreadable response: \(detail)"
        case .networkError(let detail):
            return "Network request failed: \(detail)"
        }
    }
}

/// Async client for the read-only Gmail REST API.
///
/// Refreshes the access token once on HTTP 401 and backs off on HTTP 429
/// and HTTP 403 rate or quota errors using an injected `Sleeper`.
public actor GmailClient {
    /// Default Gmail REST API base URL.
    public static let defaultBaseURL = URL(string: "https://gmail.googleapis.com/gmail/v1")!

    private let clientID: String
    private let tokenStore: any TokenStore
    private let transport: any HTTPTransport
    private let sleeper: any Sleeper
    private let retryPolicy: RetryPolicy
    private let baseURL: URL
    private let now: @Sendable () -> Date

    private static let rateLimitReasons: Set<String> = [
        "rateLimitExceeded",
        "userRateLimitExceeded",
        "quotaExceeded",
        "dailyLimitExceeded",
        "dailyLimitExceededUnreg",
        "rateLimitExceededUnreg",
    ]

    public init(
        clientID: String,
        tokenStore: any TokenStore,
        transport: any HTTPTransport = URLSessionHTTPTransport(),
        sleeper: any Sleeper = TaskSleeper(),
        retryPolicy: RetryPolicy = .default,
        baseURL: URL = GmailClient.defaultBaseURL,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.clientID = clientID
        self.tokenStore = tokenStore
        self.transport = transport
        self.sleeper = sleeper
        self.retryPolicy = retryPolicy
        self.baseURL = baseURL
        self.now = now
    }

    /// Lists message IDs matching an optional Gmail search query.
    public func listMessageIDs(
        query: String? = nil,
        maxResults: Int? = nil,
        pageToken: String? = nil
    ) async throws -> GmailMessageList {
        let endpoint = baseURL
            .appendingPathComponent("users")
            .appendingPathComponent("me")
            .appendingPathComponent("messages")

        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw GmailClientError.invalidResponse("could not build messages list URL.")
        }

        var items: [URLQueryItem] = []
        if let query, !query.isEmpty {
            items.append(URLQueryItem(name: "q", value: query))
        }
        if let maxResults {
            items.append(URLQueryItem(name: "maxResults", value: String(maxResults)))
        }
        if let pageToken, !pageToken.isEmpty {
            items.append(URLQueryItem(name: "pageToken", value: pageToken))
        }
        if !items.isEmpty {
            components.queryItems = items
        }
        guard let url = components.url else {
            throw GmailClientError.invalidResponse("could not build messages list URL.")
        }

        let data = try await performAuthorizedGET(url)
        do {
            return try JSONDecoder().decode(GmailMessageList.self, from: data)
        } catch {
            throw GmailClientError.invalidResponse("could not decode message list JSON.")
        }
    }

    /// Fetches a single Gmail message with `format=full`.
    public func message(id: String) async throws -> GmailMessage {
        guard isValidMessageID(id) else {
            throw GmailClientError.invalidMessageID
        }
        let endpoint = baseURL
            .appendingPathComponent("users")
            .appendingPathComponent("me")
            .appendingPathComponent("messages")
            .appendingPathComponent(id)

        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw GmailClientError.invalidMessageID
        }
        components.queryItems = [URLQueryItem(name: "format", value: "full")]
        guard let url = components.url else {
            throw GmailClientError.invalidMessageID
        }

        let data = try await performAuthorizedGET(url)
        do {
            return try JSONDecoder().decode(GmailMessage.self, from: data)
        } catch {
            throw GmailClientError.invalidResponse("could not decode Gmail message JSON.")
        }
    }

    private func performAuthorizedGET(_ url: URL) async throws -> Data {
        guard var tokens = try await loadTokens() else {
            throw GmailClientError.notSignedIn
        }

        var hasRefreshed = false
        if tokens.isExpired(at: now()) {
            tokens = try await refreshTokens(from: tokens)
            hasRefreshed = true
        }

        var rateLimitAttempt = 0
        while true {
            let request = HTTPRequest(
                method: "GET",
                url: url,
                headers: [
                    "Authorization": "Bearer \(tokens.accessToken)",
                    "Accept": "application/json",
                ]
            )
            let response = try await sendRequest(request)

            if (200...299).contains(response.statusCode) {
                return response.body
            }

            if response.statusCode == 401 {
                if !hasRefreshed {
                    tokens = try await refreshTokens(from: tokens)
                    hasRefreshed = true
                    continue
                }
                throw GmailClientError.unauthorized
            }

            if isRateOrQuotaError(response) {
                if rateLimitAttempt < retryPolicy.maxRetries {
                    let delay = retryPolicy.delay(
                        forAttempt: rateLimitAttempt,
                        retryAfterHeader: response.headerValue(for: "Retry-After")
                    )
                    rateLimitAttempt += 1
                    try await sleeper.sleep(for: delay)
                    continue
                }
                throw GmailClientError.rateLimited(
                    statusCode: response.statusCode,
                    attempts: rateLimitAttempt + 1
                )
            }

            let errorMessage = parseGmailError(response.body)?.message
            throw GmailClientError.httpError(statusCode: response.statusCode, message: errorMessage)
        }
    }

    private func loadTokens() async throws -> OAuthTokens? {
        do {
            return try await tokenStore.load()
        } catch {
            throw GmailClientError.tokenRefreshFailed(error.localizedDescription)
        }
    }

    private func refreshTokens(from current: OAuthTokens) async throws -> OAuthTokens {
        guard let refreshToken = current.refreshToken, !refreshToken.isEmpty else {
            throw GmailClientError.missingRefreshToken
        }
        let refreshed: OAuthTokens
        do {
            refreshed = try await GoogleOAuth.refreshAccessToken(
                clientID: clientID,
                refreshToken: refreshToken,
                transport: transport,
                now: now()
            )
        } catch let oauthError as OAuthError {
            if case .tokenEndpointError(_, let code, _) = oauthError,
               code?.lowercased() == "invalid_grant"
            {
                throw GmailClientError.invalidGrant
            }
            throw GmailClientError.tokenRefreshFailed(oauthError.localizedDescription)
        } catch let transportError as HTTPTransportError {
            throw GmailClientError.networkError(transportError.localizedDescription)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw GmailClientError.tokenRefreshFailed(error.localizedDescription)
        }

        do {
            try await tokenStore.save(refreshed)
        } catch {
            throw GmailClientError.tokenRefreshFailed("could not save refreshed tokens.")
        }
        return refreshed
    }

    private func sendRequest(_ request: HTTPRequest) async throws -> HTTPResponse {
        do {
            return try await transport.send(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let transportError as HTTPTransportError {
            throw GmailClientError.networkError(transportError.localizedDescription)
        } catch {
            throw GmailClientError.networkError(error.localizedDescription)
        }
    }

    private func isRateOrQuotaError(_ response: HTTPResponse) -> Bool {
        if response.statusCode == 429 {
            return true
        }
        guard response.statusCode == 403,
              let envelope = parseGmailError(response.body)
        else {
            return false
        }
        if envelope.status?.uppercased() == "RESOURCE_EXHAUSTED" {
            return true
        }
        for detail in envelope.errors ?? [] {
            if detail.domain == "usageLimits" {
                return true
            }
            if let reason = detail.reason, Self.rateLimitReasons.contains(reason) {
                return true
            }
        }
        return false
    }

    private func parseGmailError(_ data: Data) -> GmailAPIErrorBody.Inner? {
        try? JSONDecoder().decode(GmailAPIErrorBody.self, from: data).error
    }

    private func isValidMessageID(_ id: String) -> Bool {
        guard !id.isEmpty else { return false }
        for scalar in id.unicodeScalars {
            if scalar == "/" || scalar == "\\" || scalar == "?" || scalar == "#" || scalar.properties.isWhitespace {
                return false
            }
        }
        return true
    }
}

private struct GmailAPIErrorBody: Decodable {
    struct Inner: Decodable {
        struct Detail: Decodable {
            var domain: String?
            var reason: String?
            var message: String?
        }

        var code: Int?
        var message: String?
        var status: String?
        var errors: [Detail]?
    }

    var error: Inner?
}
