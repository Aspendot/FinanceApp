import Foundation

/// Apple receipts ("Your receipt from Apple."). The email is HTML only; the
/// parser reads its text form, where labels sit on their own line above their
/// values. Only the date, order ID, store, first item and total are kept. The
/// "billed to" block, which holds a name and an address, is never read.
enum AppleReceiptParser {
    static let sender = "no_reply@email.apple.com"
    static let version = "apple/1"

    static func parse(_ email: NoticeEmail) -> ParseOutcome {
        let subject = email.subject.lowercased()
        if subject.contains("receipt from apple") || email.subject.contains("領収書") {
            return receipt(email)
        }
        if subject.contains("subscription") || email.subject.contains("サブスクリプション") || subject.contains("invited you") {
            return .ignored("Apple: account or subscription notice")
        }
        return NoticeParsers.unknown(email, "Apple")
    }

    private static func receipt(_ email: NoticeEmail) -> ParseOutcome {
        let lines = email.text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if lines.contains(where: { $0.uppercased() == "ORDER ID:" }) {
            return invoice(email, lines)
        }
        func value(after labels: Set<String>) -> (index: Int, text: String)? {
            guard let i = lines.firstIndex(where: { labels.contains($0.uppercased()) }), i + 1 < lines.count else { return nil }
            return (i + 1, lines[i + 1])
        }
        guard let date = value(after: ["DATE", "日付"]), let day = parseDate(date.text) else {
            return .quarantined("Apple: receipt without a readable date")
        }
        guard let order = value(after: ["ORDER ID", "注文番号", "ご注文番号"]) else {
            return .quarantined("Apple: receipt without an order ID")
        }
        let orderID = String(order.text.split(separator: "|").first ?? "").trimmingCharacters(in: .whitespaces)
        guard !orderID.isEmpty, orderID.allSatisfy({ $0.isLetter || $0.isNumber }) else {
            return .quarantined("Apple: unreadable order ID")
        }
        guard let totalLine = lines.first(where: { $0.uppercased().hasPrefix("TOTAL") || $0.hasPrefix("合計") }),
              let bar = totalLine.firstIndex(of: "|"),
              let total = Yen.parse(totalLine[totalLine.index(after: bar)...].trimmingCharacters(in: .whitespaces))
        else {
            return .quarantined("Apple: receipt without a whole-yen total")
        }
        // The order line ends with "| DOCUMENT NO."; the document number, the
        // store and the first item follow it.
        var item: String?
        if order.text.uppercased().contains("DOCUMENT"), order.index + 3 < lines.count {
            item = lines[order.index + 3]
        }
        return .notice(Notice(
            messageID: email.messageID,
            source: .apple,
            kind: total < 0 ? .refund : .purchase,
            receivedAt: JST.timestamp(email.receivedAt),
            occurredOn: day,
            amount: total,
            currency: "JPY",
            merchant: item,
            reference: orderID,
            parser: version
        ))
    }

    /// The older "Invoice" layout: the date on its own line near the top, values
    /// under "Order ID:" and "Apple Account:", then "Subtotal" and "JCT charged"
    /// amounts. Their sum must equal the last amount before the footer, which is
    /// what was paid; otherwise the receipt is quarantined.
    private static func invoice(_ email: NoticeEmail, _ lines: [String]) -> ParseOutcome {
        func next(after label: String) -> (index: Int, text: String)? {
            guard let i = lines.firstIndex(where: { $0.uppercased().hasPrefix(label) }), i + 1 < lines.count else { return nil }
            return (i + 1, lines[i + 1])
        }
        guard let day = lines.prefix(5).lazy.compactMap(parseDate).first else {
            return .quarantined("Apple: invoice without a readable date")
        }
        guard let order = next(after: "ORDER ID:"), order.text.allSatisfy({ $0.isLetter || $0.isNumber }) else {
            return .quarantined("Apple: invoice without an order ID")
        }
        guard let subtotalLine = next(after: "SUBTOTAL"), let subtotal = Yen.parse(subtotalLine.text),
              let taxLine = next(after: "JCT CHARGED"), let tax = Yen.parse(taxLine.text)
        else {
            return .quarantined("Apple: invoice without a subtotal and tax")
        }
        let footer = lines.firstIndex { $0.hasPrefix("You can view") } ?? lines.count
        guard taxLine.index + 1 < footer,
              let paid = lines[taxLine.index + 1 ..< footer].reversed().lazy.compactMap({ Yen.parse($0) }).first,
              paid == subtotal + tax
        else {
            return .quarantined("Apple: invoice amounts do not agree")
        }
        let item = next(after: "APPLE ACCOUNT:").flatMap { $0.index + 1 < lines.count ? lines[$0.index + 1] : nil }
        return .notice(Notice(
            messageID: email.messageID,
            source: .apple,
            kind: paid < 0 ? .refund : .purchase,
            receivedAt: JST.timestamp(email.receivedAt),
            occurredOn: day,
            amount: paid,
            currency: "JPY",
            merchant: item,
            reference: order.text,
            parser: version
        ))
    }

    static let months = ["JAN": 1, "FEB": 2, "MAR": 3, "APR": 4, "MAY": 5, "JUN": 6,
                         "JUL": 7, "AUG": 8, "SEP": 9, "OCT": 10, "NOV": 11, "DEC": 12]

    /// "Nov 22, 2026" or "2026年11月22日" as "2026-11-22".
    static func parseDate(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.contains("年") {
            let parts = t.split(whereSeparator: { "年月日".contains($0) }).map { String($0) }
            guard parts.count == 3 else { return nil }
            return JST.day(slashed: parts[0] + "/" + parts[1] + "/" + parts[2])
        }
        let parts = t.replacingOccurrences(of: ",", with: "").split(separator: " ")
        guard parts.count == 3, let m = months[String(parts[0].prefix(3)).uppercased()] else { return nil }
        return JST.day(slashed: "\(parts[2])/\(m)/\(parts[1])")
    }
}
