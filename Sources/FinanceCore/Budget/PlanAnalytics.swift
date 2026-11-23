import Foundation

/// One month's spending point inside a category target sparkline.
public struct PlanMonthPoint: Sendable, Equatable, Identifiable {
    public var id: String { month }
    public var month: String
    public var spent: Int
    public var isSelected: Bool
    public var isInProgress: Bool

    public init(month: String, spent: Int, isSelected: Bool, isInProgress: Bool) {
        self.month = month
        self.spent = spent
        self.isSelected = isSelected
        self.isInProgress = isInProgress
    }
}

/// One category row in "Where to cut", enriched with actual spending and target pace.
public struct PlanRow: Sendable, Equatable, Identifiable {
    public var id: String { entry.category }
    public var entry: PlanEntry
    /// True when the row represents an active target (`Cut`, `Your call`, `Raise`).
    public var isActive: Bool
    public var tone: StatusTone
    public var displayStatus: String
    /// Actual spending in the selected month for this category.
    public var selectedMonthSpent: Int
    /// Actual spending in the latest/current month for this category.
    public var currentMonthSpent: Int
    /// `entry.now - target`, or nil when no target is set. Positive means monthly saving.
    public var monthlySaving: Int?
    /// `target - currentMonthSpent`, or nil when no target is set. Negative means over cap.
    public var currentMonthRemaining: Int?
    /// Fraction of target spent in the current month (`currentMonthSpent / target`), or nil if no target.
    public var currentMonthProgress: Double?
    /// Fraction of target spent in the selected month.
    public var selectedMonthProgress: Double?
    public var isOverCapCurrentMonth: Bool
    public var isNearCapCurrentMonth: Bool
    public var history: [PlanMonthPoint]

    public init(
        entry: PlanEntry,
        isActive: Bool,
        tone: StatusTone,
        displayStatus: String,
        selectedMonthSpent: Int,
        currentMonthSpent: Int,
        monthlySaving: Int?,
        currentMonthRemaining: Int?,
        currentMonthProgress: Double?,
        selectedMonthProgress: Double?,
        isOverCapCurrentMonth: Bool,
        isNearCapCurrentMonth: Bool,
        history: [PlanMonthPoint]
    ) {
        self.entry = entry
        self.isActive = isActive
        self.tone = tone
        self.displayStatus = displayStatus
        self.selectedMonthSpent = selectedMonthSpent
        self.currentMonthSpent = currentMonthSpent
        self.monthlySaving = monthlySaving
        self.currentMonthRemaining = currentMonthRemaining
        self.currentMonthProgress = currentMonthProgress
        self.selectedMonthProgress = selectedMonthProgress
        self.isOverCapCurrentMonth = isOverCapCurrentMonth
        self.isNearCapCurrentMonth = isNearCapCurrentMonth
        self.history = history
    }
}

/// Aggregated "Where to cut" summary matching the dashboard's exact savings rules.
public struct PlanSummary: Sendable, Equatable {
    public var active: [PlanRow]
    public var settled: [PlanRow]
    /// Active rows with a monthly cap, sorted by urgency (over cap first, then highest % used).
    public var watchList: [PlanRow]
    /// Baseline monthly total (average over `planWindow`, or fallback average across completed months).
    public var baselineTotal: Int
    /// Monthly savings already locked in from settled rows.
    public var alreadyCut: Int
    /// Additional monthly savings if active targets are met.
    public var potentialSavings: Int
    /// Projected monthly spending (`baselineTotal - alreadyCut - potentialSavings`).
    public var projectedTotal: Int
    public var planWindow: [String]
    public var currentMonth: String
    public var selectedMonth: String

    public var isEmpty: Bool { active.isEmpty && settled.isEmpty }

    public init(
        active: [PlanRow] = [],
        settled: [PlanRow] = [],
        watchList: [PlanRow] = [],
        baselineTotal: Int = 0,
        alreadyCut: Int = 0,
        potentialSavings: Int = 0,
        projectedTotal: Int = 0,
        planWindow: [String] = [],
        currentMonth: String = "",
        selectedMonth: String = ""
    ) {
        self.active = active
        self.settled = settled
        self.watchList = watchList
        self.baselineTotal = baselineTotal
        self.alreadyCut = alreadyCut
        self.potentialSavings = potentialSavings
        self.projectedTotal = projectedTotal
        self.planWindow = planWindow
        self.currentMonth = currentMonth
        self.selectedMonth = selectedMonth
    }

    private static let activePrefixes = ["cut", "your call", "raise"]

    public static func isActiveStatus(_ status: String) -> Bool {
        let lower = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return activePrefixes.contains { lower.hasPrefix($0) }
    }

    public static func compute(
        plan: [PlanEntry],
        planWindow: [String]?,
        totalsByMonth: [String: MonthTotals],
        selectedMonth: String,
        currentMonth: String,
        inProgressMonth: String?
    ) -> PlanSummary {
        guard !plan.isEmpty else {
            return PlanSummary(
                planWindow: planWindow ?? [],
                currentMonth: currentMonth,
                selectedMonth: selectedMonth
            )
        }

        let sortedMonths = totalsByMonth.keys.sorted()
        let windowMonths: [String]
        if let explicit = planWindow, !explicit.isEmpty {
            windowMonths = explicit
        } else {
            let completed = sortedMonths.filter { $0 != inProgressMonth }
            windowMonths = Array(completed.suffix(3))
        }

        let baselineTotal: Int
        let windowTotals = windowMonths.compactMap { totalsByMonth[$0]?.total }
        if !windowTotals.isEmpty {
            let avg = Double(windowTotals.reduce(0, +)) / Double(windowTotals.count)
            baselineTotal = Int(avg.rounded())
        } else {
            baselineTotal = plan.reduce(0) { $0 + $1.now }
        }

        var activeRows: [PlanRow] = []
        var settledRows: [PlanRow] = []

        for entry in plan {
            let isActive = isActiveStatus(entry.status)
            let tone = SubscriptionSummary.statusTone(entry.status)
            let display = SubscriptionSummary.displayStatus(entry.status) ?? entry.status

            let selectedSpent = totalsByMonth[selectedMonth]?.categories[entry.category]?.sum ?? 0
            let currentSpent = totalsByMonth[currentMonth]?.categories[entry.category]?.sum ?? 0
            let saving = entry.target.map { entry.now - $0 }
            let remaining = entry.target.map { $0 - currentSpent }

            let currentProgress: Double? = entry.target.map { cap in
                if cap <= 0 { return currentSpent > 0 ? 1.0 : 0.0 }
                return Double(max(0, currentSpent)) / Double(cap)
            }
            let selectedProgress: Double? = entry.target.map { cap in
                if cap <= 0 { return selectedSpent > 0 ? 1.0 : 0.0 }
                return Double(max(0, selectedSpent)) / Double(cap)
            }

            let isOver: Bool
            let isNear: Bool
            if let cap = entry.target {
                isOver = currentSpent > cap
                isNear = !isOver && cap > 0 && Double(currentSpent) / Double(cap) >= 0.8
            } else {
                isOver = false
                isNear = false
            }

            let history = sortedMonths.map { month in
                PlanMonthPoint(
                    month: month,
                    spent: max(0, totalsByMonth[month]?.categories[entry.category]?.sum ?? 0),
                    isSelected: month == selectedMonth,
                    isInProgress: month == inProgressMonth
                )
            }

            let row = PlanRow(
                entry: entry,
                isActive: isActive,
                tone: tone,
                displayStatus: display,
                selectedMonthSpent: selectedSpent,
                currentMonthSpent: currentSpent,
                monthlySaving: saving,
                currentMonthRemaining: remaining,
                currentMonthProgress: currentProgress,
                selectedMonthProgress: selectedProgress,
                isOverCapCurrentMonth: isOver,
                isNearCapCurrentMonth: isNear,
                history: history
            )

            if isActive {
                activeRows.append(row)
            } else {
                settledRows.append(row)
            }
        }

        let bySaving: (PlanRow, PlanRow) -> Bool = { a, b in
            let sa = a.monthlySaving ?? Int.min
            let sb = b.monthlySaving ?? Int.min
            if sa != sb { return sa > sb }
            return a.entry.category.localizedCaseInsensitiveCompare(b.entry.category) == .orderedAscending
        }
        activeRows.sort(by: bySaving)
        settledRows.sort(by: bySaving)

        // Watch list highlights active "Cut" and "Your call" caps, sorted by urgency.
        let watchList = activeRows
            .filter { row in
                guard row.entry.target != nil else { return false }
                let lower = row.entry.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return !lower.hasPrefix("raise")
            }
            .sorted { a, b in
                if a.isOverCapCurrentMonth != b.isOverCapCurrentMonth {
                    return a.isOverCapCurrentMonth
                }
                let pa = a.currentMonthProgress ?? 0
                let pb = b.currentMonthProgress ?? 0
                if abs(pa - pb) > 0.001 {
                    return pa > pb
                }
                return a.currentMonthSpent > b.currentMonthSpent
            }

        let alreadyCut = settledRows.compactMap(\.monthlySaving).reduce(0, +)
        let potential = activeRows.compactMap(\.monthlySaving).reduce(0, +)
        let projected = max(0, baselineTotal - alreadyCut - potential)

        return PlanSummary(
            active: activeRows,
            settled: settledRows,
            watchList: watchList,
            baselineTotal: baselineTotal,
            alreadyCut: alreadyCut,
            potentialSavings: potential,
            projectedTotal: projected,
            planWindow: windowMonths,
            currentMonth: currentMonth,
            selectedMonth: selectedMonth
        )
    }
}
