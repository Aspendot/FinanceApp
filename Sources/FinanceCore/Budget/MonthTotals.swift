import Foundation

/// Net sum and positive-item count for one spending category in a month.
public struct CategoryTotal: Codable, Sendable, Equatable {
    public var sum: Int
    public var count: Int

    public init(sum: Int = 0, count: Int = 0) {
        self.sum = sum
        self.count = count
    }
}

/// Aggregated spending, income and cashflow totals for one "YYYY-MM" month.
public struct MonthTotals: Codable, Sendable, Equatable {
    /// Spending sums keyed by layer name.
    public var layers: [String: Int]
    /// Spending sum and positive-amount count keyed by category name.
    public var categories: [String: CategoryTotal]
    /// Net income (negated sum of income-group items).
    public var income: Int
    /// Net outflow to the people group.
    public var people: Int
    /// Net outflow to the debt group.
    public var debt: Int
    /// Sum of spending across all layers.
    public var total: Int
    /// Remaining cash: `income - total - debt - people`.
    public var left: Int

    public init(
        layers: [String: Int] = [:],
        categories: [String: CategoryTotal] = [:],
        income: Int = 0,
        people: Int = 0,
        debt: Int = 0,
        total: Int = 0,
        left: Int = 0
    ) {
        self.layers = layers
        self.categories = categories
        self.income = income
        self.people = people
        self.debt = debt
        self.total = total
        self.left = left
    }

    /// Computes monthly totals keyed by "YYYY-MM".
    ///
    /// Items without a spending layer are excluded from `layers`, `categories` and
    /// `total`, and only count when their group matches income, people or debt.
    public static func compute(
        items: [BudgetItem],
        config: LayerConfig,
        layers: [LayerDefinition] = []
    ) -> [String: MonthTotals] {
        var result: [String: MonthTotals] = [:]
        let incomeGroup = config.resolvedIncomeGroup

        for item in items {
            guard item.date.count >= 7 else { continue }
            let month = String(item.date.prefix(7))
            var totals = result[month] ?? MonthTotals()

            if let layer = config.resolvedLayer(for: item, layers: layers) {
                totals.layers[layer, default: 0] += item.amount
                var cat = totals.categories[item.category] ?? CategoryTotal()
                cat.sum += item.amount
                if item.amount > 0 {
                    cat.count += 1
                }
                totals.categories[item.category] = cat
                totals.total += item.amount
            } else if let incomeGroup, item.group == incomeGroup {
                totals.income -= item.amount
            } else if let peopleGroup = config.peopleGroup, item.group == peopleGroup {
                totals.people += item.amount
            } else if let debtGroup = config.debtGroup, item.group == debtGroup {
                totals.debt += item.amount
            }

            result[month] = totals
        }

        for month in result.keys {
            if var totals = result[month] {
                totals.left = totals.income - totals.total - totals.debt - totals.people
                result[month] = totals
            }
        }

        return result
    }
}
