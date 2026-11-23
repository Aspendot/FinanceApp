import Foundation
import Testing
@testable import FinanceCore

// All fixtures are invented. They copy only the line layout of the real notices.

private func merpay(_ subject: String, _ text: String) -> NoticeEmail {
    NoticeEmail(messageID: "fixture-2", receivedAt: Date(timeIntervalSince1970: 1_768_437_000),
                sender: "no-reply@mercari.jp", subject: subject, text: text)
}

private let cardPurchaseText = """
テスト さん

いつもメルペイをご利用いただきありがとうございます。

メルカードのご利用がありました。

▼決済内容
店舗名　　　　　　　　　　　：　サンプル商店
決済金額　　　　　　　　　　：　￥1,200
　└ クレジット　　　　　　　：　￥1,200
還元予定ポイント　　　　　　：　P12
決済方法　　　　　　　　　　：　メルカード
決済日時　　　　　　　　　　：　2026/01/15 09:20
取引番号　　　　　　　　　　：　000000000001
"""

private let onlinePaymentText = """
テスト さん
ネット決済でのお支払いがありました。

▼取引内容
取引金額合計　　　　　　　　：　￥500
　└ポイント　　　　　　　　：　P300
　└メルペイ残高　　　　　　：　￥0
　└クレジット　　　　　　　：　￥200
還元予定ポイント　　　　　　：　対象外
ネットショップ　　　　　　　：　SAMPLE ONLINE
サービス名　　　　　　　　　：　SAMPLE ONLINE
取引方法　　　　　　　　　　：　ネット決済
取引日時　　　　　　　　　　：　2026/01/15 08:05
取引番号　　　　　　　　　　：　000000000002
Apple ご注文番号　　　　　　：　TESTORDER1
"""

private func decline(credit: String = "￥585") -> String {
    """
    テスト さん

    ポイント、メルペイ残高またはクレジットが不足しているため、お支払いができませんでした。

    ▼対象取引
    店舗名　　　　　　　　　　　：　サンプル商店
    決済金額　　　　　　　　　　：　￥600
    　└ クレジット　　　　　　　：　\(credit)
    　└ 値引き　　　　　　　　　：　￥15
    決済方法　　　　　　　　　　：　メルカード
    決済日時　　　　　　　　　　：　2026/01/15 09:10
    """
}

@Suite("Merpay parser")
struct MerpayParserTests {
    @Test func cardPurchase() {
        let outcome = NoticeParsers.parse(merpay("メルカードのご利用がありました", cardPurchaseText))
        #expect(outcome == .notice(Notice(
            messageID: "fixture-2", source: .merpay, kind: .purchase,
            receivedAt: "2026-01-15T09:30:00+09:00", occurredAt: "2026-01-15T09:20:00+09:00",
            amount: 1200, currency: "JPY", merchant: "サンプル商店", reference: "000000000001",
            parts: ["credit": 1200], parser: "merpay/1")))
    }

    @Test func onlinePaymentWithPointsAndAnAppleOrder() {
        guard case .notice(let n) = NoticeParsers.parse(merpay("ネット決済でお支払いがありました", onlinePaymentText)) else {
            Issue.record("expected a notice")
            return
        }
        #expect(n.amount == 500)
        #expect(n.parts == ["points": 300, "balance": 0, "credit": 200])
        #expect(n.merchant == "SAMPLE ONLINE")
        #expect(n.orderID == "TESTORDER1")
        #expect(n.reference == "000000000002")
    }

    @Test func declineIsNotSpending() {
        guard case .notice(let n) = NoticeParsers.parse(merpay("メルカードの利用限度額不足でお支払いできません", decline())) else {
            Issue.record("expected a notice")
            return
        }
        #expect(n.kind == .decline)
        #expect(n.amount == 600)
        #expect(n.parts == ["credit": 585, "discount": 15])
        #expect(n.reference == nil)
    }

    @Test func splitThatDoesNotAddUpIsQuarantined() {
        let outcome = NoticeParsers.parse(merpay("メルカードの利用限度額不足でお支払いできません", decline(credit: "￥580")))
        #expect(outcome == .quarantined("Merpay: split does not add up to the total"))
    }

    @Test func paymentWithoutReferenceIsQuarantined() {
        let text = cardPurchaseText.replacingOccurrences(of: "取引番号　　　　　　　　　　：　000000000001", with: "")
        #expect(NoticeParsers.parse(merpay("メルカードのご利用がありました", text)) == .quarantined("Merpay: payment without 取引番号"))
    }

    @Test func topUpFromTheSubject() {
        let outcome = NoticeParsers.parse(merpay("サンプル銀行から￥10,000チャージしました", "<html>…</html>"))
        #expect(outcome == .notice(Notice(
            messageID: "fixture-2", source: .merpay, kind: .topUp,
            receivedAt: "2026-01-15T09:30:00+09:00", amount: 10000, currency: "JPY",
            merchant: "サンプル銀行", parser: "merpay/1")))
    }

    @Test func billPaid() {
        guard case .notice(let n) = NoticeParsers.parse(merpay("【メルペイ】1月請求の支払いが完了しました", "お支払い金額：￥5,000")) else {
            Issue.record("expected a notice")
            return
        }
        #expect(n.kind == .billPaid)
        #expect(n.amount == 5000)
    }

    @Test func otherMail() {
        #expect(NoticeParsers.parse(merpay("今だけポイント還元キャンペーン", "お支払いでおトク")) == .ignored("Merpay: not a money notice"))
        #expect(NoticeParsers.parse(merpay("コード決済でお支払いがありました", "")) == .quarantined("Merpay: unknown layout that mentions money"))
    }
}
