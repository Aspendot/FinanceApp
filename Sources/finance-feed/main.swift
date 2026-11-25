import FinanceCore
import Foundation

let usage = """
finance-feed: notice emails in, notice lines and a match report out.

  finance-feed parse <dir> <notices.jsonl> <review.jsonl>
      Reads Gmail format=full JSON files under <dir>. Writes one notice per line,
      and a review list (message ID, status, reason; no email content) for
      quarantined and rejected messages.

  finance-feed match <notices.jsonl> <rows.jsonl> <coverage.json> <report.json>
      Matches notices to statement rows inside each source's coverage
      ({"<source>": {"start": "YYYY-MM-DD", "end": "YYYY-MM-DD"}}).

  finance-feed show <message.json>
      Prints the sender, subject and the text a parser sees, then the outcome.
      For writing parsers on a private machine; it prints email content.
"""

/// Loads a data file and prints what the app would compute from it, to compare with
/// the dashboard on a private machine. It prints amounts, so run it only there.
func bundleCheck(_ path: String, _ today: String) throws {
    let bundle = try DataBundle.decode(from: Data(contentsOf: URL(fileURLWithPath: path)))
    let categorizer = Categorizer(rules: bundle.rules)
    print("format \(bundle.format) · statements through \(bundle.asOf) · \(bundle.items.count) items · \(bundle.timeline.count) timeline entries")
    print("rules: \(bundle.rules.rules.count), invalid \(categorizer.invalidRuleIndexes); amount rules invalid \(categorizer.invalidAmountRuleIndexes)")
    let months = MonthTotals.compute(items: bundle.items, config: bundle.layerConfig, layers: bundle.layers)
    for month in months.keys.sorted().suffix(4) {
        guard let t = months[month] else { continue }
        print("\(month): spending \(t.total) · income \(t.income) · people \(t.people) · debt \(t.debt) · left \(t.left)")
    }
    if let p = PaydayView.compute(timeline: bundle.timeline, today: today) {
        print("payday in \(p.daysToPayday) days: money in \(p.inSum) · bills \(p.outSum) · left \(p.left) · borrowing \(p.borrowedSum) · left if borrowed \(p.leftIfBorrowed)")
    }
    var agree = 0, differ: [String: Int] = [:]
    for item in bundle.items {
        let (group, category) = categorizer.categorize(merchant: item.merchant, amount: item.amount, date: item.date)
        if group == item.group && category == item.category { agree += 1 } else { differ[item.source, default: 0] += 1 }
    }
    print("categorizer vs the PC's categories: \(agree) agree; differ by source: \(differ.sorted { $0.key < $1.key })")
}

func show(_ path: String) throws {
    let gmail = try JSONDecoder().decode(GmailMessage.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    let mail = MailMessage(gmail: gmail)
    print("from: \(mail.from?.address ?? "?")")
    print("subject: \(mail.subject)")
    print("issues: \(mail.issues)")
    print("---")
    print(mail.textBody ?? mail.htmlBody.map(HTMLText.plainText) ?? "<no body>")
    print("---")
    let item = NoticeFeed.process(gmail)
    print("\(item.status.rawValue): \(item.reason ?? "") \(try item.notice.map { try $0.jsonLine() } ?? "")")
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

func lines(_ path: String) throws -> [String] {
    try String(decoding: Data(contentsOf: URL(fileURLWithPath: path)), as: UTF8.self)
        .split(whereSeparator: \.isNewline).map(String.init)
}

func write(_ text: String, to path: String) throws {
    try Data(text.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
}

func jsonLine<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

struct ReviewLine: Codable {
    var messageID: String
    var status: String
    var reason: String
}

struct Coverage: Codable {
    var start: String
    var end: String
}

func parse(_ dir: String, _ out: String, _ reviewOut: String) throws {
    let root = URL(fileURLWithPath: dir)
    guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
        fail("cannot read \(dir)")
    }
    let files = walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }
    var notices: [Notice] = []
    var review: [ReviewLine] = []
    var counts: [String: Int] = [:]
    var issues = 0
    let decoder = JSONDecoder()
    for file in files {
        let gmail = try decoder.decode(GmailMessage.self, from: Data(contentsOf: file))
        let item = NoticeFeed.process(gmail)
        if !item.issues.isEmpty { issues += 1 }
        switch item.status {
        case .notice:
            if let n = item.notice {
                notices.append(n)
                counts["notice \(n.source.rawValue) \(n.kind.rawValue)", default: 0] += 1
            }
        case .ignored:
            counts["ignored: \(item.reason ?? "")", default: 0] += 1
        case .quarantined, .rejected:
            counts["\(item.status.rawValue): \(item.reason ?? "")", default: 0] += 1
            review.append(ReviewLine(messageID: item.messageID, status: item.status.rawValue, reason: item.reason ?? ""))
        }
    }
    notices.sort { ($0.receivedAt, $0.messageID) < ($1.receivedAt, $1.messageID) }
    review.sort { $0.messageID < $1.messageID }
    try write(notices.map { try $0.jsonLine() + "\n" }.joined(), to: out)
    try write(review.map { try jsonLine($0) + "\n" }.joined(), to: reviewOut)
    print("\(files.count) messages, \(notices.count) notices, \(review.count) to review, \(issues) with decoding issues")
    for (key, n) in counts.sorted(by: { $0.key < $1.key }) {
        print(String(format: "%6d  ", n) + key)
    }
}

func match(_ noticesPath: String, _ rowsPath: String, _ coveragePath: String, _ out: String) throws {
    let decoder = JSONDecoder()
    let coverage = try decoder.decode([String: Coverage].self, from: Data(contentsOf: URL(fileURLWithPath: coveragePath)))
    /// Notices get one day of slack past the statement's end: a notice can arrive
    /// the morning after a payment that is already on the statement.
    func inside(_ source: NoticeSource, _ day: String, slack: Int = 0) -> Bool {
        guard let c = coverage[source.rawValue], let d = JST.dayNumber(day),
              let start = JST.dayNumber(c.start), let end = JST.dayNumber(c.end)
        else { return false }
        return start <= d && d <= end + slack
    }
    var skippedNotices = 0
    let notices: [Notice] = try lines(noticesPath).compactMap { line in
        do {
            return try decoder.decode(Notice.self, from: Data(line.utf8))
        } catch {
            skippedNotices += 1
            return nil
        }
    }.filter { inside($0.source, $0.day, slack: 1) }
    if skippedNotices > 0 {
        FileHandle.standardError.write(Data("warning: skipped \(skippedNotices) malformed notice line(s) in \(noticesPath)\n".utf8))
    }
    var skippedRows = 0
    let rows: [StatementRow] = try lines(rowsPath).compactMap { line in
        do {
            return try decoder.decode(StatementRow.self, from: Data(line.utf8))
        } catch {
            skippedRows += 1
            return nil
        }
    }.filter { inside($0.source, $0.date) }
    if skippedRows > 0 {
        FileHandle.standardError.write(Data("warning: skipped \(skippedRows) malformed statement row(s) in \(rowsPath)\n".utf8))
    }
    let report = Matcher.match(notices: notices, rows: rows)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    try write(String(decoding: try encoder.encode(report), as: UTF8.self) + "\n", to: out)

    let sourceOfNotice = Dictionary(notices.map { ($0.messageID, $0.source) }, uniquingKeysWith: { a, _ in a })
    let sourceOfRow = Dictionary(rows.map { ($0.id, $0.source) }, uniquingKeysWith: { a, _ in a })
    print("source         notices  rows | reference  best  interch. | notice-only  row-only  ambiguous  adjust  not-spending")
    for source in NoticeSource.allCases where coverage[source.rawValue] != nil {
        let pairs = report.pairs.filter { sourceOfNotice[$0.noticeID] == source }
        func rule(_ r: MatchRule) -> Int { pairs.filter { $0.rule == r }.count }
        func count(_ ids: [String], _ map: [String: NoticeSource]) -> Int {
            ids.filter { map[$0] == source }.count
        }
        let noticeCount: Int = notices.filter { $0.source == source }.count
        let rowCount: Int = rows.filter { $0.source == source }.count
        let ambiguous: Int = report.ambiguous.filter { group in group.noticeIDs.contains { sourceOfNotice[$0] == source } }.count
        var cells: [Int] = [noticeCount, rowCount, rule(.reference), rule(.best), rule(.interchangeable)]
        cells.append(count(report.noticeOnly, sourceOfNotice))
        cells.append(count(report.rowOnly, sourceOfRow))
        cells.append(ambiguous)
        cells.append(count(report.adjustments, sourceOfNotice))
        cells.append(count(report.notSpending, sourceOfNotice))
        print(source.rawValue.padding(toLength: 14, withPad: " ", startingAt: 0) + cells.map { String(format: "%6d", $0) }.joined(separator: " "))
    }
}

let args = Array(CommandLine.arguments.dropFirst())
do {
    switch (args.first, args.count) {
    case ("parse", 4): try parse(args[1], args[2], args[3])
    case ("match", 5): try match(args[1], args[2], args[3], args[4])
    case ("show", 2): try show(args[1])
    case ("bundle", 3): try bundleCheck(args[1], args[2])
    default: fail(usage)
    }
} catch {
    fail("finance-feed: \(error)")
}
