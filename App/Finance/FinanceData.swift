import FinanceCore
import Foundation
import WidgetKit

/// Everything the screens show: the imported data file, confirmed Money Forward bank
/// transactions after each source's statement cutoff, remaining pending Gmail notices,
/// and phone-local additions/overrides.
struct FinanceData: Sendable {
    /// Stable per-snapshot identity so SwiftUI views can cheaply cache derived screen models.
    let id = UUID()
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
    let liveCash: LiveCashSummary?
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
    /// Pre-folded search haystacks aligned 1-to-1 with `allRowsSorted` so typing in search does zero `TextFold.key` work.
    let foldedSearchByRowID: [NumberedRow<BudgetItem>.ID: String]
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

        let start = checked.timeline.filter { $0.payday == true && $0.date <= today }.map(\.date).max()
        self.lastPayday = start

        let upcoming = PaydayView.compute(timeline: checked.timeline, today: today)
        let activePayday: PaydayView? = {
            if let upcoming, upcoming.daysToPayday >= 0 {
                return upcoming
            }
            // Payday rollover fallback: if the scheduled payday passed before a new PC bundle arrives,
            // synthesize an estimated next payday one month out so Now and the widget never go blank.
            let anchor = start ?? upcoming?.next.date
            guard let anchor,
                  let synthesizedDate = PayCycleBuilder.shiftMonth(anchor, by: 1),
                  synthesizedDate >= today
            else { return nil }
            let syntheticNext = FinanceCore.TimelineEntry(
                date: synthesizedDate,
                item: "Next payday",
                amount: 0,
                note: "Waiting for updated schedule",
                payday: true,
                next: true,
                estimate: true,
                recurring: true
            )
            let extended = checked.timeline.map { entry -> FinanceCore.TimelineEntry in
                var copy = entry
                copy.next = nil
                return copy
            } + [syntheticNext]
            return PaydayView.compute(timeline: extended, today: today)
        }()
        self.payday = activePayday
        self.comingUp = ComingUp.groups(timeline: checked.timeline, today: today)
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
        self.liveCash = LiveCashSummary.compute(
            accountBalances: bundle.accountBalances ?? [],
            sourceLabels: bundle.sourceLabels,
            bankRows: layered.allBankRows,
            pendingItems: layered.pendingItems,
            payday: activePayday,
            phoneCheckedBillKeys: checked.phoneCheckedKeys,
            lastPayday: start
        )
        self.pendingSincePayday = start.map { day in
            layered.pendingItems.filter {
                $0.date >= day && config.resolvedLayer(for: $0, layers: bundle.layers) != nil
            }.count
        } ?? 0

        let totals = MonthTotals.compute(items: items, config: config, layers: bundle.layers)
        self.totalsByMonth = totals

        let incomeGroup = config.resolvedIncomeGroup ?? "Income"
        let sortedAll = items.sorted { ($0.date, $0.amount, $0.merchant) > ($1.date, $1.amount, $1.merchant) }
        let numberedAll = NumberedRow.make(from: sortedAll)
        self.allRowsSorted = numberedAll
        var searchMap: [NumberedRow<BudgetItem>.ID: String] = [:]
        searchMap.reserveCapacity(numberedAll.count)
        for row in numberedAll {
            let item = row.value
            searchMap[row.id] = TextFold.key(item.merchant + " " + item.category + " " + item.source)
        }
        self.foldedSearchByRowID = searchMap

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

        let heroLeft = liveCash?.cashLeftUntilPayday
            ?? paydayBreakdown?.estimatedRemainingDiscretionary
            ?? p.left
        let heroBills = liveCash?.unsettledBillsSum ?? p.outSum
        let heroBorrowed = liveCash?.openBorrowedSum ?? p.borrowedSum
        let detailPrefix = liveCash != nil ? "bank cash after bills" : "est. after bills"

        return WidgetSnapshot(
            title: "Until payday · \(p.daysToPayday) days",
            value: Money.yen(heroLeft),
            detail: detailPrefix + spent,
            updatedAt: Date(),
            compactValue: FinanceFormat.compactYen(heroLeft),
            daysToPayday: p.daysToPayday,
            paydayDate: p.next.date,
            cycleProgress: cycleProgress,
            billsSum: heroBills,
            leftSum: heroLeft,
            borrowedSum: heroBorrowed,
            upcomingBills: unpaidBills
        )
    }

    static func publishWidget(_ snapshot: WidgetSnapshot, force: Bool = false) {
        guard SharedStore.groupID != nil else { return }
        if !force, let current = SharedStore.read(),
           current.title == snapshot.title,
           current.value == snapshot.value,
           current.detail == snapshot.detail,
           current.daysToPayday == snapshot.daysToPayday,
           current.paydayDate == snapshot.paydayDate,
           current.cycleProgress == snapshot.cycleProgress,
           current.billsSum == snapshot.billsSum,
           current.leftSum == snapshot.leftSum,
           current.borrowedSum == snapshot.borrowedSum,
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

/// Japan-time calendar days as text, in English, with thread-safe cached formatters
/// and memoized outputs so scrolling never allocates `DateFormatter`s per frame.
enum DayText {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = JST.timeZone
        return calendar
    }()

    private static let lock = NSLock()
    private nonisolated(unsafe) static var templateFormatters: [String: DateFormatter] = [:]
    private nonisolated(unsafe) static var fixedFormatters: [String: DateFormatter] = [:]
    private nonisolated(unsafe) static var parsedDates: [String: Date] = [:]
    private nonisolated(unsafe) static var formattedStrings: [String: String] = [:]

    static func date(_ day: String) -> Date? {
        lock.lock()
        if let cached = parsedDates[day] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let p = day.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        guard let d = calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2])) else { return nil }

        lock.lock()
        if parsedDates.count > 1_024 { parsedDates.removeAll(keepingCapacity: true) }
        parsedDates[day] = d
        lock.unlock()
        return d
    }

    static func format(_ day: String, template: String) -> String {
        let cacheKey = "t|\(template)|\(day)"
        lock.lock()
        if let cached = formattedStrings[cacheKey] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        guard let d = date(day) else { return day }

        lock.lock()
        let f: DateFormatter
        if let existing = templateFormatters[template] {
            f = existing
        } else {
            let created = DateFormatter()
            created.locale = Locale(identifier: "en_US")
            created.timeZone = JST.timeZone
            created.setLocalizedDateFormatFromTemplate(template)
            templateFormatters[template] = created
            f = created
        }
        let result = f.string(from: d)
        if formattedStrings.count > 2_048 { formattedStrings.removeAll(keepingCapacity: true) }
        formattedStrings[cacheKey] = result
        lock.unlock()
        return result
    }

    static func formatFixed(_ day: String, dateFormat: String) -> String {
        let cacheKey = "f|\(dateFormat)|\(day)"
        lock.lock()
        if let cached = formattedStrings[cacheKey] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        guard let d = date(day) else { return day }

        lock.lock()
        let f: DateFormatter
        if let existing = fixedFormatters[dateFormat] {
            f = existing
        } else {
            let created = DateFormatter()
            created.locale = Locale(identifier: "en_US")
            created.timeZone = JST.timeZone
            created.dateFormat = dateFormat
            fixedFormatters[dateFormat] = created
            f = created
        }
        let result = f.string(from: d)
        if formattedStrings.count > 2_048 { formattedStrings.removeAll(keepingCapacity: true) }
        formattedStrings[cacheKey] = result
        lock.unlock()
        return result
    }

    static func long(_ day: String) -> String { format(day, template: "EEEEMMMMd") }
    static func short(_ day: String) -> String { format(day, template: "MMMdEEE") }
    static func shortMonth(_ day: String) -> String { format(day, template: "MMM") }
    static func weekday(_ day: String) -> String { format(day, template: "EEE").uppercased() }
    static func dayOfMonth(_ day: String) -> String { String(Int(day.suffix(2)) ?? 0) }
    static func month(_ month: String) -> String { format(month + "-01", template: "MMMMyyyy") }
    static func monthUpper(_ month: String) -> String { format(month + "-01", template: "MMMM").uppercased() }
}
