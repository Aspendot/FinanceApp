import Foundation
import Testing
@testable import FinanceCore

// An invented receipt in the text layout HTMLText produces for Apple's HTML.
private let receiptText = """
Receipt
APPLE ACCOUNT
test@example.com | BILLED TO
Sample Pay
TEST USER
100-0001
東京都 千代田区 1-1
JPN
DATE
Jan 15, 2026
ORDER ID
TESTORDER1 | DOCUMENT NO.
100000000001
App Store
Sample Game
Sample Developer
App
Report a Problem
¥350
Subtotal | ¥318
JCT charged at 10% | ¥32
TOTAL | ¥350
"""

private func apple(_ subject: String, _ text: String) -> NoticeEmail {
    NoticeEmail(messageID: "fixture-3", receivedAt: Date(timeIntervalSince1970: 1_768_437_000),
                sender: "no_reply@email.apple.com", subject: subject, text: text)
}

@Suite("Apple receipt parser")
struct AppleReceiptParserTests {
    @Test func receipt() {
        let outcome = NoticeParsers.parse(apple("Your receipt from Apple.", receiptText))
        #expect(outcome == .notice(Notice(
            messageID: "fixture-3", source: .apple, kind: .purchase,
            receivedAt: "2026-01-15T09:30:00+09:00", occurredOn: "2026-01-15",
            amount: 350, currency: "JPY", merchant: "Sample Game", reference: "TESTORDER1",
            parser: "apple/1")))
    }

    @Test func noAddressOrNameIsKept() throws {
        guard case .notice(let n) = NoticeParsers.parse(apple("Your receipt from Apple.", receiptText)) else {
            Issue.record("expected a notice")
            return
        }
        let line = try n.jsonLine()
        #expect(!line.contains("TEST USER"))
        #expect(!line.contains("千代田"))
        #expect(!line.contains("example.com"))
    }

    @Test func dates() {
        #expect(AppleReceiptParser.parseDate("Nov 2, 2026") == "2026-11-02")
        #expect(AppleReceiptParser.parseDate("2026年1月5日") == "2026-01-05")
        #expect(AppleReceiptParser.parseDate("Feb 30, 2026") == nil)
    }

    @Test func missingTotalIsQuarantined() {
        let text = receiptText.replacingOccurrences(of: "TOTAL | ¥350", with: "")
        #expect(NoticeParsers.parse(apple("Your receipt from Apple.", text)) == .quarantined("Apple: receipt without a whole-yen total"))
    }

    @Test func olderInvoiceLayout() {
        let text = """
        Invoice
        January 22, 2026
        Order ID:
        TESTORDER2
        Document:
        100000000002
        Apple Account:
        test@example.com
        Sample Plan App
        Annual Plan (Annual)
        Renews January 23, 2027
        ¥1,100
        Inclusive of JCT at 10%¥100
        Billing and Payment
        TEST USER
        Subtotal
        ¥1,000
        JCT charged at 10%
        ¥100
        Sample Pay
        ¥1,100
        You can view your receipts in App Store settings.
        """
        guard case .notice(let n) = NoticeParsers.parse(apple("Your receipt from Apple.", text)) else {
            Issue.record("expected a notice")
            return
        }
        #expect(n.occurredOn == "2026-01-22")
        #expect(n.amount == 1100)
        #expect(n.reference == "TESTORDER2")
        #expect(n.merchant == "Sample Plan App")

        let disagreeing = text.replacingOccurrences(of: "Sample Pay\n¥1,100", with: "Sample Pay\n¥1,200")
        #expect(NoticeParsers.parse(apple("Your receipt from Apple.", disagreeing)) == .quarantined("Apple: invoice amounts do not agree"))
    }

    @Test func subscriptionMailIsIgnored() {
        #expect(NoticeParsers.parse(apple("Your Subscription is Confirmed", "Sample Plus\n¥500/month")) == .ignored("Apple: account or subscription notice"))
    }
}
