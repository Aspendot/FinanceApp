import Foundation

/// Global budgeting period mode shared across Months, Payments, and Targets.
public enum BudgetPeriodMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case calendarMonth = "Calendar"
    case payCycle = "Pay Cycle"

    public var id: String { rawValue }
}

/// Either a calendar month (`YYYY-MM-01`..end of month) or a payday-to-day-before-next-payday cycle.
public struct BudgetPeriod: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var mode: BudgetPeriodMode
    /// Human-readable title such as `"April 2026"` or `"Mar 25 – Apr 24"`.
    public var title: String
    /// Compact label for chart X-axis and chips such as `"Apr"` or `"Mar 25"`.
    public var shortLabel: String
    /// Inclusive `"YYYY-MM-DD"` start date.
    public var startDate: String
    /// Inclusive `"YYYY-MM-DD"` end date.
    public var endDate: String
    public var isInProgress: Bool

    public init(
        id: String,
        mode: BudgetPeriodMode,
        title: String,
        shortLabel: String,
        startDate: String,
        endDate: String,
        isInProgress: Bool
    ) {
        self.id = id
        self.mode = mode
        self.title = title
        self.shortLabel = shortLabel
        self.startDate = startDate
        self.endDate = endDate
        self.isInProgress = isInProgress
    }

    public func contains(_ date: String) -> Bool {
        date >= startDate && date <= endDate
    }

    /// Fraction (`0.0...1.0`) of calendar days elapsed within this period on `today`,
    /// or `nil` when `today` lies outside `[startDate, endDate]`.
    public func paceProgress(on today: String) -> Double? {
        guard contains(today),
              let start = JST.dayNumber(startDate),
              let end = JST.dayNumber(endDate),
              let current = JST.dayNumber(today),
              end >= start
        else { return nil }
        let totalDays = max(1, end - start + 1)
        let elapsedDays = max(1, current - start + 1)
        return min(1.0, max(0.0, Double(elapsedDays) / Double(totalDays)))
    }
}

/// Builds calendar-month and pay-cycle periods plus per-period `MonthTotals` aggregations.
public enum PayCycleBuilder {
    private static let shortMonths = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"
    ]

    private static let fullMonths = [
        "January", "February", "March", "April", "May", "June",
        "July", "August", "September", "October", "November", "December"
    ]

    /// Builds calendar-month `BudgetPeriod`s covering every sorted `"YYYY-MM"` month.
    public static func calendarPeriods(
        months: [String],
        asOf: String,
        today: String
    ) -> [BudgetPeriod] {
        let sorted = Array(Set(months)).sorted()
        let latestPartial = max(String(asOf.prefix(7)), String(today.prefix(7)))
        let years = Set(sorted.map { String($0.prefix(4)) })
        let spansYears = years.count > 1

        return sorted.compactMap { month in
            guard let (y, m) = parseYearMonth(month),
                  let lastDay = daysInMonth(year: y, month: m)
            else { return nil }
            let start = String(format: "%04d-%02d-01", y, m)
            let end = String(format: "%04d-%02d-%02d", y, m, lastDay)
            let monthName = fullMonths[m - 1]
            let shortName = shortMonths[m - 1]
            let shortLabel = spansYears ? "\(shortName) '\(String(format: "%02d", y % 100))" : shortName
            let isPartial = month >= latestPartial && month == sorted.last
            return BudgetPeriod(
                id: month,
                mode: .calendarMonth,
                title: "\(monthName) \(y)",
                shortLabel: shortLabel,
                startDate: start,
                endDate: end,
                isInProgress: isPartial
            )
        }
    }

    /// Discovers payday dates from timeline entries and regular salary deposits, returning
    /// chronological pay cycles from each payday through the day before the next payday.
    public static func payCycles(
        items: [BudgetItem],
        timeline: [TimelineEntry],
        config: LayerConfig,
        today: String
    ) -> [BudgetPeriod] {
        let incomeGroup = config.resolvedIncomeGroup ?? "Income"

        // 1. Authoritative payday dates from timeline.
        var timelinePaydays = Set(timeline.filter { $0.payday == true }.map(\.date))
        let nextPaydayDate = timeline.first(where: { $0.next == true })?.date
        if let nextPaydayDate {
            timelinePaydays.insert(nextPaydayDate)
        }

        // 2. Discover historical paydays from primary monthly salary deposits (>= ¥50,000)
        //    only for months that do not already have a timeline payday.
        let timelineMonths = Set(timelinePaydays.map { String($0.prefix(7)) })
        var bestSalaryByMonth: [String: (date: String, amount: Int)] = [:]
        for item in items where item.group == incomeGroup && item.amount <= -50_000 && item.date.count == 10 {
            let month = String(item.date.prefix(7))
            guard !timelineMonths.contains(month) else { continue }
            let magnitude = -item.amount
            if let existing = bestSalaryByMonth[month] {
                if magnitude > existing.amount {
                    bestSalaryByMonth[month] = (item.date, magnitude)
                }
            } else {
                bestSalaryByMonth[month] = (item.date, magnitude)
            }
        }

        let rawPaydays = timelinePaydays.union(bestSalaryByMonth.values.map(\.date)).sorted()

        // Collapse accidental near-duplicate paydays within 12 days (e.g. bonus shortly after salary).
        var paydays: [String] = []
        for day in rawPaydays {
            if let prev = paydays.last,
               let prevNum = JST.dayNumber(prev),
               let curNum = JST.dayNumber(day),
               curNum - prevNum < 12
            {
                // Keep timeline-marked payday if present, otherwise keep the earlier one.
                if timelinePaydays.contains(day) && !timelinePaydays.contains(prev) {
                    paydays[paydays.count - 1] = day
                }
                continue
            }
            paydays.append(day)
        }

        guard !paydays.isEmpty else { return [] }

        // Typical payday day-of-month for synthesizing boundary starts/ends.
        let paydayDaysOfMonth = paydays.compactMap { Int($0.suffix(2)) }.sorted()
        let typicalDay = paydayDaysOfMonth[paydayDaysOfMonth.count / 2]

        // If items exist before the first discovered payday, prepend one opening cycle.
        let earliestItemDate = items.map(\.date).min()
        if let earliest = earliestItemDate, let firstPayday = paydays.first, earliest < firstPayday {
            if let priorStart = shiftMonth(firstPayday, by: -1, preferredDay: typicalDay) {
                paydays.insert(min(priorStart, earliest), at: 0)
            }
        }

        // Only keep paydays that start a cycle on or before `today` (plus one future anchor for the end date).
        var starts: [String] = []
        var futureAnchor: String? = nil
        for d in paydays {
            if d <= today {
                starts.append(d)
            } else if futureAnchor == nil {
                futureAnchor = d
            }
        }

        // If every payday is in the future (unusual synthetic fixture), keep the first cycle up to it.
        if starts.isEmpty, let first = paydays.first, let prior = shiftMonth(first, by: -1, preferredDay: typicalDay) {
            starts = [prior]
            futureAnchor = first
        }

        var periods: [BudgetPeriod] = []
        for idx in 0..<starts.count {
            let start = starts[idx]
            let nextStart: String
            if idx + 1 < starts.count {
                nextStart = starts[idx + 1]
            } else if let anchor = futureAnchor {
                nextStart = anchor
            } else {
                nextStart = shiftMonth(start, by: 1, preferredDay: typicalDay)
                    ?? (JST.addingDays(30, to: start) ?? start)
            }
            guard let end = JST.addingDays(-1, to: nextStart), end >= start else { continue }
            let inProgress = (today >= start && today <= end) || (idx == starts.count - 1 && end >= today)
            periods.append(BudgetPeriod(
                id: "cycle:\(start)",
                mode: .payCycle,
                title: "\(shortDate(start)) – \(shortDate(end))",
                shortLabel: shortDate(start),
                startDate: start,
                endDate: end,
                isInProgress: inProgress
            ))
        }

        return periods
    }

    /// Computes `MonthTotals` keyed by `period.id` across any ordered list of `BudgetPeriod`s.
    public static func totalsByPeriod(
        items: [BudgetItem],
        periods: [BudgetPeriod],
        config: LayerConfig,
        layers: [LayerDefinition] = []
    ) -> [String: MonthTotals] {
        guard !periods.isEmpty else { return [:] }
        var result: [String: MonthTotals] = Dictionary(uniqueKeysWithValues: periods.map { ($0.id, MonthTotals()) })
        let incomeGroup = config.resolvedIncomeGroup

        for item in items {
            guard let period = periods.first(where: { $0.contains(item.date) }) else { continue }
            var totals = result[period.id] ?? MonthTotals()

            if let layer = config.resolvedLayer(for: item, layers: layers) {
                totals.layers[layer, default: 0] += item.amount
                var cat = totals.categories[item.category] ?? CategoryTotal()
                cat.sum += item.amount
                if item.amount > 0 { cat.count += 1 }
                totals.categories[item.category] = cat
                totals.total += item.amount
            } else if let incomeGroup, item.group == incomeGroup {
                totals.income -= item.amount
            } else if let peopleGroup = config.peopleGroup, item.group == peopleGroup {
                totals.people += item.amount
            } else if let debtGroup = config.debtGroup, item.group == debtGroup {
                totals.debt += item.amount
            }

            result[period.id] = totals
        }

        for id in result.keys {
            if var totals = result[id] {
                totals.left = totals.income - totals.total - totals.debt - totals.people
                result[id] = totals
            }
        }
        return result
    }

    /// Computes month-over-month or cycle-over-cycle comparison for any `BudgetPeriod` sequence.
    public static func periodComparison(
        periods: [BudgetPeriod],
        totalsByPeriod: [String: MonthTotals],
        selectedPeriodID: String,
        layers: [LayerDefinition]
    ) -> MonthComparison {
        let selected = periods.first(where: { $0.id == selectedPeriodID }) ?? periods.last
        let selectedID = selected?.id ?? selectedPeriodID
        let isInProgress = selected?.isInProgress ?? false
        let selectedTotals = totalsByPeriod[selectedID] ?? MonthTotals()

        let prevPeriod: BudgetPeriod? = {
            guard let idx = periods.firstIndex(where: { $0.id == selectedID }), idx > 0 else { return nil }
            return periods[idx - 1]
        }()
        let prevTotal = prevPeriod.flatMap { totalsByPeriod[$0.id]?.total }
        let delta: Int? = (!isInProgress && prevTotal != nil) ? (selectedTotals.total - prevTotal!) : nil

        let completed = periods.filter { !$0.isInProgress }
        let recentCompleted = Array(completed.suffix(3))
        let avgValues = recentCompleted.compactMap { totalsByPeriod[$0.id]?.total }
        let baselineAverage: Int? = avgValues.isEmpty
            ? nil
            : Int((Double(avgValues.reduce(0, +)) / Double(avgValues.count)).rounded())

        let keys = layers.count >= 4 ? Array(layers.prefix(4).map(\.key)) : LayerConfig.defaultLayerKeys
        let rentCost = selectedTotals.layers[keys[0], default: 0]
        let billsCost = selectedTotals.layers[keys[1], default: 0]
        let subsCost = selectedTotals.layers[keys[2], default: 0]
        let dayToDayCost = selectedTotals.layers[keys[3], default: 0]
        let fixedCosts = rentCost + billsCost + subsCost

        let savingsRate: Double? = selectedTotals.income > 0
            ? Double(selectedTotals.income - selectedTotals.total) / Double(selectedTotals.income)
            : nil

        return MonthComparison(
            selectedMonth: selectedID,
            isInProgress: isInProgress,
            previousMonth: prevPeriod?.shortLabel,
            previousTotal: prevTotal,
            deltaFromPrevious: delta,
            baselineAverage: baselineAverage,
            rentCost: rentCost,
            billsCost: billsCost,
            subsCost: subsCost,
            fixedCosts: fixedCosts,
            dayToDayCosts: dayToDayCost,
            savingsRate: savingsRate
        )
    }

    // MARK: - Date helpers

    private static func shortDate(_ ymd: String) -> String {
        let parts = ymd.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]) else { return ymd }
        return "\(shortMonths[parts[1] - 1]) \(parts[2])"
    }

    private static func parseYearMonth(_ ym: String) -> (Int, Int)? {
        let parts = ym.split(separator: "-").compactMap { Int($0) }
        guard parts.count >= 2, (1...12).contains(parts[1]) else { return nil }
        return (parts[0], parts[1])
    }

    private static func daysInMonth(year: Int, month: Int) -> Int? {
        guard (1...12).contains(month) else { return nil }
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11: return 30
        case 2:
            let leap = (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0)
            return leap ? 29 : 28
        default: return nil
        }
    }

    public static func shiftMonth(_ ymd: String, by offset: Int, preferredDay: Int? = nil) -> String? {
        let parts = ymd.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        let totalMonths = parts[0] * 12 + (parts[1] - 1) + offset
        guard totalMonths >= 0 else { return nil }
        let y = totalMonths / 12
        let m = (totalMonths % 12) + 1
        guard let maxDay = daysInMonth(year: y, month: m) else { return nil }
        let day = min(maxDay, max(1, preferredDay ?? parts[2]))
        return String(format: "%04d-%02d-%02d", y, m, day)
    }
}
