import Foundation

/// Reconciles open timeline entries against confirmed post-coverage Money Forward bank rows
/// and rolls the active pay cycle forward when the next payday salary arrives.
public enum TimelineReconciler {
    /// One confirmed bank row after bundle coverage, preserving the bank's own description text.
    public struct BankRow: Sendable, Equatable, Hashable {
        /// Bundle source label (value from `DataBundle.sourceLabels`, e.g. `"MUFG"`).
        public var source: String
        /// Transaction date in `"YYYY-MM-DD"` format.
        public var date: String
        /// Signed whole yen; positive is money out, negative is money in.
        public var amount: Int
        /// Bank's verbatim line description (before any matched notice overrides display merchant).
        public var description: String
        /// True when `BankLayering` confirmed this row is a genuinely new intraday transaction on the
        /// account's `asOf` snapshot day (not already reflected in `AccountBalance.asOfRowAmounts`).
        public var isPostSnapshotIntraday: Bool
        /// Optional specific merchant resolved from a matched email receipt (e.g. an Apple app/sub name
        /// paired to a generic `APPLE.CO` bank line), preventing unrelated purchases from clearing bills.
        public var resolvedMerchant: String?
        /// True when a pending debit notice carries only a generic billing aggregator descriptor
        /// (e.g. `APPLE.COM/BILL`) with no paired item receipt yet.
        public var isUnattributedAggregator: Bool

        public init(
            source: String,
            date: String,
            amount: Int,
            description: String,
            isPostSnapshotIntraday: Bool = false,
            resolvedMerchant: String? = nil,
            isUnattributedAggregator: Bool = false
        ) {
            self.source = source
            self.date = date
            self.amount = amount
            self.description = description
            self.isPostSnapshotIntraday = isPostSnapshotIntraday
            self.resolvedMerchant = resolvedMerchant
            self.isUnattributedAggregator = isUnattributedAggregator
        }
    }

    private static let genericServiceWords: Set<String> = [
        "apple", "via", "debit", "card", "bank", "mufg", "merpay", "yearly", "monthly",
        "bill", "sub", "subscription", "renewal", "service", "app", "store", "pro", "plus", "premium",
    ]
    private static let serviceTokenSeparators = CharacterSet(charactersIn: " /・+()（）「」『』,、:：-–—·•　")

    private static func isGenericAppleBillingPattern(_ pattern: String, regex: NSRegularExpression) -> Bool {
        let lower = pattern.lowercased()
        guard lower.contains("apple") || lower.contains("icloud") || lower.contains("itunes") else { return false }
        for probe in ["APPLE.CO", "APPLE.COM/BILL", "Appleサービス", "iCloud", "iCloud+", "ITUNES.COM/BILL"] {
            let range = NSRange(probe.startIndex..<probe.endIndex, in: probe)
            if regex.firstMatch(in: probe, options: [], range: range) != nil {
                return true
            }
        }
        return false
    }

    private static func isGenericAppleDescriptor(_ text: String) -> Bool {
        let folded = TextFold.key(text)
        guard !folded.isEmpty else { return true }
        let genericForms: Set<String> = [
            "apple", "apple.co", "apple.com", "apple.com/bill", "applebill", "applecombill", "apple.co.jp",
            "appleサ-ビス", "アツプル", "itunes", "itunes.com/bill",
        ]
        if genericForms.contains(folded) { return true }
        return folded.contains("apple.com/bill")
            || folded.hasSuffix("apple.co")
            || folded.hasSuffix("apple.com")
            || folded.hasSuffix("applebill")
            || folded.hasSuffix("applecombill")
    }

    private static func asciiWords(in text: String) -> Set<String> {
        let normalized = text.precomposedStringWithCompatibilityMapping.lowercased()
        var words = Set<String>()
        var current = ""
        for scalar in normalized.unicodeScalars {
            if (scalar.value >= 0x61 && scalar.value <= 0x7A) || (scalar.value >= 0x30 && scalar.value <= 0x39) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                words.insert(current)
                current = ""
            }
        }
        if !current.isEmpty { words.insert(current) }
        return words
    }

    private static func containsServiceToken(_ token: String, in haystack: String, rawWords: Set<String>) -> Bool {
        guard token.allSatisfy(\.isASCII) else {
            return haystack.contains(token)
        }
        if token.count <= 4 {
            if rawWords.contains(token) { return true }
        } else {
            if rawWords.contains(where: { $0.hasPrefix(token) }) { return true }
        }
        let requireRightBoundary = token.count <= 4
        var searchStart = haystack.startIndex
        while searchStart < haystack.endIndex,
              let range = haystack.range(of: token, range: searchStart..<haystack.endIndex)
        {
            let leftOK = range.lowerBound == haystack.startIndex
                || !(haystack[haystack.index(before: range.lowerBound)].isASCII && haystack[haystack.index(before: range.lowerBound)].isLetter)
            let rightOK = !requireRightBoundary
                || range.upperBound == haystack.endIndex
                || !(haystack[range.upperBound].isASCII && haystack[range.upperBound].isLetter)
            if leftOK && rightOK { return true }
            searchStart = haystack.index(after: range.lowerBound)
        }
        return false
    }

    private static func appleReceiptMatchesEntryService(merchant: String, entry: TimelineEntry) -> Bool {
        let foldedMerchant = TextFold.key(merchant)
        guard !foldedMerchant.isEmpty, !isGenericAppleDescriptor(merchant) else { return false }
        let merchantWords = asciiWords(in: merchant)
        let baseName = entry.item.split(separator: "(").first.map(String.init) ?? entry.item
        let foldedBase = TextFold.key(baseName)
        let baseWords = asciiWords(in: baseName)
        if foldedBase.count >= 3 && (
            containsServiceToken(foldedBase, in: foldedMerchant, rawWords: merchantWords)
                || containsServiceToken(foldedMerchant, in: foldedBase, rawWords: baseWords)
        ) {
            return true
        }
        for raw in entry.item.components(separatedBy: serviceTokenSeparators) {
            let token = TextFold.key(raw)
            let minLen = token.allSatisfy(\.isASCII) ? 3 : 2
            guard token.count >= minLen, !genericServiceWords.contains(token), !token.allSatisfy(\.isNumber) else {
                continue
            }
            if containsServiceToken(token, in: foldedMerchant, rawWords: merchantWords)
                || containsServiceToken(foldedMerchant, in: token, rawWords: asciiWords(in: raw))
            {
                return true
            }
        }
        return false
    }

    private struct ParsedRow {
        let index: Int
        let row: BankRow
        let dayNumber: Int
    }

    private struct CandidatePair {
        let entryIndex: Int
        let rowIndex: Int
        let distance: Int
        let rowDay: Int
        let entryDay: Int
    }

    /// Matches open (or phone-checked) timeline entries carrying a `TimelineMatch` against `bankRows`,
    /// returning the updated timeline together with the indices of `bankRows` consumed during matching.
    ///
    /// Each bank row is used at most once. When entries or rows compete, the nearest date
    /// distance wins, breaking ties by earliest row date then earliest entry date.
    /// Invalid regexes or malformed rules are skipped without failing.
    ///
    /// If the entry marked `next == true` becomes done during reconciliation, its `next` flag
    /// is cleared and `next = true` is set on the following `payday == true` entry.
    public static func reconcileWithMetadata(
        timeline: [TimelineEntry],
        bankRows: [BankRow]
    ) -> (timeline: [TimelineEntry], usedRowIndices: Set<Int>) {
        guard !timeline.isEmpty, !bankRows.isEmpty else {
            return (timeline, [])
        }
        guard timeline.contains(where: { ($0.done != true || $0.phoneChecked == true) && $0.match != nil }) else {
            return (timeline, [])
        }

        var rowsBySource: [String: [ParsedRow]] = [:]
        for (index, row) in bankRows.enumerated() {
            guard let day = JST.dayNumber(row.date) else { continue }
            rowsBySource[row.source, default: []].append(ParsedRow(index: index, row: row, dayNumber: day))
        }
        guard !rowsBySource.isEmpty else {
            return (timeline, [])
        }

        var candidates: [CandidatePair] = []
        for (entryIndex, entry) in timeline.enumerated() {
            guard (entry.done != true || entry.phoneChecked == true),
                  entry.event != true,
                  let match = entry.match,
                  !match.pattern.isEmpty,
                  match.window.count == 2,
                  let entryDay = JST.dayNumber(entry.date),
                  let sourceRows = rowsBySource[match.source]
            else { continue }

            let minOffset = match.window[0]
            let maxOffset = match.window[1]
            guard minOffset <= maxOffset else { continue }

            let expectOut: Bool
            switch match.dir.lowercased() {
            case "out":
                expectOut = true
            case "in":
                expectOut = false
            default:
                continue
            }

            guard let regex = try? NSRegularExpression(pattern: match.pattern, options: [.caseInsensitive]) else {
                continue
            }
            let genericAppleRule = isGenericAppleBillingPattern(match.pattern, regex: regex)

            for parsed in sourceRows {
                if expectOut {
                    guard parsed.row.amount > 0 else { continue }
                } else {
                    guard parsed.row.amount < 0 else { continue }
                }

                let magnitude = abs(parsed.row.amount)
                if let minAmount = match.minAmount, magnitude < minAmount { continue }
                if let maxAmount = match.maxAmount, magnitude > maxAmount { continue }

                let offset = parsed.dayNumber - entryDay
                guard offset >= minOffset && offset <= maxOffset else { continue }

                let text = parsed.row.description
                let range = NSRange(text.startIndex..<text.endIndex, in: text)
                guard regex.firstMatch(in: text, options: [], range: range) != nil else { continue }

                if genericAppleRule {
                    guard PendingBuilder.isAppleBillingDescriptor(text) else {
                        continue
                    }
                    if parsed.row.isUnattributedAggregator {
                        continue
                    }
                    if let resolved = parsed.row.resolvedMerchant?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !resolved.isEmpty,
                       !isGenericAppleDescriptor(resolved),
                       !appleReceiptMatchesEntryService(merchant: resolved, entry: entry)
                    {
                        continue
                    }
                }

                candidates.append(CandidatePair(
                    entryIndex: entryIndex,
                    rowIndex: parsed.index,
                    distance: abs(offset),
                    rowDay: parsed.dayNumber,
                    entryDay: entryDay
                ))
            }
        }

        guard !candidates.isEmpty else {
            return (timeline, [])
        }

        candidates.sort { a, b in
            (a.distance, a.rowDay, a.entryDay, a.entryIndex, a.rowIndex)
                < (b.distance, b.rowDay, b.entryDay, b.entryIndex, b.rowIndex)
        }

        var result = timeline
        var matchedEntries = Set<Int>()
        var usedRows = Set<Int>()

        for pair in candidates {
            guard !matchedEntries.contains(pair.entryIndex),
                  !usedRows.contains(pair.rowIndex)
            else { continue }

            matchedEntries.insert(pair.entryIndex)
            usedRows.insert(pair.rowIndex)

            let row = bankRows[pair.rowIndex]
            result[pair.entryIndex].done = true
            result[pair.entryIndex].phoneChecked = nil
            result[pair.entryIndex].date = row.date
            if result[pair.entryIndex].cardBilled == true {
                result[pair.entryIndex].billedAmount = abs(row.amount)
            } else {
                result[pair.entryIndex].amount = row.amount
            }
            result[pair.entryIndex].estimate = nil
        }

        // Cycle roll: move `next` to the following payday entry when the current `next` becomes done.
        var newCycleStart: String?
        while let currentIdx = result.firstIndex(where: { $0.next == true }),
              matchedEntries.contains(currentIdx)
        {
            let originalDate = timeline[currentIdx].date
            let updatedDate = result[currentIdx].date
            result[currentIdx].next = nil
            newCycleStart = updatedDate

            let following = result.indices
                .filter { idx in
                    idx != currentIdx
                        && result[idx].payday == true
                        && result[idx].date > updatedDate
                        && timeline[idx].date > originalDate
                }
                .min { (result[$0].date, $0) < (result[$1].date, $1) }

            if let nextIdx = following {
                result[nextIdx].next = true
            } else {
                break
            }
        }

        // After a roll the finished cycle's settled entries and prior inflows no longer belong to the new cycle.
        // Unpaid overdue bills and bank-matched phone-checked holds stay visible; manual checkoffs without a
        // bank match rule expire at rollover so they never hold cash indefinitely.
        if let start = newCycleStart {
            let filtered = result.filter { entry in
                entry.date >= start
                    || (entry.amount > 0 && entry.event != true && entry.borrowed != true && entry.cardBilled != true
                        && (entry.done != true || (entry.phoneChecked == true && entry.match != nil)))
            }
            return (filtered, usedRows)
        }
        return (result, usedRows)
    }

    public static func reconcile(
        timeline: [TimelineEntry],
        bankRows: [BankRow]
    ) -> [TimelineEntry] {
        reconcileWithMetadata(timeline: timeline, bankRows: bankRows).timeline
    }

    /// Reconciles remaining open non-payday outflow entries against unsettled debit or card notices,
    /// mapping debit card notice sources to their linked bank's label via `accountBalances`.
    ///
    /// This prevents double-counting during the 1-3 day gap when a debit email has already reduced
    /// `LiveCashSummary.estimatedBankCash` before Money Forward posts the settled bank row, and
    /// marks card-billed subscription renewals as charged as soon as their card notice arrives.
    public static func reconcilePendingNotices(
        timeline: [TimelineEntry],
        pendingItems: [BudgetItem],
        accountBalances: [AccountBalance],
        sourceLabels: [String: String]
    ) -> [TimelineEntry] {
        guard !timeline.isEmpty, !pendingItems.isEmpty else { return timeline }
        guard timeline.contains(where: { ($0.done != true || $0.phoneChecked == true) && $0.payday != true && $0.match != nil }) else {
            return timeline
        }

        var debitLabelToBank: [String: (bankLabel: String, asOf: String)] = [:]
        for account in accountBalances {
            let bankLabel = sourceLabels[account.source] ?? account.label
            for debitKey in account.debitNoticeSources ?? [] where !debitKey.isEmpty {
                debitLabelToBank[debitKey] = (bankLabel, account.asOf)
                if let label = sourceLabels[debitKey], !label.isEmpty {
                    debitLabelToBank[label] = (bankLabel, account.asOf)
                }
            }
        }

        // Open Apple-billed timeline entries require service-identity agreement when reconciling from
        // pending notices, so neither an unrelated Apple purchase receipt nor an unattributed generic
        // APPLE.COM/BILL debit notice can falsely clear a scheduled subscription.
        var regularRows: [BankRow] = []
        var appleItems: [(item: BudgetItem, bankLabel: String)] = []
        for item in pendingItems {
            guard item.isPending, item.amount > 0 else { continue }
            let rawSource = item.fundingSource ?? item.source
            let linkedBank = debitLabelToBank[rawSource]
            // Only settle a bank-linked bill when this pending item also reduced that bank's live cash
            // (`item.date >= account.asOf`); pre-asOf stale notices must not clear open bills without deducting cash.
            if let linkedBank, item.date < linkedBank.asOf {
                continue
            }
            let resolvedSource = linkedBank?.bankLabel
                ?? sourceLabels[rawSource]
                ?? item.source
            if item.source.caseInsensitiveCompare("Apple") == .orderedSame {
                appleItems.append((item, resolvedSource))
            } else {
                regularRows.append(BankRow(
                    source: resolvedSource,
                    date: item.date,
                    amount: item.amount,
                    description: item.merchant,
                    isUnattributedAggregator: isGenericAppleDescriptor(item.merchant)
                ))
            }
        }

        var currentTimeline = regularRows.isEmpty ? timeline : reconcile(timeline: timeline, bankRows: regularRows)
        guard !appleItems.isEmpty else { return currentTimeline }

        // Match each Apple receipt only against open entries whose service name agrees with `item.merchant`.
        for (item, resolvedSource) in appleItems {
            guard let itemDay = JST.dayNumber(item.date) else { continue }
            var bestIdx: Int?
            var bestDist = Int.max
            for (idx, entry) in currentTimeline.enumerated() {
                guard (entry.done != true || entry.phoneChecked == true),
                      entry.payday != true,
                      entry.event != true,
                      let match = entry.match,
                      match.source == resolvedSource,
                      match.dir.lowercased() == "out",
                      match.window.count == 2,
                      let entryDay = JST.dayNumber(entry.date)
                else { continue }
                let offset = itemDay - entryDay
                guard offset >= match.window[0], offset <= match.window[1] else { continue }
                if let minA = match.minAmount, item.amount < minA { continue }
                if let maxA = match.maxAmount, item.amount > maxA { continue }
                let matchesDirectPattern: Bool = {
                    guard let regex = try? NSRegularExpression(pattern: match.pattern, options: [.caseInsensitive]) else {
                        return false
                    }
                    let range = NSRange(item.merchant.startIndex..<item.merchant.endIndex, in: item.merchant)
                    return regex.firstMatch(in: item.merchant, options: [], range: range) != nil
                }()
                let matchesAppleService: Bool = {
                    let isAppleMatch = match.pattern.lowercased().contains("apple")
                    return isAppleMatch && appleReceiptMatchesEntryService(merchant: item.merchant, entry: entry)
                }()
                guard matchesDirectPattern || matchesAppleService else { continue }
                let dist = abs(offset)
                if dist < bestDist {
                    bestDist = dist
                    bestIdx = idx
                }
            }
            if let idx = bestIdx {
                currentTimeline[idx].done = true
                currentTimeline[idx].phoneChecked = nil
                currentTimeline[idx].date = item.date
                if currentTimeline[idx].cardBilled == true {
                    currentTimeline[idx].billedAmount = item.amount
                } else {
                    currentTimeline[idx].amount = item.amount
                }
                currentTimeline[idx].estimate = nil
            }
        }
        return currentTimeline
    }
}
