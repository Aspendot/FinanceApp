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
    /// Allowed day offsets (`bankTransaction.date - notice.day`) when notices carry an explicit purchase date.
    public static let matchDayOffsets: ClosedRange<Int> = 0...3
    /// Allowed day offsets for notices lacking a purchase timestamp/date (only email receipt date),
    /// allowing late-night purchases whose email arrives after midnight (`-1` day) to reconcile cleanly.
    public static let receiptOnlyMatchDayOffsets: ClosedRange<Int> = -1...4

    private struct CompiledStatementRule: @unchecked Sendable {
        let regex: NSRegularExpression
        let referenceGroup: Int?
        let merchantGroup: Int?
        let itemSource: String?

        init?(_ rule: StatementLineRule) {
            guard let regex = try? NSRegularExpression(pattern: rule.pattern, options: [.caseInsensitive]) else {
                return nil
            }
            self.regex = regex
            self.referenceGroup = rule.referenceGroup
            self.merchantGroup = rule.merchantGroup
            self.itemSource = rule.itemSource
        }

        func parse(_ text: String) -> (reference: String?, merchant: String?, itemSource: String?)? {
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
            return (capture(referenceGroup), capture(merchantGroup), itemSource)
        }
    }

    private struct MappedRow: Sendable {
        let transaction: BankTransaction
        let sourceID: String
        let sourceLabel: String
        let itemSource: String
        let dayNumber: Int
        /// Approval/reference number extracted by a bundle `StatementLineRule`, if any.
        let parsedReference: String?
        /// Merchant text used for prefix matching: extracted by a matching `StatementLineRule`
        /// (which may be `nil` when the bank line format carries no merchant), or the raw
        /// description when no rule matched.
        let matchMerchant: String?
        /// True when a `StatementLineRule` matched this bank row.
        let matchedStatementRule: Bool
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
            var resolvedItemSource = label
            var matchedRule = false
            if let rules = compiledLineRules[sourceID] {
                for rule in rules {
                    if let parsed = rule.parse(tx.description) {
                        parsedRef = parsed.reference
                        matchMerchant = parsed.merchant
                        if let customSource = parsed.itemSource, !customSource.isEmpty {
                            resolvedItemSource = customSource
                        }
                        matchedRule = true
                        break
                    }
                }
            }
            mappedRows.append(MappedRow(
                transaction: tx,
                sourceID: sourceID,
                sourceLabel: label,
                itemSource: resolvedItemSource,
                dayNumber: day,
                parsedReference: parsedRef,
                matchMerchant: matchMerchant,
                matchedStatementRule: matchedRule
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

        // Snapshot-day intraday tracking: when an AccountBalance exports `asOfRowAmounts`, we know
        // the exact multiset of signed amounts already included in the bundle on that account's `asOf` date,
        // so any later intraday row on `asOf` is emitted into `bankItems` & `bankRows` instead of vanishing.
        var snapshotAmountsBySource: [String: (asOf: String, counts: [Int: Int])] = [:]
        for account in bundle.accountBalances ?? [] {
            guard let amounts = account.asOfRowAmounts else { continue }
            var counts: [Int: Int] = [:]
            for a in amounts { counts[a, default: 0] += 1 }
            snapshotAmountsBySource[account.source] = (account.asOf, counts)
        }

        var (candidates, unmatched) = PendingBuilder.postBundleCandidates(notices: notices, bundle: bundle)

        // Map every bundle item's source label (including `"<Account> bank"` ledger channels and
        // statement-line `itemSource` aliases) to its underlying bank/account sourceID so snapshot
        // and post-cutoff deduplication match real bank rows accurately without colliding across accounts.
        var itemSourceToAccountIDs: [String: Set<String>] = [:]
        var accountAsOfBySource: [String: String] = [:]
        for (srcID, label) in bundle.sourceLabels {
            itemSourceToAccountIDs[srcID, default: []].insert(srcID)
            itemSourceToAccountIDs[label, default: []].insert(srcID)
            itemSourceToAccountIDs["\(label) bank", default: []].insert(srcID)
        }
        for account in bundle.accountBalances ?? [] {
            let bankID = account.source
            accountAsOfBySource[bankID] = account.asOf
            itemSourceToAccountIDs[bankID, default: []].insert(bankID)
            itemSourceToAccountIDs[account.label, default: []].insert(bankID)
            itemSourceToAccountIDs["\(account.label) bank", default: []].insert(bankID)
            if let label = bundle.sourceLabels[bankID] {
                itemSourceToAccountIDs[label, default: []].insert(bankID)
                itemSourceToAccountIDs["\(label) bank", default: []].insert(bankID)
            }
            for debitKey in account.debitNoticeSources ?? [] where !debitKey.isEmpty {
                itemSourceToAccountIDs[debitKey, default: []].insert(bankID)
                if let debitLabel = bundle.sourceLabels[debitKey], !debitLabel.isEmpty {
                    itemSourceToAccountIDs[debitLabel, default: []].insert(bankID)
                }
            }
        }
        for (noticeSrc, bankSrcs) in bundle.noticeSourceMatches ?? [:] {
            for bankID in bankSrcs where !bankID.isEmpty {
                itemSourceToAccountIDs[noticeSrc, default: []].insert(bankID)
                if let label = bundle.sourceLabels[noticeSrc], !label.isEmpty {
                    itemSourceToAccountIDs[label, default: []].insert(bankID)
                }
            }
        }
        for (srcID, rules) in bundle.statementLineRules ?? [:] {
            for rule in rules {
                if let itemSrc = rule.itemSource, !itemSrc.isEmpty {
                    itemSourceToAccountIDs[itemSrc, default: []].insert(srcID)
                }
            }
        }

        // Only confirmed statement/ledger bundle items (never phone manual entries) reflect bank balances.
        let appleSourceLabels: Set<String> = {
            var set: Set<String> = ["apple", "Apple"]
            if let lbl = bundle.sourceLabels["apple"], !lbl.isEmpty { set.insert(lbl) }
            return set
        }()
        func normalizedApprovalRef(_ raw: String?) -> String? {
            guard let raw else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        func extractUnnamedApprovalRef(from merchant: String) -> String? {
            let full = TextFold.key(merchant)
            guard full.contains("nonameyet") else { return nil }
            let base = TextFold.key(PendingBuilder.stripTrailingAnnotation(merchant))
            guard base.count >= 6 else { return nil }
            let suffix = String(base.suffix(6))
            guard suffix.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return suffix
        }

        func refsCompatible(_ rowRef: String?, _ existingRef: String?) -> Bool {
            guard let r = rowRef, !r.isEmpty, let e = existingRef, !e.isEmpty else { return true }
            return r == e
        }

        var bundleMerchantsByAccountDateAmount: [String: [(rawMerchant: String, full: String, base: String, rawBase: String, isAppleSource: Bool, reference: String?)]] = [:]
        for item in bundle.items where item.isManual != true {
            let rawBase = PendingBuilder.stripTrailingAnnotation(item.merchant)
            let full = TextFold.key(item.merchant)
            let base = TextFold.key(rawBase)
            let isApple = appleSourceLabels.contains(item.source)
            let itemRef = normalizedApprovalRef(item.reference) ?? extractUnnamedApprovalRef(from: item.merchant)
            let targets = itemSourceToAccountIDs[item.source] ?? [item.source]
            for accountID in targets {
                bundleMerchantsByAccountDateAmount["\(accountID)|\(item.date)|\(item.amount)", default: []]
                    .append((rawMerchant: item.merchant, full: full, base: base, rawBase: rawBase, isAppleSource: isApple, reference: itemRef))
            }
        }

        func effectiveRowRawMerchant(_ row: MappedRow, resolvedNoticeMerchant: String? = nil) -> String {
            if let resolved = resolvedNoticeMerchant, !resolved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return resolved
            }
            if let m = row.matchMerchant {
                return m
            }
            // A statement line matched by a merchantless rule (e.g. Docomo `"デビット 123456"`) carries no
            // shop name in the bank text itself.
            return row.matchedStatementRule ? "" : row.transaction.description
        }

        func snapshotMerchantMatches(
            rawRow: String,
            rawRowBase: String,
            rowFull: String,
            rowBase: String,
            existing: (rawMerchant: String, full: String, base: String, rawBase: String, isAppleSource: Bool, reference: String?)
        ) -> Bool {
            if PendingBuilder.merchantsMatchForBoundaryDedupe(
                rawA: rawRowBase,
                foldedFullA: rowFull,
                foldedBaseA: rowBase,
                rawB: existing.rawBase,
                foldedFullB: existing.full,
                foldedBaseB: existing.base
            ) {
                return true
            }
            let a = rowBase.isEmpty ? rowFull : rowBase
            let b = existing.base.isEmpty ? existing.full : existing.base
            let aPlain = a.replacingOccurrences(of: "-", with: "")
            let bPlain = b.replacingOccurrences(of: "-", with: "")
            if !aPlain.isEmpty && aPlain == bPlain {
                return true
            }
            // Allow PC-annotated bank rows whose FIRST parenthetical embeds the verbatim bank
            // description after `" · "` (e.g. `"Rent (Dec 2026 lease · <bank text>)"`, handling
            // balanced, unbalanced, padded, full-width `（）`, or unclosed trailing parens, while
            // ignoring any second trailing note such as `"(confirmed · CO)"`). Match strictly
            // against the full folded bank description `rowFull` (never stripped `a`, so
            // `"Transfer Cafe (WEST)"` never collapses onto `"Transfer Cafe"`).
            var normalizedExisting = existing.rawMerchant
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "（", with: " (")
                .replacingOccurrences(of: "）", with: ")")
            while normalizedExisting.contains("  (") {
                normalizedExisting = normalizedExisting.replacingOccurrences(of: "  (", with: " (")
            }
            if let openRange = normalizedExisting.range(of: " (") {
                let rowFullPlain = rowFull.replacingOccurrences(of: "-", with: "")
                let strippedExisting = PendingBuilder.stripTrailingAnnotation(normalizedExisting)
                var firstBody: Substring? = nil
                if strippedExisting != normalizedExisting,
                   normalizedExisting.hasPrefix(strippedExisting) {
                    if strippedExisting.hasSuffix(")"),
                       let baseOpen = strippedExisting.range(of: " (") {
                        let baseEnd = strippedExisting.index(before: strippedExisting.endIndex)
                        if baseOpen.upperBound < baseEnd {
                            firstBody = strippedExisting[baseOpen.upperBound..<baseEnd]
                        }
                    } else {
                        let tailStart = normalizedExisting.index(normalizedExisting.startIndex, offsetBy: strippedExisting.count)
                        let tail = normalizedExisting[tailStart...]
                        var depth = 0
                        var groupStart: String.Index? = nil
                        var idx = tail.startIndex
                        while idx < tail.endIndex {
                            let ch = tail[idx]
                            if ch == "(" {
                                if depth == 0 { groupStart = tail.index(after: idx) }
                                depth += 1
                            } else if ch == ")" {
                                depth -= 1
                                if depth == 0, let start = groupStart {
                                    firstBody = tail[start..<idx]
                                    break
                                }
                            }
                            idx = tail.index(after: idx)
                        }
                    }
                }
                if firstBody == nil || !(firstBody!.contains(" · ")) {
                    let endIdx = normalizedExisting.hasSuffix(")")
                        ? normalizedExisting.index(before: normalizedExisting.endIndex)
                        : normalizedExisting.endIndex
                    if openRange.upperBound < endIdx {
                        firstBody = normalizedExisting[openRange.upperBound..<endIdx]
                    }
                }
                if let body = firstBody, let sepRange = body.range(of: " · ") {
                    let embeddedBankText = body[sepRange.upperBound...]
                    let segKey = TextFold.key(String(embeddedBankText))
                    if !segKey.isEmpty, !rowFull.isEmpty {
                        let segPlain = segKey.replacingOccurrences(of: "-", with: "")
                        if segKey == rowFull || (!rowFullPlain.isEmpty && segPlain == rowFullPlain) {
                            return true
                        }
                    }
                }
            }
            return false
        }

        // Pre-classify snapshot-day (`account.asOf`, even when `account.asOf < coverage.end`) rows BEFORE
        // notice matching so:
        //  - Covered morning rows are excluded from `matchNotices` (never swallowing a partial-feed
        //    same-shop repeat, never tying with an afternoon repeat, and never accepting `-1` overnight matches).
        //  - Genuine intraday post-snapshot rows (including partial-feed rows with a distinct merchant in
        //    any script, such as `"NEW CAFE"` vs `"旧店"`) stay eligible for notice matching, emission into
        //    `bankItems`, and `LiveCashSummary` deduction.
        var coveredSnapshotRowIDs = Set<String>()
        var intradayPostSnapshotTxIDs = Set<String>()
        for (sourceID, snap) in snapshotAmountsBySource {
            let cutoff = bundle.coverage[sourceID]?.end ?? bundle.asOf
            guard snap.asOf <= cutoff else { continue }
            var remainingSnap = snap.counts
            var remainingMerchantsByAmount: [Int: [(rawMerchant: String, full: String, base: String, rawBase: String, isAppleSource: Bool, reference: String?)]] = [:]
            for amt in snap.counts.keys {
                remainingMerchantsByAmount[amt] = bundleMerchantsByAccountDateAmount["\(sourceID)|\(snap.asOf)|\(amt)"] ?? []
            }
            let sameDay = mappedRows.filter { $0.sourceID == sourceID && $0.transaction.date == snap.asOf }

            // Pass 1a: claim rows whose 6-digit approval reference matches a bundle item's reference
            // (works for both unnamed placeholders and merchant-enriched debit items).
            for row in sameDay {
                let amt = row.transaction.amount
                guard let rem = remainingSnap[amt], rem > 0,
                      var pool = remainingMerchantsByAmount[amt], !pool.isEmpty,
                      let rowRef = normalizedApprovalRef(row.parsedReference),
                      let refIdx = pool.firstIndex(where: { $0.reference == rowRef })
                else { continue }
                pool.remove(at: refIdx)
                remainingMerchantsByAmount[amt] = pool
                remainingSnap[amt] = rem - 1
                coveredSnapshotRowIDs.insert(row.transaction.id)
            }

            // Pass 1b: claim rows whose merchant strictly matches a ref-compatible bundle item.
            for row in sameDay where !coveredSnapshotRowIDs.contains(row.transaction.id) {
                let amt = row.transaction.amount
                guard let rem = remainingSnap[amt], rem > 0,
                      var pool = remainingMerchantsByAmount[amt], !pool.isEmpty else { continue }
                let rowRef = normalizedApprovalRef(row.parsedReference)
                let rawRow = effectiveRowRawMerchant(row)
                let rawRowBase = PendingBuilder.stripTrailingAnnotation(rawRow)
                let rowFull = TextFold.key(rawRow)
                let rowBase = TextFold.key(rawRowBase)
                guard !rowFull.isEmpty else { continue }
                if let matchIdx = pool.firstIndex(where: { existing in
                    refsCompatible(rowRef, existing.reference) && snapshotMerchantMatches(
                        rawRow: rawRow,
                        rawRowBase: rawRowBase,
                        rowFull: rowFull,
                        rowBase: rowBase,
                        existing: existing
                    )
                }) {
                    pool.remove(at: matchIdx)
                    remainingMerchantsByAmount[amt] = pool
                    remainingSnap[amt] = rem - 1
                    coveredSnapshotRowIDs.insert(row.transaction.id)
                }
            }

            // Pass 2: claim only genuinely unattributed slots — excluded/hidden bank rows not exported
            // into `bundle.items` (`pool.isEmpty`), merchantless bank lines (`rowFull.isEmpty`, e.g. Docomo
            // `"デビット 123456"`) whose approval ref does not conflict with an existing item's ref,
            // empty-merchant bundle items, or generic Apple bank lines (`APPLE.CO`) replaced by an
            // itemized `"Apple"` entry. Distinct non-empty merchants or distinct approval refs never collapse.
            for row in sameDay where !coveredSnapshotRowIDs.contains(row.transaction.id) {
                let amt = row.transaction.amount
                guard let rem = remainingSnap[amt], rem > 0 else { continue }
                let rawRow = effectiveRowRawMerchant(row)
                let rowFull = TextFold.key(rawRow)
                let rowRef = normalizedApprovalRef(row.parsedReference)
                var pool = remainingMerchantsByAmount[amt] ?? []
                if pool.isEmpty {
                    remainingSnap[amt] = rem - 1
                    coveredSnapshotRowIDs.insert(row.transaction.id)
                } else if rowFull.isEmpty {
                    if let compatIdx = pool.firstIndex(where: { refsCompatible(rowRef, $0.reference) }) {
                        pool.remove(at: compatIdx)
                        remainingMerchantsByAmount[amt] = pool
                        remainingSnap[amt] = rem - 1
                        coveredSnapshotRowIDs.insert(row.transaction.id)
                    }
                } else {
                    let rowIsApple = PendingBuilder.isAppleBillingDescriptor(rawRow)
                    if let compatIdx = pool.firstIndex(where: { existing in
                        refsCompatible(rowRef, existing.reference)
                            && (existing.full.isEmpty || (rowIsApple && existing.isAppleSource))
                    }) {
                        pool.remove(at: compatIdx)
                        remainingMerchantsByAmount[amt] = pool
                        remainingSnap[amt] = rem - 1
                        coveredSnapshotRowIDs.insert(row.transaction.id)
                    }
                }
            }

            for row in sameDay where !coveredSnapshotRowIDs.contains(row.transaction.id) {
                intradayPostSnapshotTxIDs.insert(row.transaction.id)
            }
        }

        let matchableRows = coveredSnapshotRowIDs.isEmpty
            ? mappedRows
            : mappedRows.filter { !coveredSnapshotRowIDs.contains($0.transaction.id) }

        // Only strictly post-cutoff rows and genuinely new intraday post-snapshot rows may match at offset `-1`.
        var negativeOffsetEligibleRowIDs = Set<String>()
        for row in matchableRows {
            let cutoff = bundle.coverage[row.sourceID]?.end ?? bundle.asOf
            if row.transaction.date > cutoff || intradayPostSnapshotTxIDs.contains(row.transaction.id) {
                negativeOffsetEligibleRowIDs.insert(row.transaction.id)
            }
        }

        if notices.contains(where: { $0.kind == .cancellation }) {
            // Keep the reversal pending when the purchase already appears in bank history.
            let beforeCancellation = PendingBuilder.postBundleCandidates(
                notices: notices, bundle: bundle, applyCancellations: false
            ).candidates
            let purchaseIDs = Set(beforeCancellation.filter { $0.notice.kind == .purchase }.map { $0.notice.messageID })
            let confirmed = matchNotices(
                candidates: beforeCancellation,
                rows: matchableRows,
                noticeSourceMatches: bundle.noticeSourceMatches,
                negativeOffsetEligibleRowIDs: negativeOffsetEligibleRowIDs
            )
            let confirmedPurchases = Set(confirmed.pairs.map(\.noticeID)).intersection(purchaseIDs)
            if !confirmedPurchases.isEmpty {
                (candidates, unmatched) = PendingBuilder.postBundleCandidates(
                    notices: notices, bundle: bundle, confirmedPurchaseIDs: confirmedPurchases
                )
            }
        }

        // Covered bank rows (except snapshot-covered cutoff rows) still reconcile cross-source notices.
        let matchOutput = matchNotices(
            candidates: candidates,
            rows: matchableRows,
            noticeSourceMatches: bundle.noticeSourceMatches,
            negativeOffsetEligibleRowIDs: negativeOffsetEligibleRowIDs
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

        // Detect any post-cutoff row that is ALREADY present as a confirmed row in `bundle.items` so
        // `bankItems` never emits a duplicate ledger entry. Cash balance adjustments in `LiveCashSummary`
        // strictly follow `AccountBalance.asOf` (never suppressing valid post-`asOf` bank rows).
        var postCutoffBundlePool = bundleMerchantsByAccountDateAmount
        var alreadyCoveredPostCutoffIDs = Set<String>()
        let candidatePreBakedRows = mappedRows.filter { row in
            let cutoff = bundle.coverage[row.sourceID]?.end ?? bundle.asOf
            return row.transaction.date > cutoff
        }
        // Pass A1: exact approval-reference match (both named and unnamed debits).
        for row in candidatePreBakedRows {
            let key = "\(row.sourceID)|\(row.transaction.date)|\(row.transaction.amount)"
            guard var pool = postCutoffBundlePool[key], !pool.isEmpty,
                  let ref = normalizedApprovalRef(row.parsedReference),
                  let refIdx = pool.firstIndex(where: { $0.reference == ref })
            else { continue }
            pool.remove(at: refIdx)
            postCutoffBundlePool[key] = pool
            alreadyCoveredPostCutoffIDs.insert(row.transaction.id)
        }
        // Pass A2: strict merchant match on ref-compatible bundle items.
        for row in candidatePreBakedRows where !alreadyCoveredPostCutoffIDs.contains(row.transaction.id) {
            let key = "\(row.sourceID)|\(row.transaction.date)|\(row.transaction.amount)"
            guard var pool = postCutoffBundlePool[key], !pool.isEmpty else { continue }
            let rowRef = normalizedApprovalRef(row.parsedReference)
            let rawRow = effectiveRowRawMerchant(row, resolvedNoticeMerchant: merchantByTransaction[row.transaction.id])
            let rawRowBase = PendingBuilder.stripTrailingAnnotation(rawRow)
            let rowFull = TextFold.key(rawRow)
            let rowBase = TextFold.key(rawRowBase)
            guard !rowFull.isEmpty else { continue }
            if let hitIdx = pool.firstIndex(where: { existing in
                refsCompatible(rowRef, existing.reference) && PendingBuilder.merchantsMatchForBoundaryDedupe(
                    rawA: rawRowBase,
                    foldedFullA: rowFull,
                    foldedBaseA: rowBase,
                    rawB: existing.rawBase,
                    foldedFullB: existing.full,
                    foldedBaseB: existing.base
                )
            }) {
                pool.remove(at: hitIdx)
                postCutoffBundlePool[key] = pool
                alreadyCoveredPostCutoffIDs.insert(row.transaction.id)
            }
        }
        // Pass B: fallback for merchantless bank rows (e.g. Docomo `"デビット 123456"` with no paired notice)
        // whose approval ref does not conflict with an existing item's ref, or empty-merchant bundle rows.
        for row in candidatePreBakedRows where !alreadyCoveredPostCutoffIDs.contains(row.transaction.id) {
            let key = "\(row.sourceID)|\(row.transaction.date)|\(row.transaction.amount)"
            guard var pool = postCutoffBundlePool[key], !pool.isEmpty else { continue }
            let rawRow = effectiveRowRawMerchant(row, resolvedNoticeMerchant: merchantByTransaction[row.transaction.id])
            let rowFull = TextFold.key(rawRow)
            let rowRef = normalizedApprovalRef(row.parsedReference)
            if let hitIdx = pool.firstIndex(where: { existing in
                refsCompatible(rowRef, existing.reference) && (rowFull.isEmpty || existing.full.isEmpty)
            }) {
                pool.remove(at: hitIdx)
                postCutoffBundlePool[key] = pool
                alreadyCoveredPostCutoffIDs.insert(row.transaction.id)
            }
        }

        let allBankRows = mappedRows.map { row in
            TimelineReconciler.BankRow(
                source: row.sourceLabel,
                date: row.transaction.date,
                amount: row.transaction.amount,
                description: row.transaction.description,
                isPostSnapshotIntraday: intradayPostSnapshotTxIDs.contains(row.transaction.id),
                resolvedMerchant: merchantByTransaction[row.transaction.id]
            )
        }

        var bankItems: [BudgetItem] = []
        var bankTransactionIDs: [String] = []
        var bankRows: [TimelineReconciler.BankRow] = []
        for row in mappedRows {
            let cutoff = bundle.coverage[row.sourceID]?.end ?? bundle.asOf
            let isPostCutoff = row.transaction.date > cutoff && !alreadyCoveredPostCutoffIDs.contains(row.transaction.id)
            let isIntradayNew = intradayPostSnapshotTxIDs.contains(row.transaction.id)
            guard isPostCutoff || isIntradayNew else { continue }

            let fallbackMerchant = (row.matchedStatementRule ? row.matchMerchant : nil) ?? row.transaction.description
            let merchant = merchantByTransaction[row.transaction.id] ?? fallbackMerchant
            let (group, category) = categorizer.categorize(
                merchant: merchant,
                amount: row.transaction.amount,
                date: row.transaction.date
            )
            let layer = config.layer(group: group, category: category, layers: bundle.layers)
            bankItems.append(BudgetItem(
                date: row.transaction.date,
                source: row.itemSource,
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
                description: row.transaction.description,
                isPostSnapshotIntraday: isIntradayNew,
                resolvedMerchant: merchantByTransaction[row.transaction.id]
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

    /// Returns the Japan-time hour (0...23) from an ISO-8601 timestamp (`+09:00`, `Z`, or `±HH:MM`).
    private static func jstHour(from isoTimestamp: String) -> Int? {
        guard let tIndex = isoTimestamp.firstIndex(of: "T") else { return nil }
        let afterT = String(isoTimestamp[isoTimestamp.index(after: tIndex)...])
        let timeChars = afterT.prefix(8)
        let hm = timeChars.split(separator: ":")
        guard hm.count >= 2, let rawHour = Int(hm[0]), let rawMin = Int(hm[1]),
              (0...23).contains(rawHour), (0...59).contains(rawMin)
        else { return nil }
        let rest = afterT.dropFirst(min(8, afterT.count))
        var offsetMinutes = 9 * 60
        if rest.contains("Z") || rest.contains("z") {
            offsetMinutes = 0
        } else if let signIdx = rest.firstIndex(where: { $0 == "+" || $0 == "-" }) {
            let sign = rest[signIdx] == "-" ? -1 : 1
            let tzParts = rest[rest.index(after: signIdx)...].split(separator: ":")
            if let tzH = tzParts.first.flatMap({ Int($0.prefix(2)) }) {
                let tzM = tzParts.count >= 2 ? (Int(tzParts[1].prefix(2)) ?? 0) : 0
                offsetMinutes = sign * (tzH * 60 + tzM)
            }
        }
        let totalJSTMinutes = rawHour * 60 + rawMin + (9 * 60 - offsetMinutes)
        let normalized = ((totalJSTMinutes % 1440) + 1440) % 1440
        return normalized / 60
    }

    private static func matchNotices(
        candidates: [PendingBuilder.CandidateNotice],
        rows: [MappedRow],
        noticeSourceMatches: [String: [String]]?,
        negativeOffsetEligibleRowIDs: Set<String>
    ) -> (pairs: [BankMatchPair], ambiguous: [AmbiguousGroup]) {
        guard !candidates.isEmpty, !rows.isEmpty else { return ([], []) }

        let sortedCandidates = candidates.sorted { $0.notice.messageID < $1.notice.messageID }
        let sortedRows = rows.sorted { $0.transaction.id < $1.transaction.id }
        let rowsByAmount = Dictionary(grouping: sortedRows, by: { $0.transaction.amount })
        let rowByID = Dictionary(sortedRows.map { ($0.transaction.id, $0) }, uniquingKeysWith: { a, _ in a })

        func allowedSources(for candidate: PendingBuilder.CandidateNotice) -> Set<String> {
            var set: Set<String> = [candidate.sourceID]
            if let extras = noticeSourceMatches?[candidate.sourceID] {
                for extra in extras where !extra.isEmpty {
                    set.insert(extra)
                }
            }
            if let funding = candidate.fundingSourceID, !funding.isEmpty {
                set.insert(funding)
                if let fundingExtras = noticeSourceMatches?[funding] {
                    for extra in fundingExtras where !extra.isEmpty {
                        set.insert(extra)
                    }
                }
            }
            return set
        }

        func referenceConflict(_ candidate: PendingBuilder.CandidateNotice, _ row: MappedRow) -> Bool {
            // Apple receipts store an Apple Order ID while bank debit lines store a 6-digit VISA
            // approval number; those namespaces are unrelated and must never conflict.
            if candidate.sourceID == "apple" { return false }
            guard let noticeRef = candidate.notice.reference?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !noticeRef.isEmpty,
                  let rowRef = row.parsedReference, !rowRef.isEmpty
            else { return false }
            return noticeRef != rowRef
        }

        func referenceAgrees(_ candidate: PendingBuilder.CandidateNotice, _ row: MappedRow) -> Bool {
            if candidate.sourceID == "apple" { return false }
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
            if candidate.sourceID == "apple" && PendingBuilder.isAppleBillingDescriptor(rowMerchant) {
                return true
            }
            guard !a.isEmpty, !b.isEmpty else { return false }
            if a.hasPrefix(b) || b.hasPrefix(a) { return true }
            let aPlain = a.replacingOccurrences(of: "-", with: "")
            let bPlain = b.replacingOccurrences(of: "-", with: "")
            guard !aPlain.isEmpty, !bPlain.isEmpty else { return false }
            return aPlain.hasPrefix(bPlain) || bPlain.hasPrefix(aPlain)
        }

        func merchantClearlyConflicts(_ candidate: PendingBuilder.CandidateNotice, _ row: MappedRow) -> Bool {
            guard candidate.sourceID != "apple",
                  row.matchedStatementRule,
                  !referenceAgrees(candidate, row),
                  let rowMerchant = row.matchMerchant
            else { return false }
            let a = TextFold.key(candidate.notice.merchant ?? "")
            let b = TextFold.key(rowMerchant)
            guard !a.isEmpty, !b.isEmpty, !merchantAgrees(candidate, row) else { return false }
            let aHasASCII = a.contains { $0.isASCII && $0.isLetter }
            let bHasASCII = b.contains { $0.isASCII && $0.isLetter }
            let aHasNonASCII = a.contains { !$0.isASCII }
            let bHasNonASCII = b.contains { !$0.isASCII }
            let bothPureASCII = aHasASCII && !aHasNonASCII && bHasASCII && !bHasNonASCII
            let bothNonASCII = aHasNonASCII && bHasNonASCII
            return bothPureASCII || bothNonASCII
        }

        func nonEmptyRef(_ raw: String?) -> String? {
            guard let t = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
            return t
        }

        func areInterchangeableGroup(_ ns: [PendingBuilder.CandidateNotice], _ rs: [MappedRow]) -> Bool {
            guard !ns.isEmpty, !rs.isEmpty else { return false }
            // Only distinguish items by reference when BOTH sides carry references in the same namespace
            // (so MUFG bank approval numbers without notice refs, or Merpay tx IDs without bank refs,
            // never turn identical same-day purchases into double-counted ambiguous ties).
            let comparableRefs = ns.allSatisfy { nonEmptyRef($0.notice.reference) != nil && $0.sourceID != "apple" }
                && rs.allSatisfy { nonEmptyRef($0.parsedReference) != nil }

            func nSig(_ candidate: PendingBuilder.CandidateNotice) -> String {
                let refPart = comparableRefs ? (nonEmptyRef(candidate.notice.reference) ?? "") : ""
                if candidate.sourceID == "apple" || PendingBuilder.isAppleBillingDescriptor(candidate.notice.merchant ?? "") {
                    return "apple_billing|\(candidate.amount)|\(candidate.day)|\(refPart)"
                }
                return "\(candidate.sourceID)|\(candidate.amount)|\(candidate.day)|\(refPart)|\(TextFold.key(candidate.notice.merchant ?? ""))"
            }

            func rSig(_ row: MappedRow) -> String {
                let refPart = comparableRefs ? (nonEmptyRef(row.parsedReference) ?? "") : ""
                return "\(row.sourceID)|\(row.transaction.amount)|\(row.transaction.date)|\(refPart)|\(TextFold.key(row.matchMerchant ?? ""))"
            }

            return Set(ns.map(nSig)).count == 1 && Set(rs.map(rSig)).count == 1
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
            let targets = allowedSources(for: candidate)
            let isReceiptDateOnly = candidate.notice.occurredAt == nil && candidate.notice.occurredOn == nil
            let allowedRange = isReceiptDateOnly ? receiptOnlyMatchDayOffsets : matchDayOffsets

            var amountBuckets = rowsByAmount[candidate.amount] ?? []
            if let parts = candidate.notice.parts, !parts.isEmpty {
                let creditSlice = (parts["credit"] ?? 0) + (parts["deferred"] ?? 0)
                if creditSlice > 0 && creditSlice != candidate.amount, let extra = rowsByAmount[creditSlice] {
                    amountBuckets.append(contentsOf: extra)
                }
            }

            return amountBuckets.compactMap { row in
                guard openRows.contains(row.transaction.id), targets.contains(row.sourceID) else { return nil }
                if referenceConflict(candidate, row) { return nil }
                // Apple receipts only reconcile against recognized Apple billing descriptors (never "PINEAPPLE CAFE").
                if candidate.sourceID == "apple" {
                    guard PendingBuilder.isAppleBillingDescriptor(row.matchMerchant ?? row.transaction.description) else { return nil }
                }
                // Do not reconcile a statement-parsed bank line against a notice with a clearly different same-script merchant.
                if merchantClearlyConflicts(candidate, row) { return nil }
                let offset = row.dayNumber - noticeDay
                guard allowedRange.contains(offset) else { return nil }
                // Allow the `-1` day offset for email-only notices (which can arrive overnight at 00:03
                // or in a next-morning batch around 09:02 JST) strictly against post-bundle/intraday bank
                // rows, never against already-covered pre-cutoff rows.
                if offset < 0 {
                    guard isReceiptDateOnly, negativeOffsetEligibleRowIDs.contains(row.transaction.id) else {
                        return nil
                    }
                }
                let refMatch = referenceAgrees(candidate, row)
                let merchantMatch = merchantAgrees(candidate, row)
                return (row, Rank(reference: refMatch ? 0 : 1, merchant: merchantMatch ? 0 : 1, distance: abs(offset)))
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
                   areInterchangeableGroup(group, rowsInSet),
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
            if areInterchangeableGroup(ns, rs) {
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
