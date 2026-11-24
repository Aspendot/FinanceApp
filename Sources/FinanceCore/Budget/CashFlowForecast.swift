import Foundation

/// Interactive "What-If" overrides applied on top of the 90-day cash-flow runway estimate.
public struct WhatIfScenario: Sendable, Equatable {
    /// Subscription IDs toggled off in the simulator (reduces monthly outflow).
    public var cancelledSubscriptionIDs: Set<String>
    /// Extra monthly payment directed toward debt reduction (increases monthly outflow).
    public var extraMonthlyDebtPayment: Int
    /// Monthly reduction in day-to-day discretionary spending (reduces daily burn).
    public var monthlyDayToDaySavings: Int

    public init(
        cancelledSubscriptionIDs: Set<String> = [],
        extraMonthlyDebtPayment: Int = 0,
        monthlyDayToDaySavings: Int = 0
    ) {
        self.cancelledSubscriptionIDs = cancelledSubscriptionIDs
        self.extraMonthlyDebtPayment = extraMonthlyDebtPayment
        self.monthlyDayToDaySavings = monthlyDayToDaySavings
    }

    public var isBaseline: Bool {
        cancelledSubscriptionIDs.isEmpty
            && extraMonthlyDebtPayment == 0
            && monthlyDayToDaySavings == 0
    }
}

/// One scheduled or extrapolated cash event occurring on a forecasted day.
public struct CashFlowEvent: Sendable, Equatable, Identifiable {
    public var id: String
    public var date: String
    public var title: String
    /// Positive is money out, negative is money in.
    public var amount: Int
    public var isEstimate: Bool
    public var isProjectedRepeat: Bool

    public init(
        id: String,
        date: String,
        title: String,
        amount: Int,
        isEstimate: Bool,
        isProjectedRepeat: Bool
    ) {
        self.id = id
        self.date = date
        self.title = title
        self.amount = amount
        self.isEstimate = isEstimate
        self.isProjectedRepeat = isProjectedRepeat
    }
}

/// Single day along the 90-day projected balance curve.
public struct CashFlowDayPoint: Sendable, Equatable, Identifiable {
    public var id: String { date }
    public var date: String
    public var dayIndex: Int
    public var baselineBalance: Int
    public var scenarioBalance: Int
    public var events: [CashFlowEvent]

    public init(
        date: String,
        dayIndex: Int,
        baselineBalance: Int,
        scenarioBalance: Int,
        events: [CashFlowEvent] = []
    ) {
        self.date = date
        self.dayIndex = dayIndex
        self.baselineBalance = baselineBalance
        self.scenarioBalance = scenarioBalance
        self.events = events
    }
}

/// Complete 90-day balance forecast comparing baseline trajectory vs interactive What-If scenario.
public struct CashFlowSummary: Sendable, Equatable {
    public var startDate: String
    public var endDate: String
    public var days: Int
    /// Estimated starting available cash on `startDate`.
    public var startingCashEstimate: Int
    /// Estimated daily day-to-day discretionary spend used in baseline projection.
    public var baselineDailyBurn: Int
    /// Monthly savings unlocked by toggled-off subscriptions in the scenario.
    public var cancelledSubsMonthlyTotal: Int
    public var points: [CashFlowDayPoint]
    public var baselineLowest: CashFlowDayPoint?
    public var scenarioLowest: CashFlowDayPoint?
    public var baselineEndBalance: Int
    public var scenarioEndBalance: Int
    public var scenarioDelta: Int
    /// Dates where the baseline projection dips below the caution floor (¥20,000 or negative).
    public var dipDates: [String]

    public init(
        startDate: String,
        endDate: String,
        days: Int,
        startingCashEstimate: Int,
        baselineDailyBurn: Int,
        cancelledSubsMonthlyTotal: Int,
        points: [CashFlowDayPoint],
        baselineLowest: CashFlowDayPoint?,
        scenarioLowest: CashFlowDayPoint?,
        baselineEndBalance: Int,
        scenarioEndBalance: Int,
        scenarioDelta: Int,
        dipDates: [String]
    ) {
        self.startDate = startDate
        self.endDate = endDate
        self.days = days
        self.startingCashEstimate = startingCashEstimate
        self.baselineDailyBurn = baselineDailyBurn
        self.cancelledSubsMonthlyTotal = cancelledSubsMonthlyTotal
        self.points = points
        self.baselineLowest = baselineLowest
        self.scenarioLowest = scenarioLowest
        self.baselineEndBalance = baselineEndBalance
        self.scenarioEndBalance = scenarioEndBalance
        self.scenarioDelta = scenarioDelta
        self.dipDates = dipDates
    }
}

/// Pure deterministic 90-day cash-flow simulator (always labelled as an estimate in the UI).
public enum CashFlowForecast {
    /// Projects day-by-day estimated cash balance over `days` (default 90 days, ~3 pay cycles).
    public static func project(
        today: String,
        days: Int = 90,
        payday: PaydayView?,
        paydayBreakdown: PaydayBreakdown?,
        timeline: [TimelineEntry],
        allItems: [BudgetItem],
        subscriptionSummary: SubscriptionSummary,
        config: LayerConfig,
        layers: [LayerDefinition],
        scenario: WhatIfScenario = WhatIfScenario(),
        startingCashOverride: Int? = nil
    ) -> CashFlowSummary {
        let horizon = max(7, min(180, days))
        let endDate = JST.addingDays(horizon - 1, to: today) ?? today

        // 1. Estimate starting cash on hand today from active payday cycle math.
        let startingCash: Int = {
            if let override = startingCashOverride { return override }
            if let breakdown = paydayBreakdown {
                return breakdown.receivedInSum - breakdown.paidBillsSum - breakdown.dayToDaySpentSincePayday
            }
            if let payday {
                return payday.left + payday.outs.filter { $0.done != true }.reduce(0) { $0 + $1.amount }
            }
            return 0
        }()

        // 2. Estimate daily non-bill discretionary burn from the last 60 days of Day-to-day spending.
        let baselineDailyBurn: Int = {
            guard let lookbackStart = JST.addingDays(-60, to: today) else { return 0 }
            let keys = layers.count >= 4 ? Array(layers.prefix(4).map(\.key)) : LayerConfig.defaultLayerKeys
            let dayToDayKey = keys[3]
            let recent = allItems.filter { item in
                item.date >= lookbackStart
                    && item.date <= today
                    && item.amount > 0
                    && config.resolvedLayer(for: item, layers: layers) == dayToDayKey
            }
            guard !recent.isEmpty else { return 0 }
            let earliest = recent.map(\.date).min() ?? lookbackStart
            let spanDays: Int = {
                if let s = JST.dayNumber(earliest), let e = JST.dayNumber(today) {
                    return max(14, min(60, e - s + 1))
                }
                return 30
            }()
            let sum = recent.reduce(0) { $0 + $1.amount }
            return Int((Double(sum) / Double(spanDays)).rounded())
        }()

        // 3. Collect explicit unpaid upcoming timeline events inside [today, endDate],
        //    plus extrapolate monthly recurring salary & bills for months 2 and 3.
        var eventsByDate: [String: [CashFlowEvent]] = [:]
        var existingKeys = Set<String>()

        func addEvent(_ event: CashFlowEvent) {
            guard event.date >= today, event.date <= endDate else { return }
            let dedupe = "\(String(event.date.prefix(7)))|\(TextFold.key(event.title))|\(event.amount < 0 ? "in" : "out")"
            guard existingKeys.insert(dedupe).inserted else { return }
            eventsByDate[event.date, default: []].append(event)
        }

        // Explicit future/today entries from timeline.
        for (idx, entry) in timeline.enumerated() {
            guard entry.done != true, entry.event != true, entry.borrowed != true, entry.amount != 0 else { continue }
            guard entry.date >= today, entry.date <= endDate else { continue }
            addEvent(CashFlowEvent(
                id: "tl:\(idx):\(entry.date):\(entry.item)",
                date: entry.date,
                title: entry.item,
                amount: entry.amount,
                isEstimate: entry.estimate == true,
                isProjectedRepeat: false
            ))
        }

        // Recurring templates from the current cycle (payday salary + regular bills) projected +1, +2, +3 months.
        let recurringTemplates: [TimelineEntry] = {
            var templates: [TimelineEntry] = []
            if let next = payday?.next, next.amount != 0 {
                templates.append(next)
            }
            for entry in timeline {
                guard entry.event != true, entry.borrowed != true, entry.amount != 0 else { continue }
                // Skip one-off bonuses (usually flagged with estimate & label) from blind monthly repeat.
                let lower = entry.item.lowercased()
                if lower.contains("bonus") || lower.contains("賞与") { continue }
                if entry.payday == true || entry.amount > 0 {
                    templates.append(entry)
                }
            }
            return templates
        }()

        for (tIdx, tmpl) in recurringTemplates.enumerated() {
            for shift in 1...3 {
                guard let shifted = PayCycleBuilder.shiftMonth(tmpl.date, by: shift),
                      shifted >= today, shifted <= endDate
                else { continue }
                addEvent(CashFlowEvent(
                    id: "proj:\(tIdx):\(shift):\(shifted):\(tmpl.item)",
                    date: shifted,
                    title: tmpl.item,
                    amount: tmpl.amount,
                    isEstimate: true,
                    isProjectedRepeat: true
                ))
            }
        }

        // 4. Scenario monthly delta expressed as daily net savings/cost.
        let cancelledSubsMonthly = subscriptionSummary.running
            .filter { scenario.cancelledSubscriptionIDs.contains($0.id) }
            .reduce(0) { $0 + $1.entry.monthly }

        let monthlyScenarioNetSaving = cancelledSubsMonthly
            + max(0, scenario.monthlyDayToDaySavings)
            - max(0, scenario.extraMonthlyDebtPayment)
        let dailyScenarioDelta = Double(monthlyScenarioNetSaving) / 30.0

        // 5. Walk day by day from day 0 (`today`) to `horizon - 1`.
        var points: [CashFlowDayPoint] = []
        points.reserveCapacity(horizon)

        var runningBaseline = Double(startingCash)
        var runningScenario = Double(startingCash)
        var dipDates: [String] = []

        for offset in 0..<horizon {
            guard let day = JST.addingDays(offset, to: today) else { break }
            let dayEvents = eventsByDate[day] ?? []
            let eventNet = dayEvents.reduce(0) { $0 - $1.amount } // negative amount = money in => +cash

            runningBaseline += Double(eventNet)
            runningScenario += Double(eventNet)

            if offset > 0 {
                runningBaseline -= Double(baselineDailyBurn)
                runningScenario -= Double(baselineDailyBurn)
                runningScenario += dailyScenarioDelta
            }

            let baseRounded = Int(runningBaseline.rounded())
            let scenRounded = Int(runningScenario.rounded())
            if baseRounded < 20_000 {
                dipDates.append(day)
            }

            points.append(CashFlowDayPoint(
                date: day,
                dayIndex: offset,
                baselineBalance: baseRounded,
                scenarioBalance: scenRounded,
                events: dayEvents
            ))
        }

        let baselineLowest = points.min(by: { $0.baselineBalance < $1.baselineBalance })
        let scenarioLowest = points.min(by: { $0.scenarioBalance < $1.scenarioBalance })
        let baseEnd = points.last?.baselineBalance ?? startingCash
        let scenEnd = points.last?.scenarioBalance ?? startingCash

        return CashFlowSummary(
            startDate: today,
            endDate: points.last?.date ?? endDate,
            days: points.count,
            startingCashEstimate: startingCash,
            baselineDailyBurn: baselineDailyBurn,
            cancelledSubsMonthlyTotal: cancelledSubsMonthly,
            points: points,
            baselineLowest: baselineLowest,
            scenarioLowest: scenarioLowest,
            baselineEndBalance: baseEnd,
            scenarioEndBalance: scenEnd,
            scenarioDelta: scenEnd - baseEnd,
            dipDates: dipDates
        )
    }
}
