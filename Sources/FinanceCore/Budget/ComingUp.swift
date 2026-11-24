import Foundation

/// Timeline entries grouped under a single "YYYY-MM-DD" date.
public struct ComingUpGroup: Codable, Sendable, Equatable {
    public var date: String
    public var entries: [TimelineEntry]
    public var isPast: Bool
    public var isToday: Bool
    public var hasPayday: Bool

    public init(
        date: String,
        entries: [TimelineEntry],
        isPast: Bool,
        isToday: Bool,
        hasPayday: Bool
    ) {
        self.date = date
        self.entries = entries
        self.isPast = isPast
        self.isToday = isToday
        self.hasPayday = hasPayday
    }
}

/// Running bank-cash balance projection across chronological `ComingUpGroup` entries starting from today.
public struct ComingUpRunningBalance: Sendable, Equatable {
    /// Current live bank cash right now (before reserving unsettled overdue bills).
    public var cashNow: Int
    /// Unsettled overdue bills dated strictly before `today` (still in bank cash, reserved before today's bills).
    public var overdueUnpaidSum: Int
    /// Past-dated bills marked paid only on the phone whose bank debit has not cleared yet.
    public var pastPhoneHeldSum: Int
    /// Total past unsettled holds subtracted before today's bills (`overdueUnpaidSum + pastPhoneHeldSum`).
    public var priorHeldSum: Int { overdueUnpaidSum + pastPhoneHeldSum }
    /// Expected past non-borrowed inflows in this cycle not yet marked received.
    public var pastPendingInflowsSum: Int
    /// Available bank cash entering today's scheduled bills (`cashNow + pastPendingInflowsSum - priorHeldSum`).
    public var startingTodayCash: Int
    /// Projected balance immediately after each entry at `balanceAfter[groupIndex][entryIndex]`,
    /// or `nil` for entries that do not move bank cash from today onward (past paid items, events,
    /// card-billed renewals, or optional borrowing).
    public var balanceAfter: [[Int?]]

    public init(
        cashNow: Int,
        overdueUnpaidSum: Int,
        pastPhoneHeldSum: Int,
        pastPendingInflowsSum: Int = 0,
        startingTodayCash: Int,
        balanceAfter: [[Int?]]
    ) {
        self.cashNow = cashNow
        self.overdueUnpaidSum = overdueUnpaidSum
        self.pastPhoneHeldSum = pastPhoneHeldSum
        self.pastPendingInflowsSum = pastPendingInflowsSum
        self.startingTodayCash = startingTodayCash
        self.balanceAfter = balanceAfter
    }
}

/// Groups timeline entries by day in ascending chronological order.
public enum ComingUp {
    /// Groups `timeline` by date ascending, preserving entry order within each day.
    public static func groups(timeline: [TimelineEntry], today: String) -> [ComingUpGroup] {
        var byDate: [String: [TimelineEntry]] = [:]
        for entry in timeline {
            byDate[entry.date, default: []].append(entry)
        }
        return byDate.keys.sorted().map { date in
            let entries = byDate[date] ?? []
            return ComingUpGroup(
                date: date,
                entries: entries,
                isPast: date < today,
                isToday: date == today,
                hasPayday: entries.contains { $0.payday == true }
            )
        }
    }

    /// Convenience overload converting a `Date` to a Japan-time "YYYY-MM-DD" day.
    public static func groups(timeline: [TimelineEntry], today: Date) -> [ComingUpGroup] {
        groups(timeline: timeline, today: JST.day(today))
    }

    /// Computes today's starting bank cash and the remaining balance after each unsettled cash
    /// payment or inflow from `today` onward, matching `LiveCashSummary.cashLeftUntilPayday` to the yen.
    public static func runningBalances(
        groups: [ComingUpGroup],
        today: String,
        liveCash: LiveCashSummary?,
        phoneCheckedBillKeys: Set<String> = [],
        lastPayday: String? = nil
    ) -> ComingUpRunningBalance? {
        guard let liveCash else { return nil }

        let cashNow = liveCash.estimatedBankCash
        let alreadyCleared = liveCash.postBalanceMatchedKeys
        var overdueUnpaid = 0
        var pastPhoneHeld = 0
        var pastPendingInflows = 0

        // Pass 1: reserve any unsettled items dated strictly before today so today's step-down
        // stays strictly aligned with LiveCashSummary.cashLeftUntilPayday.
        for group in groups where group.date < today {
            for entry in group.entries {
                guard entry.event != true, entry.borrowed != true, entry.cardBilled != true, entry.amount != 0 else {
                    continue
                }
                let key = BillCheckoff.key(for: entry)
                if alreadyCleared.contains(key) { continue }
                if entry.amount > 0 {
                    if entry.done != true {
                        overdueUnpaid += entry.amount
                    } else if phoneCheckedBillKeys.contains(key),
                              (lastPayday == nil || entry.date >= lastPayday!)
                    {
                        pastPhoneHeld += entry.amount
                    }
                } else if entry.amount < 0, entry.done != true,
                          (lastPayday == nil || entry.date >= lastPayday!)
                {
                    pastPendingInflows += -entry.amount
                }
            }
        }

        let startingToday = cashNow + pastPendingInflows - overdueUnpaid - pastPhoneHeld
        var running = startingToday
        var matrix: [[Int?]] = []
        matrix.reserveCapacity(groups.count)

        // Pass 2: step through today and future groups in chronological order.
        for group in groups {
            if group.date < today {
                matrix.append(Array(repeating: nil, count: group.entries.count))
                continue
            }
            var rowBalances: [Int?] = []
            rowBalances.reserveCapacity(group.entries.count)
            for entry in group.entries {
                guard entry.event != true, entry.borrowed != true, entry.cardBilled != true, entry.amount != 0 else {
                    rowBalances.append(nil)
                    continue
                }
                let key = BillCheckoff.key(for: entry)
                if alreadyCleared.contains(key) {
                    rowBalances.append(nil)
                    continue
                }
                let isUnsettledPhoneCheck = entry.done == true
                    && entry.amount > 0
                    && phoneCheckedBillKeys.contains(key)
                    && (lastPayday == nil || entry.date >= lastPayday!)
                if entry.done == true && !isUnsettledPhoneCheck {
                    rowBalances.append(nil)
                    continue
                }
                running -= entry.amount
                rowBalances.append(running)
            }
            matrix.append(rowBalances)
        }

        return ComingUpRunningBalance(
            cashNow: cashNow,
            overdueUnpaidSum: overdueUnpaid,
            pastPhoneHeldSum: pastPhoneHeld,
            pastPendingInflowsSum: pastPendingInflows,
            startingTodayCash: startingToday,
            balanceAfter: matrix
        )
    }
}
