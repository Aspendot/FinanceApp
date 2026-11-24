import Foundation

/// A one-to-one match between a Gmail notice and a confirmed `BankTransaction`.
public struct BankMatchPair: Codable, Sendable, Equatable {
    public var noticeID: String
    public var transactionID: String
    public var rule: MatchRule
    public var referenceAgrees: Bool
    public var merchantAgrees: Bool
    /// `transaction.date - notice.day` in whole days (always in `0...3`).
    public var dayOffset: Int

    public init(
        noticeID: String,
        transactionID: String,
        rule: MatchRule,
        referenceAgrees: Bool = false,
        merchantAgrees: Bool,
        dayOffset: Int
    ) {
        self.noticeID = noticeID
        self.transactionID = transactionID
        self.rule = rule
        self.referenceAgrees = referenceAgrees
        self.merchantAgrees = merchantAgrees
        self.dayOffset = dayOffset
    }
}

/// Output of `BankLayering.build`: confirmed Money Forward items, remaining pending
/// Gmail notice items, unmatched older bundle notices, match diagnostics and effective coverage.
public struct BankLayeringResult: Sendable, Equatable {
    /// Confirmed items built from mapped Money Forward transactions dated after each source's bundle coverage end.
    public var bankItems: [BudgetItem]
    /// Money Forward transaction IDs aligned one-to-one with `bankItems`.
    public var bankTransactionIDs: [String]
    /// Confirmed bank rows aligned one-to-one with `bankItems`, keeping each row's raw bank
    /// description for timeline reconciliation even when a Gmail notice supplied `BudgetItem.merchant`.
    public var bankRows: [TimelineReconciler.BankRow]
    /// All mapped confirmed bank rows regardless of bundle ledger coverage, so balance roll-forwards
    /// (`LiveCashSummary`) never drop confirmed rows dated between an account's `asOf` and the bundle cutoff.
    public var allBankRows: [TimelineReconciler.BankRow]
    /// Pending items built from Gmail notices not matched to Money Forward or covered by the bundle.
    public var pendingItems: [BudgetItem]
    /// Gmail message IDs aligned one-to-one with `pendingItems`.
    public var pendingNoticeIDs: [String]
    /// Notices excluded because they precede their source's bundle coverage end.
    public var unmatched: [Notice]
    /// One-to-one matches between post-bundle Gmail notices and Money Forward rows.
    public var matchedPairs: [BankMatchPair]
    /// Notice/transaction ties left unresolved.
    public var ambiguous: [AmbiguousGroup]
    /// Per-source coverage extended from `bundle.coverage` to each source's newest mapped Money Forward row.
    public var effectiveCoverage: [String: CoverageRange]

    public init(
        bankItems: [BudgetItem] = [],
        bankTransactionIDs: [String] = [],
        bankRows: [TimelineReconciler.BankRow] = [],
        allBankRows: [TimelineReconciler.BankRow] = [],
        pendingItems: [BudgetItem] = [],
        pendingNoticeIDs: [String] = [],
        unmatched: [Notice] = [],
        matchedPairs: [BankMatchPair] = [],
        ambiguous: [AmbiguousGroup] = [],
        effectiveCoverage: [String: CoverageRange] = [:]
    ) {
        self.bankItems = bankItems
        self.bankTransactionIDs = bankTransactionIDs
        self.bankRows = bankRows
        self.allBankRows = allBankRows
        self.pendingItems = pendingItems
        self.pendingNoticeIDs = pendingNoticeIDs
        self.unmatched = unmatched
        self.matchedPairs = matchedPairs
        self.ambiguous = ambiguous
        self.effectiveCoverage = effectiveCoverage
    }
}

/// Combines bundle history, Money Forward bank transactions and Gmail notices into
/// confirmed and pending `BudgetItem`s per source.
///
/// Layering rules:
/// 1. Bundle items cover each source up to `bundle.coverage[source].end`.
/// 2. Mapped Money Forward transactions dated strictly after `bundle.coverage[source].end`
///    become confirmed items (`isPending == false`), categorized with `categorizer`,
///    with the matched notice's merchant or the transaction description.
/// 3. Post-bundle Gmail notices are matched one-to-one against Money Forward rows
///    with equal amount and date offset `0...3` days (including cross-source targets from
///    `bundle.noticeSourceMatches`). Ties stay unresolved.
/// 4. Effective coverage extends to the newest mapped row. Unmatched post-bundle notices stay pending.
public enum BankLayering {
    /// Allowed day offsets (`bankTransaction.date - notice.day`) when matching notices to bank rows.
    public static let matchDayOffsets: ClosedRange<Int> = 0...3

    private struct CompiledStatementRule: @unchecked Sendable {
        let regex: NSRegularExpression
        let referenceGroup: Int?
        let merchantGroup: Int?

        init?(_ rule: StatementLineRule) {
            guard let regex = try? NSRegularExpression(pattern: rule.pattern, options: [.caseInsensitive]) else {
                return nil
            }
            self.regex = regex
            self.referenceGroup = rule.referenceGroup
            self.merchantGroup = rule.merchantGroup
        }

        func parse(_ text: String) -> (reference: String?, merchant: String?)? {
            let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, options: [], range: fullRange) else {
                return nil
            }
            func capture(_ group: Int?) -> String? {
                guard let group, group > 0, group < match.numberOfRanges else { return nil }
                let nsRange = match.range(at: group)
                guard nsRange.location != NSNotFound, let range = Range(nsRange, in: text) else { return nil }
                let value = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }
            return (capture(referenceGroup), capture(merchantGroup))
        }
    }

    private struct MappedRow: Sendable {
        let transaction: BankTransaction
        let sourceID: String
        let sourceLabel: String
        let dayNumber: Int
        /// Approval/reference number extracted by a bundle `StatementLineRule`, if any.
        let parsedReference: String?
        /// Merchant text used for prefix matching: extracted by a matching `StatementLineRule`
        /// (which may be `nil` when the bank line format carries no merchant), or the raw
        /// description when no rule matched.
        let matchMerchant: String?
    }

    private struct Rank: Comparable, Equatable {
        let reference: Int
        let merchant: Int
        let distance: Int

        static func < (lhs: Rank, rhs: Rank) -> Bool {
            (lhs.reference, lhs.merchant, lhs.distance) < (rhs.reference, rhs.merchant, rhs.distance)
        }
    }

    public static func build(
        bundle: DataBundle,
        bankTransactions: [BankTransaction],
        accountMapping: [String: String],
        notices: [Notice],
        categorizer: Categorizer,
        config: LayerConfig
    ) -> BankLayeringResult {
        // Compile optional per-source statement-line rules from the bundle.
        var compiledLineRules: [String: [CompiledStatementRule]] = [:]
        if let rawRules = bundle.statementLineRules {
            for (sourceID, rules) in rawRules {
                compiledLineRules[sourceID] = rules.compactMap(CompiledStatementRule.init)
            }
        }

        // Deduplicate bank transactions deterministically by ID.
        var seenTxIDs = Set<String>()
        let uniqueTransactions = bankTransactions
            .sorted { ($0.date, $0.id) < ($1.date, $1.id) }
            .filter { seenTxIDs.insert($0.id).inserted }

        // Map transactions to bundle sources and extend effective coverage per source.
        var effectiveCoverage = bundle.coverage
        var sourceMinDate: [String: String] = [:]
        var sourceMaxDate: [String: String] = [:]
        var mappedRows: [MappedRow] = []

        for tx in uniqueTransactions {
            guard let sourceID = tx.mappedSource(using: accountMapping),
                  let day = JST.dayNumber(tx.date) else { continue }
            if let existingMin = sourceMinDate[sourceID] {
                if tx.date < existingMin { sourceMinDate[sourceID] = tx.date }
            } else {
                sourceMinDate[sourceID] = tx.date
            }
            if let existingMax = sourceMaxDate[sourceID] {
                if tx.date > existingMax { sourceMaxDate[sourceID] = tx.date }
            } else {
                sourceMaxDate[sourceID] = tx.date
            }

            let label = bundle.sourceLabels[sourceID] ?? sourceID
            var parsedRef: String? = nil
            var matchMerchant: String? = tx.description
            if let rules = compiledLineRules[sourceID] {
                for rule in rules {
                    if let parsed = rule.parse(tx.description) {
                        parsedRef = parsed.reference
                        matchMerchant = parsed.merchant
                        break
                    }
                }
            }
            mappedRows.append(MappedRow(
                transaction: tx,
                sourceID: sourceID,
                sourceLabel: label,
                dayNumber: day,
                parsedReference: parsedRef,
                matchMerchant: matchMerchant
            ))
        }

        for (sourceID, newestDate) in sourceMaxDate {
            if var existing = effectiveCoverage[sourceID] {
                if newestDate > existing.end {
                    existing.end = newestDate
                    effectiveCoverage[sourceID] = existing
                }
            } else {
                effectiveCoverage[sourceID] = CoverageRange(
                    start: sourceMinDate[sourceID] ?? newestDate,
                    end: newestDate
                )
            }
        }

        var (candidates, unmatched) = PendingBuilder.postBundleCandidates(notices: notices, bundle: bundle)
        if notices.contains(where: { $0.kind == .cancellation }) {
            // Keep the reversal pending when the purchase already appears in bank history.
            let beforeCancellation = PendingBuilder.postBundleCandidates(
                notices: notices, bundle: bundle, applyCancellations: false
            ).candidates
            let purchaseIDs = Set(beforeCancellation.filter { $0.notice.kind == .purchase }.map { $0.notice.messageID })
            let confirmed = matchNotices(
                candidates: beforeCancellation, rows: mappedRows, noticeSourceMatches: bundle.noticeSourceMatches
            )
            let confirmedPurchases = Set(confirmed.pairs.map(\.noticeID)).intersection(purchaseIDs)
            if !confirmedPurchases.isEmpty {
                (candidates, unmatched) = PendingBuilder.postBundleCandidates(
                    notices: notices, bundle: bundle, confirmedPurchaseIDs: confirmedPurchases
                )
            }
        }

        // Covered bank rows still reconcile cross-source notices after the bundle advances.
        let matchOutput = matchNotices(
            candidates: candidates, rows: mappedRows, noticeSourceMatches: bundle.noticeSourceMatches
        )
        let matchedNoticeIDs = Set(matchOutput.pairs.map(\.noticeID))
        let candidatesByID = Dictionary(candidates.map { ($0.notice.messageID, $0) }, uniquingKeysWith: { first, _ in first })
        let merchantByTransaction = Dictionary(
            matchOutput.pairs.compactMap { pair -> (String, String)? in
                guard let merchant = candidatesByID[pair.noticeID]?.notice.merchant,
                      !merchant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { return nil }
                return (pair.transactionID, merchant)
            },
            uniquingKeysWith: { first, _ in first }
        )

        let allBankRows = mappedRows.map { row in
            TimelineReconciler.BankRow(
                source: row.sourceLabel,
                date: row.transaction.date,
                amount: row.transaction.amount,
                description: row.transaction.description
            )
        }

        var bankItems: [BudgetItem] = []
        var bankTransactionIDs: [String] = []
        var bankRows: [TimelineReconciler.BankRow] = []
        for row in mappedRows where row.transaction.date > (bundle.coverage[row.sourceID]?.end ?? bundle.asOf) {
            let merchant = merchantByTransaction[row.transaction.id] ?? row.transaction.description
            let (group, category) = categorizer.categorize(
                merchant: merchant,
                amount: row.transaction.amount,
                date: row.transaction.date
            )
            let layer = config.layer(group: group, category: category, layers: bundle.layers)
            bankItems.append(BudgetItem(
                date: row.transaction.date,
                source: row.sourceLabel,
                merchant: merchant,
                amount: row.transaction.amount,
                group: group,
                category: category,
                layer: layer,
                isPending: false
            ))
            bankTransactionIDs.append(row.transaction.id)
            bankRows.append(TimelineReconciler.BankRow(
                source: row.sourceLabel,
                date: row.transaction.date,
                amount: row.transaction.amount,
                description: row.transaction.description
            ))
        }

        let pending = candidates.filter { !matchedNoticeIDs.contains($0.notice.messageID) }
        let pendingItems = pending.map {
            PendingBuilder.makePendingItem(from: $0, bundle: bundle, categorizer: categorizer, config: config)
        }

        return BankLayeringResult(
            bankItems: bankItems,
            bankTransactionIDs: bankTransactionIDs,
            bankRows: bankRows,
            allBankRows: allBankRows,
            pendingItems: pendingItems,
            pendingNoticeIDs: pending.map { $0.notice.messageID },
            unmatched: unmatched,
            matchedPairs: matchOutput.pairs,
            ambiguous: matchOutput.ambiguous,
            effectiveCoverage: effectiveCoverage
        )
    }

    private static func matchNotices(
        candidates: [PendingBuilder.CandidateNotice],
        rows: [MappedRow],
        noticeSourceMatches: [String: [String]]?
    ) -> (pairs: [BankMatchPair], ambiguous: [AmbiguousGroup]) {
        guard !candidates.isEmpty, !rows.isEmpty else { return ([], []) }

        let sortedCandidates = candidates.sorted { $0.notice.messageID < $1.notice.messageID }
        let sortedRows = rows.sorted { $0.transaction.id < $1.transaction.id }
        let rowsByAmount = Dictionary(grouping: sortedRows, by: { $0.transaction.amount })
        let rowByID = Dictionary(sortedRows.map { ($0.transaction.id, $0) }, uniquingKeysWith: { a, _ in a })

        func allowedSources(for noticeSourceID: String) -> Set<String> {
            var set: Set<String> = [noticeSourceID]
            if let extras = noticeSourceMatches?[noticeSourceID] {
                for extra in extras where !extra.isEmpty {
                    set.insert(extra)
                }
            }
            return set
        }

        func referenceAgrees(_ candidate: PendingBuilder.CandidateNotice, _ row: MappedRow) -> Bool {
            guard let noticeRef = candidate.notice.reference?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !noticeRef.isEmpty,
                  let rowRef = row.parsedReference, !rowRef.isEmpty
            else { return false }
            return noticeRef == rowRef
        }

        func merchantAgrees(_ candidate: PendingBuilder.CandidateNotice, _ row: MappedRow) -> Bool {
            guard let rowMerchant = row.matchMerchant else { return false }
            let a = TextFold.key(candidate.notice.merchant ?? "")
            let b = TextFold.key(rowMerchant)
            guard !a.isEmpty, !b.isEmpty else { return false }
            if a.hasPrefix(b) || b.hasPrefix(a) { return true }
            let aPlain = a.replacingOccurrences(of: "-", with: "")
            let bPlain = b.replacingOccurrences(of: "-", with: "")
            guard !aPlain.isEmpty, !bPlain.isEmpty else { return false }
            return aPlain.hasPrefix(bPlain) || bPlain.hasPrefix(aPlain)
        }

        func noticeSignature(_ candidate: PendingBuilder.CandidateNotice) -> String {
            "\(candidate.sourceID)|\(candidate.amount)|\(candidate.day)|\(candidate.notice.reference ?? "")|\(TextFold.key(candidate.notice.merchant ?? ""))"
        }

        func rowSignature(_ row: MappedRow) -> String {
            "\(row.sourceID)|\(row.transaction.amount)|\(row.transaction.date)|\(row.parsedReference ?? "")|\(TextFold.key(row.matchMerchant ?? ""))"
        }

        func makePair(_ candidate: PendingBuilder.CandidateNotice, _ row: MappedRow, _ rule: MatchRule) -> BankMatchPair {
            let offset = row.dayNumber - (JST.dayNumber(candidate.day) ?? 0)
            return BankMatchPair(
                noticeID: candidate.notice.messageID,
                transactionID: row.transaction.id,
                rule: rule,
                referenceAgrees: referenceAgrees(candidate, row),
                merchantAgrees: merchantAgrees(candidate, row),
                dayOffset: offset
            )
        }

        var openRows = Set(sortedRows.map(\.transaction.id))
        var openNotices = sortedCandidates
        var pairs: [BankMatchPair] = []

        func rowCandidates(for candidate: PendingBuilder.CandidateNotice) -> [(row: MappedRow, rank: Rank)] {
            guard let noticeDay = JST.dayNumber(candidate.day) else { return [] }
            let targets = allowedSources(for: candidate.sourceID)
            return (rowsByAmount[candidate.amount] ?? []).compactMap { row in
                guard openRows.contains(row.transaction.id), targets.contains(row.sourceID) else { return nil }
                let offset = row.dayNumber - noticeDay
                guard matchDayOffsets.contains(offset) else { return nil }
                let refMatch = referenceAgrees(candidate, row)
                let merchantMatch = merchantAgrees(candidate, row)
                return (row, Rank(reference: refMatch ? 0 : 1, merchant: merchantMatch ? 0 : 1, distance: offset))
            }
        }

        // 1. Mutual single best, repeated until fixed point (reusing Matcher's algorithm).
        var changed = true
        while changed {
            changed = false
            var bestRows: [String: [String]] = [:]
            var rowBest: [String: (rank: Rank, notices: [String])] = [:]

            for candidate in openNotices {
                let cands = rowCandidates(for: candidate)
                guard let top = cands.map(\.rank).min() else { continue }
                let noticeID = candidate.notice.messageID
                bestRows[noticeID] = cands.filter { $0.rank == top }.map(\.row.transaction.id)
                for c in cands {
                    let rowID = c.row.transaction.id
                    if let current = rowBest[rowID], current.rank < c.rank { continue }
                    if let current = rowBest[rowID], current.rank == c.rank {
                        rowBest[rowID] = (c.rank, current.notices + [noticeID])
                    } else {
                        rowBest[rowID] = (c.rank, [noticeID])
                    }
                }
            }

            var done = Set<String>()
            for candidate in openNotices where !done.contains(candidate.notice.messageID) {
                let noticeID = candidate.notice.messageID
                guard let best = bestRows[noticeID] else { continue }
                if best.count == 1, let rowID = best.first,
                   rowBest[rowID]?.notices == [noticeID],
                   openRows.contains(rowID),
                   let row = rowByID[rowID]
                {
                    pairs.append(makePair(candidate, row, .best))
                    openRows.remove(rowID)
                    done.insert(noticeID)
                    changed = true
                    continue
                }

                // Interchangeable identical notices and identical best rows.
                let bestSet = Set(best)
                let rivals = Set(best.flatMap { rowBest[$0]?.notices ?? [] })
                let group = openNotices.filter { rivals.contains($0.notice.messageID) && !done.contains($0.notice.messageID) }
                let rowsInSet = best.compactMap { openRows.contains($0) ? rowByID[$0] : nil }
                if best.count > 1,
                   rowsInSet.count == best.count,
                   Set(rowsInSet.map(rowSignature)).count == 1,
                   Set(group.map(noticeSignature)).count == 1,
                   group.allSatisfy({ Set(bestRows[$0.notice.messageID] ?? []) == bestSet })
                {
                    for (g, row) in zip(
                        group.sorted { $0.notice.messageID < $1.notice.messageID },
                        rowsInSet.sorted { $0.transaction.id < $1.transaction.id }
                    ) {
                        pairs.append(makePair(g, row, .interchangeable))
                        openRows.remove(row.transaction.id)
                        done.insert(g.notice.messageID)
                    }
                    changed = true
                }
            }

            openNotices = openNotices.filter { !done.contains($0.notice.messageID) }
        }

        // 2. Remaining candidates: interchangeable components pair in order; real ties stay unresolved.
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

        var noticeByID: [String: PendingBuilder.CandidateNotice] = [:]
        for candidate in openNotices {
            let cands = rowCandidates(for: candidate)
            if cands.isEmpty { continue }
            let noticeID = candidate.notice.messageID
            noticeByID[noticeID] = candidate
            parent["n:" + noticeID] = "n:" + noticeID
            for c in cands {
                let rowKey = "r:" + c.row.transaction.id
                parent[rowKey] = parent[rowKey] ?? rowKey
                union("n:" + noticeID, rowKey)
            }
        }

        var groups: [String: (notices: [String], rows: [String])] = [:]
        for key in parent.keys.sorted() {
            let root = find(key)
            let id = String(key.dropFirst(2))
            if key.hasPrefix("n:") {
                groups[root, default: ([], [])].notices.append(id)
            } else {
                groups[root, default: ([], [])].rows.append(id)
            }
        }

        var ambiguous: [AmbiguousGroup] = []
        for root in groups.keys.sorted() {
            guard let g = groups[root] else { continue }
            let ns = g.notices.compactMap { noticeByID[$0] }
            let rs = g.rows.compactMap { rowByID[$0] }
            let sameNotices = Set(ns.map(noticeSignature)).count == 1
            let sameRows = Set(rs.map(rowSignature)).count == 1
            if sameNotices, sameRows {
                for (n, row) in zip(ns, rs) {
                    pairs.append(makePair(n, row, .interchangeable))
                    openRows.remove(row.transaction.id)
                }
            } else {
                ambiguous.append(AmbiguousGroup(noticeIDs: g.notices, rowIDs: g.rows))
                for r in g.rows { openRows.remove(r) }
            }
        }

        pairs.sort { ($0.noticeID, $0.transactionID) < ($1.noticeID, $1.transactionID) }
        return (pairs, ambiguous)
    }
}
