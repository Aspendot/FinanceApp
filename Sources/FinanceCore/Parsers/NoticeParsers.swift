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
        default:
            return .quarantined("no parser for this sender yet")
        }
    }

    /// Words that suggest an unknown email moves money, so it is quarantined
    /// rather than ignored.
    static let moneyWords = ["金額", "引落", "入金", "出金", "振込", "請求", "支払"]

    static func unknown(_ email: NoticeEmail, _ label: String) -> ParseOutcome {
        let text = email.subject + "\n" + email.text
        if moneyWords.contains(where: { text.contains($0) }) {
            return .quarantined("\(label): unknown layout that mentions money")
        }
        return .ignored("\(label): not a money notice")
    }
}

/// Reads "key : value" and "key ： value" lines. Keys match by their folded form,
/// so full-width spellings and padding spaces don't matter. The first line with a
/// given key wins, because the data lines come before the boilerplate.
struct Fields {
    private var values: [String: String] = [:]

    init(_ text: String) {
        for line in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            guard let sep = line.firstIndex(where: { $0 == ":" || $0 == "：" }) else { continue }
            let key = TextFold.key(String(line[..<sep]))
            guard !key.isEmpty, values[key] == nil else { continue }
            values[key] = line[line.index(after: sep)...].trimmingCharacters(in: .whitespaces)
        }
    }

    subscript(_ key: String) -> String? {
        values[TextFold.key(key)]
    }
}
