import FinanceCore
import Foundation

/// One accounting fiscal period returned by `/api/v3/accessible_offices` or `/api/v3/offices`.
public struct MoneyForwardAccountingPeriod: Codable, Equatable, Sendable {
    public var startDate: String
    public var endDate: String
    public var fiscalYear: Int

    enum CodingKeys: String, CodingKey {
        case startDate = "start_date"
        case endDate = "end_date"
        case fiscalYear = "fiscal_year"
    }

    public init(startDate: String, endDate: String, fiscalYear: Int) {
        self.startDate = startDate
        self.endDate = endDate
        self.fiscalYear = fiscalYear
    }
}

/// One Money Forward Cloud Accounting office (`事業者`).
public struct MoneyForwardOffice: Codable, Equatable, Sendable, Identifiable {
    public var id: String { code }
    public var name: String
    public var code: String
    public var type: String
    public var accountingPeriods: [MoneyForwardAccountingPeriod]

    enum CodingKeys: String, CodingKey {
        case name
        case code
        case type
        case accountingPeriods = "accounting_periods"
    }

    public init(
        name: String,
        code: String,
        type: String,
        accountingPeriods: [MoneyForwardAccountingPeriod] = []
    ) {
        self.name = name
        self.code = code
        self.type = type
        self.accountingPeriods = accountingPeriods
    }
}

/// One sub-account under a Money Forward connected service (`connected_sub_accounts`).
public struct MoneyForwardConnectedSubAccount: Codable, Equatable, Sendable, Identifiable {
    /// Already URL-encoded ID returned by Money Forward. Keep verbatim.
    public var id: String
    public var name: String
    public var accountID: String?
    public var subAccountID: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case accountID = "account_id"
        case subAccountID = "sub_account_id"
    }

    public init(id: String, name: String, accountID: String? = nil, subAccountID: String? = nil) {
        self.id = id
        self.name = name
        self.accountID = accountID
        self.subAccountID = subAccountID
    }
}

/// One connected service returned by `GET /api/v3/connected_accounts`.
public struct MoneyForwardConnectedAccount: Codable, Equatable, Sendable, Identifiable {
    /// Already URL-encoded ID returned by Money Forward. Keep verbatim.
    public var id: String
    public var name: String
    public var isManual: Bool
    public var accountID: String?
    public var subAccountID: String?
    public var connectedSubAccounts: [MoneyForwardConnectedSubAccount]

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case isManual = "is_manual"
        case accountID = "account_id"
        case subAccountID = "sub_account_id"
        case connectedSubAccounts = "connected_sub_accounts"
    }

    public init(
        id: String,
        name: String,
        isManual: Bool = false,
        accountID: String? = nil,
        subAccountID: String? = nil,
        connectedSubAccounts: [MoneyForwardConnectedSubAccount] = []
    ) {
        self.id = id
        self.name = name
        self.isManual = isManual
        self.accountID = accountID
        self.subAccountID = subAccountID
        self.connectedSubAccounts = connectedSubAccounts
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        isManual = try c.decodeIfPresent(Bool.self, forKey: .isManual) ?? false
        accountID = try c.decodeIfPresent(String.self, forKey: .accountID)
        subAccountID = try c.decodeIfPresent(String.self, forKey: .subAccountID)
        connectedSubAccounts = try c.decodeIfPresent([MoneyForwardConnectedSubAccount].self, forKey: .connectedSubAccounts) ?? []
    }

    /// Flattens this connected service into the entries the owner maps to bundle sources:
    /// one row per sub-account when `connectedSubAccounts` is non-empty, or the service itself otherwise.
    public var mappableAccounts: [MoneyForwardMappableAccount] {
        if connectedSubAccounts.isEmpty {
            return [MoneyForwardMappableAccount(
                id: id,
                parentAccountID: id,
                isSubAccount: false,
                displayName: name
            )]
        }
        return connectedSubAccounts.map { sub in
            MoneyForwardMappableAccount(
                id: sub.id,
                parentAccountID: id,
                isSubAccount: true,
                displayName: "\(name) · \(sub.name)"
            )
        }
    }
}

/// Flattened account entry displayed in the account-mapping settings list.
public struct MoneyForwardMappableAccount: Equatable, Sendable, Identifiable {
    /// Key stored in the local mapping (`connected_sub_account_id` or `connected_account_id`).
    public var id: String
    /// Parent `connected_account_id`.
    public var parentAccountID: String
    public var isSubAccount: Bool
    public var displayName: String

    public init(id: String, parentAccountID: String, isSubAccount: Bool, displayName: String) {
        self.id = id
        self.parentAccountID = parentAccountID
        self.isSubAccount = isSubAccount
        self.displayName = displayName
    }
}

/// One page returned by `GET /api/v3/transactions`.
public struct MoneyForwardTransactionsPage: Equatable, Sendable {
    public var transactions: [BankTransaction]
    public var totalCount: Int
    public var totalPages: Int

    public init(transactions: [BankTransaction], totalCount: Int, totalPages: Int) {
        self.transactions = transactions
        self.totalCount = totalCount
        self.totalPages = totalPages
    }
}

/// Result of fetching all paginated transactions across a date range.
public struct MoneyForwardFetchResult: Equatable, Sendable {
    public var transactions: [BankTransaction]
    public var reachedDeadline: Bool
    public var pagesFetched: Int

    public init(transactions: [BankTransaction], reachedDeadline: Bool = false, pagesFetched: Int = 0) {
        self.transactions = transactions
        self.reachedDeadline = reachedDeadline
        self.pagesFetched = pagesFetched
    }
}

/// Errors thrown by `MoneyForwardClient`, phrased without leaking API keys or tokens.
public enum MoneyForwardClientError: Error, LocalizedError, Equatable, Sendable {
    case notConnected
    case missingOfficeCode
    case invalidCredentials
    case unauthorized
    case forbidden(code: String?, message: String?)
    case rateLimited(statusCode: Int, attempts: Int)
    case maintenanceOrServerError(statusCode: Int, message: String?)
    case httpError(statusCode: Int, code: String?, message: String?)
    case invalidDateRange(String)
    case invalidResponse(String)
    case networkError(String)

    /// True when the stored API key or OAuth session was rejected and the user must reconnect.
    public var requiresReconnect: Bool {
        switch self {
        case .invalidCredentials, .unauthorized:
            return true
        default:
            return false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Money Forward is not connected."
        case .missingOfficeCode:
            return "No Money Forward office code is configured."
        case .invalidCredentials, .unauthorized:
            return "Reconnect Money Forward"
        case .forbidden:
            return "Money Forward refused access (plan or permission, HTTP 403)"
        case .rateLimited(let statusCode, let attempts):
            return "Money Forward rate limit reached (HTTP \(statusCode)) after \(attempts) attempts."
        case .maintenanceOrServerError(let statusCode, _):
            return "Money Forward is temporarily unavailable (HTTP \(statusCode))."
        case .httpError(let statusCode, let code, let message):
            if let message, !message.isEmpty {
                return "Money Forward request failed (HTTP \(statusCode)): \(message)"
            }
            if let code, !code.isEmpty {
                return "Money Forward request failed (HTTP \(statusCode), \(code))."
            }
            return "Money Forward request failed (HTTP \(statusCode))."
        case .invalidDateRange(let reason):
            return "Invalid Money Forward date range: \(reason)"
        case .invalidResponse(let detail):
            return "Money Forward returned an unreadable response: \(detail)"
        case .networkError(let detail):
            return "Could not reach Money Forward: \(detail)"
        }
    }
}

/// Async client for the Money Forward Cloud Accounting API V3.
///
/// Supports API-key authentication (exchanging the key at `POST /auth/exchange` for a
/// cached 1-hour JWT and sending `office_code`) and OAuth 2.0 Bearer tokens.
/// Retries HTTP 429 and transient 5xx responses with backoff, respects deadlines and
/// cancellation, and preserves already-URL-encoded Money Forward IDs in query strings.
public actor MoneyForwardClient {
    public static let defaultBaseURL = URL(string: "https://api-accounting.moneyforward.com")!
    /// Maximum inclusive day difference allowed by `GET /api/v3/transactions`.
    public static let maxDateSpanDays = 366

    private let credentialStore: any MoneyForwardCredentialStore
    private let transport: any HTTPTransport
    private let sleeper: any Sleeper
    private let retryPolicy: RetryPolicy
    private let baseURL: URL
    private let exchangeEndpoint: URL
    private let tokenEndpoint: URL
    private let now: @Sendable () -> Date

    public init(
        credentialStore: any MoneyForwardCredentialStore,
        transport: any HTTPTransport = URLSessionHTTPTransport(),
        sleeper: any Sleeper = TaskSleeper(),
        retryPolicy: RetryPolicy = .default,
        baseURL: URL = MoneyForwardClient.defaultBaseURL,
        exchangeEndpoint: URL = MoneyForwardAuth.exchangeEndpoint,
        tokenEndpoint: URL = MoneyForwardAuth.tokenEndpoint,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.credentialStore = credentialStore
        self.transport = transport
        self.sleeper = sleeper
        self.retryPolicy = retryPolicy
        self.baseURL = baseURL
        self.exchangeEndpoint = exchangeEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.now = now
    }

    /// Returns `true` during Money Forward's nightly maintenance window (01:00–06:00 JST).
    public static func isInNightlyMaintenance(at date: Date = Date()) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = JST.timeZone
        let hour = calendar.component(.hour, from: date)
        return (1..<6).contains(hour)
    }

    /// Lists offices accessible to the current API key or OAuth token (`GET /api/v3/accessible_offices`).
    /// Does not require `office_code`.
    public func listAccessibleOffices(deadline: Date? = nil) async throws -> [MoneyForwardOffice] {
        let url = try buildURL(path: "/api/v3/accessible_offices", rawQueryPairs: [])
        let data = try await performAuthorizedGET(url, deadline: deadline)
        do {
            return try JSONDecoder().decode(AccessibleOfficesEnvelope.self, from: data).accessibleOffices
        } catch {
            throw MoneyForwardClientError.invalidResponse("could not decode accessible offices JSON.")
        }
    }

    /// Fetches details for the target office (`GET /api/v3/offices`).
    public func currentOffice(officeCode: String? = nil, deadline: Date? = nil) async throws -> MoneyForwardOffice {
        let query = try await officeCodeQueryPairs(explicitOfficeCode: officeCode)
        let url = try buildURL(path: "/api/v3/offices", rawQueryPairs: query)
        let data = try await performAuthorizedGET(url, deadline: deadline)
        do {
            return try JSONDecoder().decode(MoneyForwardOffice.self, from: data)
        } catch {
            throw MoneyForwardClientError.invalidResponse("could not decode office JSON.")
        }
    }

    /// Lists connected financial institutions and their sub-accounts (`GET /api/v3/connected_accounts`).
    public func listConnectedAccounts(officeCode: String? = nil, deadline: Date? = nil) async throws -> [MoneyForwardConnectedAccount] {
        let query = try await officeCodeQueryPairs(explicitOfficeCode: officeCode)
        let url = try buildURL(path: "/api/v3/connected_accounts", rawQueryPairs: query)
        let data = try await performAuthorizedGET(url, deadline: deadline)
        do {
            return try JSONDecoder().decode(ConnectedAccountsEnvelope.self, from: data).connectedAccounts
        } catch {
            throw MoneyForwardClientError.invalidResponse("could not decode connected accounts JSON.")
        }
    }

    /// Fetches one page of transactions (`GET /api/v3/transactions`).
    ///
    /// `connectedAccountID` and `connectedSubAccountID` are mutually exclusive and are
    /// inserted verbatim (not double-encoded) as required by the Money Forward V3 spec.
    public func transactionsPage(
        startDate: String,
        endDate: String,
        officeCode: String? = nil,
        connectedAccountID: String? = nil,
        connectedSubAccountID: String? = nil,
        page: Int = 1,
        perPage: Int = 100,
        order: String = "desc",
        deadline: Date? = nil
    ) async throws -> MoneyForwardTransactionsPage {
        try validateDateRange(startDate: startDate, endDate: endDate)
        if connectedAccountID != nil, connectedSubAccountID != nil {
            throw MoneyForwardClientError.invalidDateRange("connected_account_id and connected_sub_account_id cannot both be set.")
        }

        let clampedPage = max(1, page)
        let clampedPerPage = min(500, max(10, perPage))
        var pairs = try await officeCodeQueryPairs(explicitOfficeCode: officeCode)
        pairs.append(("start_date", FormURLEncoder.percentEncode(startDate)))
        pairs.append(("end_date", FormURLEncoder.percentEncode(endDate)))
        if let accountID = connectedAccountID, !accountID.isEmpty {
            // Money Forward returns IDs already URL-encoded; do not double-encode.
            pairs.append(("connected_account_id", accountID))
        } else if let subAccountID = connectedSubAccountID, !subAccountID.isEmpty {
            pairs.append(("connected_sub_account_id", subAccountID))
        }
        pairs.append(("order", FormURLEncoder.percentEncode(order)))
        pairs.append(("page", String(clampedPage)))
        pairs.append(("per_page", String(clampedPerPage)))

        let url = try buildURL(path: "/api/v3/transactions", rawQueryPairs: pairs)
        let data = try await performAuthorizedGET(url, deadline: deadline)

        let envelope: TransactionsEnvelope
        do {
            envelope = try JSONDecoder().decode(TransactionsEnvelope.self, from: data)
        } catch {
            throw MoneyForwardClientError.invalidResponse("could not decode transactions JSON.")
        }

        var converted: [BankTransaction] = []
        converted.reserveCapacity(envelope.transactions.count)
        for dto in envelope.transactions {
            guard let amount = BankTransaction.signedAmount(value: dto.value, rawSide: dto.side) else {
                throw MoneyForwardClientError.invalidResponse("unexpected transaction value/side in response.")
            }
            converted.append(BankTransaction(
                id: dto.id,
                connectedAccountID: dto.connectedAccountID,
                connectedSubAccountID: dto.connectedSubAccountID,
                date: dto.date,
                amount: amount,
                description: dto.content ?? "",
                memo: dto.memo,
                journalizingStatus: dto.journalizingStatus
            ))
        }

        return MoneyForwardTransactionsPage(
            transactions: converted,
            totalCount: envelope.metadata.totalCount,
            totalPages: envelope.metadata.totalPages
        )
    }

    /// Fetches all pages of transactions across `[startDate, endDate]`.
    ///
    /// Automatically chunks ranges wider than 366 days, stops cleanly if `deadline` is
    /// reached (returning transactions fetched so far with `reachedDeadline == true`),
    /// and deduplicates transactions by ID.
    public func fetchAllTransactions(
        startDate: String,
        endDate: String,
        officeCode: String? = nil,
        connectedAccountID: String? = nil,
        connectedSubAccountID: String? = nil,
        perPage: Int = 100,
        order: String = "desc",
        deadline: Date? = nil
    ) async throws -> MoneyForwardFetchResult {
        guard let startDay = JST.dayNumber(startDate), let endDay = JST.dayNumber(endDate) else {
            throw MoneyForwardClientError.invalidDateRange("dates must be YYYY-MM-DD.")
        }
        guard startDay <= endDay else {
            throw MoneyForwardClientError.invalidDateRange("start_date must be on or before end_date.")
        }

        // Split into <= 366-day windows, newest window first so partial deadline runs get recent rows first.
        var windows: [(String, String)] = []
        var windowEnd = endDay
        while windowEnd >= startDay {
            let windowStart = max(startDay, windowEnd - Self.maxDateSpanDays)
            windows.append((JST.day(fromDayNumber: windowStart), JST.day(fromDayNumber: windowEnd)))
            windowEnd = windowStart - 1
        }

        var seenIDs = Set<String>()
        var allTransactions: [BankTransaction] = []
        var pagesFetched = 0
        var reachedDeadline = false

        outer: for (winStart, winEnd) in windows {
            var page = 1
            while true {
                try Task.checkCancellation()
                if let deadline, now() >= deadline {
                    reachedDeadline = true
                    break outer
                }

                let result = try await transactionsPage(
                    startDate: winStart,
                    endDate: winEnd,
                    officeCode: officeCode,
                    connectedAccountID: connectedAccountID,
                    connectedSubAccountID: connectedSubAccountID,
                    page: page,
                    perPage: perPage,
                    order: order,
                    deadline: deadline
                )
                pagesFetched += 1
                for tx in result.transactions where seenIDs.insert(tx.id).inserted {
                    allTransactions.append(tx)
                }

                if page >= result.totalPages || result.transactions.isEmpty {
                    break
                }
                page += 1
            }
        }

        return MoneyForwardFetchResult(
            transactions: allTransactions,
            reachedDeadline: reachedDeadline,
            pagesFetched: pagesFetched
        )
    }

    private func validateDateRange(startDate: String, endDate: String) throws {
        guard let startDay = JST.dayNumber(startDate), let endDay = JST.dayNumber(endDate) else {
            throw MoneyForwardClientError.invalidDateRange("dates must be YYYY-MM-DD.")
        }
        guard startDay <= endDay else {
            throw MoneyForwardClientError.invalidDateRange("start_date must be on or before end_date.")
        }
        guard endDay - startDay <= Self.maxDateSpanDays else {
            throw MoneyForwardClientError.invalidDateRange("date span exceeds \(Self.maxDateSpanDays) days.")
        }
    }

    private func officeCodeQueryPairs(explicitOfficeCode: String?) async throws -> [(String, String)] {
        guard let creds = try await loadCredentials() else {
            throw MoneyForwardClientError.notConnected
        }
        guard creds.mode == .apiKey else {
            return []
        }
        let code = (explicitOfficeCode ?? creds.apiKey?.officeCode)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let code, !code.isEmpty else {
            throw MoneyForwardClientError.missingOfficeCode
        }
        return [("office_code", FormURLEncoder.percentEncode(code))]
    }

    private func buildURL(path: String, rawQueryPairs: [(String, String)]) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw MoneyForwardClientError.invalidResponse("could not build Money Forward URL.")
        }
        let basePath = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = basePath + path
        if !rawQueryPairs.isEmpty {
            components.percentEncodedQuery = rawQueryPairs
                .map { "\($0.0)=\($0.1)" }
                .joined(separator: "&")
        }
        guard let url = components.url else {
            throw MoneyForwardClientError.invalidResponse("could not construct Money Forward request URL.")
        }
        return url
    }

    private func performAuthorizedGET(_ url: URL, deadline: Date?) async throws -> Data {
        try Task.checkCancellation()
        var bearer = try await currentAccessToken(forceRefresh: false)
        var hasRefreshed = false
        var retryAttempt = 0

        while true {
            try Task.checkCancellation()
            let request = HTTPRequest(
                method: "GET",
                url: url,
                headers: [
                    "Authorization": "Bearer \(bearer)",
                    "Accept": "application/json",
                ]
            )
            let response = try await sendRequest(request)

            if (200...299).contains(response.statusCode) {
                return response.body
            }

            if response.statusCode == 401 {
                if !hasRefreshed {
                    bearer = try await currentAccessToken(forceRefresh: true)
                    hasRefreshed = true
                    continue
                }
                throw MoneyForwardClientError.unauthorized
            }

            if response.statusCode == 403 {
                let err = Self.parseFirstError(response.body)
                throw MoneyForwardClientError.forbidden(code: err?.code, message: err?.message)
            }

            let isRetryable = response.statusCode == 429 || (500...599).contains(response.statusCode)
            if isRetryable {
                if retryAttempt < retryPolicy.maxRetries {
                    let delay = retryPolicy.delay(
                        forAttempt: retryAttempt,
                        retryAfterHeader: response.headerValue(for: "Retry-After")
                    )
                    if let deadline, now().addingTimeInterval(Self.seconds(from: delay)) >= deadline {
                        if response.statusCode == 429 {
                            throw MoneyForwardClientError.rateLimited(statusCode: 429, attempts: retryAttempt + 1)
                        }
                        throw MoneyForwardClientError.maintenanceOrServerError(
                            statusCode: response.statusCode,
                            message: Self.parseFirstError(response.body)?.message
                        )
                    }
                    retryAttempt += 1
                    try await sleeper.sleep(for: delay)
                    continue
                }
                if response.statusCode == 429 {
                    throw MoneyForwardClientError.rateLimited(statusCode: 429, attempts: retryAttempt + 1)
                }
                throw MoneyForwardClientError.maintenanceOrServerError(
                    statusCode: response.statusCode,
                    message: Self.parseFirstError(response.body)?.message
                )
            }

            let err = Self.parseFirstError(response.body)
            throw MoneyForwardClientError.httpError(
                statusCode: response.statusCode,
                code: err?.code,
                message: err?.message
            )
        }
    }

    private func currentAccessToken(forceRefresh: Bool) async throws -> String {
        guard var creds = try await loadCredentials() else {
            throw MoneyForwardClientError.notConnected
        }

        switch creds.mode {
        case .apiKey:
            guard var apiKeyCreds = creds.apiKey, !apiKeyCreds.apiKey.isEmpty else {
                throw MoneyForwardClientError.invalidCredentials
            }
            if !forceRefresh, apiKeyCreds.hasValidJWT(at: now()), let jwt = apiKeyCreds.cachedJWT {
                return jwt
            }
            let exchanged = try await exchangeAPIKeyWithRetries(apiKeyCreds.apiKey)
            apiKeyCreds.cachedJWT = exchanged.accessToken
            apiKeyCreds.jwtExpiresAt = exchanged.expiresAt
            creds.apiKey = apiKeyCreds
            try await saveCredentials(creds)
            return exchanged.accessToken

        case .oauth:
            guard let config = creds.oauthConfig, let tokens = creds.oauthTokens else {
                throw MoneyForwardClientError.invalidCredentials
            }
            if !forceRefresh, !tokens.isExpired(at: now()) {
                return tokens.accessToken
            }
            guard let refreshToken = tokens.refreshToken, !refreshToken.isEmpty else {
                throw MoneyForwardClientError.invalidCredentials
            }
            let refreshed = try await MoneyForwardAuth.refreshAccessToken(
                config: config,
                refreshToken: refreshToken,
                transport: transport,
                endpoint: tokenEndpoint,
                now: now()
            )
            creds.oauthTokens = refreshed
            try await saveCredentials(creds)
            return refreshed.accessToken
        }
    }

    private func exchangeAPIKeyWithRetries(_ apiKey: String) async throws -> (accessToken: String, expiresAt: Date) {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                return try await MoneyForwardAuth.exchangeAPIKey(
                    apiKey,
                    transport: transport,
                    endpoint: exchangeEndpoint,
                    now: now()
                )
            } catch let error as MoneyForwardClientError {
                let retryable: Bool
                switch error {
                case .rateLimited, .maintenanceOrServerError:
                    retryable = true
                default:
                    retryable = false
                }
                if retryable, attempt < retryPolicy.maxRetries {
                    let delay = retryPolicy.delay(forAttempt: attempt, retryAfterHeader: nil)
                    attempt += 1
                    try await sleeper.sleep(for: delay)
                    continue
                }
                throw error
            }
        }
    }

    private func loadCredentials() async throws -> MoneyForwardCredentials? {
        do {
            return try await credentialStore.load()
        } catch {
            throw MoneyForwardClientError.networkError("could not load Money Forward credentials.")
        }
    }

    private func saveCredentials(_ credentials: MoneyForwardCredentials) async throws {
        do {
            try await credentialStore.save(credentials)
        } catch {
            throw MoneyForwardClientError.networkError("could not save Money Forward credentials.")
        }
    }

    private func sendRequest(_ request: HTTPRequest) async throws -> HTTPResponse {
        try Task.checkCancellation()
        do {
            return try await transport.send(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let transportError as HTTPTransportError {
            try Task.checkCancellation()
            throw MoneyForwardClientError.networkError(transportError.localizedDescription)
        } catch {
            try Task.checkCancellation()
            throw MoneyForwardClientError.networkError(error.localizedDescription)
        }
    }

    private static func seconds(from duration: Duration) -> Double {
        let c = duration.components
        return Double(c.seconds) + Double(c.attoseconds) / 1_000_000_000_000_000_000.0
    }

    static func parseFirstError(_ data: Data) -> MoneyForwardAPIErrorItem? {
        try? JSONDecoder().decode(MoneyForwardAPIErrorEnvelope.self, from: data).errors.first
    }
}

struct MoneyForwardAPIErrorItem: Decodable {
    let code: String?
    let message: String?
}

private struct MoneyForwardAPIErrorEnvelope: Decodable {
    let errors: [MoneyForwardAPIErrorItem]
}

private struct AccessibleOfficesEnvelope: Decodable {
    let accessibleOffices: [MoneyForwardOffice]

    enum CodingKeys: String, CodingKey {
        case accessibleOffices = "accessible_offices"
    }
}

private struct ConnectedAccountsEnvelope: Decodable {
    let connectedAccounts: [MoneyForwardConnectedAccount]

    enum CodingKeys: String, CodingKey {
        case connectedAccounts = "connected_accounts"
    }
}

private struct TransactionsEnvelope: Decodable {
    struct Metadata: Decodable {
        let totalCount: Int
        let totalPages: Int

        enum CodingKeys: String, CodingKey {
            case totalCount = "total_count"
            case totalPages = "total_pages"
        }
    }

    struct TransactionDTO: Decodable {
        let id: String
        let date: String
        let value: Int
        let side: String
        let content: String?
        let memo: String?
        let journalizingStatus: String?
        let connectedAccountID: String
        let connectedSubAccountID: String?

        enum CodingKeys: String, CodingKey {
            case id
            case date
            case value
            case side
            case content
            case memo
            case journalizingStatus = "journalizing_status"
            case connectedAccountID = "connected_account_id"
            case connectedSubAccountID = "connected_sub_account_id"
        }
    }

    let transactions: [TransactionDTO]
    let metadata: Metadata
}
