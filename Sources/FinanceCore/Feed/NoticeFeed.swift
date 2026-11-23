import Foundation

/// What happened to one Gmail message on its way to a notice.
public struct FeedItem: Sendable, Equatable {
    public enum Status: String, Codable, Sendable {
        /// Parsed into a notice.
        case notice
        /// A real email from a known sender that isn't a money notice.
        case ignored
        /// From a known sender and about money, but not a known layout. Needs a look.
        case quarantined
        /// Not from a known sender, or the sender check failed. Never parsed.
        case rejected
    }

    public var messageID: String
    public var status: Status
    public var notice: Notice?
    public var reason: String?
    /// Problems found while decoding the email, such as private-use characters.
    public var issues: [String]
}

/// Turns Gmail messages into notices. The same path runs on the PC and on the phone.
public enum NoticeFeed {
    /// The notice senders this app knows, and the domain each one's DKIM
    /// signature must align with.
    public static let senders: [String: String] = [
        "mail@debit.bk.mufg.jp": "bk.mufg.jp",
        "mail@direct-11.bk.mufg.jp": "bk.mufg.jp",
        "post_master@netbk.co.jp": "netbk.co.jp",
        "no-reply@mercari.jp": "mercari.jp",
        "no_reply@email.apple.com": "apple.com",
    ]

    public static func process(_ gmail: GmailMessage) -> FeedItem {
        let mail = MailMessage(gmail: gmail)
        func item(_ status: FeedItem.Status, _ notice: Notice? = nil, _ reason: String? = nil) -> FeedItem {
            FeedItem(messageID: gmail.id, status: status, notice: notice, reason: reason, issues: mail.issues)
        }
        guard let from = mail.from?.address.lowercased(), let domain = senders[from] else {
            return item(.rejected, nil, "not a known notice sender")
        }
        if case .fail(let reasons) = SenderCheck.verify(mail, allowedDomains: [domain]) {
            return item(.rejected, nil, "sender check failed: " + reasons.joined(separator: " "))
        }
        guard let receivedAt = mail.receivedAt else {
            return item(.quarantined, nil, "no receive time")
        }
        guard let text = mail.textBody ?? mail.htmlBody.map(HTMLText.plainText) else {
            return item(.quarantined, nil, "no readable body")
        }
        let email = NoticeEmail(messageID: gmail.id, receivedAt: receivedAt, sender: from, subject: mail.subject, text: text)
        switch NoticeParsers.parse(email) {
        case .notice(let n): return item(.notice, n)
        case .ignored(let why): return item(.ignored, nil, why)
        case .quarantined(let why): return item(.quarantined, nil, why)
        }
    }
}

extension Notice {
    /// The purchase day if the notice states one, else the day Gmail received it.
    public var day: String {
        occurredAt.map { String($0.prefix(10)) } ?? occurredOn ?? String(receivedAt.prefix(10))
    }
}
