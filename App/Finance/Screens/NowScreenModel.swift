import FinanceCore
import Foundation

/// Derived view model for the Now screen, computed from `FinanceData` without mutating it.
struct NowScreenModel: Sendable {
    struct TimelineRowItem: Identifiable, Sendable {
        var id: NumberedRow<TimelineEntry>.ID { row.id }
        let row: NumberedRow<TimelineEntry>
        var value: TimelineEntry { row.value }
        /// Projected bank cash remaining immediately after this payment/inflow, when applicable.
        let remainingBalance: Int?
    }

    struct TimelineDay: Identifiable, Sendable {
        var id: String { date }
        let date: String
        let monthKey: String
        let showsMonthHeader: Bool
        let label: String?
        let entries: [TimelineRowItem]
        let isPast: Bool
        let isToday: Bool
        let hasPayday: Bool
        let isNextPayday: Bool
    }

    let alerts: [FinanceAlert]
    let reviewQueueCount: Int
    let activePeriodPace: Double?
    let payday: PaydayView?
    let paydayBreakdown: PaydayBreakdown?
    let liveCash: LiveCashSummary?
    let todayCashBalance: ComingUpRunningBalance?
    let lastPayday: String?
    let spentSincePayday: Int?
    let pendingSincePayday: Int
    let watchList: [PlanRow]
    let timelineDays: [TimelineDay]
    let phoneCheckedBillKeys: Set<String>
    let afterNote: String?
    let recentPending: [NumberedRow<BudgetItem>]
    let pendingSpendingTotal: Int
    let debts: [DebtEntry]
    let totalDebt: Int
    let notes: [String]
    let subscriptionSummary: SubscriptionSummary

    init(data: FinanceData, today: String) {
        self.alerts = data.alerts
        self.reviewQueueCount = data.reviewQueue.count
        self.activePeriodPace = data.currentPeriod(for: .calendarMonth, today: today)?.paceProgress(on: today)
        self.payday = data.payday
        self.paydayBreakdown = data.paydayBreakdown
        self.liveCash = data.liveCash
        self.lastPayday = data.lastPayday
        self.spentSincePayday = data.spentSincePayday
        self.pendingSincePayday = data.pendingSincePayday
        self.watchList = data.planSummary.watchList
        self.phoneCheckedBillKeys = data.phoneCheckedBillKeys
        self.afterNote = data.bundle.afterNote

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

        let runningProjection = ComingUp.runningBalances(
            groups: groups,
            today: today,
            liveCash: data.liveCash,
            phoneCheckedBillKeys: data.phoneCheckedBillKeys,
            lastPayday: data.lastPayday
        )
        self.todayCashBalance = runningProjection

        var lastMonthKey: String? = nil
        var builtDays: [TimelineDay] = []
        for (gIdx, group) in groups.enumerated() {
            let mKey = String(group.date.prefix(7))
            let showHeader = (lastMonthKey != nil && lastMonthKey != mKey) || (lastMonthKey == nil && groups.count > 1)
            lastMonthKey = mKey
            let isNext = group.date == nextPaydayDate || group.entries.contains { $0.next == true }
            let dayLabel = group.entries.compactMap(\.label).first { !$0.isEmpty }
            let numbered = NumberedRow.make(from: group.entries)
            let groupBalances = runningProjection?.balanceAfter[gIdx]
            let rowItems = numbered.enumerated().map { eIdx, row in
                TimelineRowItem(
                    row: row,
                    remainingBalance: groupBalances?[eIdx]
                )
            }
            builtDays.append(TimelineDay(
                date: group.date,
                monthKey: mKey,
                showsMonthHeader: showHeader,
                label: dayLabel,
                entries: rowItems,
                isPast: group.date < today,
                isToday: group.date == today,
                hasPayday: group.hasPayday,
                isNextPayday: isNext
            ))
        }
        self.timelineDays = builtDays

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

        self.debts = data.effectiveDebts
        self.totalDebt = data.effectiveDebts.reduce(0) { $0 + $1.balance }
        self.notes = data.bundle.notes ?? []
        self.subscriptionSummary = data.subscriptionSummary
    }
}
