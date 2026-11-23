import FinanceCore
import Foundation
import Testing
@testable import FinanceSync

@Suite("NoticeSync")
struct NoticeSyncTests {
    private let sampleClientID = "12345-sample.apps.googleusercontent.com"
    private let fixedNow = Date(timeIntervalSince1970: 1_768_440_000)

    private let docomoAuth = "mx.google.com; dkim=pass header.i=@netbk.co.jp header.s=s1 header.b=abc; spf=pass smtp.mailfrom=netbk.co.jp; dmarc=pass header.from=netbk.co.jp"
    private let docomoSubject = "【デビットカード】ご利用のお知らせ(ドコモSMTBネット銀行)"
    private let docomoBody = """
    【取引情報】
    承認番号 ： 000777
    利用日時 ： 2026/01/15 09:28:41
    利用加盟店 ： SAMPLE STORE
    引落通貨 ： JPY
    引落金額 ： 1,500.00
    """

    private func makeClient(transport: FakeHTTPTransport) -> GmailClient {
        let tokens = OAuthTokens(
            accessToken: "sample-access-1",
            refreshToken: "sample-refresh-1",
            expiresAt: fixedNow.addingTimeInterval(3600)
        )
        return GmailClient(
            clientID: sampleClientID,
            tokenStore: InMemoryTokenStore(tokens: tokens),
            transport: transport,
            sleeper: RecordingSleeper(),
            now: { self.fixedNow }
        )
    }

    private func gmailJSON(
        id: String,
        from: String,
        authResults: String,
        subject: String,
        body: String,
        mimeType: String = "text/plain"
    ) -> [String: Any] {
        [
            "id": id,
            "internalDate": "1768437000000",
            "payload": [
                "mimeType": mimeType,
                "headers": [
                    ["name": "Authentication-Results", "value": authResults],
                    ["name": "From", "value": from],
                    ["name": "Subject", "value": subject],
                    ["name": "Content-Type", "value": "\(mimeType); charset=UTF-8"],
                ],
                "body": [
                    "size": body.utf8.count,
                    "data": TestJSON.base64url(body),
                ],
            ],
        ]
    }

    @Test("Builds Gmail query with all NoticeFeed senders, lookback window, and subject exclusions")
    func queryIncludesAllSendersAndExclusions() {
        let query = NoticeSync.buildQuery(lookbackDays: 14)
        let expectedSenders = NoticeFeed.senders.keys.sorted().joined(separator: " OR ")
        #expect(query == "from:(\(expectedSenders)) newer_than:14d -subject:(認証コード OR ワンタイムパスワード OR 確認コード OR 認証番号 OR パスコード OR 本人確認)")
    }

    @Test("Paginates across pages and skips message IDs already in SyncState")
    func incrementalSyncSkipsSeenIDsAcrossPages() async throws {
        let transport = FakeHTTPTransport(responses: [
            try TestJSON.response(json: [
                "messages": [["id": "seen-1"], ["id": "new-1"]],
                "nextPageToken": "page-2",
            ]),
            try TestJSON.response(json: [
                "messages": [["id": "seen-2"], ["id": "new-2"]],
            ]),
            try TestJSON.response(json: gmailJSON(
                id: "new-1",
                from: "ドコモSMTBネット銀行 <post_master@netbk.co.jp>",
                authResults: docomoAuth,
                subject: docomoSubject,
                body: docomoBody
            )),
            try TestJSON.response(json: gmailJSON(
                id: "new-2",
                from: "ドコモSMTBネット銀行 <post_master@netbk.co.jp>",
                authResults: docomoAuth,
                subject: "お知らせ",
                body: "キャンペーンのご案内です。"
            )),
        ])
        let client = makeClient(transport: transport)
        let priorState = SyncState(
            seenMessageIDs: ["seen-1", "seen-2"],
            lastSyncAt: fixedNow.addingTimeInterval(-3600)
        )

        let result = try await NoticeSync.sync(
            client: client,
            state: priorState,
            lookbackDays: 7,
            now: { self.fixedNow }
        )

        #expect(result.items.map(\.messageID) == ["new-1", "new-2"])
        #expect(result.state.seenMessageIDs == ["seen-1", "seen-2", "new-1", "new-2"])
        #expect(result.state.lastSyncAt == fixedNow)
        #expect(result.droppedOneTimeCodeCount == 0)

        let requests = await transport.requests()
        #expect(requests.count == 4)
        #expect(!requests.contains { $0.url.absoluteString.contains("seen-1") })
        #expect(!requests.contains { $0.url.absoluteString.contains("seen-2") })

        // Verify SyncState is Codable and round-trips cleanly.
        let encoded = try JSONEncoder().encode(result.state)
        let decoded = try JSONDecoder().decode(SyncState.self, from: encoded)
        #expect(decoded == result.state)
    }

    @Test("Drops one-time-code messages matching subject, plain text, or HTML before parsing")
    func dropsOneTimeCodeMessages() async throws {
        let transport = FakeHTTPTransport(responses: [
            try TestJSON.response(json: [
                "messages": [
                    ["id": "otp-subject"],
                    ["id": "otp-body-jp"],
                    ["id": "otp-body-en"],
                    ["id": "otp-html"],
                    ["id": "real-notice"],
                ],
            ]),
            try TestJSON.response(json: gmailJSON(
                id: "otp-subject",
                from: "post_master@netbk.co.jp",
                authResults: docomoAuth,
                subject: "認証コードのお知らせ",
                body: "コードは 111111 です。"
            )),
            try TestJSON.response(json: gmailJSON(
                id: "otp-body-jp",
                from: "post_master@netbk.co.jp",
                authResults: docomoAuth,
                subject: "ご利用手続きのご案内",
                body: "ワンタイムパスワード: 222222 を入力してください。"
            )),
            try TestJSON.response(json: gmailJSON(
                id: "otp-body-en",
                from: "post_master@netbk.co.jp",
                authResults: docomoAuth,
                subject: "Sign-in request",
                body: "Your Verification Code is 333333."
            )),
            try TestJSON.response(json: gmailJSON(
                id: "otp-html",
                from: "post_master@netbk.co.jp",
                authResults: docomoAuth,
                subject: "セキュリティ通知",
                body: "<html><body><p>セキュリティコードは 444444 です。</p></body></html>",
                mimeType: "text/html"
            )),
            try TestJSON.response(json: gmailJSON(
                id: "real-notice",
                from: "post_master@netbk.co.jp",
                authResults: docomoAuth,
                subject: docomoSubject,
                body: docomoBody
            )),
        ])
        let client = makeClient(transport: transport)

        let result = try await NoticeSync.sync(client: client, now: { self.fixedNow })
        #expect(result.droppedOneTimeCodeCount == 4)
        #expect(result.items.count == 1)
        #expect(result.items[0].messageID == "real-notice")
        #expect(result.items[0].status == .notice)
        #expect(result.state.seenMessageIDs == ["otp-subject", "otp-body-jp", "otp-body-en", "otp-html", "real-notice"])

        let stateJSON = String(decoding: try JSONEncoder().encode(result.state), as: UTF8.self)
        #expect(!stateJSON.contains("111111"))
        #expect(!stateJSON.contains("222222"))
        #expect(!stateJSON.contains("333333"))
        #expect(!stateJSON.contains("444444"))
    }

    @Test("End-to-end sync parses an invented bank Gmail JSON into a Notice FeedItem")
    func endToEndBankNoticeSync() async throws {
        let transport = FakeHTTPTransport(responses: [
            try TestJSON.response(json: [
                "messages": [["id": "bank-notice-1"]],
                "resultSizeEstimate": 1,
            ]),
            try TestJSON.response(json: gmailJSON(
                id: "bank-notice-1",
                from: "ドコモSMTBネット銀行 <post_master@netbk.co.jp>",
                authResults: docomoAuth,
                subject: docomoSubject,
                body: docomoBody
            )),
        ])
        let client = makeClient(transport: transport)

        let result = try await NoticeSync.sync(client: client, lookbackDays: 30, now: { self.fixedNow })
        #expect(result.droppedOneTimeCodeCount == 0)
        #expect(result.items.count == 1)

        let item = result.items[0]
        #expect(item.messageID == "bank-notice-1")
        #expect(item.status == .notice)
        #expect(item.issues.isEmpty)

        let notice = try #require(item.notice)
        #expect(notice.source == .docomoDebit)
        #expect(notice.kind == .purchase)
        #expect(notice.amount == 1500)
        #expect(notice.currency == "JPY")
        #expect(notice.merchant == "SAMPLE STORE")
        #expect(notice.reference == "000777")
        #expect(notice.occurredAt == "2026-01-15T09:28:41+09:00")
        #expect(notice.receivedAt == "2026-01-15T09:30:00+09:00")
        #expect(result.state.seenMessageIDs == ["bank-notice-1"])
        #expect(result.state.lastSyncAt == fixedNow)
    }

    @Test("OneTimeCodeFilter matches all required terms including case and width variants")
    func oneTimeCodeFilterTerms() {
        for term in OneTimeCodeFilter.terms {
            #expect(OneTimeCodeFilter.matches(subject: "Notice: \(term)", text: nil))
            #expect(OneTimeCodeFilter.matches(subject: "Notice", text: "Code: \(term)"))
        }
        #expect(OneTimeCodeFilter.matches(subject: "Notice", text: "ﾜﾝﾀｲﾑパスワード"))
        #expect(OneTimeCodeFilter.matches(subject: "Notice", text: "Enter VERIFICATION   CODE now"))
        #expect(!OneTimeCodeFilter.matches(subject: docomoSubject, text: docomoBody))
    }
}
