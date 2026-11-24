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

        public init(source: String, date: String, amount: Int, description: String) {
            self.source = source
            self.date = date
            self.amount = amount
            self.description = description
        }
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

    /// Matches open timeline entries carrying a `TimelineMatch` against `bankRows`.
    ///
    /// Each bank row is used at most once. When entries or rows compete, the nearest date
    /// distance wins, breaking ties by earliest row date then earliest entry date.
    /// Invalid regexes or malformed rules are skipped without failing.
    ///
    /// If the entry marked `next == true` becomes done during reconciliation, its `next` flag
    /// is cleared and `next = true` is set on the following `payday == true` entry.
    public static func reconcile(
        timeline: [TimelineEntry],
        bankRows: [BankRow]
    ) -> [TimelineEntry] {
        guard !timeline.isEmpty, !bankRows.isEmpty else {
            return timeline
        }
        guard timeline.contains(where: { $0.done != true && $0.match != nil }) else {
            return timeline
        }

        var rowsBySource: [String: [ParsedRow]] = [:]
        for (index, row) in bankRows.enumerated() {
            guard let day = JST.dayNumber(row.date) else { continue }
            rowsBySource[row.source, default: []].append(ParsedRow(index: index, row: row, dayNumber: day))
        }
        guard !rowsBySource.isEmpty else {
            return timeline
        }

        var candidates: [CandidatePair] = []
        for (entryIndex, entry) in timeline.enumerated() {
            guard entry.done != true,
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
            return timeline
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

        // After a roll the finished cycle's settled entries and prior inflows no longer belong to the new cycle,
        // while unpaid overdue bills must remain visible and reserved until settled or explicitly checked off.
        if let start = newCycleStart {
            return result.filter { entry in
                entry.date >= start || (entry.done != true && entry.amount > 0 && entry.event != true && entry.borrowed != true && entry.cardBilled != true)
            }
        }
        return result
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
        guard timeline.contains(where: { $0.done != true && $0.payday != true && $0.match != nil }) else {
            return timeline
        }

        var debitLabelToBankLabel: [String: String] = [:]
        for account in accountBalances {
            let bankLabel = sourceLabels[account.source] ?? account.label
            for debitKey in account.debitNoticeSources ?? [] where !debitKey.isEmpty {
                debitLabelToBankLabel[debitKey] = bankLabel
                if let label = sourceLabels[debitKey], !label.isEmpty {
                    debitLabelToBankLabel[label] = bankLabel
                }
            }
        }

        let syntheticRows: [BankRow] = pendingItems.compactMap { item in
            guard item.isPending, item.amount > 0 else { return nil }
            let resolvedSource = debitLabelToBankLabel[item.source] ?? item.source
            return BankRow(
                source: resolvedSource,
                date: item.date,
                amount: item.amount,
                description: item.merchant
            )
        }
        guard !syntheticRows.isEmpty else { return timeline }
        return reconcile(timeline: timeline, bankRows: syntheticRows)
    }
}
