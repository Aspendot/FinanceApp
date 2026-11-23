import Foundation
import Testing
@testable import FinanceCore

// Invented messages in the shape of Gmail's format=full JSON.

private func base64url(_ text: String) -> String {
    Data(text.utf8).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private func gmail(from: String, authResults: [String], subject: String, body: String) throws -> GmailMessage {
    var headers: [[String: String]] = authResults.map { ["name": "Authentication-Results", "value": $0] }
    headers += [["name": "From", "value": from], ["name": "Subject", "value": subject]]
    let json: [String: Any] = [
        "id": "feed-1",
        "internalDate": "1768437000000",
        "payload": [
            "mimeType": "text/plain",
            "headers": headers + [["name": "Content-Type", "value": "text/plain; charset=UTF-8"]],
            "body": ["size": body.utf8.count, "data": base64url(body)],
        ],
    ]
    return try JSONDecoder().decode(GmailMessage.self, from: JSONSerialization.data(withJSONObject: json))
}

private let docomoBody = """
【取引情報】
承認番号 ： 000333
利用日時 ： 2026/01/15 09:28:41
利用加盟店 ： SAMPLE MART
引落通貨 ： JPY
引落金額 ： 700.00
"""

private let goodAuth = "mx.google.com; dkim=pass header.i=@netbk.co.jp header.s=s1 header.b=abc; spf=pass smtp.mailfrom=netbk.co.jp; dmarc=pass header.from=netbk.co.jp"
private let subject = "【デビットカード】ご利用のお知らせ(ドコモSMTBネット銀行)"

@Suite("Notice feed")
struct NoticeFeedTests {
    @Test func verifiedNoticeIsParsed() throws {
        let item = NoticeFeed.process(try gmail(from: "ドコモSMTBネット銀行 <post_master@netbk.co.jp>", authResults: [goodAuth], subject: subject, body: docomoBody))
        #expect(item.status == .notice)
        #expect(item.notice?.amount == 700)
        #expect(item.notice?.reference == "000333")
        #expect(item.notice?.receivedAt == "2026-01-15T09:30:00+09:00")
    }

    @Test func forgedNoticeIsRejected() throws {
        let forged = "mx.google.com; dkim=none; spf=fail smtp.mailfrom=example.com; dmarc=fail header.from=netbk.co.jp"
        let item = NoticeFeed.process(try gmail(from: "post_master@netbk.co.jp", authResults: [forged, goodAuth], subject: subject, body: docomoBody))
        #expect(item.status == .rejected)
        #expect(item.notice == nil)
    }

    @Test func unknownSenderIsRejected() throws {
        let item = NoticeFeed.process(try gmail(from: "alerts@example.com", authResults: [goodAuth], subject: subject, body: docomoBody))
        #expect(item.status == .rejected)
        #expect(item.reason == "not a known notice sender")
    }

    @Test func dayPrefersThePurchaseDate() {
        let n = Notice(messageID: "x", source: .docomoDebit, kind: .settlement, receivedAt: "2026-01-16T08:00:00+09:00",
                       occurredOn: "2026-01-14", amount: 1, parser: "t/1")
        #expect(n.day == "2026-01-14")
    }
}
