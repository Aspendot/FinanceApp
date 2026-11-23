import FinanceCore
import Foundation

/// Derived view model for the Months screen, computed via `MonthTotals` from `FinanceData`.
struct MonthsScreenModel: Sendable {
    struct StackedSegment: Identifiable, Sendable {
        let id: String
        let month: String
        let layer: SpendingLayer
        let layerTitle: String
        let amount: Int
        let yStart: Int
        let yEnd: Int
    }

    struct LayerAmount: Identifiable, Sendable {
        var id: SpendingLayer { layer }
        let layer: SpendingLayer
        let title: String
        let amount: Int
    }

    struct CategoryBar: Identifiable, Sendable {
        var id: String { name }
        let name: String
        let sum: Int
        let count: Int
        let share: Double
        let barFraction: Double
        let layer: SpendingLayer
    }

    let months: [String]
    let spansMultipleYears: Bool
    let selectedMonth: String
    let totalsByMonth: [String: MonthTotals]
    let segments: [StackedSegment]
    let maxChartTotal: Int
    let selectedTotals: MonthTotals
    let selectedLayerAmounts: [LayerAmount]
    let categoryBars: [CategoryBar]

    init(data: FinanceData, selectedMonth: String?) {
        let pendingItems = data.paymentsByMonth.values
            .flatMap { $0 }
            .map(\.value)
            .filter(\.isPending)
        let allItems = data.bundle.items + pendingItems
        let totals = MonthTotals.compute(
            items: allItems,
            config: data.bundle.layerConfig,
            layers: data.bundle.layers
        )
        self.totalsByMonth = totals

        let sortedMonths = totals.keys.sorted()
        self.months = sortedMonths
        let years = Set(sortedMonths.map { String($0.prefix(4)) })
        self.spansMultipleYears = years.count > 1

        let resolvedMonth = selectedMonth.flatMap { sortedMonths.contains($0) ? $0 : nil }
            ?? sortedMonths.last
            ?? ""
        self.selectedMonth = resolvedMonth

        let bundleLayers = data.bundle.layers
        var builtSegments: [StackedSegment] = []
        var maxStack = 0

        for month in sortedMonths {
            guard let monthTotal = totals[month] else { continue }
            var buckets: [SpendingLayer: Int] = [:]
            for (key, value) in monthTotal.layers {
                let resolved = SpendingLayer.resolve(key: key, bundleLayers: bundleLayers)
                buckets[resolved, default: 0] += value
            }

            // Stack in strict canonical order so Rent is always the bottom flat band.
            var runningY = 0
            for layer in SpendingLayer.allCases {
                let amount = max(0, buckets[layer, default: 0])
                guard amount > 0 else { continue }
                let endY = runningY + amount
                builtSegments.append(
                    StackedSegment(
                        id: "\(month)-\(layer.rawValue)",
                        month: month,
                        layer: layer,
                        layerTitle: layer.title(in: bundleLayers),
                        amount: amount,
                        yStart: runningY,
                        yEnd: endY
                    )
                )
                runningY = endY
            }
            maxStack = max(maxStack, runningY)
        }

        self.segments = builtSegments
        self.maxChartTotal = Self.roundedAxisCeiling(maxStack)

        let activeTotals = totals[resolvedMonth] ?? MonthTotals()
        self.selectedTotals = activeTotals

        var activeLayerBuckets: [SpendingLayer: Int] = [:]
        for (key, value) in activeTotals.layers {
            let resolved = SpendingLayer.resolve(key: key, bundleLayers: bundleLayers)
            activeLayerBuckets[resolved, default: 0] += value
        }
        self.selectedLayerAmounts = SpendingLayer.allCases.map { layer in
            LayerAmount(
                layer: layer,
                title: layer.title(in: bundleLayers),
                amount: activeLayerBuckets[layer, default: 0]
            )
        }

        // Map each category in the selected month to its spending layer so bars match the chart.
        var categoryLayerVotes: [String: [SpendingLayer: Int]] = [:]
        for item in allItems where item.date.hasPrefix(resolvedMonth) {
            if let key = data.layer(of: item) {
                let resolved = SpendingLayer.resolve(key: key, bundleLayers: bundleLayers)
                categoryLayerVotes[item.category, default: [:]][resolved, default: 0] += max(1, abs(item.amount))
            }
        }

        let positiveCategories = activeTotals.categories
            .filter { $0.value.sum > 0 }
            .sorted {
                if $0.value.sum != $1.value.sum {
                    return $0.value.sum > $1.value.sum
                }
                return $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending
            }

        let maxCategorySum = max(1, positiveCategories.first?.value.sum ?? 1)
        let spendingDenom = max(1, activeTotals.total)

        self.categoryBars = positiveCategories.map { name, total in
            let votedLayer = categoryLayerVotes[name]?
                .max(by: { $0.value < $1.value })?.key
                ?? data.bundle.layerConfig.layer(group: "", category: name, layers: bundleLayers)
                    .map { SpendingLayer.resolve(key: $0, bundleLayers: bundleLayers) }
                ?? .dayToDay
            return CategoryBar(
                name: name,
                sum: total.sum,
                count: total.count,
                share: Double(total.sum) / Double(spendingDenom),
                barFraction: Double(total.sum) / Double(maxCategorySum),
                layer: votedLayer
            )
        }
    }

    private static func roundedAxisCeiling(_ value: Int) -> Int {
        guard value > 0 else { return 100_000 }
        let step = value >= 200_000 ? 50_000 : 25_000
        return ((value + step - 1) / step) * step
    }
}
