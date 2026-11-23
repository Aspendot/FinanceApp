import Foundation

/// Docomo SMTB debit card notices.
///
/// - The purchase notice comes from the card authorization. It has the
///   authorization number (承認番号), the time to the second, a merchant name that
///   can be blank, and the yen amount debited.
/// - The 引落しまたは入金 notice comes from the confirmed sale. It shares the
///   承認番号 with its purchase notice when there was one. It covers sales without
///   an earlier authorization, difference adjustments and fees, so the matcher
///   decides what it means. Its amount is the sale amount, which can differ from
///   the money actually moved.
enum DocomoDebitParser {
    static let sender = "post_master@netbk.co.jp"
    static let version = "docomo_debit/1"
    static let purchaseSubject = TextFold.key("【デビットカード】ご利用のお知らせ(ドコモSMTBネット銀行)")
    static let settlementSubject = TextFold.key("【デビットカード】引落しまたは入金処理のお知らせ(ドコモSMTBネット銀行)")

    static func parse(_ email: NoticeEmail) -> ParseOutcome {
        switch TextFold.key(email.subject) {
        case purchaseSubject:
            return purchase(email)
        case settlementSubject:
            return settlement(email)
        default:
            return NoticeParsers.unknown(email, "Docomo")
        }
    }

    private static func purchase(_ email: NoticeEmail) -> ParseOutcome {
        let f = Fields(email.text)
        guard let reference = f["承認番号"], !reference.isEmpty else {
            return .quarantined("Docomo purchase: no 承認番号")
        }
        guard let whenText = f["利用日時"], let occurredAt = JST.timestamp(slashed: whenText) else {
            return .quarantined("Docomo purchase: no readable 利用日時")
        }
        guard f["引落通貨"] == "JPY" else {
            return .quarantined("Docomo purchase: debit currency is not JPY")
        }
        guard let amountText = f["引落金額"], let amount = Yen.parse(amountText) else {
            return .quarantined("Docomo purchase: no whole-yen 引落金額")
        }
        let merchant = f["利用加盟店"] ?? ""
        return .notice(Notice(
            messageID: email.messageID,
            source: .docomoDebit,
            kind: amount < 0 ? .refund : .purchase,
            receivedAt: JST.timestamp(email.receivedAt),
            occurredAt: occurredAt,
            amount: amount,
            currency: "JPY",
            merchant: merchant.isEmpty ? nil : merchant,
            reference: reference,
            parser: version
        ))
    }

    private static func settlement(_ email: NoticeEmail) -> ParseOutcome {
        let f = Fields(email.text)
        guard let reference = f["承認番号"], !reference.isEmpty else {
            return .quarantined("Docomo settlement: no 承認番号")
        }
        guard let dayText = f["利用日"], let occurredOn = JST.day(slashed: dayText) else {
            return .quarantined("Docomo settlement: no readable 利用日")
        }
        guard let currency = f["利用通貨"], !currency.isEmpty, let amountText = f["利用金額"] else {
            return .quarantined("Docomo settlement: no currency or amount")
        }
        let merchant = f["利用加盟店"] ?? ""
        var notice = Notice(
            messageID: email.messageID,
            source: .docomoDebit,
            kind: .settlement,
            receivedAt: JST.timestamp(email.receivedAt),
            occurredOn: occurredOn,
            currency: currency,
            merchant: merchant.isEmpty ? nil : merchant,
            reference: reference,
            parser: version
        )
        if currency == "JPY" {
            guard let amount = Yen.parse(amountText) else {
                return .quarantined("Docomo settlement: no whole-yen 利用金額")
            }
            notice.amount = amount
        } else {
            // The bank warns that foreign amounts can lose their decimal point
            // here ("USD10.00" shown as "USD1,000"), so keep the text as written.
            notice.foreignAmount = amountText
        }
        return .notice(notice)
    }
}
