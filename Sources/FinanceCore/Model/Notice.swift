import Foundation

/// Which kind of notice email a record came from.
public enum NoticeSource: String, Codable, Sendable, CaseIterable {
    case mufgDebit = "mufg_debit"
    case mufgDirect = "mufg_direct"
    case docomoDebit = "docomo_debit"
    case docomoAccount = "docomo_account"
    case merpay
    case apple
}

/// What a notice reports.
public enum NoticeKind: String, Codable, Sendable {
    /// A card payment, as authorized at the shop.
    case purchase
    /// Money returned for an earlier payment.
    case refund
    /// A later debit or credit for a card payment: a sale confirmed without an
    /// earlier authorization, a difference adjustment, or a fee.
    case settlement
    /// A refused payment, or a failed transfer. Never spending.
    case decline
    /// A payment that was called off, often a card check that was released. It
    /// cancels its purchase notice; the amount is negative.
    case cancellation
    /// A bill was issued (the amount due). Not spending; the purchases on it count.
    case bill
    /// A ¥1 authorization that checks the card. Not spending; statements show it
    /// as ¥0 or not at all.
    case cardCheck = "card_check"
    /// Money moved into a wallet, such as a Merpay top-up. Not spending.
    case topUp = "top_up"
    /// A bill was paid. The purchases on it were already counted.
    case billPaid = "bill_paid"
    /// Money into the account.
    case deposit
    /// Money out of the account that is not a card payment.
    case withdrawal
}

/// One parsed notice email.
///
/// Amounts are whole yen. Positive is money out and negative is money in, as in
/// the statements. Times are Japan time, written as ISO 8601 strings with +09:00
/// so that the JSON output is stable.
public struct Notice: Codable, Sendable, Equatable {
    /// Gmail's message ID.
    public var messageID: String
    public var source: NoticeSource
    public var kind: NoticeKind
    /// When Gmail received the email.
    public var receivedAt: String
    /// The purchase time, when the notice states one.
    public var occurredAt: String?
    /// The purchase date, when the notice states a date but no time.
    public var occurredOn: String?
    /// Whole yen; nil when the notice has no yen amount.
    public var amount: Int?
    /// The currency the notice states, when it states one.
    public var currency: String?
    /// A foreign amount exactly as written, when the payment was not in yen.
    public var foreignAmount: String?
    /// The merchant exactly as written. Nil when the notice leaves it blank.
    public var merchant: String?
    /// 承認番号, 取引番号 or an order ID, when the notice has one.
    public var reference: String?
    /// For a refund or cancellation: the 取引番号 of the original payment, when
    /// the notice shows it separately.
    public var relatedReference: String?
    /// An Apple order number named in another source's notice, which links the
    /// two records so the payment is counted once.
    public var orderID: String?
    /// How the total was paid, in whole yen, when the notice splits it:
    /// "credit", "points", "balance", "discount", or the label as written.
    public var parts: [String: Int]?
    /// The parser and its version, such as "docomo_debit/1".
    public var parser: String

    public init(
        messageID: String, source: NoticeSource, kind: NoticeKind, receivedAt: String,
        occurredAt: String? = nil, occurredOn: String? = nil, amount: Int? = nil,
        currency: String? = nil, foreignAmount: String? = nil, merchant: String? = nil,
        reference: String? = nil, relatedReference: String? = nil, orderID: String? = nil,
        parts: [String: Int]? = nil, parser: String
    ) {
        self.relatedReference = relatedReference
        self.orderID = orderID
        self.parts = parts
        self.messageID = messageID
        self.source = source
        self.kind = kind
        self.receivedAt = receivedAt
        self.occurredAt = occurredAt
        self.occurredOn = occurredOn
        self.amount = amount
        self.currency = currency
        self.foreignAmount = foreignAmount
        self.merchant = merchant
        self.reference = reference
        self.parser = parser
    }

    /// One line of JSON with sorted keys and no optional fields that are nil.
    public func jsonLine() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

/// The parts of an email that notice parsers read.
public struct NoticeEmail: Sendable, Equatable {
    public var messageID: String
    public var receivedAt: Date
    /// The sender's address, lowercased.
    public var sender: String
    public var subject: String
    /// The decoded plain-text body, or HTML already turned into text.
    public var text: String

    public init(messageID: String, receivedAt: Date, sender: String, subject: String, text: String) {
        self.messageID = messageID
        self.receivedAt = receivedAt
        self.sender = sender.lowercased()
        self.subject = subject
        self.text = text
    }
}
