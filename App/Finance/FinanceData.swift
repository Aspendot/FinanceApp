import FinanceCore
import Foundation
import WidgetKit

/// Everything the screens show: the imported data file, confirmed Money Forward bank
/// transactions after each source's statement cutoff, remaining pending Gmail notices,
/// and phone-local additions/overrides.
struct FinanceData: Sendable {
    let bundle: DataBundle
    /// All recent notices kept for detail lookups (timestamps, foreign amounts, split parts) and decline alerts.
    let notices: [Notice]
    /// Notices before effective coverage, kept outside the pending totals.
    let unmatched: [Notice]
    /// Complete item list (bundle + Money Forward bank + pending notices + manual/imported local entries),
    /// with local category overrides applied.
    let allItems: [BudgetItem]
    /// Reconciled timeline (Money Forward + local bill checkoffs).
    let timeline: [FinanceCore.TimelineEntry]
    /// Keys of timeline entries marked paid on the phone rather than confirmed by a bank row.
    let phoneCheckedBillKeys: Set<String>
    /// Fingerprints of items created locally on the phone (manual or CSV import).
    let localItemKeys: Set<String>
    /// Fingerprint -> ManualEntry.ID for deleting local items.
    let localEntryByFingerprint: [String: UUID]
    /// Matched notice lookup by transaction fingerprint (`date|source|amount|foldedMerchant`) for PaymentDetailSheet.
    let noticeByFingerprint: [String: Notice]
    let payday: PaydayView?
    let paydayBreakdown: PaydayBreakdown?
    let comingUp: [ComingUpGroup]
    let lastPayday: String?
    let spentSincePayday: Int?
    let pendingSincePayday: Int
    /// All pending payments built from bank emails not yet matched by Money Forward.
    let pendingCount: Int
    /// Confirmed items added from Money Forward after bundle coverage end.
    let confirmedBankCount: Int
    /// Per-source coverage extended to the newest mapped Money Forward row.
    let effectiveCoverage: [String: CoverageRange]
    let months: [String]
    /// Monthly totals computed once over `allItems` (fixes Money Forward omission in Months).
    let totalsByMonth: [String: MonthTotals]
    /// Calendar-month periods covering every available month.
    let calendarPeriods: [BudgetPeriod]
    /// Payday-to-day-before-next-payday periods discovered from timeline and salary rows.
    let payCycles: [BudgetPeriod]
    /// Period totals keyed by pay-cycle `BudgetPeriod.id`.
    let totalsByCycle: [String: MonthTotals]
    /// Payments (excluding Income) grouped by month.
    let paymentsByMonth: [String: [NumberedRow<BudgetItem>]]
    /// All items (including Income) sorted newest first for all-time search and Income filtering.
    let allRowsSorted: [NumberedRow<BudgetItem>]
    let subscriptionSummary: SubscriptionSummary
    /// Bundle plan rows with phone target overrides applied.
    let effectivePlan: [PlanEntry]
    /// Bundle debts with phone balance overrides applied.
    let effectiveDebts: [DebtEntry]
    let planSummary: PlanSummary
    let alerts: [FinanceAlert]
    /// Daily review inbox queue (pending emails, uncategorized items, and anomalies not yet reviewed).
    let reviewQueue: [ReviewQueueItem]
    /// Distinct (group, category) pairs available in this dataset for pickers.
    let availableCategories: [(group: String, category: String)]
    /// Most frequent known merchant display spellings for Quick Add autocomplete.
    let knownMerchants: [String]
    /// Distinct sources available for filters and Quick Add.
    let availableSources: [String]

    static func load(
        notices: [Notice],
        bankTransactions: [BankTransaction]? = nil,
        accountMapping: [String: String]? = nil,
        localModifications: LocalModifications? = nil,
        now: Date = Date()
    ) async -> FinanceData? {
        await Task.detached(priority: .utility) {
            guard let raw = BundleInbox.storedData(), let bundle = try? DataBundle.decode(from: raw) else { return nil }
            let mfState = (bankTransactions == nil || accountMapping == nil)
                ? (try? MoneyForwardStore.loadState())
                : nil
            let resolvedTxs = bankTransactions ?? mfState?.transactions ?? []
            let resolvedMapping = accountMapping ?? mfState?.accountMapping ?? [:]
            let resolvedLocal = localModifications ?? LocalDataStore.loadModifications()
            return FinanceData(
                bundle: bundle,
                notices: notices,
                bankTransactions: resolvedTxs,
                accountMapping: resolvedMapping,
                localModifications: resolvedLocal,
                today: JST.day(now)
            )
        }.value
    }

    init(
        bundle: DataBundle,
        notices: [Notice],
        bankTransactions: [BankTransaction] = [],
        accountMapping: [String: String] = [:],
        localModifications: LocalModifications = LocalModifications(),
        today: String
    ) {
        self.bundle = bundle
        self.notices = notices
        let config = bundle.layerConfig
        let layered = BankLayering.build(
            bundle: bundle,
            bankTransactions: bankTransactions,
            accountMapping: accountMapping,
            notices: notices,
            categorizer: Categorizer(rules: bundle.rules),
            config: config
        )
        unmatched = layered.unmatched
        pendingCount = layered.pendingItems.count
        confirmedBankCount = layered.bankItems.count
        effectiveCoverage = layered.effectiveCoverage

        let baseItems = bundle.items + layered.bankItems + layered.pendingItems
        let applied = LocalDataApplier.apply(
            baseItems: baseItems,
            modifications: localModifications,
            config: config,
            layers: bundle.layers
        )
        let items = applied.allItems
        self.allItems = items
        self.localItemKeys = applied.localItemKeys
        self.localEntryByFingerprint = applied.localEntryByFingerprint

        // Build fast notice lookup for PaymentDetailSheet metadata (exact time, foreign currency, Merpay split, ref).
        var noticeMap: [String: Notice] = [:]
        for notice in notices {
            guard let amount = notice.amount else { continue }
            let sourceLabel = bundle.sourceLabels[notice.source.rawValue] ?? notice.source.rawValue
            let merchant = (notice.merchant?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
                ?? PendingBuilder.missingMerchantPlaceholder
            let fp = "\(notice.day)|\(sourceLabel)|\(amount)|\(TextFold.key(merchant))"
            if noticeMap[fp] == nil {
                noticeMap[fp] = notice
            }
        }
        self.noticeByFingerprint = noticeMap

        let bankReconciled = TimelineReconciler.reconcile(timeline: bundle.timeline, bankRows: layered.bankRows)
        let withReminders = LocalDataApplier.mergeCustomReminders(
            timeline: bankReconciled,
            reminders: localModifications.customReminders
        )
        let checked = LocalDataApplier.applyBillCheckoffs(
            timeline: withReminders,
            checkoffs: localModifications.billCheckoffs
        )
        self.timeline = checked.timeline
        self.phoneCheckedBillKeys = checked.phoneCheckedKeys

        let upcoming = PaydayView.compute(timeline: checked.timeline, today: today)
        let activePayday = upcoming.flatMap { $0.daysToPayday >= 0 ? $0 : nil }
        self.payday = activePayday
        self.comingUp = ComingUp.groups(timeline: checked.timeline, today: today)
        let start = checked.timeline.filter { $0.payday == true && $0.date <= today }.map(\.date).max()
        self.lastPayday = start
        self.spentSincePayday = start.map {
            PaydayView.spentSince(day: $0, items: items, config: config, layers: bundle.layers)
        }
        self.paydayBreakdown = activePayday.map {
            SpendingInsights.paydayBreakdown(
                payday: $0,
                lastPayday: start,
                items: items,
                config: config,
                layers: bundle.layers
            )
        }
        self.pendingSincePayday = start.map { day in
            layered.pendingItems.filter {
                $0.date >= day && config.resolvedLayer(for: $0, layers: bundle.layers) != nil
            }.count
        } ?? 0

        let totals = MonthTotals.compute(items: items, config: config, layers: bundle.layers)
        self.totalsByMonth = totals

        let incomeGroup = config.resolvedIncomeGroup ?? "Income"
        let sortedAll = items.sorted { ($0.date, $0.amount, $0.merchant) > ($1.date, $1.amount, $1.merchant) }
        self.allRowsSorted = NumberedRow.make(from: sortedAll)

        let payments = sortedAll.filter { $0.group != incomeGroup }
        self.paymentsByMonth = Dictionary(grouping: NumberedRow.make(from: payments)) { String($0.value.date.prefix(7)) }
        let sortedMonths = Set(paymentsByMonth.keys).union(totals.keys).sorted()
        self.months = sortedMonths

        let calPeriods = PayCycleBuilder.calendarPeriods(months: sortedMonths, asOf: bundle.asOf, today: today)
        self.calendarPeriods = calPeriods
        let cycles = PayCycleBuilder.payCycles(items: items, timeline: checked.timeline, config: config, today: today)
        self.payCycles = cycles
        self.totalsByCycle = PayCycleBuilder.totalsByPeriod(
            items: items,
            periods: cycles,
            config: config,
            layers: bundle.layers
        )

        let currentMonth = sortedMonths.last ?? String(today.prefix(7))
        let asOfMonth = String(bundle.asOf.prefix(7))
        let latestPartial = max(asOfMonth, String(today.prefix(7)))
        let inProgressMonth: String? = (currentMonth >= latestPartial) ? currentMonth : nil

        let subs = SubscriptionSummary.compute(from: bundle.subs)
        self.subscriptionSummary = subs

        // Recent 3 completed months average per category for newly added phone targets.
        let completedRecentMonths = Array(sortedMonths.filter { $0 != inProgressMonth }.suffix(3))
        var avgByCategory: [String: Int] = [:]
        if !completedRecentMonths.isEmpty {
            var sums: [String: Int] = [:]
            for m in completedRecentMonths {
                for (cat, stat) in totals[m]?.categories ?? [:] {
                    sums[cat, default: 0] += stat.sum
                }
            }
            for (cat, totalSum) in sums {
                avgByCategory[cat] = Int((Double(totalSum) / Double(completedRecentMonths.count)).rounded())
            }
        }

        let resolvedPlan = LocalDataApplier.applyPlanOverrides(
            plan: bundle.plan,
            overrides: localModifications.targetOverrides,
            recentAverageByCategory: avgByCategory
        )
        self.effectivePlan = resolvedPlan
        self.effectiveDebts = LocalDataApplier.applyDebtOverrides(
            debts: bundle.debts,
            overrides: localModifications.debtBalanceOverrides
        )

        let plan = PlanSummary.compute(
            plan: resolvedPlan,
            planWindow: bundle.planWindow,
            totalsByMonth: totals,
            selectedMonth: currentMonth,
            currentMonth: currentMonth,
            inProgressMonth: inProgressMonth
        )
        self.planSummary = plan

        let discreet = Set((bundle.discreetCategories ?? []).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })
        let detectedAlerts = SpendingInsights.detectAlerts(
            bundle: bundle,
            allItems: items,
            notices: notices,
            timeline: checked.timeline,
            planSummary: plan,
            subscriptionSummary: subs,
            today: today,
            discreetCategories: discreet
        )
        let activeAlerts = detectedAlerts.filter { !localModifications.dismissedAlertIDs.contains($0.id) }
        self.alerts = activeAlerts

        // Distinct categories from items + rules so pickers always offer every known category.
        var catPairs: [String: String] = [:]
        for item in items where !item.category.isEmpty {
            catPairs[item.category] = item.group
        }
        for rule in bundle.rules.rules where !rule.category.isEmpty {
            catPairs[rule.category] = catPairs[rule.category] ?? rule.group
        }
        let sortedCategories = catPairs
            .map { (group: $0.value, category: $0.key) }
            .sorted { $0.category.localizedCaseInsensitiveCompare($1.category) == .orderedAscending }
        self.availableCategories = sortedCategories

        self.reviewQueue = ReviewInboxBuilder.build(
            allItems: items,
            alerts: activeAlerts,
            availableCategories: sortedCategories,
            reviewedKeys: localModifications.reviewedItemKeys,
            today: today
        )

        // Frequent merchant names for Quick Add autocomplete.
        var merchantCounts: [String: Int] = [:]
        for item in items where item.amount > 0 && item.group != incomeGroup {
            merchantCounts[item.merchant, default: 0] += 1
        }
        self.knownMerchants = merchantCounts
            .sorted {
                if $0.value != $1.value { return $0.value > $1.value }
                return $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending
            }
            .prefix(80)
            .map(\.key)

        var sourceSet = Set(items.map(\.source))
        sourceSet.insert("Cash")
        self.availableSources = sourceSet.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func layer(of item: BudgetItem) -> String? {
        bundle.layerConfig.resolvedLayer(for: item, layers: bundle.layers)
    }

    func isLocalItem(_ item: BudgetItem) -> Bool {
        localItemKeys.contains(CategoryOverride.transactionFingerprint(for: item))
    }

    func localEntryID(for item: BudgetItem) -> UUID? {
        localEntryByFingerprint[CategoryOverride.transactionFingerprint(for: item)]
    }

    func matchedNotice(for item: BudgetItem) -> Notice? {
        noticeByFingerprint[CategoryOverride.transactionFingerprint(for: item)]
    }

    func periods(for mode: BudgetPeriodMode) -> [BudgetPeriod] {
        switch mode {
        case .calendarMonth:
            return calendarPeriods
        case .payCycle:
            return payCycles.isEmpty ? calendarPeriods : payCycles
        }
    }

    func totals(for mode: BudgetPeriodMode) -> [String: MonthTotals] {
        switch mode {
        case .calendarMonth:
            return totalsByMonth
        case .payCycle:
            return payCycles.isEmpty ? totalsByMonth : totalsByCycle
        }
    }

    func currentPeriod(for mode: BudgetPeriodMode, today: String) -> BudgetPeriod? {
        let list = periods(for: mode)
        return list.first(where: { $0.contains(today) }) ?? list.last
    }

    var widgetSnapshot: WidgetSnapshot {
        guard let p = payday else {
            return WidgetSnapshot(title: "Finance", value: "–", detail: "No upcoming payday in the data file", updatedAt: Date())
        }
        let dayToDay = paydayBreakdown?.dayToDaySpentSincePayday ?? spentSincePayday
        let spent = dayToDay.map { " · spent " + Money.yen($0) } ?? ""
        let unpaidBills: [WidgetBill] = p.outs
            .filter { $0.done != true && $0.amount > 0 }
            .prefix(3)
            .map { entry in
                WidgetBill(
                    title: entry.item,
                    date: entry.date,
                    dateLabel: DayText.short(entry.date),
                    amount: entry.amount,
                    isEstimate: entry.estimate == true
                )
            }

        let cycleProgress: Double?
        if let start = lastPayday,
           let startNum = JST.dayNumber(start),
           let endNum = JST.dayNumber(p.next.date),
           endNum > startNum
        {
            let span = Double(endNum - startNum)
            let elapsed = span - Double(max(0, p.daysToPayday))
            cycleProgress = min(1.0, max(0.0, elapsed / span))
        } else {
            cycleProgress = nil
        }

        return WidgetSnapshot(
            title: "Until payday · \(p.daysToPayday) days",
            value: Money.yen(p.left),
            detail: "for everything else" + spent,
            updatedAt: Date(),
            compactValue: FinanceFormat.compactYen(p.left),
            daysToPayday: p.daysToPayday,
            cycleProgress: cycleProgress,
            billsSum: p.outSum,
            leftSum: p.left,
            borrowedSum: p.borrowedSum,
            upcomingBills: unpaidBills
        )
    }

    static func publishWidget(_ snapshot: WidgetSnapshot, force: Bool = false) {
        guard SharedStore.groupID != nil else { return }
        if !force, let current = SharedStore.read(),
           current.title == snapshot.title,
           current.value == snapshot.value,
           current.detail == snapshot.detail,
           current.upcomingBills == snapshot.upcomingBills
        {
            return
        }
        SharedStore.write(snapshot)
        WidgetCenter.shared.reloadTimelines(ofKind: "FinanceWidget")
    }

    /// Fallback widget snapshot when no data file has been imported yet.
    static func noticeOnlySnapshot(notices: [Notice], now: Date = Date()) -> WidgetSnapshot {
        let since = JST.timestamp(now.addingTimeInterval(-7 * 86_400))
        let amounts = notices.filter {
            $0.receivedAt >= since && [.purchase, .refund, .settlement, .cancellation].contains($0.kind)
        }.compactMap(\.amount)
        let sum = amounts.reduce(0, +)
        return WidgetSnapshot(
            title: "Card notices, 7 days",
            value: "¥" + sum.formatted(),
            detail: "\(amounts.count) notices",
            updatedAt: now,
            compactValue: FinanceFormat.compactYen(sum)
        )
    }
}

/// Values identify rows across filters. The occurrence keeps identical rows distinct.
struct NumberedRow<Value: Hashable & Sendable>: Identifiable, Sendable {
    struct ID: Hashable, Sendable {
        let value: Value
        let occurrence: Int
    }

    let id: ID
    var value: Value { id.value }

    static func make(from values: [Value]) -> [Self] {
        var counts: [Value: Int] = [:]
        return values.map { value in
            let occurrence = counts[value, default: 0]
            counts[value] = occurrence + 1
            return Self(id: ID(value: value, occurrence: occurrence))
        }
    }
}

/// Yen as the dashboard writes it.
enum Money {
    static func yen(_ value: Int) -> String {
        (value < 0 ? "−¥" : "¥") + value.magnitude.formatted()
    }

    /// A payment: money out as "¥1,234", money in as "+¥1,234".
    static func payment(_ value: Int) -> String {
        value < 0 ? "+¥" + value.magnitude.formatted() : "¥" + value.formatted()
    }

    /// A ledger line: "+¥1,234" or "−¥1,234".
    static func signed(_ value: Int) -> String {
        (value < 0 ? "−¥" : "+¥") + value.magnitude.formatted()
    }
}

/// Japan-time calendar days as text, in English.
enum DayText {
    static func date(_ day: String) -> Date? {
        let p = day.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = JST.timeZone
        return calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
    }

    static func format(_ day: String, template: String) -> String {
        guard let d = date(day) else { return day }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.timeZone = JST.timeZone
        f.setLocalizedDateFormatFromTemplate(template)
        return f.string(from: d)
    }

    static func long(_ day: String) -> String { format(day, template: "EEEEMMMMd") }
    static func short(_ day: String) -> String { format(day, template: "MMMdEEE") }
    static func shortMonth(_ day: String) -> String { format(day, template: "MMM") }
    static func weekday(_ day: String) -> String { format(day, template: "EEE").uppercased() }
    static func dayOfMonth(_ day: String) -> String { String(Int(day.suffix(2)) ?? 0) }
    static func month(_ month: String) -> String { format(month + "-01", template: "MMMMyyyy") }
    static func monthUpper(_ month: String) -> String { format(month + "-01", template: "MMMM").uppercased() }
}
