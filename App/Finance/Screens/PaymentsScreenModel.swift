import FinanceCore
import Foundation

/// Derived view model for the Payments screen, computed from `FinanceData`.
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
    let categories: [CategoryOption]
    let sections: [DaySection]
    let totalRows: Int
    let countedSpending: Int
    let pendingCount: Int

    init(data: FinanceData, selectedMonth: String?, category: String?, query: String) {
        let allMonths = data.months
        self.months = allMonths
        let years = Set(allMonths.map { String($0.prefix(4)) })
        self.spansMultipleYears = years.count > 1

        let resolvedMonth = selectedMonth.flatMap { allMonths.contains($0) ? $0 : nil }
            ?? allMonths.last
            ?? ""
        self.selectedMonth = resolvedMonth

        let monthRows = data.paymentsByMonth[resolvedMonth] ?? []

        var categoryTotals: [String: (sum: Int, count: Int)] = [:]
        for row in monthRows {
            let item = row.value
            var entry = categoryTotals[item.category, default: (0, 0)]
            if data.layer(of: item) != nil {
                entry.sum += item.amount
            }
            entry.count += 1
            categoryTotals[item.category] = entry
        }
        self.categories = categoryTotals
            .map { CategoryOption(name: $0.key, spendingTotal: $0.value.sum, count: $0.value.count) }
            .sorted {
                if $0.spendingTotal != $1.spendingTotal {
                    return $0.spendingTotal > $1.spendingTotal
                }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = monthRows.filter { row in
            let item = row.value
            if let category, !category.isEmpty, item.category != category {
                return false
            }
            if !trimmedQuery.isEmpty {
                let haystack = item.merchant + " " + item.category + " " + item.source
                return haystack.localizedCaseInsensitiveContains(trimmedQuery)
            }
            return true
        }

        self.totalRows = filtered.count
        self.countedSpending = filtered
            .filter { data.layer(of: $0.value) != nil }
            .reduce(0) { $0 + $1.value.amount }
        self.pendingCount = filtered.filter { $0.value.isPending }.count

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
