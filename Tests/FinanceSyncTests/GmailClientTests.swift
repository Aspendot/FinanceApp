import FinanceCore
import Foundation
import Testing
@testable import FinanceSync

@Suite("GmailClient")
struct GmailClientTests {
    private let sampleClientID = "12345-sample.apps.googleusercontent.com"
    private let fixedNow = Date(timeIntervalSince1970: 1_760_000_000)

    private func validTokens(
        accessToken: String = "sample-access-1",
        refreshToken: String? = "sample-refresh-1"
    ) -> OAuthTokens {
        OAuthTokens(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: fixedNow.addingTimeInterval(3600)
        )
    }

    @Test("Refreshes the access token once on 401 and retries the Gmail request")
    func refreshesOnceOn401() async throws {
        let store = InMemoryTokenStore(tokens: validTokens(accessToken: "expired-on-server", refreshToken: "sample-refresh-1"))
        let transport = FakeHTTPTransport(responses: [
            HTTPResponse(statusCode: 401, body: Data(#"{"error":{"code":401,"message":"Invalid Credentials"}}"#.utf8)),
            try TestJSON.response(json: [
                "access_token": "fresh-access-2",
                "expires_in": 3600,
                "token_type": "Bearer",
            ]),
            try TestJSON.response(json: [
                "messages": [["id": "msg-1", "threadId": "thr-1"]],
                "resultSizeEstimate": 1,
            ]),
        ])
        let sleeper = RecordingSleeper()
        let client = GmailClient(
            clientID: sampleClientID,
            tokenStore: store,
            transport: transport,
            sleeper: sleeper,
            now: { self.fixedNow }
        )

        let list = try await client.listMessageIDs(query: "from:post_master@netbk.co.jp")
        #expect(list.messages == [GmailMessageStub(id: "msg-1", threadId: "thr-1")])
        #expect(await sleeper.durations().isEmpty)

        let requests = await transport.requests()
        #expect(requests.count == 3)
        #expect(requests[0].headers["Authorization"] == "Bearer expired-on-server")
        #expect(requests[1].method == "POST")
        #expect(requests[1].url == GoogleOAuth.tokenEndpoint)
        #expect(requests[2].headers["Authorization"] == "Bearer fresh-access-2")

        let saved = try #require(await store.load())
        #expect(saved.accessToken == "fresh-access-2")
        #expect(saved.refreshToken == "sample-refresh-1")
    }

    @Test("Does not loop when a refreshed token still receives 401")
    func doesNotRefreshMoreThanOnceOn401() async throws {
        let store = InMemoryTokenStore(tokens: validTokens())
        let transport = FakeHTTPTransport(responses: [
            HTTPResponse(statusCode: 401),
            try TestJSON.response(json: [
                "access_token": "still-bad-token",
                "expires_in": 3600,
                "token_type": "Bearer",
            ]),
            HTTPResponse(statusCode: 401),
        ])
        let client = GmailClient(
            clientID: sampleClientID,
            tokenStore: store,
            transport: transport,
            sleeper: RecordingSleeper(),
            now: { self.fixedNow }
        )

        await #expect(throws: GmailClientError.unauthorized) {
            _ = try await client.listMessageIDs()
        }
        #expect((await transport.requests()).count == 3)
    }

    @Test("Backs off exponentially on 429 and honors Retry-After header")
    func backoffOn429() async throws {
        let store = InMemoryTokenStore(tokens: validTokens())
        let transport = FakeHTTPTransport(responses: [
            HTTPResponse(statusCode: 429),
            HTTPResponse(statusCode: 429, headers: ["Retry-After": "5"]),
            HTTPResponse(statusCode: 429),
            try TestJSON.response(json: ["messages": [["id": "msg-ok"]]]),
        ])
        let sleeper = RecordingSleeper()
        let policy = RetryPolicy(maxRetries: 3, initialDelay: .seconds(1), maxDelay: .seconds(10), backoffMultiplier: 2.0)
        let client = GmailClient(
            clientID: sampleClientID,
            tokenStore: store,
            transport: transport,
            sleeper: sleeper,
            retryPolicy: policy,
            now: { self.fixedNow }
        )

        let list = try await client.listMessageIDs()
        #expect(list.messages.map(\.id) == ["msg-ok"])
        #expect(await sleeper.durations() == [.seconds(1), .seconds(5), .seconds(4)])
    }

    @Test("Backs off on 403 rateLimitExceeded but fails immediately on non-quota 403")
    func handles403QuotaVsPermissionErrors() async throws {
        let rateLimit403 = try TestJSON.response(
            statusCode: 403,
            json: [
                "error": [
                    "code": 403,
                    "message": "User-rate limit exceeded.",
                    "errors": [["domain": "usageLimits", "reason": "userRateLimitExceeded"]],
                ],
            ]
        )
        let store = InMemoryTokenStore(tokens: validTokens())
        let transport1 = FakeHTTPTransport(responses: [
            rateLimit403,
            try TestJSON.response(json: ["resultSizeEstimate": 0]),
        ])
        let sleeper1 = RecordingSleeper()
        let client1 = GmailClient(
            clientID: sampleClientID,
            tokenStore: store,
            transport: transport1,
            sleeper: sleeper1,
            now: { self.fixedNow }
        )
        let emptyList = try await client1.listMessageIDs()
        #expect(emptyList.messages.isEmpty)
        #expect(await sleeper1.durations() == [.seconds(1)])

        let permission403 = try TestJSON.response(
            statusCode: 403,
            json: [
                "error": [
                    "code": 403,
                    "message": "Request had insufficient authentication scopes.",
                    "errors": [["domain": "global", "reason": "insufficientPermissions"]],
                ],
            ]
        )
        let transport2 = FakeHTTPTransport(responses: [permission403])
        let sleeper2 = RecordingSleeper()
        let client2 = GmailClient(
            clientID: sampleClientID,
            tokenStore: store,
            transport: transport2,
            sleeper: sleeper2,
            now: { self.fixedNow }
        )
        await #expect(throws: GmailClientError.httpError(
            statusCode: 403,
            message: "Request had insufficient authentication scopes."
        )) {
            _ = try await client2.listMessageIDs()
        }
        #expect(await sleeper2.durations().isEmpty)
    }

    @Test("Supports pagination parameters and fetches format=full messages")
    func paginationAndMessageFetch() async throws {
        let store = InMemoryTokenStore(tokens: validTokens())
        let transport = FakeHTTPTransport(responses: [
            try TestJSON.response(json: [
                "messages": [["id": "msg-1"], ["id": "msg-2"]],
                "nextPageToken": "page-2",
                "resultSizeEstimate": 3,
            ]),
            try TestJSON.response(json: [
                "messages": [["id": "msg-3"]],
                "resultSizeEstimate": 3,
            ]),
            try TestJSON.response(json: [
                "id": "msg-1",
                "internalDate": "1768437000000",
                "payload": [
                    "mimeType": "text/plain",
                    "headers": [["name": "Subject", "value": "Test Notice"]],
                    "body": ["size": 5, "data": TestJSON.base64url("hello")],
                ],
            ]),
        ])
        let client = GmailClient(
            clientID: sampleClientID,
            tokenStore: store,
            transport: transport,
            sleeper: RecordingSleeper(),
            now: { self.fixedNow }
        )

        let page1 = try await client.listMessageIDs(query: "newer_than:7d", maxResults: 2)
        #expect(page1.messages.map(\.id) == ["msg-1", "msg-2"])
        #expect(page1.nextPageToken == "page-2")

        let page2 = try await client.listMessageIDs(query: "newer_than:7d", maxResults: 2, pageToken: page1.nextPageToken)
        #expect(page2.messages.map(\.id) == ["msg-3"])
        #expect(page2.nextPageToken == nil)

        let fetched = try await client.message(id: "msg-1")
        #expect(fetched.id == "msg-1")
        #expect(MailMessage(gmail: fetched).textBody == "hello")

        let requests = await transport.requests()
        #expect(requests.count == 3)
        let req2Query = URLComponents(url: requests[1].url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(req2Query.contains(URLQueryItem(name: "pageToken", value: "page-2")))
        #expect(req2Query.contains(URLQueryItem(name: "maxResults", value: "2")))
        #expect(requests[2].url.absoluteString.contains("/users/me/messages/msg-1?format=full"))
    }
}
