import Foundation
import Testing
@testable import FinanceCore

// All fixtures are invented. They copy only the line layout of the real notices.

/// 2026-01-15 09:30:00 in Japan.
private let receivedAt = Date(timeIntervalSince1970: 1_768_437_000)

private func email(_ sender: String, _ subject: String, _ text: String) -> NoticeEmail {
    NoticeEmail(messageID: "fixture-1", receivedAt: receivedAt, sender: sender, subject: subject, text: text)
}

private let mufgSubject = "【三菱ＵＦＪ‐ＶＩＳＡデビット】ご利用のお知らせ"

private func mufgBody(amount: String, merchantLine: String? = "ご利用先　　　　　　: SAMPLE STORE") -> String {
    var lines = [
        " ＴＥＳＴ　ＵＳＥＲ 様",
        "",
        "三菱ＵＦＪ‐ＶＩＳＡデビットのご利用がありましたので、ご連絡いたします。",
        "",
        "ご利用金額（円）　 : \(amount)",
    ]
    if let merchantLine { lines.append(merchantLine) }
    lines += [
        "",
        "●「ご利用金額（円）」について",
        "プラス金額の場合はお引落し、マイナス金額の場合はご入金となります。",
        "　　受付時間：毎日　9:00～17:00",
    ]
    return lines.joined(separator: "\n")
}

private let docomoPurchaseSubject = "【デビットカード】ご利用のお知らせ(ドコモSMTBネット銀行)"
private let docomoSettlementSubject = "【デビットカード】引落しまたは入金処理のお知らせ(ドコモSMTBネット銀行)"

private func docomoPurchaseBody(merchant: String = "SAMPLE MART", currency: String = "JPY", amount: String = "1,500.00") -> String {
    """
     ＴＥＳＴ　ＵＳＥＲ さま

    デビットカードのご利用がありました。

    【取引情報】
    承認番号 ： 000111
    利用日時 ： 2026/01/15 09:28:41
    利用加盟店 ： \(merchant)
    引落通貨 ： \(currency)
    引落金額 ： \(amount)
    ※利用日時は日本標準時刻となります。
    """
}

private func docomoSettlementBody(currency: String = "JPY", amount: String = "3,000.00") -> String {
    """
     ＴＥＳＴ　ＵＳＥＲ さま

    デビットカードの利用代金の引落しまたは入金を行いました。

    【取引情報（売上確定データ）】
    承認番号 ： 000222
    利用日 ： 2026/01/14
    利用加盟店 ： ｻﾝﾌﾟﾙｼｮﾂﾌﾟ
    利用通貨 ： \(currency)
    利用金額 ： \(amount)
    ※差額調整が発生した場合、上記の利用金額と入出金の金額が異なる場合があります。
    """
}

@Suite("JST")
struct JSTTests {
    @Test func formatsInJapanTime() {
        #expect(JST.timestamp(receivedAt) == "2026-01-15T09:30:00+09:00")
    }

    @Test func readsSlashedDates() {
        #expect(JST.timestamp(slashed: "2026/01/15 09:28:41") == "2026-01-15T09:28:41+09:00")
        #expect(JST.timestamp(slashed: "2026/01/15 09:28") == "2026-01-15T09:28:00+09:00")
        #expect(JST.day(slashed: "2026/02/28") == "2026-02-28")
    }

    @Test("Rejects dates and times that don't exist",
          arguments: ["2026/02/29", "2026/13/01", "2026/00/10", "26/01/15", "2026-01-15", ""])
    func rejectsDays(_ text: String) {
        #expect(JST.day(slashed: text) == nil)
    }

    @Test(arguments: ["2026/01/15 24:00:00", "2026/01/15 09:60:00", "2026/01/15 9:28", "2026/01/15", "2026/01/15 09:28:4"])
    func rejectsTimes(_ text: String) {
        #expect(JST.timestamp(slashed: text) == nil)
    }
}

@Suite("MUFG debit parser")
struct MUFGDebitParserTests {
    @Test func purchase() {
        let outcome = NoticeParsers.parse(email("mail@debit.bk.mufg.jp", mufgSubject, mufgBody(amount: "1,234")))
        #expect(outcome == .notice(Notice(
            messageID: "fixture-1", source: .mufgDebit, kind: .purchase,
            receivedAt: "2026-01-15T09:30:00+09:00", amount: 1234, currency: "JPY",
            merchant: "SAMPLE STORE", parser: "mufg_debit/1")))
    }

    @Test func negativeAmountIsARefund() {
        guard case .notice(let n) = NoticeParsers.parse(email("mail@debit.bk.mufg.jp", mufgSubject, mufgBody(amount: "-500"))) else {
            Issue.record("expected a notice")
            return
        }
        #expect(n.kind == .refund)
        #expect(n.amount == -500)
    }

    @Test func nextBusinessDaySettlement() {
        let subject = "【三菱ＵＦＪ‐ＶＩＳＡデビット】ご利用代金お引落し（またはご入金）のお知らせ"
        guard case .notice(let n) = NoticeParsers.parse(email("mail@debit.bk.mufg.jp", subject, mufgBody(amount: "-1,000"))) else {
            Issue.record("expected a notice")
            return
        }
        #expect(n.kind == .settlement)
        #expect(n.amount == -1000)
        #expect(MatchPolicy.for(n.source, n.kind).dayOffsets == 0...6)
    }

    @Test func missingMerchantLineIsQuarantined() {
        let outcome = NoticeParsers.parse(email("mail@debit.bk.mufg.jp", mufgSubject, mufgBody(amount: "980", merchantLine: nil)))
        #expect(outcome == .quarantined("MUFG debit: no merchant line"))
    }

    @Test func unreadableAmountIsQuarantined() {
        let outcome = NoticeParsers.parse(email("mail@debit.bk.mufg.jp", mufgSubject, mufgBody(amount: "12.50")))
        #expect(outcome == .quarantined("MUFG debit: amount is not whole yen"))
    }

    @Test func unknownSubjects() {
        let money = NoticeParsers.parse(email("mail@debit.bk.mufg.jp", "【三菱ＵＦＪ‐ＶＩＳＡデビット】新しいお知らせ", "ご利用金額 : 100"))
        let news = NoticeParsers.parse(email("mail@debit.bk.mufg.jp", "【三菱ＵＦＪ‐ＶＩＳＡデビット】サービス停止のご案内", "メンテナンスのお知らせです。"))
        #expect(money == .quarantined("MUFG debit: unknown layout with an amount"))
        #expect(news == .ignored("MUFG debit: not a money notice"))
    }
}

@Suite("Docomo debit parser")
struct DocomoDebitParserTests {
    @Test func purchase() {
        let outcome = NoticeParsers.parse(email("post_master@netbk.co.jp", docomoPurchaseSubject, docomoPurchaseBody()))
        #expect(outcome == .notice(Notice(
            messageID: "fixture-1", source: .docomoDebit, kind: .purchase,
            receivedAt: "2026-01-15T09:30:00+09:00", occurredAt: "2026-01-15T09:28:41+09:00",
            amount: 1500, currency: "JPY", merchant: "SAMPLE MART", reference: "000111",
            parser: "docomo_debit/1")))
    }

    @Test func blankMerchantBecomesNil() {
        guard case .notice(let n) = NoticeParsers.parse(email("post_master@netbk.co.jp", docomoPurchaseSubject, docomoPurchaseBody(merchant: ""))) else {
            Issue.record("expected a notice")
            return
        }
        #expect(n.merchant == nil)
        #expect(n.amount == 1500)
    }

    @Test func nonYenDebitIsQuarantined() {
        let outcome = NoticeParsers.parse(email("post_master@netbk.co.jp", docomoPurchaseSubject, docomoPurchaseBody(currency: "USD", amount: "10.00")))
        #expect(outcome == .quarantined("Docomo purchase: debit currency is not JPY"))
    }

    @Test func settlementInYen() {
        let outcome = NoticeParsers.parse(email("post_master@netbk.co.jp", docomoSettlementSubject, docomoSettlementBody()))
        #expect(outcome == .notice(Notice(
            messageID: "fixture-1", source: .docomoDebit, kind: .settlement,
            receivedAt: "2026-01-15T09:30:00+09:00", occurredOn: "2026-01-14",
            amount: 3000, currency: "JPY", merchant: "ｻﾝﾌﾟﾙｼｮﾂﾌﾟ", reference: "000222",
            parser: "docomo_debit/1")))
    }

    @Test func foreignSettlementKeepsTheAmountAsWritten() {
        guard case .notice(let n) = NoticeParsers.parse(email("post_master@netbk.co.jp", docomoSettlementSubject, docomoSettlementBody(currency: "USD", amount: "1,000"))) else {
            Issue.record("expected a notice")
            return
        }
        #expect(n.amount == nil)
        #expect(n.currency == "USD")
        #expect(n.foreignAmount == "1,000")
    }

    @Test func otherMailFromTheBank() {
        let news = NoticeParsers.parse(email("post_master@netbk.co.jp", "サービスのご案内(ドコモSMTBネット銀行)", "新しい機能が使えるようになりました。"))
        let maintenance = NoticeParsers.parse(email("post_master@netbk.co.jp", "振込サービス臨時メンテナンスのご案内", "期間中は振込をご利用いただけません。\n時間：2:00～6:00"))
        #expect(news == .ignored("Docomo: not a money notice"))
        #expect(maintenance == .ignored("Docomo: not a money notice"))
    }

    @Test func declinedCardPayment() {
        let text = """
        利用日時   ： 2026/01/15 13:11:30
        利用加盟店 ： SAMPLE TRAVEL
        利用通貨   ： JPY
        利用金額   ： 20,000.00
        """
        guard case .notice(let n) = NoticeParsers.parse(email("post_master@netbk.co.jp", "【デビットカード】ご利用不可のお知らせ(ドコモSMTBネット銀行)", text)) else {
            Issue.record("expected a notice")
            return
        }
        #expect(n.kind == .decline)
        #expect(n.amount == 20000)
        #expect(n.occurredAt == "2026-01-15T13:11:30+09:00")
    }

    @Test func accountNotices() {
        guard case .notice(let w) = NoticeParsers.parse(email("post_master@netbk.co.jp", "出金のお知らせ", "サービス名：ことら送金")),
              case .notice(let d) = NoticeParsers.parse(email("post_master@netbk.co.jp", "振込入金のお知らせ", "入金金額：3,000円\n振込依頼人名：サンプル"))
        else {
            Issue.record("expected notices")
            return
        }
        #expect(w.source == .docomoAccount && w.kind == .withdrawal && w.amount == nil && w.merchant == "ことら送金")
        #expect(d.kind == .deposit && d.amount == -3000)
    }
}

@Suite("Notice JSON")
struct NoticeJSONTests {
    @Test func stableSortedLine() throws {
        let n = Notice(messageID: "fixture-1", source: .docomoDebit, kind: .purchase,
                       receivedAt: "2026-01-15T09:30:00+09:00", amount: 1500, currency: "JPY",
                       merchant: "SAMPLE MART", reference: "000111", parser: "docomo_debit/1")
        #expect(try n.jsonLine() == #"{"amount":1500,"currency":"JPY","kind":"purchase","merchant":"SAMPLE MART","messageID":"fixture-1","parser":"docomo_debit/1","receivedAt":"2026-01-15T09:30:00+09:00","reference":"000111","source":"docomo_debit"}"#)
    }

    @Test func unknownSenderIsQuarantined() {
        #expect(NoticeParsers.parse(email("someone@example.com", "hello", "")) == .quarantined("no parser for this sender yet"))
    }
}
