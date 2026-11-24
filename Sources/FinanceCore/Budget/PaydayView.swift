import Foundation

/// Cashflow summary for the current period leading up to the next payday.
public struct PaydayView: Codable, Sendable, Equatable {
    /// Total money in (`-sum` of `ins`).
    public var inSum: Int
    /// Total money out (`sum` of `outs`).
    public var outSum: Int
    /// Total borrowed money (`-sum` of `borrowed`).
    public var borrowedSum: Int
    /// Remaining cash before borrowing (`inSum - outSum`).
    public var left: Int
    /// Remaining cash including borrowed funds (`left + borrowedSum`).
    public var leftIfBorrowed: Int
    /// Whole Japan-time calendar days from `today` to `next.date`.
    public var daysToPayday: Int
    public var ins: [TimelineEntry]
    public var outs: [TimelineEntry]
    public var borrowed: [TimelineEntry]
    public var next: TimelineEntry

    public init(
        inSum: Int,
        outSum: Int,
        borrowedSum: Int,
        left: Int,
        leftIfBorrowed: Int,
        daysToPayday: Int,
        ins: [TimelineEntry],
        outs: [TimelineEntry],
        borrowed: [TimelineEntry],
        next: TimelineEntry
    ) {
        self.inSum = inSum
        self.outSum = outSum
        self.borrowedSum = borrowedSum
        self.left = left
        self.leftIfBorrowed = leftIfBorrowed
        self.daysToPayday = daysToPayday
        self.ins = ins
        self.outs = outs
        self.borrowed = borrowed
        self.next = next
    }

    /// Computes the payday view up to the first entry marked `next == true`.
    /// Returns nil when no entry is marked `next == true` or either date is invalid.
    public static func compute(timeline: [TimelineEntry], today: String) -> PaydayView? {
        guard let next = timeline.first(where: { $0.next == true }),
              let nextDay = JST.dayNumber(next.date),
              let todayDay = JST.dayNumber(today)
        else {
            return nil
        }

        let period = timeline.filter { $0.next != true && $0.date < next.date }
        let ins = period.filter { $0.amount < 0 && $0.borrowed != true && $0.cardBilled != true }
        let outs = period.filter { $0.amount > 0 && $0.cardBilled != true }
        let borrowed = period.filter { $0.borrowed == true }

        let inSum = -ins.reduce(0) { $0 + $1.amount }
        let outSum = outs.reduce(0) { $0 + $1.amount }
        let borrowedSum = -borrowed.reduce(0) { $0 + $1.amount }
        let left = inSum - outSum
        let leftIfBorrowed = left + borrowedSum

        return PaydayView(
            inSum: inSum,
            outSum: outSum,
            borrowedSum: borrowedSum,
            left: left,
            leftIfBorrowed: leftIfBorrowed,
            daysToPayday: nextDay - todayDay,
            ins: ins,
            outs: outs,
            borrowed: borrowed,
            next: next
        )
    }

    /// Convenience overload converting a `Date` to a Japan-time "YYYY-MM-DD" day.
    public static func compute(timeline: [TimelineEntry], today: Date) -> PaydayView? {
        compute(timeline: timeline, today: JST.day(today))
    }

    /// Sums layered spending items dated on or after `day` ("YYYY-MM-DD").
    ///
    /// When `config` is nil, an item counts if its `layer` is non-nil and non-empty.
    /// Pass `config` (and optionally `layers`) to resolve layers for items whose `layer`
    /// field was omitted in the bundle.
    public static func spentSince(
        day: String,
        items: [BudgetItem],
        config: LayerConfig? = nil,
        layers: [LayerDefinition] = []
    ) -> Int {
        var total = 0
        for item in items where item.date >= day {
            let resolved: String?
            if let config {
                resolved = config.resolvedLayer(for: item, layers: layers)
            } else {
                resolved = item.layer.flatMap { $0.isEmpty ? nil : $0 }
            }
            if resolved != nil {
                total += item.amount
            }
        }
        return total
    }
}

/// Live estimated balance for one bank account after post-coverage bank rows and unsettled debit notices.
public struct LiveAccountBalance: Identifiable, Sendable, Equatable {
    public var id: String { source }
    public var source: String
    public var label: String
    /// Confirmed balance exported by the PC pipeline as of `asOf`.
    public var confirmedBalance: Int
    /// Last statement date included in `confirmedBalance`.
    public var asOf: String
    /// Net change from confirmed post-coverage bank rows (`in - out`).
    public var postCoverageDelta: Int
    /// Net outflow from unsettled debit-card email notices linked to this bank account.
    public var pendingDebitOutflow: Int
    /// Live estimated balance (`confirmedBalance + postCoverageDelta - pendingDebitOutflow`).
    public var estimatedBalance: Int

    public init(
        source: String,
        label: String,
        confirmedBalance: Int,
        asOf: String,
        postCoverageDelta: Int,
        pendingDebitOutflow: Int,
        estimatedBalance: Int
    ) {
        self.source = source
        self.label = label
        self.confirmedBalance = confirmedBalance
        self.asOf = asOf
        self.postCoverageDelta = postCoverageDelta
        self.pendingDebitOutflow = pendingDebitOutflow
        self.estimatedBalance = estimatedBalance
    }
}

/// Single source of truth for real bank cash on hand and cash left until next payday after unpaid bills.
public struct LiveCashSummary: Sendable, Equatable {
    public var accounts: [LiveAccountBalance]
    /// Sum of confirmed bank balances from the bundle.
    public var confirmedBankCash: Int
    /// Sum of live estimated bank balances after post-coverage bank rows and pending debit notices.
    public var estimatedBankCash: Int
    /// Total unsettled debit-card email notices already subtracted from `estimatedBankCash`.
    public var pendingDebitOutflow: Int
    /// Scheduled bills before next payday that have not yet been paid (`done != true`).
    public var remainingBillsSum: Int
    public var remainingBillsCount: Int
    /// Scheduled bills marked paid only on the phone (no bank row yet), held back from cash left so checking
    /// a bill off manually never creates phantom extra cash before the bank debit posts.
    public var phoneCheckedBillsSum: Int
    /// Total scheduled bills still expected to leave bank accounts (`remainingBillsSum + phoneCheckedBillsSum`).
    public var unsettledBillsSum: Int { remainingBillsSum + phoneCheckedBillsSum }
    /// Expected non-borrowed inflows before next payday not yet received (`done != true`).
    public var remainingInflowsSum: Int
    /// Optional credit/borrowing headroom before next payday not yet drawn (`done != true`).
    public var openBorrowedSum: Int
    /// Estimated cash left in banks until next payday after all unsettled bills (`estimatedBankCash + remainingInflowsSum - unsettledBillsSum`).
    public var cashLeftUntilPayday: Int
    /// Cash left if optional credit headroom were used (`cashLeftUntilPayday + openBorrowedSum`).
    public var cashLeftIfBorrowed: Int
    /// True whenever pending debit notices, post-coverage rows, phone checkoffs, or estimate bills are involved.
    public var isEstimate: Bool

    public init(
        accounts: [LiveAccountBalance],
        confirmedBankCash: Int,
        estimatedBankCash: Int,
        pendingDebitOutflow: Int,
        remainingBillsSum: Int,
        remainingBillsCount: Int,
        phoneCheckedBillsSum: Int,
        remainingInflowsSum: Int,
        openBorrowedSum: Int,
        cashLeftUntilPayday: Int,
        cashLeftIfBorrowed: Int,
        isEstimate: Bool
    ) {
        self.accounts = accounts
        self.confirmedBankCash = confirmedBankCash
        self.estimatedBankCash = estimatedBankCash
        self.pendingDebitOutflow = pendingDebitOutflow
        self.remainingBillsSum = remainingBillsSum
        self.remainingBillsCount = remainingBillsCount
        self.phoneCheckedBillsSum = phoneCheckedBillsSum
        self.remainingInflowsSum = remainingInflowsSum
        self.openBorrowedSum = openBorrowedSum
        self.cashLeftUntilPayday = cashLeftUntilPayday
        self.cashLeftIfBorrowed = cashLeftIfBorrowed
        self.isEstimate = isEstimate
    }

    public static func compute(
        accountBalances: [AccountBalance],
        sourceLabels: [String: String],
        bankRows: [TimelineReconciler.BankRow],
        pendingItems: [BudgetItem],
        payday: PaydayView?,
        phoneCheckedBillKeys: Set<String> = [],
        lastPayday: String? = nil
    ) -> LiveCashSummary? {
        guard !accountBalances.isEmpty else { return nil }

        var liveAccounts: [LiveAccountBalance] = []
        var anyPostCoverageRows = false
        var postBalanceOutflows: [(dayNum: Int, amount: Int)] = []

        for account in accountBalances {
            let resolvedLabel = sourceLabels[account.source] ?? account.label
            let bankNames: Set<String> = [account.source, account.label, resolvedLabel]

            // BankRow uses positive = money out, negative = money in.
            let matchingBankRows = bankRows.filter { row in
                row.date > account.asOf && bankNames.contains(row.source)
            }
            if !matchingBankRows.isEmpty {
                anyPostCoverageRows = true
                for row in matchingBankRows where row.amount > 0 {
                    if let dayNum = JST.dayNumber(row.date) {
                        postBalanceOutflows.append((dayNum, row.amount))
                    }
                }
            }
            let postDelta = -matchingBankRows.reduce(0) { $0 + $1.amount }

            // Only unsettled debit-card notices linked to this bank reduce bank cash immediately.
            // Deferred credit cards are paid via their scheduled monthly bills instead.
            var debitSourceNames = Set<String>()
            for rawKey in account.debitNoticeSources ?? [] where !rawKey.isEmpty {
                debitSourceNames.insert(rawKey)
                if let label = sourceLabels[rawKey], !label.isEmpty {
                    debitSourceNames.insert(label)
                }
            }
            let pendingOutflow: Int
            if debitSourceNames.isEmpty {
                pendingOutflow = 0
            } else {
                pendingOutflow = pendingItems
                    .filter { item in
                        item.isPending
                            && item.date >= account.asOf
                            && debitSourceNames.contains(item.source)
                    }
                    .reduce(0) { $0 + $1.amount }
            }

            let estimated = account.balance + postDelta - pendingOutflow
            liveAccounts.append(LiveAccountBalance(
                source: account.source,
                label: account.label,
                confirmedBalance: account.balance,
                asOf: account.asOf,
                postCoverageDelta: postDelta,
                pendingDebitOutflow: pendingOutflow,
                estimatedBalance: estimated
            ))
        }

        let confirmedTotal = liveAccounts.reduce(0) { $0 + $1.confirmedBalance }
        let estimatedTotal = liveAccounts.reduce(0) { $0 + $1.estimatedBalance }
        let totalPendingDebit = liveAccounts.reduce(0) { $0 + $1.pendingDebitOutflow }

        // Release a phone-only bill checkoff hold once a post-asOf bank outflow of the exact same
        // positive amount has posted near the bill's date, avoiding double-subtraction.
        var availablePostOutflows = postBalanceOutflows
        func consumeMatchingPostOutflow(for entry: TimelineEntry) -> Bool {
            guard entry.amount > 0, let entryDay = JST.dayNumber(entry.date) else { return false }
            if let idx = availablePostOutflows.firstIndex(where: {
                $0.amount == entry.amount && (-2...5).contains($0.dayNum - entryDay)
            }) {
                availablePostOutflows.remove(at: idx)
                return true
            }
            return false
        }

        let remainingBills = (payday?.outs ?? []).filter { entry in
            guard entry.done != true else { return false }
            // If an unpaid bill without a match rule already posted as an exact-amount post-asOf bank row,
            // avoid double-subtracting it from estimated bank cash.
            if entry.match == nil, consumeMatchingPostOutflow(for: entry) {
                return false
            }
            return true
        }
        let remainingBillsSum = remainingBills.reduce(0) { $0 + $1.amount }
        let phoneCheckedBills = (payday?.outs ?? []).filter { entry in
            guard entry.done == true, phoneCheckedBillKeys.contains(BillCheckoff.key(for: entry)) else {
                return false
            }
            // Ignore checked-off reminders left over from previous pay cycles.
            if let lastPayday, entry.date < lastPayday {
                return false
            }
            // Once the debit actually posts after account.asOf, release the temporary phone hold.
            if consumeMatchingPostOutflow(for: entry) {
                return false
            }
            return true
        }
        let phoneCheckedSum = phoneCheckedBills.reduce(0) { $0 + $1.amount }

        let remainingInflows = payday?.ins.filter { entry in
            guard entry.done != true && entry.borrowed != true else { return false }
            if let lastPayday, entry.date < lastPayday { return false }
            return true
        } ?? []
        let remainingInflowsSum = -remainingInflows.reduce(0) { $0 + $1.amount }

        let openBorrowed = payday?.borrowed.filter { $0.done != true } ?? []
        let openBorrowedSum = -openBorrowed.reduce(0) { $0 + $1.amount }

        let cashLeft = estimatedTotal + remainingInflowsSum - remainingBillsSum - phoneCheckedSum
        let hasEstimateLine = remainingBills.contains { $0.estimate == true }
            || remainingInflows.contains { $0.estimate == true }
        let isEstimate = totalPendingDebit != 0 || anyPostCoverageRows || phoneCheckedSum != 0 || hasEstimateLine

        return LiveCashSummary(
            accounts: liveAccounts,
            confirmedBankCash: confirmedTotal,
            estimatedBankCash: estimatedTotal,
            pendingDebitOutflow: totalPendingDebit,
            remainingBillsSum: remainingBillsSum,
            remainingBillsCount: remainingBills.count,
            phoneCheckedBillsSum: phoneCheckedSum,
            remainingInflowsSum: remainingInflowsSum,
            openBorrowedSum: openBorrowedSum,
            cashLeftUntilPayday: cashLeft,
            cashLeftIfBorrowed: cashLeft + openBorrowedSum,
            isEstimate: isEstimate
        )
    }
}
