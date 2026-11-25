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

/// One unsettled optional borrowing or credit-room entry available before the next payday.
public struct ComingUpCreditSource: Sendable, Equatable {
    /// Full entry title from the timeline (e.g. `"Card credit: usable room"`).
    public var item: String
    /// Compact display label (text before `":"` when present, otherwise `item`).
    public var shortLabel: String
    /// Positive yen amount available (`-entry.amount`).
    public var amount: Int

    public init(item: String, shortLabel: String? = nil, amount: Int) {
        self.item = item
        self.shortLabel = shortLabel ?? Self.compactLabel(for: item)
        self.amount = amount
    }

    /// Extracts a concise source name from a timeline title (prefix before `":"` if non-empty).
    public static func compactLabel(for item: String) -> String {
        let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
        if let colon = trimmed.firstIndex(of: ":") {
            let prefix = trimmed[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
            if !prefix.isEmpty {
                return String(prefix)
            }
        }
        return trimmed
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
    /// Projected bank cash after all scheduled bills before the next payday (matches `LiveCashSummary.cashLeftUntilPayday`).
    public var cashAfterBills: Int
    /// Unsettled optional borrowing and credit-room entries available before the next payday.
    public var openCreditSources: [ComingUpCreditSource]
    /// Sum of unsettled optional borrowing / credit room before the next payday.
    public var openCreditSum: Int { openCreditSources.reduce(0) { $0 + $1.amount } }
    /// Total funds before next payday including optional borrowing / credit room (`cashAfterBills + openCreditSum`).
    public var totalWithCredit: Int { cashAfterBills + openCreditSum }
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
        cashAfterBills: Int? = nil,
        openCreditSources: [ComingUpCreditSource] = [],
        balanceAfter: [[Int?]]
    ) {
        self.cashNow = cashNow
        self.overdueUnpaidSum = overdueUnpaidSum
        self.pastPhoneHeldSum = pastPhoneHeldSum
        self.pastPendingInflowsSum = pastPendingInflowsSum
        self.startingTodayCash = startingTodayCash
        self.cashAfterBills = cashAfterBills ?? startingTodayCash
        self.openCreditSources = openCreditSources
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

        let nextPaydayDate = groups.first { group in
            group.entries.contains { $0.next == true }
        }?.date

        // Pass 1: reserve any unsettled items dated strictly before today so today's step-down
        // stays strictly aligned with LiveCashSummary.cashLeftUntilPayday.
        for group in groups where group.date < today {
            for entry in group.entries {
                guard entry.event != true, entry.borrowed != true, entry.cardBilled != true, entry.amount != 0 else {
                    continue
                }
                if BillCheckoff.matches(entry, in: alreadyCleared) { continue }
                if entry.amount > 0 {
                    if entry.done != true {
                        overdueUnpaid += entry.amount
                    } else if (entry.phoneChecked == true || BillCheckoff.matches(entry, in: phoneCheckedBillKeys)),
                              LiveCashSummary.isPhoneCheckedHoldActive(for: entry, lastPayday: lastPayday, today: today)
                    {
                        pastPhoneHeld += entry.amount
                    }
                } else if LiveCashSummary.isConfirmedPendingInflow(entry, lastPayday: lastPayday, today: today) {
                    pastPendingInflows += -entry.amount
                }
            }
        }

        let openCreditSources: [ComingUpCreditSource]
        if !liveCash.creditSources.isEmpty {
            openCreditSources = liveCash.creditSources
        } else {
            var timelineCredits: [ComingUpCreditSource] = []
            for group in groups {
                if let nextPaydayDate, group.date >= nextPaydayDate { break }
                for entry in group.entries where entry.borrowed == true && entry.done != true && entry.amount < 0 {
                    timelineCredits.append(ComingUpCreditSource(item: entry.item, amount: -entry.amount))
                }
            }
            openCreditSources = timelineCredits
        }

        let startingToday = cashNow + pastPendingInflows - overdueUnpaid - pastPhoneHeld
        var running = startingToday
        var cashBeforeNextPayday: Int?
        var matrix: [[Int?]] = []
        matrix.reserveCapacity(groups.count)

        // Pass 2: step through today and future groups in chronological order.
        for group in groups {
            if cashBeforeNextPayday == nil, let nextPaydayDate, group.date >= nextPaydayDate {
                cashBeforeNextPayday = running
            }
            if group.date < today {
                matrix.append(Array(repeating: nil, count: group.entries.count))
                continue
            }
            let isBeforeNextPayday = nextPaydayDate.map { group.date < $0 } ?? true
            var rowBalances: [Int?] = []
            rowBalances.reserveCapacity(group.entries.count)
            for entry in group.entries {
                guard entry.event != true, entry.borrowed != true, entry.cardBilled != true, entry.amount != 0 else {
                    rowBalances.append(nil)
                    continue
                }
                if BillCheckoff.matches(entry, in: alreadyCleared) {
                    rowBalances.append(nil)
                    continue
                }
                let isUnsettledPhoneCheck = entry.done == true
                    && entry.amount > 0
                    && (entry.phoneChecked == true || BillCheckoff.matches(entry, in: phoneCheckedBillKeys))
                    && LiveCashSummary.isPhoneCheckedHoldActive(for: entry, lastPayday: lastPayday, today: today)
                if entry.done == true && !isUnsettledPhoneCheck {
                    rowBalances.append(nil)
                    continue
                }
                // Keep unconfirmed estimated inflows (e.g. an unconfirmed bonus) out of guaranteed
                // pre-payday running balances so the final pre-payday line matches the hero to the yen.
                if isBeforeNextPayday && entry.amount < 0 && !LiveCashSummary.isConfirmedPendingInflow(entry, lastPayday: lastPayday, today: today) {
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
            cashAfterBills: cashBeforeNextPayday ?? running,
            openCreditSources: openCreditSources,
            balanceAfter: matrix
        )
    }
}
