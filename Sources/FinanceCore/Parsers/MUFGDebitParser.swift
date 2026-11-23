import Foundation

/// MUFG VISA debit notices.
///
/// Both notices carry only the amount in yen and the merchant: no purchase time
/// and no authorization number. A negative amount is money back.
/// - The purchase notice comes at the time of payment.
/// - The 「ご利用代金お引落し（またはご入金）」 notice says money moves on the next
///   bank business day: a recurring bill, a refund, or only an exchange-rate
///   difference. It is always a settlement, whatever its sign.
enum MUFGDebitParser {
    static let sender = "mail@debit.bk.mufg.jp"
    static let version = "mufg_debit/1"
    static let purchaseSubject = TextFold.key("【三菱ＵＦＪ‐ＶＩＳＡデビット】ご利用のお知らせ")
    static let settlementSubject = TextFold.key("【三菱ＵＦＪ‐ＶＩＳＡデビット】ご利用代金お引落し（またはご入金）のお知らせ")

    static func parse(_ email: NoticeEmail) -> ParseOutcome {
        let subject = TextFold.key(email.subject)
        guard subject == purchaseSubject || subject == settlementSubject else {
            return NoticeParsers.unknown(email, "MUFG debit")
        }
        let isSettlement = subject == settlementSubject
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
            kind: isSettlement ? .settlement : (amount < 0 ? .refund : .purchase),
            receivedAt: JST.timestamp(email.receivedAt),
            amount: amount,
            currency: "JPY",
            merchant: merchant.isEmpty ? nil : merchant,
            parser: version
        ))
    }
}
