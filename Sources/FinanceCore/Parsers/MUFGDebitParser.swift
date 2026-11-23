import Foundation

/// MUFG VISA debit notices.
///
/// The purchase notice carries only the amount in yen and the merchant: no
/// purchase time and no authorization number. A negative amount is money back.
enum MUFGDebitParser {
    static let sender = "mail@debit.bk.mufg.jp"
    static let version = "mufg_debit/1"
    static let purchaseSubject = TextFold.key("【三菱ＵＦＪ‐ＶＩＳＡデビット】ご利用のお知らせ")

    static func parse(_ email: NoticeEmail) -> ParseOutcome {
        guard TextFold.key(email.subject) == purchaseSubject else {
            return NoticeParsers.unknown(email, "MUFG debit")
        }
        let fields = Fields(email.text)
        guard let amountText = fields["ご利用金額（円）"] else {
            return .quarantined("MUFG debit: no amount line")
        }
        guard let amount = Yen.parse(amountText) else {
            return .quarantined("MUFG debit: amount is not whole yen")
        }
        guard let merchant = fields["ご利用先"] else {
            return .quarantined("MUFG debit: no merchant line")
        }
        return .notice(Notice(
            messageID: email.messageID,
            source: .mufgDebit,
            kind: amount < 0 ? .refund : .purchase,
            receivedAt: JST.timestamp(email.receivedAt),
            amount: amount,
            currency: "JPY",
            merchant: merchant.isEmpty ? nil : merchant,
            parser: version
        ))
    }
}
