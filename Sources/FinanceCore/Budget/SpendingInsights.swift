import Foundation

/// Aggregated spending stats for one merchant (grouped by folded name, preserving display spelling).
public struct MerchantSummary: Sendable, Equatable, Identifiable {
    public var id: String
    public var merchant: String
    public var total: Int
    public var count: Int
    public var average: Int
    public var category: String
    public var layer: String?
    public var lastDate: String
    public var sources: [String]

    public init(
        id: String,
        merchant: String,
        total: Int,
        count: Int,
        average: Int,
        category: String,
        layer: String?,
        lastDate: String,
        sources: [String]
    ) {
        self.id = id
        self.merchant = merchant
        self.total = total
        self.count = count
        self.average = average
        self.category = category
        self.layer = layer
        self.lastDate = lastDate
        self.sources = sources
    }
}

/// Aggregated spending stats for one card, bank or wallet source.
public struct SourceSummary: Sendable, Equatable, Identifiable {
    public var id: String { source }
    public var source: String
    public var total: Int
    public var count: Int
    public var share: Double

    public init(source: String, total: Int, count: Int, share: Double) {
        self.source = source
        self.total = total
        self.count = count
        self.share = share
    }
}

/// Month-over-month, fixed vs day-to-day, and baseline comparison for one selected month.
public struct MonthComparison: Sendable, Equatable {
    public var selectedMonth: String
    public var isInProgress: Bool
    public var previousMonth: String?
    public var previousTotal: Int?
    /// `selectedTotal - previousTotal`, or nil when the selected month is still in progress.
    public var deltaFromPrevious: Int?
    public var baselineAverage: Int?
    public var rentCost: Int
    public var billsCost: Int
    public var subsCost: Int
    public var fixedCosts: Int
    public var dayToDayCosts: Int
    /// `(income - total) / income` when income > 0 and not in progress (or current ratio).
    public var savingsRate: Double?

    public init(
        selectedMonth: String,
        isInProgress: Bool,
        previousMonth: String?,
        previousTotal: Int?,
        deltaFromPrevious: Int?,
        baselineAverage: Int?,
        rentCost: Int,
        billsCost: Int,
        subsCost: Int,
        fixedCosts: Int,
        dayToDayCosts: Int,
        savingsRate: Double?
    ) {
        self.selectedMonth = selectedMonth
        self.isInProgress = isInProgress
        self.previousMonth = previousMonth
        self.previousTotal = previousTotal
        self.deltaFromPrevious = deltaFromPrevious
        self.baselineAverage = baselineAverage
        self.rentCost = rentCost
        self.billsCost = billsCost
        self.subsCost = subsCost
        self.fixedCosts = fixedCosts
        self.dayToDayCosts = dayToDayCosts
        self.savingsRate = savingsRate
    }
}

/// Clarified payday cycle breakdown separating paid vs upcoming bills and day-to-day spending.
public struct PaydayBreakdown: Sendable, Equatable {
    public var paidBillsSum: Int
    public var paidBillsCount: Int
    public var remainingBillsSum: Int
    public var remainingBillsCount: Int
    public var receivedInSum: Int
    public var expectedInSum: Int
    /// Non-rent, non-fixed-bill spending since the last payday (Day-to-day + Subscriptions).
    public var dayToDaySpentSincePayday: Int
    /// Total layered spending since the last payday (all 4 layers).
    public var totalSpentSincePayday: Int
    /// Estimated discretionary cash left: `payday.left - dayToDaySpentSincePayday`.
    public var estimatedRemainingDiscretionary: Int

    public init(
        paidBillsSum: Int,
        paidBillsCount: Int,
        remainingBillsSum: Int,
        remainingBillsCount: Int,
        receivedInSum: Int,
        expectedInSum: Int,
        dayToDaySpentSincePayday: Int,
        totalSpentSincePayday: Int,
        estimatedRemainingDiscretionary: Int
    ) {
        self.paidBillsSum = paidBillsSum
        self.paidBillsCount = paidBillsCount
        self.remainingBillsSum = remainingBillsSum
        self.remainingBillsCount = remainingBillsCount
        self.receivedInSum = receivedInSum
        self.expectedInSum = expectedInSum
        self.dayToDaySpentSincePayday = dayToDaySpentSincePayday
        self.totalSpentSincePayday = totalSpentSincePayday
        self.estimatedRemainingDiscretionary = estimatedRemainingDiscretionary
    }
}

/// Pure arithmetic loan payoff projection (no financial advice).
public struct DebtPayoffResult: Sendable, Equatable {
    public var balance: Int
    public var annualRatePercent: Double
    public var monthlyPayment: Int
    /// Approximate first month's interest in yen.
    public var firstMonthInterest: Int
    /// Months until balance reaches zero, or nil when payment cannot cover monthly interest.
    public var monthsToPayoff: Int?
    /// Total interest paid over the payoff period, or nil when it does not amortize.
    public var totalInterest: Int?
    /// Estimated final payoff month ("YYYY-MM"), or nil when it does not amortize.
    public var payoffMonth: String?

    public init(
        balance: Int,
        annualRatePercent: Double,
        monthlyPayment: Int,
        firstMonthInterest: Int,
        monthsToPayoff: Int?,
        totalInterest: Int?,
        payoffMonth: String?
    ) {
        self.balance = balance
        self.annualRatePercent = annualRatePercent
        self.monthlyPayment = monthlyPayment
        self.firstMonthInterest = firstMonthInterest
        self.monthsToPayoff = monthsToPayoff
        self.totalInterest = totalInterest
        self.payoffMonth = payoffMonth
    }
}

/// Side-by-side comparison of base monthly payment vs paying an extra monthly amount.
public struct DebtPayoffComparison: Sendable, Equatable {
    public var baseline: DebtPayoffResult
    public var accelerated: DebtPayoffResult
    public var monthsSaved: Int?
    public var interestSaved: Int?

    public init(
        baseline: DebtPayoffResult,
        accelerated: DebtPayoffResult,
        monthsSaved: Int?,
        interestSaved: Int?
    ) {
        self.baseline = baseline
        self.accelerated = accelerated
        self.monthsSaved = monthsSaved
        self.interestSaved = interestSaved
    }
}

/// Actionable, factual alert surfaced from notices, statements, timeline and targets.
public struct FinanceAlert: Sendable, Equatable, Identifiable {
    public enum Severity: Int, Sendable, Comparable {
        case info = 0
        case warning = 1
        case urgent = 2

        public static func < (lhs: Severity, rhs: Severity) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    public enum Kind: String, Sendable, Equatable {
        case declinedPayment
        case cancelledSubscriptionCharge
        case possibleDuplicate
        case uncategorizedItems
        case capExceeded
        case capNear
        case upcomingBillSoon
        case priceIncrease
    }

    public enum Action: Sendable, Equatable {
        case openPayments(month: String?, category: String?, query: String?, onlyUncategorized: Bool)
        case openComingUp
        case openTargets
    }

    public var id: String
    public var kind: Kind
    public var severity: Severity
    public var title: String
    public var detail: String
    public var badge: String
    public var action: Action

    public init(
        id: String,
        kind: Kind,
        severity: Severity,
        title: String,
        detail: String,
        badge: String,
        action: Action
    ) {
        self.id = id
        self.kind = kind
        self.severity = severity
        self.title = title
        self.detail = detail
        self.badge = badge
        self.action = action
    }
}

/// Deterministic analytics helpers for merchants, cards, comparisons, debt math and alerts.
public enum SpendingInsights {
    /// Groups layered spending items by folded merchant name, ranked by total descending.
    public static func topMerchants(
        items: [BudgetItem],
        config: LayerConfig,
        layers: [LayerDefinition] = [],
        month: String? = nil,
        limit: Int = 25
    ) -> [MerchantSummary] {
        struct Bucket {
            var spellings: [String: Int] = [:]
            var categories: [String: Int] = [:]
            var layers: [String: Int] = [:]
            var sources: Set<String> = []
            var total: Int = 0
            var count: Int = 0
            var lastDate: String = ""
        }

        var buckets: [String: Bucket] = [:]
        for item in items {
            if let month, !item.date.hasPrefix(month) { continue }
            guard let resolvedLayer = config.resolvedLayer(for: item, layers: layers) else { continue }
            let key = TextFold.key(item.merchant)
            guard !key.isEmpty else { continue }

            var bucket = buckets[key] ?? Bucket()
            bucket.spellings[item.merchant, default: 0] += 1
            bucket.categories[item.category, default: 0] += max(1, abs(item.amount))
            bucket.layers[resolvedLayer, default: 0] += max(1, abs(item.amount))
            bucket.sources.insert(item.source)
            bucket.total += item.amount
            if item.amount > 0 { bucket.count += 1 }
            if item.date > bucket.lastDate { bucket.lastDate = item.date }
            buckets[key] = bucket
        }

        let summaries = buckets.compactMap { key, bucket -> MerchantSummary? in
            guard bucket.total > 0 else { return nil }
            let bestSpelling = bucket.spellings.max {
                if $0.value != $1.value { return $0.value < $1.value }
                return $0.key > $1.key
            }?.key ?? key
            let bestCategory = bucket.categories.max { $0.value < $1.value }?.key ?? "Uncategorized"
            let bestLayer = bucket.layers.max { $0.value < $1.value }?.key
            let effectiveCount = max(1, bucket.count)
            let average = Int((Double(bucket.total) / Double(effectiveCount)).rounded())
            return MerchantSummary(
                id: key,
                merchant: bestSpelling,
                total: bucket.total,
                count: bucket.count,
                average: average,
                category: bestCategory,
                layer: bestLayer,
                lastDate: bucket.lastDate,
                sources: bucket.sources.sorted()
            )
        }
        .sorted {
            if $0.total != $1.total { return $0.total > $1.total }
            return $0.merchant.localizedCaseInsensitiveCompare($1.merchant) == .orderedAscending
        }

        return limit > 0 ? Array(summaries.prefix(limit)) : summaries
    }

    /// Groups layered spending items by source/card, ranked by total descending.
    public static func spendingBySource(
        items: [BudgetItem],
        config: LayerConfig,
        layers: [LayerDefinition] = [],
        month: String? = nil
    ) -> [SourceSummary] {
        var totals: [String: (sum: Int, count: Int)] = [:]
        for item in items {
            if let month, !item.date.hasPrefix(month) { continue }
            guard config.resolvedLayer(for: item, layers: layers) != nil else { continue }
            var entry = totals[item.source, default: (0, 0)]
            entry.sum += item.amount
            if item.amount > 0 { entry.count += 1 }
            totals[item.source] = entry
        }

        let positive = totals.filter { $0.value.sum > 0 }
        let grandTotal = max(1, positive.values.reduce(0) { $0 + $1.sum })

        return positive.map { source, stats in
            SourceSummary(
                source: source,
                total: stats.sum,
                count: stats.count,
                share: Double(stats.sum) / Double(grandTotal)
            )
        }
        .sorted {
            if $0.total != $1.total { return $0.total > $1.total }
            return $0.source.localizedCaseInsensitiveCompare($1.source) == .orderedAscending
        }
    }

    /// Computes month-over-month delta, fixed vs day-to-day split, and savings rate.
    public static func monthComparison(
        totalsByMonth: [String: MonthTotals],
        selectedMonth: String,
        asOf: String,
        today: String,
        planWindow: [String]?,
        layers: [LayerDefinition]
    ) -> MonthComparison {
        let sortedMonths = totalsByMonth.keys.sorted()
        let asOfMonth = String(asOf.prefix(7))
        let todayMonth = String(today.prefix(7))
        let latestPartialMonth = max(asOfMonth, todayMonth)
        let isInProgress = selectedMonth >= latestPartialMonth && selectedMonth == sortedMonths.last

        let selectedTotals = totalsByMonth[selectedMonth] ?? MonthTotals()
        let prevMonth: String?
        if let idx = sortedMonths.firstIndex(of: selectedMonth), idx > 0 {
            prevMonth = sortedMonths[idx - 1]
        } else {
            prevMonth = nil
        }
        let prevTotal = prevMonth.flatMap { totalsByMonth[$0]?.total }
        let delta: Int? = (!isInProgress && prevTotal != nil) ? (selectedTotals.total - prevTotal!) : nil

        let windowMonths: [String]
        if let explicit = planWindow, !explicit.isEmpty {
            windowMonths = explicit
        } else {
            let completed = sortedMonths.filter { $0 < latestPartialMonth }
            windowMonths = Array(completed.suffix(3))
        }
        let windowValues = windowMonths.compactMap { totalsByMonth[$0]?.total }
        let baselineAverage: Int? = windowValues.isEmpty
            ? nil
            : Int((Double(windowValues.reduce(0, +)) / Double(windowValues.count)).rounded())

        let keys = layers.count >= 4 ? Array(layers.prefix(4).map(\.key)) : LayerConfig.defaultLayerKeys
        let rentCost = selectedTotals.layers[keys[0], default: 0]
        let billsCost = selectedTotals.layers[keys[1], default: 0]
        let subsCost = selectedTotals.layers[keys[2], default: 0]
        let dayToDayCost = selectedTotals.layers[keys[3], default: 0]
        let fixedCosts = rentCost + billsCost + subsCost

        let savingsRate: Double?
        if selectedTotals.income > 0 {
            savingsRate = Double(selectedTotals.income - selectedTotals.total) / Double(selectedTotals.income)
        } else {
            savingsRate = nil
        }

        return MonthComparison(
            selectedMonth: selectedMonth,
            isInProgress: isInProgress,
            previousMonth: prevMonth,
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

    /// Computes paid vs remaining bills and Day-to-day spending since the last payday.
    ///
    /// Strictly counts the `Day-to-day` layer within `[lastPayday, payday.next.date)` so tapping
    /// the Payday hero strip into Payments (`layer: .dayToDay`) reconciles to the exact yen and
    /// never double-counts subscriptions already on the scheduled timeline.
    public static func paydayBreakdown(
        payday: PaydayView,
        lastPayday: String?,
        items: [BudgetItem],
        config: LayerConfig,
        layers: [LayerDefinition]
    ) -> PaydayBreakdown {
        let paidBills = payday.outs.filter { $0.done == true }
        let remainingBills = payday.outs.filter { $0.done != true }
        let receivedIn = payday.ins.filter { $0.done == true }
        let expectedIn = payday.ins.filter { $0.done != true }

        let keys = layers.count >= 4 ? Array(layers.prefix(4).map(\.key)) : LayerConfig.defaultLayerKeys
        let dayToDayLayer = keys[3]

        var dayToDaySpent = 0
        var totalSpent = 0
        if let start = lastPayday {
            for item in items where item.date >= start && item.date < payday.next.date {
                guard let layer = config.resolvedLayer(for: item, layers: layers) else { continue }
                totalSpent += item.amount
                if layer == dayToDayLayer {
                    dayToDaySpent += item.amount
                }
            }
        }

        return PaydayBreakdown(
            paidBillsSum: paidBills.reduce(0) { $0 + $1.amount },
            paidBillsCount: paidBills.count,
            remainingBillsSum: remainingBills.reduce(0) { $0 + $1.amount },
            remainingBillsCount: remainingBills.count,
            receivedInSum: -receivedIn.reduce(0) { $0 + $1.amount },
            expectedInSum: -expectedIn.reduce(0) { $0 + $1.amount },
            dayToDaySpentSincePayday: dayToDaySpent,
            totalSpentSincePayday: totalSpent,
            estimatedRemainingDiscretionary: payday.left - dayToDaySpent
        )
    }

    // MARK: - Debt Payoff Math

    /// Extracts an annual interest rate (e.g. "18.0%" or "~15%") from a debt's info lines, if written.
    public static func extractAnnualRate(from lines: [String]?) -> Double? {
        guard let lines else { return nil }
        let pattern = #"(\d+(?:\.\d+)?)\s*%"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        for line in lines {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            if let match = regex.firstMatch(in: line, range: range),
               let r = Range(match.range(at: 1), in: line),
               let value = Double(line[r]), value >= 0, value <= 100
            {
                return value
            }
        }
        return nil
    }

    /// Extracts a suggested monthly payment (e.g. "¥11,000") from a debt's info lines, if written.
    public static func extractMonthlyPayment(from lines: [String]?) -> Int? {
        guard let lines else { return nil }
        let pattern = #"[¥￥]\s*([0-9][0-9,]*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        for line in lines {
            let lower = line.lowercased()
            // Skip lines that only mention interest or available credit rather than a payment.
            if lower.contains("interest") || lower.contains("available") { continue }
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            if let match = regex.firstMatch(in: line, range: range),
               let r = Range(match.range(at: 1), in: line),
               let value = Int(line[r].replacingOccurrences(of: ",", with: "")), value > 0
            {
                return value
            }
        }
        return nil
    }

    /// Simulates fixed-payment amortization month by month.
    public static func simulateDebtPayoff(
        balance: Int,
        annualRatePercent: Double,
        monthlyPayment: Int,
        startMonth: String
    ) -> DebtPayoffResult {
        guard balance > 0 else {
            return DebtPayoffResult(
                balance: 0,
                annualRatePercent: annualRatePercent,
                monthlyPayment: monthlyPayment,
                firstMonthInterest: 0,
                monthsToPayoff: 0,
                totalInterest: 0,
                payoffMonth: startMonth
            )
        }

        let monthlyRate = max(0, annualRatePercent) / 100.0 / 12.0
        let firstInterest = Int((Double(balance) * monthlyRate).rounded())

        guard monthlyPayment > 0 else {
            return DebtPayoffResult(
                balance: balance,
                annualRatePercent: annualRatePercent,
                monthlyPayment: monthlyPayment,
                firstMonthInterest: firstInterest,
                monthsToPayoff: nil,
                totalInterest: nil,
                payoffMonth: nil
            )
        }

        var remaining = Double(balance)
        var totalInterest = 0.0
        var months = 0
        let maxMonths = 600

        while remaining > 0.5 && months < maxMonths {
            let interest = remaining * monthlyRate
            if Double(monthlyPayment) <= interest && monthlyRate > 0 {
                return DebtPayoffResult(
                    balance: balance,
                    annualRatePercent: annualRatePercent,
                    monthlyPayment: monthlyPayment,
                    firstMonthInterest: firstInterest,
                    monthsToPayoff: nil,
                    totalInterest: nil,
                    payoffMonth: nil
                )
            }
            let principal = min(remaining, Double(monthlyPayment) - interest)
            remaining -= principal
            totalInterest += interest
            months += 1
        }

        guard remaining <= 0.5 else {
            return DebtPayoffResult(
                balance: balance,
                annualRatePercent: annualRatePercent,
                monthlyPayment: monthlyPayment,
                firstMonthInterest: firstInterest,
                monthsToPayoff: nil,
                totalInterest: nil,
                payoffMonth: nil
            )
        }

        return DebtPayoffResult(
            balance: balance,
            annualRatePercent: annualRatePercent,
            monthlyPayment: monthlyPayment,
            firstMonthInterest: firstInterest,
            monthsToPayoff: months,
            totalInterest: Int(totalInterest.rounded()),
            payoffMonth: addMonths(months, to: startMonth)
        )
    }

    public static func compareDebtPayoff(
        balance: Int,
        annualRatePercent: Double,
        basePayment: Int,
        extraPayment: Int,
        startMonth: String
    ) -> DebtPayoffComparison {
        let base = simulateDebtPayoff(
            balance: balance,
            annualRatePercent: annualRatePercent,
            monthlyPayment: basePayment,
            startMonth: startMonth
        )
        let accel = simulateDebtPayoff(
            balance: balance,
            annualRatePercent: annualRatePercent,
            monthlyPayment: basePayment + max(0, extraPayment),
            startMonth: startMonth
        )
        let monthsSaved: Int?
        let interestSaved: Int?
        if let bm = base.monthsToPayoff, let am = accel.monthsToPayoff {
            monthsSaved = max(0, bm - am)
        } else {
            monthsSaved = nil
        }
        if let bi = base.totalInterest, let ai = accel.totalInterest {
            interestSaved = max(0, bi - ai)
        } else {
            interestSaved = nil
        }
        return DebtPayoffComparison(
            baseline: base,
            accelerated: accel,
            monthsSaved: monthsSaved,
            interestSaved: interestSaved
        )
    }

    private static func addMonths(_ offset: Int, to month: String) -> String? {
        let parts = month.split(separator: "-").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        let totalMonths = parts[0] * 12 + (parts[1] - 1) + offset
        guard totalMonths >= 0 else { return nil }
        let y = totalMonths / 12
        let m = (totalMonths % 12) + 1
        return String(format: "%04d-%02d", y, m)
    }

    // MARK: - Smart Alerts & Watchdog

    public static func detectAlerts(
        bundle: DataBundle,
        allItems: [BudgetItem],
        notices: [Notice],
        timeline: [TimelineEntry],
        planSummary: PlanSummary,
        subscriptionSummary: SubscriptionSummary,
        today: String,
        discreetCategories: Set<String> = []
    ) -> [FinanceAlert] {
        var alerts: [FinanceAlert] = []
        let todayNum = JST.dayNumber(today) ?? 0
        let currentMonth = String(today.prefix(7))
        let config = bundle.layerConfig

        // 1. Recent declined or failed payments from email notices (last 14 days).
        if let cutoffDay = JST.addingDays(-14, to: today) {
            let declines = notices
                .filter { $0.kind == .decline && $0.day >= cutoffDay }
                .sorted { ($0.receivedAt, $0.messageID) > ($1.receivedAt, $1.messageID) }
            for notice in declines.prefix(3) {
                let sourceLabel = bundle.sourceLabels[notice.source.rawValue] ?? notice.source.rawValue
                let amountPart = notice.amount.map { "¥\($0.magnitude.formatted())" } ?? "Payment"
                let merchant = (notice.merchant?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
                let detail = merchant.map { "\($0) · \(sourceLabel) · \(notice.day)" } ?? "\(sourceLabel) · \(notice.day)"
                alerts.append(FinanceAlert(
                    id: "decline:\(notice.messageID)",
                    kind: .declinedPayment,
                    severity: .urgent,
                    title: "Declined: \(amountPart)",
                    detail: detail,
                    badge: "Declined",
                    action: .openPayments(month: String(notice.day.prefix(7)), category: nil, query: merchant, onlyUncategorized: false)
                ))
            }
        }

        // 2. Unpaid scheduled bills due within the next 3 days (including today).
        if let soonLimit = JST.addingDays(3, to: today) {
            let dueSoon = timeline.filter { entry in
                entry.done != true
                    && entry.event != true
                    && entry.borrowed != true
                    && entry.amount > 0
                    && entry.date >= today
                    && entry.date <= soonLimit
            }
            for entry in dueSoon.prefix(3) {
                let daysLeft = (JST.dayNumber(entry.date) ?? todayNum) - todayNum
                let when: String
                switch daysLeft {
                case 0: when = "Due today"
                case 1: when = "Due tomorrow"
                default: when = "Due in \(daysLeft) days"
                }
                let est = entry.estimate == true ? " (estimate)" : ""
                alerts.append(FinanceAlert(
                    id: "bill:\(entry.date):\(entry.item):\(entry.amount)",
                    kind: .upcomingBillSoon,
                    severity: daysLeft == 0 ? .urgent : .warning,
                    title: "\(entry.item) · ¥\(entry.amount.formatted())\(est)",
                    detail: entry.note.map { "\(when) · \($0)" } ?? when,
                    badge: daysLeft == 0 ? "Today" : "\(daysLeft)d",
                    action: .openComingUp
                ))
            }
        }

        // 3. Cancelled or stopped subscriptions showing a recent charge (last 35 days, after stoppedDate if known).
        //    Never flag a charge that already belongs to an active subscription (e.g. active plan vs stopped API credits).
        if let cutoffDay = JST.addingDays(-35, to: today) {
            let offSubs = subscriptionSummary.stopped.filter(\.countsAsSaving)
            let recentCharges = allItems.filter {
                $0.date >= cutoffDay && $0.amount > 0 && config.resolvedLayer(for: $0, layers: bundle.layers) != nil
            }
            var activeClaimedFingerprints = Set<String>()
            for activeSub in subscriptionSummary.running {
                for item in recentCharges where SubscriptionHistory.matchesItem(
                    item,
                    for: activeSub.entry,
                    config: config,
                    layers: bundle.layers,
                    allowAnnualMultiplier: true
                ) {
                    activeClaimedFingerprints.insert(CategoryOverride.transactionFingerprint(for: item))
                }
            }
            for sub in offSubs {
                let stoppedAfter = sub.entry.stoppedDate?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let hit = recentCharges.first(where: { item in
                    if let stoppedAfter, !stoppedAfter.isEmpty, item.date <= stoppedAfter {
                        return false
                    }
                    if activeClaimedFingerprints.contains(CategoryOverride.transactionFingerprint(for: item)) {
                        return false
                    }
                    return SubscriptionHistory.matchesItem(
                        item,
                        for: sub.entry,
                        config: config,
                        layers: bundle.layers,
                        allowAnnualMultiplier: false
                    )
                }) {
                    let subKey = TextFold.key(sub.entry.name)
                    alerts.append(FinanceAlert(
                        id: "resurrected:\(subKey):\(hit.date):\(hit.amount)",
                        kind: .cancelledSubscriptionCharge,
                        severity: .urgent,
                        title: "Possible charge on stopped subscription",
                        detail: "\(hit.merchant) · ¥\(hit.amount.formatted()) on \(hit.date) (listed as \(sub.entry.status ?? "stopped"))",
                        badge: "Verify",
                        action: .openPayments(month: String(hit.date.prefix(7)), category: nil, query: hit.merchant, onlyUncategorized: false)
                    ))
                }
            }
        }

        // 4. Possible duplicate charges (last 21 days, same card/amount/merchant).
        //    Same-day duplicates trigger at >= ¥500; consecutive-day duplicates require >= ¥2,000 and
        //    skip routine everyday food/convenience categories so daily workday coffee/lunch doesn't spam alerts.
        if let cutoffDay = JST.addingDays(-21, to: today) {
            let recent = allItems
                .filter {
                    $0.date >= cutoffDay
                        && $0.amount >= 500
                        && config.resolvedLayer(for: $0, layers: bundle.layers) != nil
                        && !discreetCategories.contains($0.category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
                }
                .sorted { ($0.date, $0.merchant, $0.amount) < ($1.date, $1.merchant, $1.amount) }

            let routineDailyKeywords = [
                "convenience", "supermarket", "grocer", "dining", "eating out", "coffee", "cafe", "bakery", "transport",
            ]
            var reportedDupKeys = Set<String>()
            for i in 0..<recent.count {
                let a = recent[i]
                let keyA = TextFold.key(a.merchant)
                guard !keyA.isEmpty, let dayA = JST.dayNumber(a.date) else { continue }
                let catLower = a.category.lowercased()
                let isRoutineDaily = routineDailyKeywords.contains { catLower.contains($0) }
                for j in (i + 1)..<recent.count {
                    let b = recent[j]
                    guard let dayB = JST.dayNumber(b.date), dayB - dayA <= 1 else { break }
                    if dayB > dayA && (a.amount < 2_000 || isRoutineDaily) { continue }
                    guard a.amount == b.amount, a.source == b.source, TextFold.key(b.merchant) == keyA else { continue }
                    // Ignore when one is pending and the other is confirmed on the same source (likely unmatched lag).
                    guard a.isPending == b.isPending else { continue }
                    let dupKey = "\(keyA)|\(a.amount)|\(a.source)|\(a.date)"
                    guard reportedDupKeys.insert(dupKey).inserted else { continue }
                    alerts.append(FinanceAlert(
                        id: "dup:\(dupKey)",
                        kind: .possibleDuplicate,
                        severity: .warning,
                        title: "Possible duplicate · ¥\(a.amount.formatted())",
                        detail: "\(a.merchant) appeared twice on \(a.source) (\(a.date == b.date ? a.date : "\(a.date) & \(b.date)"))",
                        badge: "Check",
                        action: .openPayments(month: String(b.date.prefix(7)), category: nil, query: a.merchant, onlyUncategorized: false)
                    ))
                    break
                }
            }
        }

        // 5. Cut targets exceeded or nearing cap this month.
        for row in planSummary.watchList.prefix(3) {
            guard let target = row.entry.target else { continue }
            if row.isOverCapCurrentMonth {
                let over = row.currentMonthSpent - target
                alerts.append(FinanceAlert(
                    id: "cap-over:\(currentMonth):\(row.entry.category)",
                    kind: .capExceeded,
                    severity: .warning,
                    title: "\(row.entry.category) over target",
                    detail: "¥\(row.currentMonthSpent.formatted()) spent vs ¥\(target.formatted()) target (+¥\(over.formatted()))",
                    badge: "Over cap",
                    action: .openPayments(month: currentMonth, category: row.entry.category, query: nil, onlyUncategorized: false)
                ))
            } else if row.isNearCapCurrentMonth, let rem = row.currentMonthRemaining {
                let pct = Int(((row.currentMonthProgress ?? 0) * 100).rounded())
                alerts.append(FinanceAlert(
                    id: "cap-near:\(currentMonth):\(row.entry.category)",
                    kind: .capNear,
                    severity: .info,
                    title: "\(row.entry.category) at \(pct)% of target",
                    detail: "¥\(rem.formatted()) left under your ¥\(target.formatted()) cap",
                    badge: "\(pct)%",
                    action: .openPayments(month: currentMonth, category: row.entry.category, query: nil, onlyUncategorized: false)
                ))
            }
        }

        // 6. Uncategorized payments in the last 45 days.
        if let cutoffDay = JST.addingDays(-45, to: today) {
            let uncategorized = allItems.filter {
                $0.date >= cutoffDay && $0.category.caseInsensitiveCompare("Uncategorized") == .orderedSame
            }
            if !uncategorized.isEmpty {
                let total = uncategorized.reduce(0) { $0 + $1.amount }
                let word = uncategorized.count == 1 ? "payment" : "payments"
                alerts.append(FinanceAlert(
                    id: "uncategorized:\(uncategorized.count):\(total)",
                    kind: .uncategorizedItems,
                    severity: .info,
                    title: "\(uncategorized.count) uncategorized \(word)",
                    detail: "¥\(total.magnitude.formatted()) total. Tap to review and assign categories.",
                    badge: "Review",
                    action: .openPayments(month: nil, category: nil, query: nil, onlyUncategorized: true)
                ))
            }
        }

        // 7. Recurring price jumps: same merchant billed monthly (>= 3 prior months) with latest >= +15% and +¥500.
        let recurringJumps = detectPriceIncreases(
            items: allItems,
            config: config,
            layers: bundle.layers,
            currentMonth: currentMonth,
            discreetCategories: discreetCategories
        )
        alerts.append(contentsOf: recurringJumps.prefix(2))

        return alerts.sorted {
            if $0.severity != $1.severity { return $0.severity > $1.severity }
            return $0.id < $1.id
        }
    }

    /// Finds merchants billed once per month across >= 3 prior months whose latest charge jumped >= 15% and >= ¥500.
    public static func detectPriceIncreases(
        items: [BudgetItem],
        config: LayerConfig,
        layers: [LayerDefinition],
        currentMonth: String,
        discreetCategories: Set<String> = []
    ) -> [FinanceAlert] {
        // Group spending items by folded merchant -> month -> list of positive amounts.
        var byMerchant: [String: (name: String, category: String, months: [String: [Int]])] = [:]
        for item in items where item.amount > 0 && item.date.count >= 7 {
            guard config.resolvedLayer(for: item, layers: layers) != nil else { continue }
            guard !discreetCategories.contains(item.category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) else {
                continue
            }
            let key = TextFold.key(item.merchant)
            guard !key.isEmpty else { continue }
            let m = String(item.date.prefix(7))
            var entry = byMerchant[key] ?? (item.merchant, item.category, [:])
            entry.months[m, default: []].append(item.amount)
            byMerchant[key] = entry
        }

        var results: [FinanceAlert] = []
        for (key, data) in byMerchant {
            // Only look at true single-charge-per-month recurring merchants (bills / subscriptions).
            let singleMonths = data.months.filter { $0.value.count == 1 }
            guard singleMonths.count >= 4 else { continue }
            let sortedMonths = singleMonths.keys.sorted()
            guard let latestMonth = sortedMonths.last, latestMonth == currentMonth,
                  let latestAmount = singleMonths[latestMonth]?.first
            else { continue }

            let prior = sortedMonths.dropLast().suffix(3).compactMap { singleMonths[$0]?.first }.sorted()
            guard prior.count == 3 else { continue }
            let median = prior[1]
            // Require prior 3 months to have been fairly steady (within 15% of each other).
            guard median > 0, Double(prior[2] - prior[0]) / Double(median) <= 0.15 else { continue }
            let increase = latestAmount - median
            guard increase >= 500, Double(increase) / Double(median) >= 0.15 else { continue }

            results.append(FinanceAlert(
                id: "price-jump:\(key):\(latestMonth)",
                kind: .priceIncrease,
                severity: .info,
                title: "\(data.name) rose by ¥\(increase.formatted())",
                detail: "¥\(latestAmount.formatted()) in \(latestMonth) vs usual ¥\(median.formatted())",
                badge: "Higher",
                action: .openPayments(month: latestMonth, category: nil, query: data.name, onlyUncategorized: false)
            ))
        }

        return results.sorted { $0.id < $1.id }
    }
}
