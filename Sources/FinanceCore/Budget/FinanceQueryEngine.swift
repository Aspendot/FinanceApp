import Foundation

/// A single key-value breakdown line inside an on-device financial answer.
public struct QueryAnswerRow: Sendable, Equatable, Identifiable {
    public var id: String { "\(label)|\(value)|\(detail ?? "")" }
    public var label: String
    public var value: String
    public var detail: String?

    public init(label: String, value: String, detail: String? = nil) {
        self.label = label
        self.value = value
        self.detail = detail
    }
}

/// Exact, zero-hallucination answer produced by `FinanceQueryEngine`.
public struct QueryAnswer: Sendable, Equatable {
    public enum Action: Sendable, Equatable {
        case openPayments(month: String?, category: String?, query: String?, source: String? = nil)
        case openMonths(month: String?)
        case openNow
    }

    public var headline: String
    public var subtitle: String
    public var rows: [QueryAnswerRow]
    public var note: String?
    public var actionTitle: String?
    public var action: Action?

    public init(
        headline: String,
        subtitle: String,
        rows: [QueryAnswerRow] = [],
        note: String? = nil,
        actionTitle: String? = nil,
        action: Action? = nil
    ) {
        self.headline = headline
        self.subtitle = subtitle
        self.rows = rows
        self.note = note
        self.actionTitle = actionTitle
        self.action = action
    }
}

/// Deterministic, offline financial question engine operating directly on the exact yen ledger.
///
/// Every number comes straight from `BudgetItem`, `MonthTotals`, `PaydayView`, `PlanSummary`,
/// `SubscriptionSummary`, and `DebtEntry`—never estimated unless explicitly labelled.
public enum FinanceQueryEngine {
    public struct Context: Sendable {
        public var bundle: DataBundle
        public var allItems: [BudgetItem]
        public var totalsByMonth: [String: MonthTotals]
        public var timeline: [TimelineEntry]
        public var payday: PaydayView?
        public var liveCash: LiveCashSummary?
        public var effectiveDebts: [DebtEntry]?
        public var planSummary: PlanSummary
        public var subscriptionSummary: SubscriptionSummary
        public var today: String

        public init(
            bundle: DataBundle,
            allItems: [BudgetItem],
            totalsByMonth: [String: MonthTotals],
            timeline: [TimelineEntry],
            payday: PaydayView?,
            liveCash: LiveCashSummary? = nil,
            effectiveDebts: [DebtEntry]? = nil,
            planSummary: PlanSummary,
            subscriptionSummary: SubscriptionSummary,
            today: String
        ) {
            self.bundle = bundle
            self.allItems = allItems
            self.totalsByMonth = totalsByMonth
            self.timeline = timeline
            self.payday = payday
            self.liveCash = liveCash
            self.effectiveDebts = effectiveDebts
            self.planSummary = planSummary
            self.subscriptionSummary = subscriptionSummary
            self.today = today
        }
    }

    /// Suggested quick prompts adapted to the data present in `context`.
    public static func suggestedPrompts(for context: Context) -> [String] {
        var prompts = [
            "How much is left until payday?",
            "What bills are still unpaid?",
            "Where did my money go this month?",
        ]
        if !context.planSummary.isEmpty {
            prompts.append("How am I doing on my cut targets?")
        }
        if !context.bundle.debts.isEmpty {
            prompts.append("How much debt do I owe?")
        }
        if !context.subscriptionSummary.isEmpty {
            prompts.append("What subscriptions am I paying?")
        }
        let months = context.totalsByMonth.keys.sorted()
        if months.count >= 2 {
            let prev = months[months.count - 2]
            prompts.append("Compare \(monthShortName(prev)) and \(monthShortName(months.last!))")
        }
        return prompts
    }

    /// Answers a plain-English question strictly from the local ledger.
    public static func answer(_ rawQuestion: String, context: Context) -> QueryAnswer {
        let question = rawQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else {
            return helpAnswer(context: context)
        }
        let lower = question.lowercased()
        let sortedMonths = context.totalsByMonth.keys.sorted()
        let currentMonth = sortedMonths.last ?? String(context.today.prefix(7))
        let resolvedMonths = extractMonths(from: lower, availableMonths: sortedMonths, today: context.today)
        let isAllTime = lower.contains("all time") || lower.contains("all-time") || containsWord("ever", in: lower)
            || containsWord("overall", in: lower) || lower.contains("all months")
        let targetMonth: String? = isAllTime ? nil : (resolvedMonths.first ?? nil)

        // 1. Compare two months.
        if (containsWord("compare", in: lower) || lower.contains(" vs ") || containsWord("versus", in: lower)),
           resolvedMonths.count >= 2
        {
            return compareMonthsAnswer(m1: resolvedMonths[0], m2: resolvedMonths[1], context: context)
        }

        // 2. Unpaid / upcoming bills before generic payday overview so "Which bills are due before payday?"
        //    returns the itemized bill list, while "How much is left after bills?" stays on the payday summary.
        let asksCashRemaining = (lower.contains("how much") || lower.contains("cash"))
            && (containsWord("left", in: lower) || containsWord("remaining", in: lower))
            && !lower.contains("which") && !lower.contains("what bill")
        if !asksCashRemaining,
           (containsWord("bill", in: lower) || containsWord("bills", in: lower)),
           (lower.contains("unpaid") || containsWord("due", in: lower) || containsWord("left", in: lower)
               || lower.contains("coming") || lower.contains("upcoming") || containsWord("next", in: lower)
               || containsWord("remaining", in: lower))
        {
            return upcomingBillsAnswer(context: context)
        }
        if lower.contains("payday") || lower.contains("left until") || asksCashRemaining {
            return paydayAnswer(context: context)
        }

        // 3. Debt.
        if containsWord("debt", in: lower) || containsWord("debts", in: lower)
            || containsWord("owe", in: lower) || containsWord("owed", in: lower)
            || containsWord("loan", in: lower) || containsWord("loans", in: lower)
            || lower.contains("revolving")
        {
            return debtAnswer(context: context)
        }

        // 4. Subscriptions.
        if lower.contains("subscription") || containsWord("subs", in: lower) || lower.contains("recurring") {
            return subscriptionsAnswer(context: context)
        }

        // 5. Cut targets / budget plan.
        if containsWord("target", in: lower) || containsWord("targets", in: lower)
            || containsWord("cut", in: lower) || containsWord("cuts", in: lower)
            || containsWord("budget", in: lower) || containsWord("plan", in: lower)
            || containsWord("cap", in: lower) || containsWord("caps", in: lower)
        {
            return targetsAnswer(context: context)
        }

        // 6. Income / salary.
        if lower.contains("income") || lower.contains("salary") || lower.contains("earned") || lower.contains("bonus") {
            return incomeAnswer(month: targetMonth ?? currentMonth, allTime: isAllTime, context: context)
        }

        // 7. Specific category match.
        let allCategories = Array(Set(context.allItems.map(\.category))).sorted { $0.count > $1.count }
        if let matchedCategory = matchCategory(in: lower, categories: allCategories) {
            return categoryAnswer(
                category: matchedCategory,
                month: targetMonth,
                defaultMonth: currentMonth,
                allTime: isAllTime,
                context: context
            )
        }

        // 8. Specific source/card match.
        let allSources = Array(Set(context.allItems.map(\.source))).sorted { $0.count > $1.count }
        if let matchedSource = matchSource(in: lower, sources: allSources) {
            return sourceAnswer(
                source: matchedSource,
                month: targetMonth,
                defaultMonth: currentMonth,
                allTime: isAllTime,
                context: context
            )
        }

        // 9. Top categories / biggest expenses / "where did my money go".
        if lower.contains("biggest") || lower.contains("largest") || lower.contains("top")
            || lower.contains("where") || lower.contains("most")
        {
            if lower.contains("merchant") || lower.contains("shop") || lower.contains("store") {
                return topMerchantsAnswer(month: targetMonth ?? (isAllTime ? nil : currentMonth), context: context)
            }
            if lower.contains("payment") || lower.contains("purchase") || lower.contains("expense") || lower.contains("item") {
                return largestPaymentsAnswer(month: targetMonth ?? (isAllTime ? nil : currentMonth), context: context)
            }
            return whereItWentAnswer(month: targetMonth ?? currentMonth, context: context)
        }

        // 10. Specific month spending summary.
        if let explicitMonth = resolvedMonths.first,
           (lower.contains("spend") || lower.contains("spent") || lower.contains("total") || lower.contains("how much") || lower.contains("summary"))
        {
            return whereItWentAnswer(month: explicitMonth, context: context)
        }

        // 11. Merchant search fallback (match tokens against actual merchant names in the ledger).
        if let merchantHit = merchantSearchAnswer(rawQuestion: question, month: targetMonth, context: context) {
            return merchantHit
        }

        // 12. General spending question for current month.
        if lower.contains("spend") || lower.contains("spent") || lower.contains("how much") || lower.contains("total") {
            return whereItWentAnswer(month: targetMonth ?? currentMonth, context: context)
        }

        return helpAnswer(context: context)
    }

    private static func containsWord(_ word: String, in lowerText: String) -> Bool {
        let pattern = "(?<![a-z0-9])" + NSRegularExpression.escapedPattern(for: word) + "(?![a-z0-9])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return lowerText.contains(word) }
        return regex.firstMatch(in: lowerText, range: NSRange(lowerText.startIndex..<lowerText.endIndex, in: lowerText)) != nil
    }

    // MARK: - Specific answer builders

    @inline(never)
    private static func latestPaydayDate(in timeline: [TimelineEntry], today: String) -> String? {
        var latest: String?
        for entry in timeline {
            guard entry.payday == true else { continue }
            guard entry.done == true || entry.date < today else { continue }
            if let current = latest {
                if entry.date > current { latest = entry.date }
            } else {
                latest = entry.date
            }
        }
        return latest
    }

    @inline(never)
    private static func livePaydayAnswer(
        payday: PaydayView,
        live: LiveCashSummary,
        breakdown: PaydayBreakdown
    ) -> QueryAnswer {
        var rows = [
            QueryAnswerRow(label: "Estimated cash in banks", value: formatYen(live.estimatedBankCash)),
            QueryAnswerRow(
                label: "Unpaid bills left",
                value: formatYen(live.remainingBillsSum),
                detail: "\(live.remainingBillsCount) left"
            ),
        ]
        if live.phoneCheckedBillsSum > 0 {
            rows.append(QueryAnswerRow(
                label: "Marked paid on phone",
                value: formatYen(live.phoneCheckedBillsSum),
                detail: "Awaiting bank debit"
            ))
        }
        if live.remainingInflowsSum > 0 {
            rows.append(QueryAnswerRow(label: "Expected inflows", value: signedYen(live.remainingInflowsSum)))
        }
        if live.estimatedInflowsSum > 0 {
            rows.append(QueryAnswerRow(label: "Estimated inflows (not counted)", value: signedYen(live.estimatedInflowsSum), detail: "Unconfirmed"))
        }
        rows.append(QueryAnswerRow(label: "Day-to-day spent since payday", value: formatYen(breakdown.dayToDaySpentSincePayday)))
        rows.append(QueryAnswerRow(label: "Cycle budget (income − bills)", value: formatYen(payday.left)))
        if live.openBorrowedSum > 0 {
            rows.append(QueryAnswerRow(label: "Left if credit room used", value: formatYen(live.cashLeftIfBorrowed)))
        }
        return QueryAnswer(
            headline: formatYen(live.cashLeftUntilPayday),
            subtitle: "Bank cash after unpaid bills · \(payday.daysToPayday) days to \(payday.next.date)",
            rows: rows,
            note: live.isEstimate ? "Estimate based on latest confirmed bank balances, post-balance bank rows, and unsettled debit notices." : nil,
            actionTitle: "Open Now",
            action: .openNow
        )
    }

    private static func paydayAnswer(context: Context) -> QueryAnswer {
        guard let payday = context.payday else {
            return QueryAnswer(
                headline: "No upcoming payday",
                subtitle: "No next payday entry is marked in the current timeline.",
                actionTitle: "Open Now",
                action: .openNow
            )
        }
        let breakdown = SpendingInsights.paydayBreakdown(
            payday: payday,
            lastPayday: latestPaydayDate(in: context.timeline, today: context.today),
            items: context.allItems,
            config: context.bundle.layerConfig,
            layers: context.bundle.layers
        )
        if let live = context.liveCash {
            return livePaydayAnswer(payday: payday, live: live, breakdown: breakdown)
        }
        var rows = [
            QueryAnswerRow(label: "Money in", value: signedYen(payday.inSum)),
            QueryAnswerRow(label: "Bills paid", value: formatYen(breakdown.paidBillsSum), detail: "\(breakdown.paidBillsCount) paid"),
            QueryAnswerRow(label: "Bills still due", value: formatYen(breakdown.remainingBillsSum), detail: "\(breakdown.remainingBillsCount) left"),
            QueryAnswerRow(label: "Day-to-day spent since payday", value: formatYen(breakdown.dayToDaySpentSincePayday)),
            QueryAnswerRow(label: "Estimated remaining discretionary", value: formatYen(breakdown.estimatedRemainingDiscretionary), detail: "Estimate"),
        ]
        if payday.borrowedSum > 0 {
            rows.append(QueryAnswerRow(label: "Left if borrowed", value: formatYen(payday.leftIfBorrowed)))
        }
        return QueryAnswer(
            headline: formatYen(payday.left),
            subtitle: "Left after scheduled bills · \(payday.daysToPayday) days to \(payday.next.date)",
            rows: rows,
            note: "Discretionary remaining subtracts non-bill spending since last payday and is an estimate.",
            actionTitle: "Open Now",
            action: .openNow
        )
    }

    private static func upcomingBillsAnswer(context: Context) -> QueryAnswer {
        let clearedByBank = context.liveCash?.postBalanceMatchedKeys ?? []
        let latestPayday = latestPaydayDate(in: context.timeline, today: context.today)
        let unsettled = context.timeline.filter { entry in
            let isActivePhoneHold = entry.done == true
                && entry.phoneChecked == true
                && LiveCashSummary.isPhoneCheckedHoldActive(for: entry, lastPayday: latestPayday, today: context.today)
            let isUnsettled = entry.done != true || isActivePhoneHold
            guard isUnsettled, entry.event != true, entry.borrowed != true, entry.cardBilled != true, entry.amount > 0 else {
                return false
            }
            if BillCheckoff.matches(entry, in: clearedByBank) { return false }
            return context.payday.map { entry.date < $0.next.date } ?? true
        }
        let total = unsettled.reduce(0) { $0 + $1.amount }
        let rows = unsettled.prefix(12).map { entry -> QueryAnswerRow in
            var detailParts = [entry.date]
            if entry.phoneChecked == true {
                detailParts.append("marked paid on phone")
            } else if entry.estimate == true {
                detailParts.append("estimate")
            }
            return QueryAnswerRow(
                label: entry.item,
                value: formatYen(entry.amount),
                detail: detailParts.joined(separator: " · ")
            )
        }
        return QueryAnswer(
            headline: formatYen(total),
            subtitle: unsettled.isEmpty
                ? "All scheduled bills before payday are confirmed paid."
                : "\(unsettled.count) unsettled \(unsettled.count == 1 ? "bill" : "bills") left before payday",
            rows: rows,
            actionTitle: "Open Coming up",
            action: .openNow
        )
    }

    private static func debtAnswer(context: Context) -> QueryAnswer {
        let debts = context.effectiveDebts ?? context.bundle.debts
        let total = debts.reduce(0) { $0 + $1.balance }
        let rows = debts.map { debt -> QueryAnswerRow in
            let detail: String?
            if let limit = debt.limit, limit > 0 {
                let pct = Int((Double(debt.balance) / Double(limit) * 100).rounded())
                detail = "\(pct)% of \(formatYen(limit)) limit"
            } else {
                detail = debt.lines?.first
            }
            return QueryAnswerRow(label: debt.name, value: formatYen(debt.balance), detail: detail)
        }
        return QueryAnswer(
            headline: formatYen(total),
            subtitle: debts.isEmpty ? "No debts recorded." : "Total owed across \(debts.count) accounts",
            rows: rows,
            note: "Balances reflect the latest statement snapshot and any updates made on this phone.",
            actionTitle: "Open Now",
            action: .openNow
        )
    }

    private static func subscriptionsAnswer(context: Context) -> QueryAnswer {
        let summary = context.subscriptionSummary
        let rows = summary.running.prefix(16).map { item in
            QueryAnswerRow(
                label: item.entry.name,
                value: "\(formatYen(item.entry.monthly))/mo",
                detail: [item.entry.via, item.displayStatus].compactMap { $0 }.joined(separator: " · ")
            )
        }
        let savingNote = summary.monthlySavings > 0
            ? "Stopped or cancelled subscriptions save \(formatYen(summary.monthlySavings))/month (\(formatYen(summary.annualSavings))/year)."
            : nil
        return QueryAnswer(
            headline: "\(formatYen(summary.runningMonthlyTotal))/mo",
            subtitle: "\(summary.runningCount) running subscriptions · \(formatYen(summary.runningAnnualTotal))/year",
            rows: rows,
            note: savingNote,
            actionTitle: "Open Now",
            action: .openNow
        )
    }

    private static func targetsAnswer(context: Context) -> QueryAnswer {
        let plan = context.planSummary
        guard !plan.isEmpty else {
            return QueryAnswer(
                headline: "No targets configured",
                subtitle: "Add targets in the data bundle to track monthly caps.",
                actionTitle: "Open Months",
                action: .openMonths(month: nil)
            )
        }
        let rows = plan.watchList.prefix(7).map { row -> QueryAnswerRow in
            let target = row.entry.target ?? 0
            let pct = Int(((row.currentMonthProgress ?? 0) * 100).rounded())
            let status: String
            if row.isOverCapCurrentMonth {
                status = "Over by \(formatYen(row.currentMonthSpent - target))"
            } else {
                status = "\(pct)% of \(formatYen(target)) cap"
            }
            return QueryAnswerRow(
                label: row.entry.category,
                value: formatYen(row.currentMonthSpent),
                detail: status
            )
        }
        return QueryAnswer(
            headline: formatYen(plan.potentialSavings) + "/mo",
            subtitle: "Potential extra savings · \(formatYen(plan.alreadyCut))/mo already cut · target \(formatYen(plan.projectedTotal))/mo",
            rows: rows,
            actionTitle: "Open Months",
            action: .openMonths(month: plan.currentMonth)
        )
    }

    private static func incomeAnswer(month: String, allTime: Bool, context: Context) -> QueryAnswer {
        if allTime {
            let total = context.totalsByMonth.values.reduce(0) { $0 + $1.income }
            let rows = context.totalsByMonth.keys.sorted().reversed().prefix(6).compactMap { m -> QueryAnswerRow? in
                guard let inc = context.totalsByMonth[m]?.income, inc > 0 else { return nil }
                return QueryAnswerRow(label: monthFullName(m), value: formatYen(inc))
            }
            return QueryAnswer(
                headline: formatYen(total),
                subtitle: "Total recorded income across \(context.totalsByMonth.count) months",
                rows: rows,
                actionTitle: "Open Months",
                action: .openMonths(month: nil)
            )
        }
        let totals = context.totalsByMonth[month] ?? MonthTotals()
        return QueryAnswer(
            headline: formatYen(totals.income),
            subtitle: "Income in \(monthFullName(month)) · spent \(formatYen(totals.total)) · \(totals.left >= 0 ? "left" : "short by") \(formatYen(abs(totals.left)))",
            actionTitle: "Open Months",
            action: .openMonths(month: month)
        )
    }

    private static func categoryAnswer(
        category: String,
        month: String?,
        defaultMonth: String,
        allTime: Bool,
        context: Context
    ) -> QueryAnswer {
        let effectiveMonth = allTime ? nil : (month ?? defaultMonth)
        let matches = context.allItems.filter { item in
            item.category.caseInsensitiveCompare(category) == .orderedSame
                && (effectiveMonth == nil || item.date.hasPrefix(effectiveMonth!))
        }
        let total = matches.reduce(0) { $0 + $1.amount }
        let positiveCount = matches.filter { $0.amount > 0 }.count
        let topShops = SpendingInsights.topMerchants(
            items: matches,
            config: context.bundle.layerConfig,
            layers: context.bundle.layers,
            limit: 5
        )
        let rows = topShops.map {
            QueryAnswerRow(label: $0.merchant, value: formatYen($0.total), detail: "\($0.count) \($0.count == 1 ? "visit" : "visits")")
        }
        let scopeText = effectiveMonth.map { monthFullName($0) } ?? "all \(context.totalsByMonth.count) months"
        return QueryAnswer(
            headline: formatYen(total),
            subtitle: "\(category) in \(scopeText) · \(positiveCount) \(positiveCount == 1 ? "payment" : "payments")",
            rows: rows,
            actionTitle: "View payments",
            action: .openPayments(month: effectiveMonth, category: category, query: nil)
        )
    }

    private static func sourceAnswer(
        source: String,
        month: String?,
        defaultMonth: String,
        allTime: Bool,
        context: Context
    ) -> QueryAnswer {
        let effectiveMonth = allTime ? nil : (month ?? defaultMonth)
        let config = context.bundle.layerConfig
        let matches = context.allItems.filter { item in
            item.source.caseInsensitiveCompare(source) == .orderedSame
                && config.resolvedLayer(for: item, layers: context.bundle.layers) != nil
                && (effectiveMonth == nil || item.date.hasPrefix(effectiveMonth!))
        }
        let total = matches.reduce(0) { $0 + $1.amount }
        let topShops = SpendingInsights.topMerchants(
            items: matches,
            config: config,
            layers: context.bundle.layers,
            limit: 5
        )
        let rows = topShops.map { QueryAnswerRow(label: $0.merchant, value: formatYen($0.total), detail: $0.category) }
        let scopeText = effectiveMonth.map { monthFullName($0) } ?? "all months"
        return QueryAnswer(
            headline: formatYen(total),
            subtitle: "\(source) spending in \(scopeText) · \(matches.count) payments",
            rows: rows,
            actionTitle: "Filter Payments",
            action: .openPayments(month: effectiveMonth, category: nil, query: nil, source: source)
        )
    }

    private static func whereItWentAnswer(month: String, context: Context) -> QueryAnswer {
        let totals = context.totalsByMonth[month] ?? MonthTotals()
        let topCats = totals.categories
            .filter { $0.value.sum > 0 }
            .sorted { $0.value.sum > $1.value.sum }
            .prefix(6)
        let denom = max(1, totals.total)
        let rows = topCats.map { name, stats -> QueryAnswerRow in
            let pct = Int((Double(stats.sum) / Double(denom) * 100).rounded())
            return QueryAnswerRow(label: name, value: formatYen(stats.sum), detail: "\(pct)% · \(stats.count) payments")
        }
        return QueryAnswer(
            headline: formatYen(totals.total),
            subtitle: "Spending in \(monthFullName(month))",
            rows: rows,
            actionTitle: "Open \(monthShortName(month))",
            action: .openMonths(month: month)
        )
    }

    private static func topMerchantsAnswer(month: String?, context: Context) -> QueryAnswer {
        let merchants = SpendingInsights.topMerchants(
            items: context.allItems,
            config: context.bundle.layerConfig,
            layers: context.bundle.layers,
            month: month,
            limit: 6
        )
        let scope = month.map { monthFullName($0) } ?? "all months"
        let top = merchants.first
        let rows = merchants.map {
            QueryAnswerRow(label: $0.merchant, value: formatYen($0.total), detail: "\($0.count)x · avg \(formatYen($0.average))")
        }
        return QueryAnswer(
            headline: top.map { "\($0.merchant) · \(formatYen($0.total))" } ?? "No merchants found",
            subtitle: "Top merchants in \(scope)",
            rows: rows,
            actionTitle: "Open Payments",
            action: .openPayments(month: month, category: nil, query: top?.merchant)
        )
    }

    private static func largestPaymentsAnswer(month: String?, context: Context) -> QueryAnswer {
        let config = context.bundle.layerConfig
        let matches = context.allItems.filter { item in
            item.amount > 0
                && config.resolvedLayer(for: item, layers: context.bundle.layers) != nil
                && (month == nil || item.date.hasPrefix(month!))
        }.sorted { $0.amount > $1.amount }
        let top = matches.first
        let rows = matches.prefix(6).map {
            QueryAnswerRow(label: $0.merchant, value: formatYen($0.amount), detail: "\($0.date) · \($0.category)")
        }
        return QueryAnswer(
            headline: top.map { formatYen($0.amount) } ?? "¥0",
            subtitle: top.map { "Largest payment: \($0.merchant) on \($0.date)" } ?? "No spending payments found",
            rows: rows,
            actionTitle: "Open Payments",
            action: .openPayments(month: month, category: nil, query: nil)
        )
    }

    private static func compareMonthsAnswer(m1: String, m2: String, context: Context) -> QueryAnswer {
        let a = min(m1, m2)
        let b = max(m1, m2)
        let ta = context.totalsByMonth[a] ?? MonthTotals()
        let tb = context.totalsByMonth[b] ?? MonthTotals()
        let diff = tb.total - ta.total

        // Find biggest category movers between month a and month b.
        let cats = Set(ta.categories.keys).union(tb.categories.keys)
        let movers = cats.map { cat -> (String, Int, Int, Int) in
            let va = ta.categories[cat]?.sum ?? 0
            let vb = tb.categories[cat]?.sum ?? 0
            return (cat, va, vb, vb - va)
        }
        .filter { abs($0.3) >= 1000 }
        .sorted { abs($0.3) > abs($1.3) }
        .prefix(5)

        var rows = [
            QueryAnswerRow(label: monthFullName(a), value: formatYen(ta.total)),
            QueryAnswerRow(label: monthFullName(b), value: formatYen(tb.total)),
        ]
        for mover in movers {
            rows.append(QueryAnswerRow(
                label: mover.0,
                value: signedYen(mover.3),
                detail: "\(formatYen(mover.1)) → \(formatYen(mover.2))"
            ))
        }
        let dir = diff >= 0 ? "more" : "less"
        return QueryAnswer(
            headline: "\(signedYen(diff))",
            subtitle: "\(monthFullName(b)) was \(formatYen(abs(diff))) \(dir) than \(monthFullName(a))",
            rows: rows,
            actionTitle: "Open \(monthShortName(b))",
            action: .openMonths(month: b)
        )
    }

    private static func merchantSearchAnswer(rawQuestion: String, month: String?, context: Context) -> QueryAnswer? {
        let stopWords: Set<String> = [
            "how", "much", "did", "i", "spend", "spent", "at", "on", "in", "for", "the",
            "my", "to", "from", "what", "is", "was", "total", "all", "time", "this", "last",
            "month", "year", "payments", "payment", "show", "me", "find", "search", "of", "a", "an"
        ]
        let tokens = rawQuestion
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "ぁ-んァ-ヶ一-龯ー")).inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 2 && !stopWords.contains($0.lowercased()) }

        for token in tokens.sorted(by: { $0.count > $1.count }) {
            let foldedToken = TextFold.key(token)
            guard foldedToken.count >= 2 else { continue }
            let hits = context.allItems.filter { item in
                (month == nil || item.date.hasPrefix(month!))
                    && TextFold.key(item.merchant).contains(foldedToken)
            }.sorted { $0.date > $1.date }
            guard !hits.isEmpty else { continue }
            let total = hits.reduce(0) { $0 + $1.amount }
            let rows = hits.prefix(6).map {
                QueryAnswerRow(label: $0.merchant, value: formatYen($0.amount), detail: "\($0.date) · \($0.source)")
            }
            let scope = month.map { monthFullName($0) } ?? "all recorded months"
            return QueryAnswer(
                headline: formatYen(total),
                subtitle: "\(hits.count) \(hits.count == 1 ? "payment" : "payments") matching \"\(token)\" in \(scope)",
                rows: rows,
                actionTitle: "Search in Payments",
                action: .openPayments(month: month, category: nil, query: token)
            )
        }
        return nil
    }

    private static func helpAnswer(context: Context) -> QueryAnswer {
        QueryAnswer(
            headline: "Ask about your spending",
            subtitle: "Try a category, merchant, month, bills, debt, subscriptions, or cut targets.",
            rows: [
                QueryAnswerRow(label: "Examples", value: "Payday", detail: "How much is left until payday?"),
                QueryAnswerRow(label: "Categories", value: "Monthly", detail: "How much on groceries last month?"),
                QueryAnswerRow(label: "Comparisons", value: "2 months", detail: "Compare March and April"),
            ]
        )
    }

    // MARK: - NLP parsing helpers

    private static func matchCategory(in lower: String, categories: [String]) -> String? {
        for cat in categories {
            let cLower = cat.lowercased()
            if lower.contains(cLower) { return cat }
            // Also check primary word before parenthesis or "&".
            let stem = cLower.split(separator: "(").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? cLower
            if stem.count >= 4, lower.contains(stem) { return cat }
        }
        // Common shorthand synonyms.
        let synonyms: [(String, [String])] = [
            ("convenience", ["convenience"]),
            ("grocer", ["supermarket", "grocer"]),
            ("supermarket", ["supermarket", "grocer"]),
            ("coffee", ["coffee", "cafe"]),
            ("dining", ["eating out", "dining", "restaurant"]),
            ("eating out", ["eating out", "dining"]),
            ("delivery", ["delivery"]),
            ("rent", ["rent"]),
            ("transport", ["transport", "train", "suica", "shinkansen"]),
            ("shopping", ["shopping", "online shopping"]),
            ("pharmacy", ["pharmacy", "drugstore"]),
        ]
        for (needle, targets) in synonyms where lower.contains(needle) {
            if let hit = categories.first(where: { cat in
                let cl = cat.lowercased()
                return targets.contains { cl.contains($0) }
            }) {
                return hit
            }
        }
        return nil
    }

    private static func matchSource(in lower: String, sources: [String]) -> String? {
        for source in sources {
            if lower.contains(source.lowercased()) {
                return source
            }
        }
        return nil
    }

    private static func extractMonths(from lower: String, availableMonths: [String], today: String) -> [String] {
        var found: [String] = []
        let todayMonth = String(today.prefix(7))
        let previousMonth: String? = {
            let parts = todayMonth.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 2 else { return nil }
            let total = parts[0] * 12 + (parts[1] - 1) - 1
            guard total >= 0 else { return nil }
            return String(format: "%04d-%02d", total / 12, (total % 12) + 1)
        }()

        if lower.contains("this month") || lower.contains("current month") {
            found.append(todayMonth)
        }
        if lower.contains("last month") || lower.contains("previous month") {
            if let prev = previousMonth {
                found.append(prev)
            } else if let idx = availableMonths.firstIndex(of: todayMonth), idx > 0 {
                found.append(availableMonths[idx - 1])
            }
        }

        // Explicit YYYY-MM patterns.
        if let regex = try? NSRegularExpression(pattern: #"\b(20\d{2}-\d{2})\b"#) {
            let range = NSRange(lower.startIndex..<lower.endIndex, in: lower)
            for m in regex.matches(in: lower, range: range) {
                if let r = Range(m.range(at: 1), in: lower) {
                    let ym = String(lower[r])
                    if !found.contains(ym) { found.append(ym) }
                }
            }
        }

        // Month names ("jan", "january", ...). Resolve to newest matching month in availableMonths.
        let monthNames: [(Int, [String])] = [
            (1, ["january", "jan"]), (2, ["february", "feb"]), (3, ["march", "mar"]),
            (4, ["april", "apr"]), (5, ["may"]), (6, ["june", "jun"]),
            (7, ["july", "jul"]), (8, ["august", "aug"]), (9, ["september", "sept", "sep"]),
            (10, ["october", "oct"]), (11, ["november", "nov"]), (12, ["december", "dec"]),
        ]
        var hitsWithPos: [(Int, String)] = []
        for (num, names) in monthNames {
            let suffix = String(format: "-%02d", num)
            guard let resolved = availableMonths.last(where: { $0.hasSuffix(suffix) }) else { continue }
            for name in names {
                if let regex = try? NSRegularExpression(pattern: "\\b\(name)\\b"),
                   let m = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..<lower.endIndex, in: lower))
                {
                    hitsWithPos.append((m.range.location, resolved))
                    break
                }
            }
        }
        for (_, ym) in hitsWithPos.sorted(by: { $0.0 < $1.0 }) {
            if !found.contains(ym) { found.append(ym) }
        }
        return found
    }

    private static func formatYen(_ amount: Int) -> String {
        (amount < 0 ? "−¥" : "¥") + amount.magnitude.formatted()
    }

    private static func signedYen(_ amount: Int) -> String {
        (amount < 0 ? "−¥" : "+¥") + amount.magnitude.formatted()
    }

    private static func monthShortName(_ ym: String) -> String {
        let names = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let parts = ym.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2, (1...12).contains(parts[1]) else { return ym }
        return names[parts[1] - 1]
    }

    private static func monthFullName(_ ym: String) -> String {
        let names = [
            "January", "February", "March", "April", "May", "June",
            "July", "August", "September", "October", "November", "December"
        ]
        let parts = ym.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2, (1...12).contains(parts[1]) else { return ym }
        return "\(names[parts[1] - 1]) \(parts[0])"
    }
}
