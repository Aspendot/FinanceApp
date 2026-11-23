import FinanceCore
import Foundation

/// Derived view model for the Now screen, computed from `FinanceData` without mutating it.
struct NowScreenModel: Sendable {
    struct TimelineDay: Identifiable, Sendable {
        var id: String { date }
        let date: String
        let entries: [NumberedRow<TimelineEntry>]
        let isPast: Bool
        let isToday: Bool
        let hasPayday: Bool
        let isNextPayday: Bool
    }

    let payday: PaydayView?
    let lastPayday: String?
    let spentSincePayday: Int?
    let pendingSincePayday: Int
    let timelineDays: [TimelineDay]
    let recentPending: [NumberedRow<BudgetItem>]
    let pendingSpendingTotal: Int
    let debts: [DebtEntry]
    let totalDebt: Int
    let subscriptions: [SubscriptionEntry]
    let totalMonthlySubscriptions: Int

    init(data: FinanceData, today: String) {
        self.payday = data.payday
        self.lastPayday = data.lastPayday
        self.spentSincePayday = data.spentSincePayday
        self.pendingSincePayday = data.pendingSincePayday

        let nextPaydayDate = data.payday?.next.date
        var groups = data.comingUp
        if !groups.contains(where: { $0.date == today }) {
            let todayGroup = ComingUpGroup(
                date: today,
                entries: [],
                isPast: false,
                isToday: true,
                hasPayday: false
            )
            groups.append(todayGroup)
            groups.sort { $0.date < $1.date }
        }

        self.timelineDays = groups.map { group in
            let isNext = group.date == nextPaydayDate || group.entries.contains { $0.next == true }
            return TimelineDay(
                date: group.date,
                entries: NumberedRow.make(from: group.entries),
                isPast: group.date < today,
                isToday: group.date == today,
                hasPayday: group.hasPayday,
                isNextPayday: isNext
            )
        }

        let pending = data.paymentsByMonth.values
            .flatMap { $0 }
            .filter { $0.value.isPending }
            .sorted {
                if $0.value.date != $1.value.date {
                    return $0.value.date > $1.value.date
                }
                if $0.value.amount != $1.value.amount {
                    return $0.value.amount > $1.value.amount
                }
                return $0.value.merchant < $1.value.merchant
            }
        self.recentPending = pending
        self.pendingSpendingTotal = pending
            .filter { data.layer(of: $0.value) != nil }
            .reduce(0) { $0 + $1.value.amount }

        self.debts = data.bundle.debts
        self.totalDebt = data.bundle.debts.reduce(0) { $0 + $1.balance }

        self.subscriptions = data.bundle.subs.sorted {
            if $0.monthly != $1.monthly {
                return $0.monthly > $1.monthly
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        self.totalMonthlySubscriptions = data.bundle.subs.reduce(0) { $0 + $1.monthly }
    }
}
