import Foundation

/// One row of a statement or usage list, as the pipeline exports it.
public struct StatementRow: Codable, Sendable, Equatable {
    /// A stable ID from the pipeline.
    public var id: String
    public var source: NoticeSource
    /// "YYYY-MM-DD" as the statement shows it.
    public var date: String
    /// Whole yen; positive is money out.
    public var amount: Int
    /// The merchant as the statement shows it.
    public var merchant: String
    /// 承認番号, 取引番号 or an order ID, when the statement has one.
    public var reference: String?

    public init(id: String, source: NoticeSource, date: String, amount: Int, merchant: String, reference: String? = nil) {
        self.id = id
        self.source = source
        self.date = date
        self.amount = amount
        self.merchant = merchant
        self.reference = reference
    }
}

/// Why a notice and a row were paired.
public enum MatchRule: String, Codable, Sendable {
    /// The same 承認番号, 取引番号 or order ID.
    case reference
    /// Same source and amount within the date window, and each is the other's
    /// single best candidate.
    case best
    /// Notices and rows that can't be told apart (same amount, day and merchant).
    /// Any pairing gives the same totals.
    case interchangeable
}

public struct MatchPair: Codable, Sendable, Equatable {
    public var noticeID: String
    public var rowID: String
    public var rule: MatchRule
    /// Whether the folded merchant names agree (one is a prefix of the other).
    public var merchantAgrees: Bool
    /// The row's date minus the notice's date, in days.
    public var dayOffset: Int
}

/// Notices and rows that could pair in more than one way. They are left for a
/// person to look at, never guessed.
public struct AmbiguousGroup: Codable, Sendable, Equatable {
    public var noticeIDs: [String]
    public var rowIDs: [String]
}

public struct MatchReport: Codable, Sendable, Equatable {
    public var pairs: [MatchPair] = []
    /// Spending notices with no statement row.
    public var noticeOnly: [String] = []
    /// Statement rows with no notice.
    public var rowOnly: [String] = []
    public var ambiguous: [AmbiguousGroup] = []
    /// Settlement notices that share a 承認番号 with a purchase notice: they
    /// adjust that purchase and are not separate rows.
    public var adjustments: [String] = []
    /// Declines, top-ups, bills, bill payments and account moves: never matched
    /// to spending rows.
    public var notSpending: [String] = []
    /// Cancellations paired with the purchase notice they call off. Neither
    /// reaches a statement.
    public var cancelled: [CancelledPair] = []
    /// A purchase and a refund of the same amount within a week, neither on the
    /// statement and with no shared reference. Probably reversed; not confirmed.
    public var probablyReversed: [CancelledPair] = []
}

public struct CancelledPair: Codable, Sendable, Equatable {
    public var cancellationID: String
    public var purchaseID: String
}

/// How far a statement row's date may sit from the notice's date, in days.
public struct MatchPolicy: Sendable, Equatable {
    public var dayOffsets: ClosedRange<Int>

    public static func `for`(_ source: NoticeSource, _ kind: NoticeKind = .purchase) -> MatchPolicy {
        switch (source, kind) {
        // MUFG's settlement notice moves money on the next bank business day,
        // which can be several days later over a long holiday.
        case (.mufgDebit, .settlement): return MatchPolicy(dayOffsets: 0...6)
        // MUFG notices have no purchase time; one can arrive the morning after
        // the statement date, and the statement can post a day later.
        case (.mufgDebit, _): return MatchPolicy(dayOffsets: -1...1)
        case (.apple, _): return MatchPolicy(dayOffsets: -1...3)
        default: return MatchPolicy(dayOffsets: -1...1)
        }
    }
}

/// Pairs notices with statement rows, one to one. Deterministic: the same input
/// in any order gives the same report.
public enum Matcher {
    public static func match(notices: [Notice], rows: [StatementRow]) -> MatchReport {
        var report = MatchReport()
        let notices = notices.sorted { $0.messageID < $1.messageID }
        let rows = rows.sorted { $0.id < $1.id }
        let rowByID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        // Settlements that adjust an earlier purchase notice. The latest one gives
        // the final amount, which is what the statement shows.
        let purchaseRefs = Set(notices.filter { $0.kind == .purchase }.compactMap { ref($0) })
        var finalAmount: [String: Int] = [:]
        for n in notices.sorted(by: { ($0.receivedAt, $0.messageID) < ($1.receivedAt, $1.messageID) })
        where n.kind == .settlement {
            if let r = ref(n), purchaseRefs.contains(r), let amount = n.amount {
                finalAmount["\(n.source.rawValue)|\(r)"] = amount
            }
        }
        func effectiveAmount(_ n: Notice) -> Int? {
            guard n.kind == .purchase, let r = ref(n) else { return n.amount }
            return finalAmount["\(n.source.rawValue)|\(r)"] ?? n.amount
        }

        // Cancellations that call off a purchase notice with the same reference.
        var purchaseByRef: [String: String] = [:]
        for n in notices where n.kind == .purchase {
            if let r = ref(n) { purchaseByRef["\(n.source.rawValue)|\(r)"] = purchaseByRef["\(n.source.rawValue)|\(r)"] ?? n.messageID }
        }
        var calledOff: Set<String> = []
        for n in notices where n.kind == .cancellation {
            let keys = [n.reference, n.relatedReference].compactMap { $0 }.filter { !$0.isEmpty }
            if let purchase = keys.lazy.compactMap({ purchaseByRef["\(n.source.rawValue)|\($0)"] }).first(where: { !calledOff.contains($0) }) {
                report.cancelled.append(CancelledPair(cancellationID: n.messageID, purchaseID: purchase))
                calledOff.insert(purchase)
                calledOff.insert(n.messageID)
            }
        }

        var eligible: [Notice] = []
        for n in notices where !calledOff.contains(n.messageID) {
            switch n.kind {
            case .settlement where ref(n).map(purchaseRefs.contains) == true:
                report.adjustments.append(n.messageID)
            case .purchase, .refund, .settlement, .cancellation:
                if n.amount != nil {
                    eligible.append(n)
                } else {
                    report.noticeOnly.append(n.messageID)
                }
            default:
                report.notSpending.append(n.messageID)
            }
        }

        var openRows = Set(rows.map(\.id))
        var openNotices: [Notice] = []

        // 1. Same reference.
        for n in eligible {
            if let r = ref(n) {
                let hits = rows.filter { $0.source == n.source && $0.reference == r && openRows.contains($0.id) }
                if hits.count == 1, let row = hits.first {
                    report.pairs.append(pair(n, row, .reference))
                    openRows.remove(row.id)
                    continue
                }
            }
            openNotices.append(n)
        }

        // 2. Mutual single best, repeated until nothing changes.
        func candidates(_ n: Notice) -> [(row: StatementRow, rank: Rank)] {
            guard let amount = effectiveAmount(n), let day = noticeDay(n) else { return [] }
            let policy = MatchPolicy.for(n.source, n.kind)
            return rows.compactMap { row in
                guard openRows.contains(row.id), row.source == n.source, row.amount == amount,
                      let rowDay = JST.dayNumber(row.date)
                else { return nil }
                let offset = rowDay - day
                guard policy.dayOffsets.contains(offset) else { return nil }
                return (row, Rank(merchant: merchantAgrees(n, row) ? 0 : 1, distance: abs(offset), late: offset < 0 ? 1 : 0))
            }
        }

        var changed = true
        while changed {
            changed = false
            var bestRows: [String: [String]] = [:]
            var rowBest: [String: (rank: Rank, notices: [String])] = [:]
            for n in openNotices {
                let cands = candidates(n)
                guard let top = cands.map(\.rank).min() else { continue }
                bestRows[n.messageID] = cands.filter { $0.rank == top }.map(\.row.id)
                for c in cands {
                    if let current = rowBest[c.row.id], current.rank < c.rank { continue }
                    if let current = rowBest[c.row.id], current.rank == c.rank {
                        rowBest[c.row.id] = (c.rank, current.notices + [n.messageID])
                    } else {
                        rowBest[c.row.id] = (c.rank, [n.messageID])
                    }
                }
            }
            var done: Set<String> = []
            for n in openNotices where !done.contains(n.messageID) {
                guard let best = bestRows[n.messageID] else { continue }
                if best.count == 1, let rowID = best.first,
                   rowBest[rowID]?.notices == [n.messageID], openRows.contains(rowID), let row = rowByID[rowID] {
                    report.pairs.append(pair(n, row, .best))
                    openRows.remove(rowID)
                    done.insert(n.messageID)
                    changed = true
                    continue
                }
                // Identical notices that all have the same identical best rows:
                // any pairing among them gives the same totals.
                let bestSet = Set(best)
                let rivals = Set(best.flatMap { rowBest[$0]?.notices ?? [] })
                let group = openNotices.filter { rivals.contains($0.messageID) && !done.contains($0.messageID) }
                let rowsInSet = best.compactMap { openRows.contains($0) ? rowByID[$0] : nil }
                if best.count > 1,
                   rowsInSet.count == best.count,
                   Set(rowsInSet.map(signature)).count == 1,
                   Set(group.map(signature)).count == 1,
                   group.allSatisfy({ Set(bestRows[$0.messageID] ?? []) == bestSet }) {
                    for (g, row) in zip(group.sorted { $0.messageID < $1.messageID }, rowsInSet.sorted { $0.id < $1.id }) {
                        report.pairs.append(pair(g, row, .interchangeable))
                        openRows.remove(row.id)
                        done.insert(g.messageID)
                    }
                    changed = true
                }
            }
            openNotices = openNotices.filter { !done.contains($0.messageID) }
        }

        // 3. What's left: interchangeable groups pair in order; anything else is
        // ambiguous, or has no candidate at all.
        var parent: [String: String] = [:]
        func find(_ x: String) -> String {
            var x = x
            while let p = parent[x], p != x { x = p }
            return x
        }
        func union(_ a: String, _ b: String) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[max(ra, rb)] = min(ra, rb) }
        }
        var noticeByID: [String: Notice] = [:]
        for n in openNotices {
            let cands = candidates(n)
            if cands.isEmpty {
                report.noticeOnly.append(n.messageID)
                continue
            }
            noticeByID[n.messageID] = n
            parent["n:" + n.messageID] = "n:" + n.messageID
            for c in cands {
                parent["r:" + c.row.id] = parent["r:" + c.row.id] ?? "r:" + c.row.id
                union("n:" + n.messageID, "r:" + c.row.id)
            }
        }
        var groups: [String: (notices: [String], rows: [String])] = [:]
        for key in parent.keys.sorted() {
            let root = find(key)
            let id = String(key.dropFirst(2))
            if key.hasPrefix("n:") { groups[root, default: ([], [])].notices.append(id) } else { groups[root, default: ([], [])].rows.append(id) }
        }
        for root in groups.keys.sorted() {
            guard let g = groups[root] else { continue }
            let ns = g.notices.compactMap { noticeByID[$0] }
            let rs = g.rows.compactMap { rowByID[$0] }
            let sameNotices = Set(ns.map(signature)).count == 1
            let sameRows = Set(rs.map(signature)).count == 1
            if sameNotices, sameRows {
                for (n, row) in zip(ns, rs) {
                    report.pairs.append(pair(n, row, .interchangeable))
                    openRows.remove(row.id)
                }
                report.noticeOnly += ns.dropFirst(rs.count).map(\.messageID)
            } else {
                report.ambiguous.append(AmbiguousGroup(noticeIDs: g.notices, rowIDs: g.rows))
                for r in g.rows { openRows.remove(r) }
            }
        }

        // 4. Leftover purchases and refunds of the same amount within a week:
        // probably reversed before reaching the statement. Reported separately,
        // because nothing confirms it.
        let byID = Dictionary(notices.map { ($0.messageID, $0) }, uniquingKeysWith: { a, _ in a })
        let leftovers = report.noticeOnly.compactMap { byID[$0] }
        var reversed: Set<String> = []
        let refunds = leftovers.filter { ($0.kind == .refund || $0.kind == .cancellation) && ($0.amount ?? 0) < 0 }
        for r in refunds.sorted(by: { ($0.day, $0.messageID) < ($1.day, $1.messageID) }) {
            guard let amount = r.amount, let refundDay = JST.dayNumber(r.day) else { continue }
            let options = leftovers.filter { p in
                guard p.kind == .purchase, p.source == r.source, p.amount == -amount, !reversed.contains(p.messageID),
                      let d = JST.dayNumber(p.day) else { return false }
                return (0...7).contains(refundDay - d)
            }
            if let p = options.max(by: { ($0.day, $1.messageID) < ($1.day, $0.messageID) }) {
                report.probablyReversed.append(CancelledPair(cancellationID: r.messageID, purchaseID: p.messageID))
                reversed.insert(p.messageID)
                reversed.insert(r.messageID)
            }
        }
        report.noticeOnly.removeAll { reversed.contains($0) }

        report.rowOnly = openRows.sorted()
        report.pairs.sort { ($0.noticeID, $0.rowID) < ($1.noticeID, $1.rowID) }
        report.noticeOnly.sort()
        report.adjustments.sort()
        report.notSpending.sort()
        report.cancelled.sort { $0.cancellationID < $1.cancellationID }
        return report
    }

    struct Rank: Comparable, Equatable {
        var merchant: Int
        var distance: Int
        var late: Int
        static func < (a: Rank, b: Rank) -> Bool {
            (a.merchant, a.distance, a.late) < (b.merchant, b.distance, b.late)
        }
    }

    static func ref(_ n: Notice) -> String? {
        guard let r = n.reference, !r.isEmpty else { return nil }
        return r
    }

    /// The purchase day if the notice states one, else the day Gmail received it.
    static func noticeDay(_ n: Notice) -> Int? {
        let text = n.occurredAt.map { String($0.prefix(10)) } ?? n.occurredOn ?? String(n.receivedAt.prefix(10))
        return JST.dayNumber(text)
    }

    static func merchantAgrees(_ n: Notice, _ row: StatementRow) -> Bool {
        let a = TextFold.key(n.merchant ?? ""), b = TextFold.key(row.merchant)
        guard !a.isEmpty, !b.isEmpty else { return false }
        return a.hasPrefix(b) || b.hasPrefix(a)
    }

    static func signature(_ n: Notice) -> String {
        "\(n.source.rawValue)|\(n.amount ?? 0)|\(noticeDay(n) ?? 0)|\(TextFold.key(n.merchant ?? ""))"
    }

    static func signature(_ r: StatementRow) -> String {
        "\(r.source.rawValue)|\(r.amount)|\(r.date)|\(TextFold.key(r.merchant))"
    }

    static func pair(_ n: Notice, _ row: StatementRow, _ rule: MatchRule) -> MatchPair {
        let offset = (JST.dayNumber(row.date) ?? 0) - (noticeDay(n) ?? 0)
        return MatchPair(noticeID: n.messageID, rowID: row.id, rule: rule, merchantAgrees: merchantAgrees(n, row), dayOffset: offset)
    }
}

extension JST {
    /// Days since 1970-01-01 for "YYYY-MM-DD", by pure arithmetic. Returns `nil` for impossible calendar dates.
    public static func dayNumber(_ text: String) -> Int? {
        let p = text.split(separator: "-", omittingEmptySubsequences: false)
        guard p.count == 3, p[0].count == 4, p[1].count == 2, p[2].count == 2,
              let y = Int(p[0]), let m = Int(p[1]), let d = Int(p[2]),
              (1...12).contains(m), (1...31).contains(d)
        else { return nil }
        let yy = m <= 2 ? y - 1 : y
        let era = (yy >= 0 ? yy : yy - 399) / 400
        let yoe = yy - era * 400
        let doy = (153 * ((m + 9) % 12) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let z = era * 146_097 + doe - 719_468
        guard JST.day(fromDayNumber: z) == text else { return nil }
        return z
    }
}
