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

/// Derived view model for the Payments screen, supporting single-month or all-months search and rich filters.
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

    let months: [String]
    let spansMultipleYears: Bool
    let selectedMonth: String
    let allMonths: Bool
    let categories: [CategoryOption]
    let sources: [String]
    let sections: [DaySection]
    let totalRows: Int
    let spendingRowCount: Int
    let excludedRowCount: Int
    let countedSpending: Int
    let incomeTotal: Int
    let pendingCount: Int
    let manualCount: Int

    init(
        data: FinanceData,
        selectedMonth: String?,
        allMonths: Bool,
        category: String?,
        source: String?,
        statusFilter: PaymentStatusFilter,
        typeFilter: PaymentTypeFilter,
        sortOrder: PaymentSortOrder,
        query: String
    ) {
        let allAvailableMonths = data.months
        self.months = allAvailableMonths
        let years = Set(allAvailableMonths.map { String($0.prefix(4)) })
        self.spansMultipleYears = years.count > 1
        self.allMonths = allMonths

        let resolvedMonth = selectedMonth.flatMap { allAvailableMonths.contains($0) ? $0 : nil }
            ?? allAvailableMonths.last
            ?? ""
        self.selectedMonth = resolvedMonth

        let incomeGroup = data.bundle.layerConfig.resolvedIncomeGroup ?? "Income"
        let scopeRows: [NumberedRow<BudgetItem>]
        if typeFilter == .income {
            scopeRows = data.allRowsSorted.filter { row in
                row.value.group == incomeGroup && (allMonths || row.value.date.hasPrefix(resolvedMonth))
            }
        } else if allMonths {
            scopeRows = data.allRowsSorted.filter { $0.value.group != incomeGroup }
        } else {
            scopeRows = data.paymentsByMonth[resolvedMonth] ?? []
        }

        // Category pills and source filter options reflect the active month/scope.
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

        let filtered = scopeRows.filter { row in
            let item = row.value
            let isSpending = data.layer(of: item) != nil

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
                let haystack = item.merchant + " " + item.category + " " + item.source
                if haystack.localizedCaseInsensitiveContains(trimmedQuery) {
                    return true
                }
                if !foldedQuery.isEmpty && TextFold.key(haystack).contains(foldedQuery) {
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
        self.incomeTotal = -filtered.filter { $0.value.group == incomeGroup }.reduce(0) { $0 + $1.value.amount }
        self.pendingCount = filtered.filter { $0.value.isPending }.count
        self.manualCount = filtered.filter { data.isLocalItem($0.value) }.count

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
