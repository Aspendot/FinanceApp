import FinanceCore
import Foundation
import Testing
@testable import FinanceSync

// Invented Money Forward Cloud Accounting API V3 fixtures following the documented OpenAPI schema.

@Suite("MoneyForwardAuth and MoneyForwardClient")
struct MoneyForwardClientTests {
    private let sampleAPIKey = "mf_api_pro_sample0123456789abcdef"
    private let sampleOfficeCode = "1234-5678"

    @Test("API key exchange caches JWT, reuses it, and redacts credentials")
    func apiKeyExchangeAndCaching() async throws {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let store = InMemoryMoneyForwardCredentialStore(
            credentials: MoneyForwardCredentials(
                apiKey: MoneyForwardAPIKeyCredentials(apiKey: sampleAPIKey, officeCode: sampleOfficeCode)
            )
        )
        let transport = FakeHTTPTransport()
        await transport.enqueue(try TestJSON.response(json: [
            "access_token": "sample-jwt-token-1",
            "token_type": "Bearer",
            "expires_in": 3600,
        ]))
        await transport.enqueue(try TestJSON.response(json: [
            "accessible_offices": [
                [
                    "name": "Sample Sole Proprietor",
                    "code": "1234-5678",
                    "type": "INDIVIDUAL",
                    "accounting_periods": [
                        ["start_date": "2026-01-01", "end_date": "2026-12-31", "fiscal_year": 2026],
                    ],
                ],
            ],
        ]))
        await transport.enqueue(try TestJSON.response(json: [
            "connected_accounts": [
                [
                    "id": "BowMhLnFvzZ1y9TeF5%2B3QQ%3D%3D",
                    "name": "サンプル銀行1",
                    "is_manual": false,
                    "account_id": NSNull(),
                    "sub_account_id": NSNull(),
                    "connected_sub_accounts": [
                        [
                            "id": "Sb0m10vvYk2dUdLU8aGxgQ%3D%3D",
                            "name": "普通預金1",
                            "account_id": "AccId%3D%3D",
                            "sub_account_id": NSNull(),
                        ],
                    ],
                ],
            ],
        ]))

        let client = MoneyForwardClient(
            credentialStore: store,
            transport: transport,
            sleeper: RecordingSleeper(),
            now: { now }
        )

        let offices = try await client.listAccessibleOffices()
        #expect(offices.count == 1)
        #expect(offices[0].code == "1234-5678")
        #expect(offices[0].type == "INDIVIDUAL")

        // Second call reuses the cached JWT without hitting /auth/exchange again.
        let accounts = try await client.listConnectedAccounts()
        #expect(accounts.count == 1)
        #expect(accounts[0].mappableAccounts == [
            MoneyForwardMappableAccount(
                id: "Sb0m10vvYk2dUdLU8aGxgQ%3D%3D",
                parentAccountID: "BowMhLnFvzZ1y9TeF5%2B3QQ%3D%3D",
                isSubAccount: true,
                displayName: "サンプル銀行1 · 普通預金1"
            ),
        ])

        let requests = await transport.requests()
        #expect(requests.count == 3)
        #expect(requests[0].method == "POST")
        #expect(requests[0].url == MoneyForwardAuth.exchangeEndpoint)
        #expect(requests[0].headers["Authorization"] == "Bearer \(sampleAPIKey)")

        // accessible_offices omits office_code; connected_accounts includes office_code.
        #expect(requests[1].url.path == "/api/v3/accessible_offices")
        #expect(requests[1].url.query == nil)
        #expect(requests[1].headers["Authorization"] == "Bearer sample-jwt-token-1")

        #expect(requests[2].url.path == "/api/v3/connected_accounts")
        #expect(requests[2].url.query == "office_code=1234-5678")

        // Credentials redact secrets.
        let saved = try #require(await store.load())
        #expect(!String(describing: saved).contains(sampleAPIKey))
        #expect(!String(describing: saved.apiKey!).contains(sampleAPIKey))
        #expect(!String(describing: saved.apiKey!).contains("sample-jwt-token-1"))
    }

    @Test("Transactions query preserves pre-encoded IDs without double encoding and converts signs")
    func transactionsNoDoubleEncodingAndSignConversion() async throws {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let store = InMemoryMoneyForwardCredentialStore(
            credentials: MoneyForwardCredentials(
                apiKey: MoneyForwardAPIKeyCredentials(
                    apiKey: sampleAPIKey,
                    officeCode: sampleOfficeCode,
                    cachedJWT: "valid-jwt",
                    jwtExpiresAt: now.addingTimeInterval(1800)
                )
            )
        )
        let transport = FakeHTTPTransport()
        await transport.enqueue(try TestJSON.response(json: [
            "transactions": [
                [
                    "id": "TxOne%2B1%3D%3D",
                    "date": "2026-04-03",
                    "value": 3200,
                    "side": "EXPENSE",
                    "content": "サンプル商店 本店",
                    "memo": NSNull(),
                    "journalizing_status": "excluded",
                    "connected_account_id": "BowMhLnFvzZ1y9TeF5%2B3QQ%3D%3D",
                    "connected_sub_account_id": "Sb0m10vvYk2dUdLU8aGxgQ%3D%3D",
                    "voucher_file_ids": [],
                ],
                [
                    "id": "TxTwo%2B2%3D%3D",
                    "date": "2026-04-25",
                    "value": 250000,
                    "side": "INCOME",
                    "content": "振込 サンプルカイシャ",
                    "memo": "4月給与",
                    "journalizing_status": "none",
                    "connected_account_id": "BowMhLnFvzZ1y9TeF5%2B3QQ%3D%3D",
                    "connected_sub_account_id": NSNull(),
                    "voucher_file_ids": [],
                ],
            ],
            "metadata": [
                "total_count": 2,
                "total_pages": 1,
            ],
        ]))

        let client = MoneyForwardClient(
            credentialStore: store,
            transport: transport,
            sleeper: RecordingSleeper(),
            now: { now }
        )

        let page = try await client.transactionsPage(
            startDate: "2026-04-01",
            endDate: "2026-04-30",
            connectedAccountID: "BowMhLnFvzZ1y9TeF5%2B3QQ%3D%3D"
        )

        #expect(page.totalCount == 2)
        #expect(page.totalPages == 1)
        #expect(page.transactions == [
            BankTransaction(
                id: "TxOne%2B1%3D%3D",
                connectedAccountID: "BowMhLnFvzZ1y9TeF5%2B3QQ%3D%3D",
                connectedSubAccountID: "Sb0m10vvYk2dUdLU8aGxgQ%3D%3D",
                date: "2026-04-03",
                amount: 3200,
                description: "サンプル商店 本店",
                memo: nil,
                journalizingStatus: "excluded"
            ),
            BankTransaction(
                id: "TxTwo%2B2%3D%3D",
                connectedAccountID: "BowMhLnFvzZ1y9TeF5%2B3QQ%3D%3D",
                connectedSubAccountID: nil,
                date: "2026-04-25",
                amount: -250000,
                description: "振込 サンプルカイシャ",
                memo: "4月給与",
                journalizingStatus: "none"
            ),
        ])

        let requestURL = try #require((await transport.requests()).first?.url.absoluteString)
        #expect(requestURL.contains("connected_account_id=BowMhLnFvzZ1y9TeF5%2B3QQ%3D%3D"))
        #expect(!requestURL.contains("%252B"))
        #expect(!requestURL.contains("%253D"))
    }

    @Test("Paginates across pages, retries 429 with backoff, and stops cleanly on deadline")
    func paginationRetryAndDeadline() async throws {
        let clockBox = ClockBox(Date(timeIntervalSince1970: 1_760_000_000))
        let store = InMemoryMoneyForwardCredentialStore(
            credentials: MoneyForwardCredentials(
                apiKey: MoneyForwardAPIKeyCredentials(
                    apiKey: sampleAPIKey,
                    officeCode: sampleOfficeCode,
                    cachedJWT: "valid-jwt",
                    jwtExpiresAt: clockBox.current().addingTimeInterval(1800)
                )
            )
        )
        let transport = FakeHTTPTransport()
        let sleeper = RecordingSleeper()

        // Page 1 returns 429 first, then succeeds.
        await transport.enqueue(HTTPResponse(
            statusCode: 429,
            headers: ["Retry-After": "2"],
            body: Data(#"{"errors":[{"code":"too_many_requests","message":"Operations per second is over the account limit."}]}"#.utf8)
        ))
        await transport.enqueue(try TestJSON.response(json: [
            "transactions": [
                [
                    "id": "t1", "date": "2026-04-10", "value": 1000, "side": "EXPENSE",
                    "content": "SHOP A", "memo": NSNull(), "journalizing_status": "none",
                    "connected_account_id": "acc1", "connected_sub_account_id": NSNull(), "voucher_file_ids": [],
                ],
            ],
            "metadata": ["total_count": 3, "total_pages": 3],
        ]))
        // Page 2 advances clock past deadline after succeeding.
        await transport.enqueue { _ in
            clockBox.advance(by: 10)
            return try TestJSON.response(json: [
                "transactions": [
                    [
                        "id": "t2", "date": "2026-04-09", "value": 2000, "side": "EXPENSE",
                        "content": "SHOP B", "memo": NSNull(), "journalizing_status": "none",
                        "connected_account_id": "acc1", "connected_sub_account_id": NSNull(), "voucher_file_ids": [],
                    ],
                ],
                "metadata": ["total_count": 3, "total_pages": 3],
            ])
        }

        let client = MoneyForwardClient(
            credentialStore: store,
            transport: transport,
            sleeper: sleeper,
            retryPolicy: RetryPolicy(maxRetries: 2, initialDelay: .seconds(1), maxDelay: .seconds(4)),
            now: { clockBox.current() }
        )

        let deadline = clockBox.current().addingTimeInterval(5)
        let result = try await client.fetchAllTransactions(
            startDate: "2026-04-01",
            endDate: "2026-04-10",
            deadline: deadline
        )

        #expect(result.reachedDeadline == true)
        #expect(result.pagesFetched == 2)
        #expect(result.transactions.map(\.id) == ["t1", "t2"])
        #expect(await sleeper.durations() == [.seconds(2)])
    }

    @Test("Revoked API key throws invalidCredentials with Reconnect Money Forward message")
    func revokedAPIKeyRequiresReconnect() async throws {
        let store = InMemoryMoneyForwardCredentialStore(
            credentials: MoneyForwardCredentials(
                apiKey: MoneyForwardAPIKeyCredentials(apiKey: sampleAPIKey, officeCode: sampleOfficeCode)
            )
        )
        let transport = FakeHTTPTransport(responses: [
            HTTPResponse(
                statusCode: 401,
                body: Data(#"{"errors":[{"code":"INVALID_API_KEY","message":"The provided API key is invalid or has been revoked."}]}"#.utf8)
            ),
        ])
        let client = MoneyForwardClient(
            credentialStore: store, transport: transport, sleeper: RecordingSleeper(),
            now: { Date(timeIntervalSince1970: 1_760_000_000) }
        )

        do {
            _ = try await client.listConnectedAccounts()
            Issue.record("Expected invalidCredentials")
        } catch let error as MoneyForwardClientError {
            #expect(error == .invalidCredentials)
            #expect(error.requiresReconnect == true)
            #expect(error.localizedDescription == "Reconnect Money Forward")
        }
    }

    @Test("OAuth URL includes PKCE, custom scheme redirect URI, and read-only scopes")
    func oauthURLAndBasicAuthTokenExchange() async throws {
        let pkce = try PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        let url = try MoneyForwardAuth.authorizationURL(
            clientID: "sample-mf-client",
            redirectURI: MoneyForwardAuth.defaultRedirectURI,
            pkce: pkce,
            state: "mf-state-1"
        )
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.host == "api.biz.moneyforward.com")
        #expect(components.path == "/authorize")
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(query["response_type"] == "code")
        #expect(query["client_id"] == "sample-mf-client")
        #expect(query["redirect_uri"] == MoneyForwardAuth.defaultRedirectURI)
        #expect(query["code_challenge_method"] == "S256")
        #expect(query["scope"] == MoneyForwardAuth.readOnlyScopes.joined(separator: " "))

        let config = MoneyForwardOAuthConfig(
            clientID: "sample-mf-client",
            clientSecret: "sample-mf-secret",
            redirectURI: MoneyForwardAuth.defaultRedirectURI
        )
        let req = try MoneyForwardAuth.authorizationCodeTokenRequest(
            config: config,
            code: "mf-code-1",
            codeVerifier: pkce.verifier
        )
        #expect(req.method == "POST")
        #expect(req.url == MoneyForwardAuth.tokenEndpoint)
        let expectedBasic = "Basic " + Data("sample-mf-client:sample-mf-secret".utf8).base64EncodedString()
        #expect(req.headers["Authorization"] == expectedBasic)
        #expect(!String(describing: config).contains("sample-mf-secret"))
    }

    @Test("Nightly maintenance window covers 01:00 to 06:00 JST")
    func nightlyMaintenanceWindow() throws {
        let fmt = ISO8601DateFormatter()
        #expect(MoneyForwardClient.isInNightlyMaintenance(at: try #require(fmt.date(from: "2026-11-23T00:59:59+09:00"))) == false)
        #expect(MoneyForwardClient.isInNightlyMaintenance(at: try #require(fmt.date(from: "2026-11-23T01:00:00+09:00"))) == true)
        #expect(MoneyForwardClient.isInNightlyMaintenance(at: try #require(fmt.date(from: "2026-11-23T05:59:59+09:00"))) == true)
        #expect(MoneyForwardClient.isInNightlyMaintenance(at: try #require(fmt.date(from: "2026-11-23T06:00:00+09:00"))) == false)
    }

    @Test("HTTP 403 surfaces clear plan-or-permission refusal message")
    func forbiddenAccessReportsPlanOrPermission() async throws {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let store = InMemoryMoneyForwardCredentialStore(
            credentials: MoneyForwardCredentials(
                apiKey: MoneyForwardAPIKeyCredentials(
                    apiKey: sampleAPIKey,
                    officeCode: sampleOfficeCode,
                    cachedJWT: "valid-jwt",
                    jwtExpiresAt: now.addingTimeInterval(1800)
                )
            )
        )
        let transport = FakeHTTPTransport(responses: [
            HTTPResponse(
                statusCode: 403,
                body: Data(#"{"errors":[{"code":"operation_not_permitted","message":"The authenticated user is not permitted to execute this operation due to subscription restrictions."}]}"#.utf8)
            ),
        ])
        let client = MoneyForwardClient(
            credentialStore: store,
            transport: transport,
            sleeper: RecordingSleeper(),
            now: { now }
        )

        do {
            _ = try await client.listConnectedAccounts()
            Issue.record("Expected forbidden error")
        } catch let error as MoneyForwardClientError {
            #expect(error.requiresReconnect == false)
            #expect(error.localizedDescription == "Money Forward refused access (plan or permission, HTTP 403)")
        }
    }
    @Test func cachedJWTIsRenewedAfter401AndExchangeHonorsRetryAfter() async throws {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let store = InMemoryMoneyForwardCredentialStore(credentials: .init(apiKey: .init(
            apiKey: sampleAPIKey, officeCode: sampleOfficeCode,
            cachedJWT: "stale-jwt", jwtExpiresAt: now.addingTimeInterval(1800)
        )))
        let transport = FakeHTTPTransport(responses: [
            HTTPResponse(statusCode: 401),
            HTTPResponse(statusCode: 503, headers: ["Retry-After": "9"]),
            HTTPResponse(statusCode: 200, body: Data(#"{"access_token":"renewed-jwt","expires_in":3600}"#.utf8)),
            HTTPResponse(statusCode: 200, body: Data(#"{"connected_accounts":[]}"#.utf8)),
        ])
        let sleeper = RecordingSleeper()
        let client = MoneyForwardClient(credentialStore: store, transport: transport, sleeper: sleeper, now: { now })
        #expect(try await client.listConnectedAccounts().isEmpty)
        #expect(await sleeper.durations() == [.seconds(9)])
        let requests = await transport.requests()
        #expect(requests.map(\.method) == ["GET", "POST", "POST", "GET"])
        #expect(requests.last?.headers["Authorization"] == "Bearer renewed-jwt")
        #expect(try await store.load()?.apiKey?.cachedJWT == "renewed-jwt")
        #expect(!String(reflecting: requests).contains(sampleAPIKey))
        #expect(!String(reflecting: requests).contains("renewed-jwt"))
    }

    @Test func splitsDateWindowsAndRejectsMalformedEncodedID() async throws {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let store = InMemoryMoneyForwardCredentialStore(credentials: .init(apiKey: .init(
            apiKey: sampleAPIKey, officeCode: sampleOfficeCode,
            cachedJWT: "cached-jwt", jwtExpiresAt: now.addingTimeInterval(1800)
        )))
        let empty = HTTPResponse(statusCode: 200, body: Data(#"{"transactions":[],"metadata":{"total_count":0,"total_pages":0}}"#.utf8))
        let transport = FakeHTTPTransport(responses: [empty, empty])
        let client = MoneyForwardClient(credentialStore: store, transport: transport, now: { now })
        await #expect(throws: MoneyForwardClientError.invalidResponse("invalid encoded Money Forward ID.")) {
            _ = try await client.transactionsPage(startDate: "2025-03-01", endDate: "2025-03-31",
                                                   connectedAccountID: "sample%&page=2")
        }

        let result = try await client.fetchAllTransactions(startDate: "2024-02-28", endDate: "2025-03-03")
        #expect(result.pagesFetched == 2)
        let requests = await transport.requests()
        #expect(requests.count == 2)
        let first = try #require(requests.first?.url.query)
        let second = try #require(requests.last?.url.query)
        #expect(first.contains("start_date=2024-03-02&end_date=2025-03-03"))
        #expect(second.contains("start_date=2024-02-28&end_date=2024-03-01"))
    }

}

private final class ClockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date) {
        self.date = date
    }

    func current() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return date
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        date = date.addingTimeInterval(seconds)
    }
}
