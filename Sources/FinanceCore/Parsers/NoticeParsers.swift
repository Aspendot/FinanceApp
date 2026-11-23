import Foundation

/// What happened to one email.
public enum ParseOutcome: Sendable, Equatable {
    /// A payment or money-movement notice.
    case notice(Notice)
    /// Not a money notice (news, security or marketing mail). Dropped on purpose.
    case ignored(String)
    /// Looks like a money notice but doesn't fit a known layout. Kept for review
    /// and never guessed at.
    case quarantined(String)
}

/// Routes an email to the parser for its sender. The sender must already have
/// passed the sender check; parsers trust the address they are given.
public enum NoticeParsers {
    public static func parse(_ email: NoticeEmail) -> ParseOutcome {
        switch email.sender {
        case MUFGDebitParser.sender:
            return MUFGDebitParser.parse(email)
        case DocomoDebitParser.sender:
            return DocomoDebitParser.parse(email)
        case MerpayParser.sender:
            return MerpayParser.parse(email)
        case AppleReceiptParser.sender:
            return AppleReceiptParser.parse(email)
        default:
            return .quarantined("no parser for this sender yet")
        }
    }

    /// An unknown email is quarantined only if it looks like a transaction: a
    /// "…金額 : <yen>" line, or a yen amount in the subject. News, maintenance and
    /// marketing mail are ignored.
    static func unknown(_ email: NoticeEmail, _ label: String) -> ParseOutcome {
        let fields = Fields(email.text)
        let hasAmountLine = fields.entries.contains { $0.key.contains("金額") && Yen.parse($0.value.prefix { $0 != "(" && $0 != "（" }.trimmingCharacters(in: .whitespaces)) != nil }
        if hasAmountLine || yenInSubject(email.subject) != nil {
            return .quarantined("\(label): unknown layout with an amount")
        }
        return .ignored("\(label): not a money notice")
    }

    /// The first "￥12,345" or "¥12,345" in a subject.
    static func yenInSubject(_ subject: String) -> Int? {
        guard let mark = subject.firstIndex(where: { $0 == "￥" || $0 == "¥" }) else { return nil }
        let digits = subject[subject.index(after: mark)...].prefix { ("0"..."9").contains($0) || $0 == "," || ("０"..."９").contains($0) || $0 == "，" }
        return Yen.parse(String(digits))
    }
}

/// Reads "key : value" and "key ： value" lines. Keys match by their folded form,
/// so full-width spellings and padding spaces don't matter. The first line with a
/// given key wins, because the data lines come before the boilerplate.
struct Fields {
    struct Entry {
        var key: String
        var value: String
    }

    /// Every "key : value" line, in order, with folded keys.
    private(set) var entries: [Entry] = []

    init(_ text: String) {
        for line in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            guard let sep = line.firstIndex(where: { $0 == ":" || $0 == "：" }) else { continue }
            let key = TextFold.key(String(line[..<sep]))
            guard !key.isEmpty else { continue }
            entries.append(Entry(key: key, value: line[line.index(after: sep)...].trimmingCharacters(in: .whitespaces)))
        }
    }

    subscript(_ key: String) -> String? {
        let folded = TextFold.key(key)
        return entries.first { $0.key == folded }?.value
    }

    /// Every value for a key, in order.
    func all(_ key: String) -> [String] {
        let folded = TextFold.key(key)
        return entries.filter { $0.key == folded }.map(\.value)
    }
}
