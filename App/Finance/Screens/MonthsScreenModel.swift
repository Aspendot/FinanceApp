import FinanceCore
import Foundation

/// Derived view model for the Months screen, supporting both Calendar Months and Pay Cycles
/// over ALL items (statements + Money Forward + pending emails + local entries & overrides).
struct MonthsScreenModel: Sendable {
    struct StackedSegment: Identifiable, Sendable {
        let id: String
        let periodID: String
        let layer: SpendingLayer
        let layerTitle: String
        let amount: Int
        let yStart: Int
        let yEnd: Int
        let isInProgress: Bool
    }

    struct IncomePoint: Identifiable, Sendable {
        var id: String { periodID }
        let periodID: String
        let income: Int
    }

    struct LayerAmount: Identifiable, Sendable {
        var id: SpendingLayer { layer }
        let layer: SpendingLayer
        let title: String
        let amount: Int
        let share: Double
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

    let periodMode: BudgetPeriodMode
    let periods: [BudgetPeriod]
    let periodIDs: [String]
    let periodByID: [String: BudgetPeriod]
    let selectedPeriod: BudgetPeriod?
    let selectedPeriodID: String
    let inProgressPeriodID: String?
    let activePeriodPace: Double?
    let totalsByPeriod: [String: MonthTotals]
    let segments: [StackedSegment]
    let incomePoints: [IncomePoint]
    let maxChartTotal: Int
    let selectedTotals: MonthTotals
    let comparison: MonthComparison
    let selectedLayerAmounts: [LayerAmount]
    let categoryBars: [CategoryBar]
    let topMerchants: [MerchantSummary]
    let sourceSummaries: [SourceSummary]
    let planSummary: PlanSummary

    init(
        data: FinanceData,
        periodMode: BudgetPeriodMode,
        selectedPeriodID: String?,
        today: String
    ) {
        self.periodMode = periodMode
        let allItems = data.allItems
        let periodsList = data.periods(for: periodMode)
        let totals = data.totals(for: periodMode)
        self.periods = periodsList
        self.periodIDs = periodsList.map(\.id)
        self.periodByID = Dictionary(uniqueKeysWithValues: periodsList.map { ($0.id, $0) })
        self.totalsByPeriod = totals

        let resolvedPeriod = selectedPeriodID.flatMap { id in periodsList.first(where: { $0.id == id }) }
            ?? periodsList.last
        self.selectedPeriod = resolvedPeriod
        let resolvedID = resolvedPeriod?.id ?? ""
        self.selectedPeriodID = resolvedID

        let partialID = periodsList.last(where: { $0.isInProgress })?.id
        self.inProgressPeriodID = partialID
        self.activePeriodPace = resolvedPeriod?.paceProgress(on: today)

        let bundleLayers = data.bundle.layers
        var builtSegments: [StackedSegment] = []
        var incomePts: [IncomePoint] = []
        var maxStack = 0

        for period in periodsList {
            guard let periodTotal = totals[period.id] else { continue }
            var buckets: [SpendingLayer: Int] = [:]
            for (key, value) in periodTotal.layers {
                let resolved = SpendingLayer.resolve(key: key, bundleLayers: bundleLayers)
                buckets[resolved, default: 0] += value
            }

            // Stack in strict canonical order so Rent is always the flat bottom band.
            var runningY = 0
            for layer in SpendingLayer.allCases {
                let amount = max(0, buckets[layer, default: 0])
                guard amount > 0 else { continue }
                let endY = runningY + amount
                builtSegments.append(
                    StackedSegment(
                        id: "\(period.id)-\(layer.rawValue)",
                        periodID: period.id,
                        layer: layer,
                        layerTitle: layer.title(in: bundleLayers),
                        amount: amount,
                        yStart: runningY,
                        yEnd: endY,
                        isInProgress: period.isInProgress
                    )
                )
                runningY = endY
            }
            maxStack = max(maxStack, runningY)

            // Draw income line across completed periods (and in Pay Cycle mode, also the current cycle since salary lands Day 1!).
            if (!period.isInProgress || period.mode == .payCycle) && periodTotal.income > 0 {
                incomePts.append(IncomePoint(periodID: period.id, income: periodTotal.income))
                maxStack = max(maxStack, periodTotal.income)
            }
        }

        self.segments = builtSegments
        self.incomePoints = incomePts
        self.maxChartTotal = Self.roundedAxisCeiling(maxStack)

        let activeTotals = totals[resolvedID] ?? MonthTotals()
        self.selectedTotals = activeTotals

        if periodMode == .calendarMonth {
            self.comparison = SpendingInsights.monthComparison(
                totalsByMonth: data.totalsByMonth,
                selectedMonth: resolvedID,
                asOf: data.bundle.asOf,
                today: today,
                planWindow: data.bundle.planWindow,
                layers: bundleLayers
            )
        } else {
            self.comparison = PayCycleBuilder.periodComparison(
                periods: periodsList,
                totalsByPeriod: totals,
                selectedPeriodID: resolvedID,
                layers: bundleLayers
            )
        }

        var activeLayerBuckets: [SpendingLayer: Int] = [:]
        for (key, value) in activeTotals.layers {
            let resolved = SpendingLayer.resolve(key: key, bundleLayers: bundleLayers)
            activeLayerBuckets[resolved, default: 0] += value
        }
        let spendingDenom = max(1, activeTotals.total)
        self.selectedLayerAmounts = SpendingLayer.allCases.map { layer in
            let amt = activeLayerBuckets[layer, default: 0]
            return LayerAmount(
                layer: layer,
                title: layer.title(in: bundleLayers),
                amount: amt,
                share: Double(max(0, amt)) / Double(spendingDenom)
            )
        }

        let periodItems: [BudgetItem] = {
            guard let resolvedPeriod else { return [] }
            return allItems.filter { resolvedPeriod.contains($0.date) }
        }()

        var categoryLayerVotes: [String: [SpendingLayer: Int]] = [:]
        for item in periodItems {
            if let key = data.layer(of: item) {
                let resolved = SpendingLayer.resolve(key: key, bundleLayers: bundleLayers)
                categoryLayerVotes[item.category, default: [:]][resolved, default: 0] += max(1, abs(item.amount))
            }
        }

        let positiveCategories = activeTotals.categories
            .filter { $0.value.sum > 0 }
            .sorted {
                if $0.value.sum != $1.value.sum { return $0.value.sum > $1.value.sum }
                return $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending
            }

        let maxCategorySum = max(1, positiveCategories.first?.value.sum ?? 1)
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

        self.topMerchants = SpendingInsights.topMerchants(
            items: periodItems,
            config: data.bundle.layerConfig,
            layers: bundleLayers,
            month: nil,
            limit: 20
        )

        self.sourceSummaries = SpendingInsights.spendingBySource(
            items: periodItems,
            config: data.bundle.layerConfig,
            layers: bundleLayers,
            month: nil
        )

        self.planSummary = PlanSummary.compute(
            plan: data.effectivePlan,
            planWindow: periodMode == .calendarMonth ? data.bundle.planWindow : nil,
            totalsByMonth: totals,
            selectedMonth: resolvedID,
            currentMonth: periodsList.last?.id ?? resolvedID,
            inProgressMonth: partialID
        )
    }

    func axisLabel(for periodID: String) -> String {
        guard let period = periodByID[periodID] else { return periodID }
        let suffix = period.isInProgress ? "*" : ""
        if period.mode == .calendarMonth {
            return FinanceFormat.chartMonth(period.id) + suffix
        }
        return period.shortLabel + suffix
    }

    private static func roundedAxisCeiling(_ value: Int) -> Int {
        guard value > 0 else { return 100_000 }
        let step = value >= 200_000 ? 50_000 : 25_000
        return ((value + step - 1) / step) * step
    }
}
