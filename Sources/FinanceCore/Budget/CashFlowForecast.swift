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
    /// Estimated daily cash/debit day-to-day spend used in baseline projection
    /// (excludes deferred credit cards already billed as monthly lump sums on the timeline).
    public var baselineDailyBurn: Int
    /// Deferred credit/postpay card sources excluded from daily burn because their monthly bill is on the timeline.
    public var excludedDeferredCardSources: [String]
    /// Monthly debit/cash subscriptions not already on the timeline included in baseline outflow.
    public var baselineMonthlySubs: Int
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
        excludedDeferredCardSources: [String] = [],
        baselineMonthlySubs: Int = 0,
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
        self.excludedDeferredCardSources = excludedDeferredCardSources
        self.baselineMonthlySubs = baselineMonthlySubs
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
        startingCashOverride: Int? = nil,
        liveCash: LiveCashSummary? = nil
    ) -> CashFlowSummary {
        let horizon = max(7, min(180, days))
        let endDate = JST.addingDays(horizon - 1, to: today) ?? today

        // 1. Start from user override, else real bank cash (minus phone-only checkoffs whose bank debit hasn't posted),
        //    else fall back to payday cycle math for legacy bundles without accountBalances.
        let startingCash: Int = {
            if let override = startingCashOverride { return override }
            if let liveCash { return liveCash.estimatedBankCash - liveCash.phoneCheckedBillsSum }
            if let breakdown = paydayBreakdown {
                return breakdown.receivedInSum - breakdown.paidBillsSum - breakdown.dayToDaySpentSincePayday
            }
            if let payday {
                return payday.left + payday.outs.filter { $0.done != true }.reduce(0) { $0 + $1.amount }
            }
            return 0
        }()

        // Detect deferred-bill card sources (credit cards whose monthly lump-sum bill is already on the
        // timeline) so we do not double-count both their daily purchases and their monthly bill.
        let timelineBillTitles: [String] = timeline
            .filter { $0.event != true && $0.borrowed != true && $0.amount > 0 }
            .map { TextFold.key($0.item) }

        let deferredCardSources: Set<String> = {
            let distinctSources = Set(allItems.map(\.source))
            var deferred = Set<String>()
            for source in distinctSources {
                let lower = source.lowercased()
                if lower.contains("debit") || lower.contains("bank") || lower == "cash" || lower == "apple" {
                    continue
                }
                let foldedSource = TextFold.key(source)
                guard foldedSource.count >= 4 else { continue }
                if timelineBillTitles.contains(where: { title in
                    title.contains(foldedSource) && (title.contains("bill") || title.contains("請求") || title.contains("card"))
                }) {
                    deferred.insert(source)
                }
            }
            return deferred
        }()

        // 2. Estimate daily non-bill discretionary cash/debit burn from the last 60 days of Day-to-day spending.
        let baselineDailyBurn: Int = {
            guard let lookbackStart = JST.addingDays(-60, to: today) else { return 0 }
            let keys = layers.count >= 4 ? Array(layers.prefix(4).map(\.key)) : LayerConfig.defaultLayerKeys
            let dayToDayKey = keys[3]
            let recent = allItems.filter { item in
                item.date >= lookbackStart
                    && item.date <= today
                    && item.amount > 0
                    && !deferredCardSources.contains(item.source)
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

        // Include running subscriptions billed outside the timeline and outside deferred-bill cards so
        // baseline drag and What-If cancellation toggles stay mathematically consistent.
        let deferredFolded = deferredCardSources.map { TextFold.key($0) }
        let baselineMonthlySubs: Int = subscriptionSummary.running
            .filter { sub in
                guard sub.entry.monthly > 0 else { return false }
                let statusLower = (sub.entry.status ?? "").lowercased()
                if statusLower.contains("repaid") || statusLower.contains("yearly") { return false }
                // Skip subscriptions billed solely via a deferred card whose monthly bill is already on the timeline.
                let viaParts = (sub.entry.via ?? "")
                    .split(separator: "/")
                    .map { TextFold.key(String($0)) }
                    .filter { !$0.isEmpty }
                if !viaParts.isEmpty,
                   viaParts.allSatisfy({ part in deferredFolded.contains(where: { part.contains($0) }) })
                {
                    return false
                }
                // Skip subscriptions already represented directly as a bill on the timeline.
                let tokens = SubscriptionHistory.searchTokens(for: sub.entry.name)
                if timelineBillTitles.contains(where: { title in tokens.contains(where: { title.contains($0) }) }) {
                    return false
                }
                return true
            }
            .reduce(0) { $0 + $1.entry.monthly }

        // 3. Collect explicit unpaid timeline events (including overdue unpaid bills reserved on day 0),
        //    plus extrapolate monthly recurring salary & bills for months 2 and 3.
        var eventsByDate: [String: [CashFlowEvent]] = [:]
        var explicitByMonthDir: [String: [String]] = [:]
        var existingExplicitIDs = Set<String>()
        var existingProjectedKeys = Set<String>()

        func addEvent(_ event: CashFlowEvent) {
            guard event.date >= today, event.date <= endDate else { return }
            let ym = String(event.date.prefix(7))
            let dir = event.amount < 0 ? "in" : "out"
            let foldedTitle = TextFold.key(event.title)
            if event.isProjectedRepeat {
                let dedupe = "\(ym)|\(foldedTitle)|\(dir)"
                guard existingProjectedKeys.insert(dedupe).inserted else { return }
                let explicitTitles = explicitByMonthDir["\(ym)|\(dir)"] ?? []
                if explicitTitles.contains(where: { $0 == foldedTitle || $0.hasPrefix(foldedTitle) || foldedTitle.hasPrefix($0) }) {
                    return
                }
            } else {
                guard existingExplicitIDs.insert(event.id).inserted else { return }
                explicitByMonthDir["\(ym)|\(dir)", default: []].append(foldedTitle)
            }
            eventsByDate[event.date, default: []].append(event)
        }

        // Explicit future/today entries from timeline, plus overdue unpaid bills reserved on day 0.
        for (idx, entry) in timeline.enumerated() {
            guard entry.done != true, entry.event != true, entry.borrowed != true, entry.amount != 0 else { continue }
            if entry.date < today {
                // Reserve overdue unpaid outflows on day 0 so Runway stays consistent with Now.
                guard entry.amount > 0 else { continue }
                addEvent(CashFlowEvent(
                    id: "overdue:\(idx):\(entry.date):\(entry.item)",
                    date: today,
                    title: "\(entry.item) (overdue)",
                    amount: entry.amount,
                    isEstimate: entry.estimate == true,
                    isProjectedRepeat: false
                ))
                continue
            }
            guard entry.date <= endDate else { continue }
            addEvent(CashFlowEvent(
                id: "tl:\(idx):\(entry.date):\(entry.item)",
                date: entry.date,
                title: entry.item,
                amount: entry.amount,
                isEstimate: entry.estimate == true,
                isProjectedRepeat: false
            ))
        }

        // Recurring templates from the timeline (payday salary + regular monthly bills) projected +1..+3 months.
        // Never blindly repeats one-off bills (loans, quarterly taxes, bonuses, custom one-off reminders).
        let hasExplicitRecurringFlags = timeline.contains { $0.recurring != nil }
        let oneOffKeywords = ["bonus", "賞与", "resident tax", "住民税", "pay back", "cashback", "refund", "flight", "hotel"]

        let recurringTemplates: [TimelineEntry] = {
            var latestByTitle: [String: TimelineEntry] = [:]
            if let next = payday?.next, next.amount != 0 {
                latestByTitle[TextFold.key(next.item)] = next
            }
            for entry in timeline {
                guard entry.event != true, entry.borrowed != true, entry.amount != 0 else { continue }
                let shouldRepeat: Bool
                if hasExplicitRecurringFlags {
                    shouldRepeat = entry.recurring == true || entry.payday == true
                } else {
                    let lower = entry.item.lowercased()
                    let looksOneOff = oneOffKeywords.contains { lower.contains($0) }
                    shouldRepeat = !looksOneOff && (entry.payday == true || entry.amount > 0)
                }
                guard shouldRepeat else { continue }
                let key = TextFold.key(entry.item)
                if let existing = latestByTitle[key] {
                    if entry.date >= existing.date {
                        latestByTitle[key] = entry
                    }
                } else {
                    latestByTitle[key] = entry
                }
            }
            return latestByTitle.values.sorted { ($0.date, $0.item) < ($1.date, $1.item) }
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

        let dailyBaselineSubs = Double(baselineMonthlySubs) / 30.0
        let maxTrim = baselineDailyBurn > 0 ? baselineDailyBurn * 30 : Int.max
        let effectiveDayToDaySavings = min(max(0, scenario.monthlyDayToDaySavings), maxTrim)
        let monthlyScenarioNetSaving = cancelledSubsMonthly
            + effectiveDayToDaySavings
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
                let dailyDrag = Double(baselineDailyBurn) + dailyBaselineSubs
                runningBaseline -= dailyDrag
                runningScenario -= dailyDrag
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
            excludedDeferredCardSources: deferredCardSources.sorted(),
            baselineMonthlySubs: baselineMonthlySubs,
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
