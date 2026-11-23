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
"""

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
    func inside(_ source: NoticeSource, _ day: String) -> Bool {
        guard let c = coverage[source.rawValue] else { return false }
        return c.start <= day && day <= c.end
    }
    let notices = try lines(noticesPath).map { try decoder.decode(Notice.self, from: Data($0.utf8)) }
        .filter { inside($0.source, $0.day) }
    let rows = try lines(rowsPath).map { try decoder.decode(StatementRow.self, from: Data($0.utf8)) }
        .filter { inside($0.source, $0.date) }
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
    default: fail(usage)
    }
} catch {
    fail("finance-feed: \(error)")
}
