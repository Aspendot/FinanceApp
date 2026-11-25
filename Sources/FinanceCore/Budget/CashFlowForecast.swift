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
            .filter { $0.event != true && $0.borrowed != true && $0.cardBilled != true && $0.amount > 0 }
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
                let sourceHasCard = foldedSource.contains("card") || foldedSource.contains("カ-ド") || foldedSource.contains("カード")
                if timelineBillTitles.contains(where: { title in
                    guard title.contains(foldedSource) else { return false }
                    // Prevent a non-card wallet (e.g. "WalletA") from matching a separate card bill ("WalletA Card bill").
                    if !sourceHasCard && (title.contains("\(foldedSource)card") || title.contains("\(foldedSource)カ-ド") || title.contains("\(foldedSource)カード")) {
                        return false
                    }
                    return title.contains("bill") || title.contains("請求") || title.contains("card")
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

        // 3. Collect explicit unpaid timeline events (including overdue unpaid bills and lagging paydays
        //    reserved on day 0), plus extrapolate monthly recurring salary & bills for months 2 and 3.
        let eventsByDate = Self.buildEventsByDate(
            today: today,
            endDate: endDate,
            payday: payday,
            timeline: timeline,
            clearedByPostBalance: liveCash?.postBalanceMatchedKeys ?? []
        )

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

    private struct EventCollector {
        let today: String
        let endDate: String
        var eventsByDate: [String: [CashFlowEvent]] = [:]
        var explicitByMonthDir: [String: [String]] = [:]
        var existingExplicitIDs = Set<String>()
        var existingProjectedKeys = Set<String>()

        @inline(never)
        mutating func add(_ event: CashFlowEvent, recordAsExplicitForMonth: Bool = true) {
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
                if recordAsExplicitForMonth {
                    explicitByMonthDir["\(ym)|\(dir)", default: []].append(foldedTitle)
                }
            }
            eventsByDate[event.date, default: []].append(event)
        }
    }

    @inline(never)
    private static func buildEventsByDate(
        today: String,
        endDate: String,
        payday: PaydayView?,
        timeline: [TimelineEntry],
        clearedByPostBalance: Set<String>
    ) -> [String: [CashFlowEvent]] {
        var collector = EventCollector(today: today, endDate: endDate)
        collectExplicitEvents(
            into: &collector,
            today: today,
            endDate: endDate,
            timeline: timeline,
            clearedByPostBalance: clearedByPostBalance
        )
        let recurringTemplates = extractRecurringTemplates(timeline: timeline, payday: payday)
        let projectedEvents = Self.projectedRecurringEvents(
            recurringTemplates: recurringTemplates,
            timeline: timeline,
            today: today,
            endDate: endDate
        )
        for ev in projectedEvents {
            collector.add(ev)
        }
        return collector.eventsByDate
    }

    @inline(never)
    private static func latestPastOrDonePayday(in timeline: [TimelineEntry], today: String) -> String? {
        var latest: String?
        for entry in timeline {
            guard entry.payday == true else { continue }
            guard entry.done == true || entry.date < today else { continue }
            if let cur = latest {
                if entry.date > cur { latest = entry.date }
            } else {
                latest = entry.date
            }
        }
        return latest
    }

    @inline(never)
    private static func makeExplicitEvent(
        index idx: Int,
        entry: TimelineEntry,
        today: String,
        todayMonth: String,
        endDate: String,
        inferredLastPayday: String?,
        clearedByPostBalance: Set<String>
    ) -> (event: CashFlowEvent, recordAsExplicit: Bool)? {
        guard entry.done != true, entry.event != true, entry.borrowed != true, entry.cardBilled != true, entry.amount != 0 else {
            return nil
        }
        guard !BillCheckoff.matches(entry, in: clearedByPostBalance) else { return nil }
        if entry.date < today {
            let isSameMonth = String(entry.date.prefix(7)) == todayMonth
            if entry.amount > 0 {
                return (
                    CashFlowEvent(
                        id: "overdue:\(idx):\(entry.date):\(entry.item)",
                        date: today,
                        title: "\(entry.item) (overdue)",
                        amount: entry.amount,
                        isEstimate: entry.estimate == true,
                        isProjectedRepeat: false
                    ),
                    isSameMonth
                )
            }
            if LiveCashSummary.isConfirmedPendingInflow(entry, lastPayday: inferredLastPayday, today: today) {
                return (
                    CashFlowEvent(
                        id: "lagin:\(idx):\(entry.date):\(entry.item)",
                        date: today,
                        title: "\(entry.item) (pending)",
                        amount: entry.amount,
                        isEstimate: entry.estimate == true,
                        isProjectedRepeat: false
                    ),
                    isSameMonth
                )
            }
            return nil
        }
        guard entry.date <= endDate else { return nil }
        return (
            CashFlowEvent(
                id: "tl:\(idx):\(entry.date):\(entry.item)",
                date: entry.date,
                title: entry.item,
                amount: entry.amount,
                isEstimate: entry.estimate == true,
                isProjectedRepeat: false
            ),
            true
        )
    }

    @inline(never)
    private static func collectExplicitEvents(
        into collector: inout EventCollector,
        today: String,
        endDate: String,
        timeline: [TimelineEntry],
        clearedByPostBalance: Set<String>
    ) {
        let inferredLastPayday = latestPastOrDonePayday(in: timeline, today: today)
        let todayMonth = String(today.prefix(7))
        for idx in timeline.indices {
            if let built = makeExplicitEvent(
                index: idx,
                entry: timeline[idx],
                today: today,
                todayMonth: todayMonth,
                endDate: endDate,
                inferredLastPayday: inferredLastPayday,
                clearedByPostBalance: clearedByPostBalance
            ) {
                collector.add(built.event, recordAsExplicitForMonth: built.recordAsExplicit)
            }
        }
    }

    @inline(never)
    private static func extractRecurringTemplates(
        timeline: [TimelineEntry],
        payday: PaydayView?
    ) -> [TimelineEntry] {
        let hasExplicitRecurringFlags = timeline.contains { $0.recurring != nil }
        let oneOffKeywords = ["bonus", "賞与", "resident tax", "住民税", "pay back", "cashback", "refund", "flight", "hotel"]
        var latestByTitle: [String: TimelineEntry] = [:]
        if let next = payday?.next, next.amount != 0 {
            latestByTitle[TextFold.key(next.item)] = next
        }
        for entry in timeline {
            guard entry.event != true, entry.borrowed != true, entry.cardBilled != true, entry.amount != 0 else { continue }
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
    }

    @inline(never)
    private static func weekdayOf(_ isoDate: String) -> Int? {
        guard let dayNum = JST.dayNumber(isoDate) else { return nil }
        // 1970-01-01 (dayNum 0) was Thursday (4); weekday 0=Sun..6=Sat.
        return ((dayNum % 7) + 7 + 4) % 7
    }

    @inline(never)
    private static func nthMondayDay(year: Int, month: Int, n: Int) -> Int {
        let first = String(format: "%04d-%02d-01", year, month)
        let wd = weekdayOf(first) ?? 1
        let firstMonday = 1 + ((8 - wd) % 7)
        return firstMonday + (n - 1) * 7
    }

    @inline(never)
    private static func isJapanNationalHoliday(year: Int, month: Int, day: Int) -> Bool {
        switch (month, day) {
        case (1, 1), (2, 11), (2, 23), (4, 29), (5, 3), (5, 4), (5, 5), (8, 11), (11, 3), (11, 23):
            return true
        default:
            break
        }
        // Happy Monday holidays: Coming of Age (2nd Mon Jan), Marine Day (3rd Mon Jul),
        // Respect for the Aged Day (3rd Mon Sep), Sports Day (2nd Mon Oct).
        if month == 1 && day == nthMondayDay(year: year, month: 1, n: 2) { return true }
        if month == 7 && day == nthMondayDay(year: year, month: 7, n: 3) { return true }
        if month == 9 && day == nthMondayDay(year: year, month: 9, n: 3) { return true }
        if month == 10 && day == nthMondayDay(year: year, month: 10, n: 2) { return true }
        // Vernal & Autumnal Equinox approximations (valid 2000...2099).
        if year >= 2000 && year <= 2099 {
            let vernal = Int(floor(20.69115 + 0.242194 * Double(year - 2000) - floor(Double(year - 2000) / 4.0)))
            let autumnal = Int(floor(23.09 + 0.242194 * Double(year - 2000) - floor(Double(year - 2000) / 4.0)))
            if month == 3 && day == vernal { return true }
            if month == 9 && day == autumnal { return true }
        }
        return false
    }

    @inline(never)
    private static func isBankClosed(_ isoDate: String) -> Bool {
        guard let wd = weekdayOf(isoDate) else { return false }
        if wd == 0 || wd == 6 { return true }
        let parts = isoDate.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return false }
        let (y, m, d) = (parts[0], parts[1], parts[2])
        // New Year bank closure (Dec 31 – Jan 3).
        if (m == 12 && d == 31) || (m == 1 && d <= 3) { return true }
        if isJapanNationalHoliday(year: y, month: m, day: d) { return true }
        // Citizens' Holiday (Kokumin no Kyujitsu): a weekday sandwiched between two national holidays
        // (e.g. Sep 22, 2026 between Respect for the Aged Day and Autumnal Equinox).
        if let prev = JST.addingDays(-1, to: isoDate),
           let next = JST.addingDays(1, to: isoDate)
        {
            let pp = prev.split(separator: "-").compactMap { Int($0) }
            let np = next.split(separator: "-").compactMap { Int($0) }
            if pp.count == 3, np.count == 3,
               isJapanNationalHoliday(year: pp[0], month: pp[1], day: pp[2]),
               isJapanNationalHoliday(year: np[0], month: np[1], day: np[2])
            {
                return true
            }
        }
        // Furikae Kyujitsu (substitute holiday): walk backwards over consecutive national holidays;
        // if any fell on a Sunday, today is the substitute weekday off.
        var checkDate = isoDate
        for _ in 0..<5 {
            guard let prev = JST.addingDays(-1, to: checkDate) else { break }
            let pp = prev.split(separator: "-").compactMap { Int($0) }
            guard pp.count == 3, isJapanNationalHoliday(year: pp[0], month: pp[1], day: pp[2]) else { break }
            if weekdayOf(prev) == 0 { return true }
            checkDate = prev
        }
        return false
    }

    @inline(never)
    public static func adjustBankBusinessDay(_ isoDate: String, moveEarlier: Bool) -> String {
        var current = isoDate
        let step = moveEarlier ? -1 : 1
        for _ in 0..<10 {
            if !isBankClosed(current) { return current }
            guard let next = JST.addingDays(step, to: current) else { return current }
            current = next
        }
        return current
    }

    private static func shouldRollOnBankHolidays(_ tmpl: TimelineEntry) -> Bool {
        if let explicit = tmpl.rollBusinessDay { return explicit }
        if tmpl.payday == true { return true }
        let noteLower = (tmpl.note ?? "").lowercased()
        // Legacy bundles without `rollBusinessDay`: treat explicit card/app-store/wallet subscriptions
        // as fixed-calendar-day while keeping bank auto-debits on business days.
        if noteLower.contains("auto-debit") { return true }
        if noteLower.contains("debit card") || noteLower.contains("via ") || noteLower.contains("wallet") {
            return false
        }
        return true
    }

    private static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11: return 30
        case 2:
            let leap = (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0)
            return leap ? 29 : 28
        default: return 28
        }
    }

    @inline(never)
    private static func projectedRecurringEvents(
        recurringTemplates: [TimelineEntry],
        timeline: [TimelineEntry],
        today: String,
        endDate: String
    ) -> [CashFlowEvent] {
        // Recover each recurring template's un-rolled nominal day-of-month so projections do not
        // permanently drift off a holiday-adjusted month (e.g. Apr 3 -> May 3).
        var observedDaysByKey: [String: [Int]] = [:]
        var explicitNominalByKey: [String: Int] = [:]
        for entry in timeline {
            let key = TextFold.key(entry.item)
            if let nom = entry.nominalDay, (1...31).contains(nom) {
                explicitNominalByKey[key] = nom
            }
            let parts = entry.date.split(separator: "-").compactMap { Int($0) }
            if parts.count == 3 {
                observedDaysByKey[key, default: []].append(parts[2])
            }
        }

        var out: [CashFlowEvent] = []
        for (tIdx, tmpl) in recurringTemplates.enumerated() {
            let roll = shouldRollOnBankHolidays(tmpl)
            let parts = tmpl.date.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { continue }
            let baseYear = parts[0]
            let baseMonth = parts[1]
            let key = TextFold.key(tmpl.item)
            let anchorDay: Int = {
                if let explicit = tmpl.nominalDay ?? explicitNominalByKey[key], (1...31).contains(explicit) {
                    return explicit
                }
                let observed = observedDaysByKey[key] ?? [parts[2]]
                if roll {
                    // Paydays roll earlier on bank holidays (nominal day is the maximum observed day);
                    // bank auto-debits roll later (nominal day is the minimum observed day).
                    return (tmpl.payday == true ? observed.max() : observed.min()) ?? parts[2]
                }
                return parts[2]
            }()

            for shift in 1...3 {
                let totalMonths = baseYear * 12 + (baseMonth - 1) + shift
                let targetYear = totalMonths / 12
                let targetMonth = (totalMonths % 12) + 1
                let clampedDay = min(anchorDay, daysInMonth(year: targetYear, month: targetMonth))
                let rawShifted = String(format: "%04d-%02d-%02d", targetYear, targetMonth, clampedDay)
                let shifted = roll ? adjustBankBusinessDay(rawShifted, moveEarlier: tmpl.payday == true) : rawShifted
                guard shifted >= today, shifted <= endDate else { continue }
                out.append(CashFlowEvent(
                    id: "proj:\(tIdx):\(shift):\(shifted):\(tmpl.item)",
                    date: shifted,
                    title: tmpl.item,
                    amount: tmpl.amount,
                    isEstimate: true,
                    isProjectedRepeat: true
                ))
            }
        }
        return out
    }
}
