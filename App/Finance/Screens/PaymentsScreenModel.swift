import FinanceCore
import Foundation

/// Filter options for the Payments ledger.
enum PaymentStatusFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "All"
    case pending = "Pending"
    case manual = "Manual"
    case uncategorized = "Uncategorized"

    var id: String { rawValue }
}

enum PaymentTypeFilter: String, CaseIterable, Identifiable, Sendable {
    case payments = "Payments"
    case spendingOnly = "Spending only"
    case income = "Income"
    case nonSpending = "Excluded"

    var id: String { rawValue }
}

enum PaymentSortOrder: String, CaseIterable, Identifiable, Sendable {
    case newest = "Newest"
    case largest = "Largest"

    var id: String { rawValue }
}

/// Derived view model for the Payments screen, supporting Calendar Months, Pay Cycles,
/// date-range deep links, layer filters, all-months search, and swipe triage.
struct PaymentsScreenModel: Sendable {
    struct DaySection: Identifiable, Sendable {
        var id: String { date }
        let date: String
        let rows: [NumberedRow<BudgetItem>]
        let countedSubtotal: Int
    }

    struct CategoryOption: Identifiable, Sendable {
        var id: String { name }
        let name: String
        let spendingTotal: Int
        let count: Int
    }

    struct LayerSlice: Identifiable, Sendable {
        var id: SpendingLayer { layer }
        let layer: SpendingLayer
        let sum: Int
    }

    let periodMode: BudgetPeriodMode
    let periods: [BudgetPeriod]
    let selectedPeriod: BudgetPeriod?
    let selectedPeriodID: String
    let allPeriods: Bool
    let categories: [CategoryOption]
    let sources: [String]
    let sections: [DaySection]
    let layerSlices: [LayerSlice]
    let totalRows: Int
    let spendingRowCount: Int
    let excludedRowCount: Int
    let countedSpending: Int
    let incomeTotal: Int
    let pendingCount: Int
    let manualCount: Int

    init(
        data: FinanceData,
        periodMode: BudgetPeriodMode,
        selectedPeriodID: String?,
        allPeriods: Bool,
        category: String?,
        source: String?,
        layerFilter: SpendingLayer?,
        dateRange: ClosedRange<String>?,
        statusFilter: PaymentStatusFilter,
        typeFilter: PaymentTypeFilter,
        sortOrder: PaymentSortOrder,
        query: String
    ) {
        self.periodMode = periodMode
        let availablePeriods = data.periods(for: periodMode)
        self.periods = availablePeriods
        self.allPeriods = allPeriods || dateRange != nil

        let resolvedPeriod = selectedPeriodID.flatMap { id in availablePeriods.first(where: { $0.id == id }) }
            ?? availablePeriods.last
        self.selectedPeriod = resolvedPeriod
        self.selectedPeriodID = resolvedPeriod?.id ?? ""

        let incomeGroup = data.bundle.layerConfig.resolvedIncomeGroup ?? "Income"
        let scopeRows: [NumberedRow<BudgetItem>] = data.allRowsSorted.filter { row in
            let item = row.value
            if typeFilter == .income {
                guard item.group == incomeGroup else { return false }
            } else {
                guard item.group != incomeGroup else { return false }
            }
            if let dateRange {
                return dateRange.contains(item.date)
            }
            if allPeriods {
                return true
            }
            guard let resolvedPeriod else { return true }
            return resolvedPeriod.contains(item.date)
        }

        // Category pills and source filter options reflect the active scope.
        var categoryTotals: [String: (sum: Int, count: Int)] = [:]
        var sourceSet = Set<String>()
        for row in scopeRows {
            let item = row.value
            sourceSet.insert(item.source)
            var entry = categoryTotals[item.category, default: (0, 0)]
            if data.layer(of: item) != nil {
                entry.sum += item.amount
            } else if item.group == incomeGroup {
                entry.sum -= item.amount
            }
            entry.count += 1
            categoryTotals[item.category] = entry
        }
        self.categories = categoryTotals
            .map { CategoryOption(name: $0.key, spendingTotal: $0.value.sum, count: $0.value.count) }
            .sorted {
                if $0.spendingTotal != $1.spendingTotal { return $0.spendingTotal > $1.spendingTotal }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        self.sources = sourceSet.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let foldedQuery = TextFold.key(trimmedQuery)
        let bundleLayers = data.bundle.layers

        let filtered = scopeRows.filter { row in
            let item = row.value
            let layerKey = data.layer(of: item)
            let isSpending = layerKey != nil

            switch typeFilter {
            case .payments:
                break
            case .spendingOnly:
                guard isSpending else { return false }
            case .income:
                guard item.group == incomeGroup else { return false }
            case .nonSpending:
                guard !isSpending && item.group != incomeGroup else { return false }
            }

            if let layerFilter {
                guard let key = layerKey,
                      SpendingLayer.resolve(key: key, bundleLayers: bundleLayers) == layerFilter
                else { return false }
            }

            switch statusFilter {
            case .all:
                break
            case .pending:
                guard item.isPending else { return false }
            case .manual:
                guard data.isLocalItem(item) else { return false }
            case .uncategorized:
                guard item.category.caseInsensitiveCompare("Uncategorized") == .orderedSame else { return false }
            }

            if let category, !category.isEmpty, item.category != category {
                return false
            }
            if let source, !source.isEmpty, item.source != source {
                return false
            }
            if !trimmedQuery.isEmpty {
                if item.merchant.localizedCaseInsensitiveContains(trimmedQuery)
                    || item.category.localizedCaseInsensitiveContains(trimmedQuery)
                    || item.source.localizedCaseInsensitiveContains(trimmedQuery)
                {
                    return true
                }
                if !foldedQuery.isEmpty,
                   let folded = data.foldedSearchByRowID[row.id],
                   folded.contains(foldedQuery)
                {
                    return true
                }
                return false
            }
            return true
        }

        self.totalRows = filtered.count
        let spendingRows = filtered.filter { data.layer(of: $0.value) != nil }
        self.spendingRowCount = spendingRows.count
        self.excludedRowCount = filtered.filter { data.layer(of: $0.value) == nil && $0.value.group != incomeGroup }.count
        self.countedSpending = spendingRows.reduce(0) { $0 + $1.value.amount }
        let incomeRows = filtered.filter { $0.value.group == incomeGroup }
        self.incomeTotal = -incomeRows.reduce(0) { $0 + $1.value.amount }
        self.pendingCount = filtered.filter { $0.value.isPending }.count
        self.manualCount = filtered.filter { data.isLocalItem($0.value) }.count

        if typeFilter == .income {
            self.layerSlices = []
        } else {
            var totals: [SpendingLayer: Int] = [:]
            for row in spendingRows where row.value.amount > 0 {
                if let layerKey = data.layer(of: row.value) {
                    let layer = SpendingLayer.resolve(key: layerKey, bundleLayers: bundleLayers)
                    totals[layer, default: 0] += row.value.amount
                }
            }
            self.layerSlices = SpendingLayer.allCases.compactMap { layer in
                let val = totals[layer, default: 0]
                return val > 0 ? LayerSlice(layer: layer, sum: val) : nil
            }
        }

        if sortOrder == .largest {
            let sortedByAmount = filtered.sorted {
                if abs($0.value.amount) != abs($1.value.amount) {
                    return abs($0.value.amount) > abs($1.value.amount)
                }
                return $0.value.date > $1.value.date
            }
            if sortedByAmount.isEmpty {
                self.sections = []
            } else {
                self.sections = [
                    DaySection(
                        date: "LARGEST",
                        rows: sortedByAmount,
                        countedSubtotal: self.countedSpending
                    )
                ]
            }
        } else {
            let grouped = Dictionary(grouping: filtered) { $0.value.date }
            self.sections = grouped.keys.sorted(by: >).map { date in
                let dayRows = grouped[date] ?? []
                let subtotal = dayRows
                    .filter { data.layer(of: $0.value) != nil }
                    .reduce(0) { $0 + $1.value.amount }
                return DaySection(date: date, rows: dayRows, countedSubtotal: subtotal)
            }
        }
    }
}
