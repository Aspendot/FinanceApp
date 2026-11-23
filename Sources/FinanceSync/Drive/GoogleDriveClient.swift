import Foundation

/// Metadata for a file stored in Google Drive's hidden `appDataFolder`.
public struct DriveFileMetadata: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String?
    public var modifiedTime: String?
    public var md5Checksum: String?
    /// File size in bytes as a decimal string, matching Google Drive API v3 JSON.
    public var size: String?

    public var sizeBytes: Int64? {
        size.flatMap(Int64.init)
    }

    public init(
        id: String,
        name: String? = nil,
        modifiedTime: String? = nil,
        md5Checksum: String? = nil,
        size: String? = nil
    ) {
        self.id = id
        self.name = name
        self.modifiedTime = modifiedTime
        self.md5Checksum = md5Checksum
        self.size = size
    }
}

/// Errors thrown by `GoogleDriveClient`, phrased without leaking OAuth tokens.
public enum GoogleDriveClientError: Error, LocalizedError, Equatable, Sendable {
    case notSignedIn
    case missingDriveScope
    case missingRefreshToken
    case invalidGrant
    case tokenRefreshFailed(String)
    case unauthorized
    case rateLimited(statusCode: Int, attempts: Int)
    case httpError(statusCode: Int, message: String?)
    case invalidFileID
    case invalidResponse(String)
    case networkError(String)

    public var requiresSignInAgain: Bool {
        switch self {
        case .invalidGrant, .missingRefreshToken, .unauthorized:
            return true
        default:
            return false
        }
    }

    public var requiresDriveConsent: Bool {
        if case .missingDriveScope = self { return true }
        return false
    }

    public var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "No Google account is signed in."
        case .missingDriveScope:
            return "Google Drive access is not granted yet. Turn on Drive sync to allow app-data access."
        case .missingRefreshToken:
            return "The Google session expired and cannot be refreshed. Sign in again."
        case .invalidGrant:
            return "Sign in to Google again."
        case .tokenRefreshFailed(let detail):
            return "Could not refresh the Google access token: \(detail)"
        case .unauthorized:
            return "Google Drive rejected the access token after refreshing. Sign in again."
        case .rateLimited(let statusCode, let attempts):
            return "Google Drive rate limit reached (HTTP \(statusCode)) after \(attempts) attempts."
        case .httpError(let statusCode, let message):
            if let message, !message.isEmpty {
                return "Google Drive request failed (HTTP \(statusCode)): \(message)"
            }
            return "Google Drive request failed (HTTP \(statusCode))."
        case .invalidFileID:
            return "The Google Drive file ID is empty or invalid."
        case .invalidResponse(let detail):
            return "Google Drive returned an unreadable response: \(detail)"
        case .networkError(let detail):
            return "Could not reach Google Drive: \(detail)"
        }
    }
}

/// Async client for reading the encrypted bundle from Google Drive's hidden `appDataFolder`.
public actor GoogleDriveClient {
    public static let defaultBaseURL = URL(string: "https://www.googleapis.com/drive/v3")!
    public static let bundleFileName = "finance-bundle.fnb"

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
    ]

    private static let insufficientScopeReasons: Set<String> = [
        "insufficientPermissions",
        "insufficientFilePermissions",
        "appNotAuthorizedToFile",
        "authError",
    ]

    public init(
        clientID: String,
        tokenStore: any TokenStore,
        transport: any HTTPTransport = URLSessionHTTPTransport(),
        sleeper: any Sleeper = TaskSleeper(),
        retryPolicy: RetryPolicy = .default,
        baseURL: URL = GoogleDriveClient.defaultBaseURL,
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

    /// Lists matching files in `appDataFolder` ordered newest-modified first.
    public func listAppDataFiles(name: String = GoogleDriveClient.bundleFileName) async throws -> [DriveFileMetadata] {
        let endpoint = baseURL.appendingPathComponent("files")
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw GoogleDriveClientError.invalidResponse("could not build Drive files URL.")
        }
        let escapedName = name
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        let query = [
            ("spaces", "appDataFolder"),
            ("q", "name = '\(escapedName)' and trashed = false"),
            ("fields", "nextPageToken,files(id,name,modifiedTime,md5Checksum,size)"),
            ("orderBy", "modifiedTime desc"),
            ("pageSize", "100"),
        ]
        var files: [DriveFileMetadata] = []
        var pageToken: String?
        var seenTokens: Set<String> = []
        repeat {
            var pairs = query
            if let pageToken {
                guard seenTokens.insert(pageToken).inserted else {
                    throw GoogleDriveClientError.invalidResponse("Drive returned a repeated page token.")
                }
                pairs.append(("pageToken", pageToken))
            }
            components.percentEncodedQuery = String(decoding: FormURLEncoder.encode(pairs), as: UTF8.self)
            guard let url = components.url else {
                throw GoogleDriveClientError.invalidResponse("could not build Drive files URL.")
            }
            let data = try await performAuthorizedGET(url, accept: "application/json")
            let page: DriveFileListEnvelope
            do {
                page = try JSONDecoder().decode(DriveFileListEnvelope.self, from: data)
            } catch {
                throw GoogleDriveClientError.invalidResponse("could not decode Drive file list JSON.")
            }
            files.append(contentsOf: page.files)
            pageToken = page.nextPageToken
        } while pageToken != nil
        return files
    }

    /// Downloads the raw bytes of a Drive file (`alt=media`).
    public func downloadFile(id: String) async throws -> Data {
        guard isValidFileID(id) else {
            throw GoogleDriveClientError.invalidFileID
        }
        let endpoint = baseURL
            .appendingPathComponent("files")
            .appendingPathComponent(id)
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw GoogleDriveClientError.invalidFileID
        }
        components.queryItems = [URLQueryItem(name: "alt", value: "media")]
        guard let url = components.url else {
            throw GoogleDriveClientError.invalidFileID
        }
        return try await performAuthorizedGET(url, accept: "application/octet-stream")
    }

    private func performAuthorizedGET(_ url: URL, accept: String) async throws -> Data {
        try Task.checkCancellation()
        guard var tokens = try await loadTokens() else {
            throw GoogleDriveClientError.notSignedIn
        }
        if let grantedScope = tokens.scope, !grantedScope.isEmpty,
           !tokens.hasScope(GoogleOAuth.driveAppDataScope)
        {
            throw GoogleDriveClientError.missingDriveScope
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
                    "Accept": accept,
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
                throw GoogleDriveClientError.unauthorized
            }

            if isInsufficientScopeError(response) {
                throw GoogleDriveClientError.missingDriveScope
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
                throw GoogleDriveClientError.rateLimited(
                    statusCode: response.statusCode,
                    attempts: rateLimitAttempt + 1
                )
            }

            throw GoogleDriveClientError.httpError(statusCode: response.statusCode, message: nil)
        }
    }

    private func loadTokens() async throws -> OAuthTokens? {
        do {
            return try await tokenStore.load()
        } catch {
            throw GoogleDriveClientError.tokenRefreshFailed("could not load or refresh Google credentials.")
        }
    }

    private func refreshTokens(from current: OAuthTokens) async throws -> OAuthTokens {
        guard let refreshToken = current.refreshToken, !refreshToken.isEmpty else {
            throw GoogleDriveClientError.missingRefreshToken
        }
        var refreshed: OAuthTokens
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
                throw GoogleDriveClientError.invalidGrant
            }
            throw GoogleDriveClientError.tokenRefreshFailed("Google rejected the token refresh.")
        } catch is HTTPTransportError {
            throw GoogleDriveClientError.networkError("the request could not complete.")
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw GoogleDriveClientError.tokenRefreshFailed("could not load or refresh Google credentials.")
        }

        try Task.checkCancellation()
        refreshed.mailboxFingerprint = current.mailboxFingerprint
        if refreshed.scope == nil {
            refreshed.scope = current.scope
        }
        do {
            try await tokenStore.save(refreshed)
        } catch {
            throw GoogleDriveClientError.tokenRefreshFailed("could not save refreshed tokens.")
        }
        return refreshed
    }

    private func sendRequest(_ request: HTTPRequest) async throws -> HTTPResponse {
        try Task.checkCancellation()
        do {
            return try await transport.send(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch is HTTPTransportError {
            try Task.checkCancellation()
            throw GoogleDriveClientError.networkError("the request could not complete.")
        } catch {
            try Task.checkCancellation()
            throw GoogleDriveClientError.networkError("the request could not complete.")
        }
    }

    private func isInsufficientScopeError(_ response: HTTPResponse) -> Bool {
        guard response.statusCode == 403 else { return false }
        if let header = response.headerValue(for: "WWW-Authenticate"),
           header.lowercased().contains("insufficient_scope")
        {
            return true
        }
        guard let envelope = parseDriveError(response.body) else { return false }
        if envelope.status?.uppercased() == "PERMISSION_DENIED",
           let msg = envelope.message?.lowercased(),
           msg.contains("insufficient") || msg.contains("scope")
        {
            return true
        }
        for detail in envelope.errors ?? [] {
            if let reason = detail.reason, Self.insufficientScopeReasons.contains(reason) {
                return true
            }
        }
        return false
    }

    private func isRateOrQuotaError(_ response: HTTPResponse) -> Bool {
        if response.statusCode == 429 {
            return true
        }
        guard response.statusCode == 403,
              let envelope = parseDriveError(response.body)
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

    private func parseDriveError(_ data: Data) -> DriveAPIErrorBody.Inner? {
        try? JSONDecoder().decode(DriveAPIErrorBody.self, from: data).error
    }

    private func isValidFileID(_ id: String) -> Bool {
        guard !id.isEmpty else { return false }
        for scalar in id.unicodeScalars {
            if scalar == "/" || scalar == "\\" || scalar == "?" || scalar == "#" || scalar.properties.isWhitespace {
                return false
            }
        }
        return true
    }
}

private struct DriveFileListEnvelope: Decodable {
    let files: [DriveFileMetadata]
    let nextPageToken: String?

    enum CodingKeys: String, CodingKey {
        case files, nextPageToken
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        files = try c.decodeIfPresent([DriveFileMetadata].self, forKey: .files) ?? []
        nextPageToken = try c.decodeIfPresent(String.self, forKey: .nextPageToken)
    }
}

private struct DriveAPIErrorBody: Decodable {
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
