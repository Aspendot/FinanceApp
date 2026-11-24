import Foundation
import Testing
@testable import FinanceCore

// Invented fixtures only.

private func makeSampleBundle() -> DataBundle {
    DataBundle(
        generatedAt: "2026-04-12T10:00:00+09:00",
        asOf: "2026-04-12",
        coverage: [
            "mufg_debit": CoverageRange(start: "2026-01-01", end: "2026-04-12"),
        ],
        sourceLabels: [
            "mufg_debit": "Sample Bank Card",
            "merpay": "Sample Wallet",
        ],
        items: [
            BudgetItem(date: "2026-01-01", source: "Sample Bank Card", merchant: "サンプル不動産", amount: 82000, group: "Housing", category: "Rent", layer: "Rent"),
            BudgetItem(date: "2026-01-12", source: "Sample Bank Card", merchant: "ひかり通信", amount: 4400, group: "Subscriptions", category: "Mobile plan", layer: "Subscriptions"),
            BudgetItem(date: "2026-01-15", source: "Sample Bank Card", merchant: "あおばスーパー", amount: 30000, group: "Living", category: "Groceries", layer: "Day-to-day"),
            BudgetItem(date: "2026-01-25", source: "Sample Bank Card", merchant: "Sample Corp", amount: -290000, group: "Income", category: "Salary"),

            BudgetItem(date: "2026-02-01", source: "Sample Bank Card", merchant: "サンプル不動産", amount: 82000, group: "Housing", category: "Rent", layer: "Rent"),
            BudgetItem(date: "2026-02-12", source: "Sample Bank Card", merchant: "ひかり通信", amount: 4400, group: "Subscriptions", category: "Mobile plan", layer: "Subscriptions"),
            BudgetItem(date: "2026-02-15", source: "Sample Bank Card", merchant: "あおばスーパー", amount: 28000, group: "Living", category: "Groceries", layer: "Day-to-day"),
            BudgetItem(date: "2026-02-20", source: "Sample Wallet", merchant: "はな食堂", amount: 18000, group: "Living", category: "Dining", layer: "Day-to-day"),
            BudgetItem(date: "2026-02-25", source: "Sample Bank Card", merchant: "Sample Corp", amount: -290000, group: "Income", category: "Salary"),

            BudgetItem(date: "2026-03-01", source: "Sample Bank Card", merchant: "サンプル不動産", amount: 82000, group: "Housing", category: "Rent", layer: "Rent"),
            BudgetItem(date: "2026-03-12", source: "Sample Bank Card", merchant: "ひかり通信", amount: 4400, group: "Subscriptions", category: "Mobile plan", layer: "Subscriptions"),
            BudgetItem(date: "2026-03-15", source: "Sample Bank Card", merchant: "あおばスーパー", amount: 32000, group: "Living", category: "Groceries", layer: "Day-to-day"),
            BudgetItem(date: "2026-03-20", source: "Sample Wallet", merchant: "はな食堂", amount: 22000, group: "Living", category: "Dining", layer: "Day-to-day"),
            BudgetItem(date: "2026-03-25", source: "Sample Bank Card", merchant: "Sample Corp", amount: -290000, group: "Income", category: "Salary"),

            BudgetItem(date: "2026-04-01", source: "Sample Bank Card", merchant: "サンプル不動産", amount: 82000, group: "Housing", category: "Rent", layer: "Rent"),
            BudgetItem(date: "2026-04-12", source: "Sample Bank Card", merchant: "ひかり通信", amount: 5500, group: "Subscriptions", category: "Mobile plan", layer: "Subscriptions"),
            BudgetItem(date: "2026-04-08", source: "Sample Bank Card", merchant: "あおばスーパー", amount: 12000, group: "Living", category: "Groceries", layer: "Day-to-day"),
            BudgetItem(date: "2026-04-10", source: "Sample Wallet", merchant: "はな食堂", amount: 16500, group: "Living", category: "Dining", layer: "Day-to-day"),
            BudgetItem(date: "2026-04-11", source: "Sample Wallet", merchant: "サンプル動画", amount: 1200, group: "Subscriptions", category: "Media", layer: "Subscriptions"),
            BudgetItem(date: "2026-04-11", source: "Sample Bank Card", merchant: "SAMPLE SHOP", amount: 2400, group: "Other", category: "Uncategorized", layer: "Day-to-day"),
            BudgetItem(date: "2026-04-12", source: "Sample Bank Card", merchant: "SAMPLE SHOP", amount: 2400, group: "Other", category: "Uncategorized", layer: "Day-to-day"),
        ],
        timeline: [
            TimelineEntry(date: "2026-03-25", item: "Monthly salary", amount: -290000, payday: true, done: true),
            TimelineEntry(date: "2026-04-01", item: "Apartment rent", amount: 82000, done: true),
            TimelineEntry(date: "2026-04-16", item: "みどり電気", amount: 9800, estimate: true),
            TimelineEntry(date: "2026-04-25", item: "Monthly salary", amount: -290000, payday: true, next: true),
        ],
        debts: [
            DebtEntry(name: "Sample Revolving", balance: 120000, limit: 200000, lines: ["18.0% a year", "Monthly ¥10,000"]),
        ],
        subs: [
            SubscriptionEntry(name: "ひかり通信", monthly: 4400, via: "Sample Bank Card", status: "Keep"),
            SubscriptionEntry(name: "そらクラウド", monthly: 1300, via: "Sample App Store", status: "Check"),
            SubscriptionEntry(name: "サンプル動画", monthly: 1200, via: "Sample Wallet", status: "Cancelled"),
            SubscriptionEntry(name: "サンプル通勤定期", monthly: 6000, via: "Sample Bank Card", status: "Repaid by employer"),
            SubscriptionEntry(name: "サンプルジム", monthly: 3000, via: "Sample Bank Card", status: "Stopped"),
            SubscriptionEntry(name: "サンプル旧プラン", monthly: 2000, via: "Sample Bank Card", status: "Not subscribed"),
        ],
        plan: [
            PlanEntry(category: "Dining", now: 20000, target: 15000, status: "Cut", note: "Cook more on weekdays"),
            PlanEntry(category: "Groceries", now: 30000, target: 35000, status: "Raise", note: "Shift lunch from dining"),
            PlanEntry(category: "Media", now: 3200, target: 1000, status: "Done", note: "Cancelled extra streaming"),
        ],
        planWindow: ["2026-02", "2026-03"],
        layers: [
            LayerDefinition(key: "Rent", color: "#2a78d6"),
            LayerDefinition(key: "Bills & taxes", color: "#eb6834"),
            LayerDefinition(key: "Subscriptions", color: "#1baf7a"),
            LayerDefinition(key: "Day-to-day", color: "#eda100"),
        ],
        layerConfig: LayerConfig(
            notSpendingGroups: ["Income", "Transfers"],
            rentCategories: ["Rent"],
            billGroups: ["Bills"],
            subscriptionGroups: ["Subscriptions"],
            subscriptionCategories: ["Mobile plan"],
            incomeGroup: "Income",
            peopleGroup: "People",
            debtGroup: "Debt"
        ),
        rules: RuleSet(rules: [
            CategoryRule(pattern: "あおばスーパー", group: "Living", category: "Groceries"),
            CategoryRule(pattern: "さくら珈琲", group: "Living", category: "Coffee"),
        ])
    )
}

@Suite("SubscriptionSummary")
struct SubscriptionSummaryTests {
    @Test func separatesRunningFromOffAndComputesSavingsCorrectly() {
        let bundle = makeSampleBundle()
        let summary = SubscriptionSummary.compute(from: bundle.subs)

        #expect(summary.runningCount == 2)
        #expect(summary.runningMonthlyTotal == 5700)
        #expect(summary.runningAnnualTotal == 68400)
        #expect(summary.stoppedCount == 4)
        // Cancelled (1200) + Stopped (3000) count as savings; Repaid (6000) and Not subscribed (2000) do not.
        #expect(summary.monthlySavings == 4200)
        #expect(summary.annualSavings == 50400)
        #expect(SubscriptionSummary.displayStatus("OK") == "On target")
        #expect(SubscriptionSummary.displayStatus("active") == nil)
        #expect(SubscriptionSummary.statusTone("Cut") == .bad)
        #expect(SubscriptionSummary.statusTone("Check") == .accent)
        #expect(SubscriptionSummary.statusTone("Cancelled") == .good)
    }
}

@Suite("PlanAnalytics")
struct PlanAnalyticsTests {
    @Test func computesTargetsProgressAndSavings() {
        let bundle = makeSampleBundle()
        let totals = MonthTotals.compute(items: bundle.items, config: bundle.layerConfig, layers: bundle.layers)
        let plan = PlanSummary.compute(
            plan: bundle.plan,
            planWindow: bundle.planWindow,
            totalsByMonth: totals,
            selectedMonth: "2026-04",
            currentMonth: "2026-04",
            inProgressMonth: "2026-04"
        )

        #expect(plan.active.count == 2)
        #expect(plan.settled.count == 1)
        #expect(plan.alreadyCut == 2200) // 3200 - 1000
        #expect(plan.potentialSavings == 0) // Dining +5000 and Groceries -5000
        // WatchList excludes "Raise" rows, leaving only Dining (16500 > 15000 -> over cap).
        #expect(plan.watchList.count == 1)
        #expect(plan.watchList[0].entry.category == "Dining")
        #expect(plan.watchList[0].isOverCapCurrentMonth == true)
        #expect(plan.watchList[0].currentMonthRemaining == -1500)
    }
}

@Suite("SpendingInsights and DebtPayoff")
struct SpendingInsightsTests {
    @Test func detectsDeclinesDuplicatesResurrectedSubsOverCapsAndPriceJumps() {
        let bundle = makeSampleBundle()
        let totals = MonthTotals.compute(items: bundle.items, config: bundle.layerConfig, layers: bundle.layers)
        let plan = PlanSummary.compute(
            plan: bundle.plan,
            planWindow: bundle.planWindow,
            totalsByMonth: totals,
            selectedMonth: "2026-04",
            currentMonth: "2026-04",
            inProgressMonth: "2026-04"
        )
        let subs = SubscriptionSummary.compute(from: bundle.subs)
        let decline = Notice(
            messageID: "m-dec-1",
            source: .merpay,
            kind: .decline,
            receivedAt: "2026-04-13T12:00:00+09:00",
            occurredAt: "2026-04-13T12:00:00+09:00",
            amount: 4500,
            merchant: "サンプル書店",
            parser: "merpay/1"
        )

        let alerts = SpendingInsights.detectAlerts(
            bundle: bundle,
            allItems: bundle.items,
            notices: [decline],
            timeline: bundle.timeline,
            planSummary: plan,
            subscriptionSummary: subs,
            today: "2026-04-14"
        )

        let kinds = Set(alerts.map(\.kind))
        #expect(kinds.contains(.declinedPayment))
        #expect(kinds.contains(.upcomingBillSoon))
        #expect(kinds.contains(.cancelledSubscriptionCharge))
        #expect(kinds.contains(.possibleDuplicate))
        #expect(kinds.contains(.capExceeded))
        #expect(kinds.contains(.uncategorizedItems))
        #expect(kinds.contains(.priceIncrease)) // ひかり通信 4400 -> 5500 (+25%)
    }

    @Test func simulatesDebtPayoffAndExtraPaymentSavings() {
        #expect(SpendingInsights.extractAnnualRate(from: ["18.0% a year"]) == 18.0)
        #expect(SpendingInsights.extractMonthlyPayment(from: ["18.0% a year · ¥4,400 interest", "Monthly ¥11,000"]) == 11000)

        let comp = SpendingInsights.compareDebtPayoff(
            balance: 120000,
            annualRatePercent: 18.0,
            basePayment: 10000,
            extraPayment: 5000,
            startMonth: "2026-04"
        )
        #expect(comp.baseline.firstMonthInterest == 1800)
        #expect(comp.baseline.monthsToPayoff == 14)
        #expect(comp.accelerated.monthsToPayoff == 9)
        #expect(comp.monthsSaved == 5)
        #expect((comp.interestSaved ?? 0) > 4000)

        let stuck = SpendingInsights.simulateDebtPayoff(
            balance: 300000,
            annualRatePercent: 18.0,
            monthlyPayment: 4000, // below ¥4,500 monthly interest
            startMonth: "2026-04"
        )
        #expect(stuck.monthsToPayoff == nil)
    }

    @Test func computesPaydayBreakdownWithoutDoubleCountingBills() {
        let bundle = makeSampleBundle()
        let payday = PaydayView.compute(timeline: bundle.timeline, today: "2026-04-14")!
        let breakdown = SpendingInsights.paydayBreakdown(
            payday: payday,
            lastPayday: "2026-03-25",
            items: bundle.items,
            config: bundle.layerConfig,
            layers: bundle.layers
        )

        #expect(breakdown.paidBillsSum == 82000)
        #expect(breakdown.remainingBillsSum == 9800)
        // Excludes April Rent (82,000) and Subscriptions (5,500 + 1,200) so Day-to-day reconciles with Payments.
        #expect(breakdown.dayToDaySpentSincePayday == 12000 + 16500 + 2400 + 2400)
        #expect(breakdown.totalSpentSincePayday == breakdown.dayToDaySpentSincePayday + 5500 + 1200 + 82000)
        #expect(breakdown.estimatedRemainingDiscretionary == payday.left - breakdown.dayToDaySpentSincePayday)
    }
}

@Suite("LocalModifications and PayPayCSVParser")
struct LocalModificationsAndCSVTests {
    @Test func appliesOverridesMergesLocalEntriesAndDeduplicatesSupersededImports() {
        let bundle = makeSampleBundle()
        let manual = ManualEntry(
            date: "2026-04-14",
            source: "Cash",
            merchant: "サンプルパン屋",
            amount: 850,
            group: "Living",
            category: "Groceries",
            origin: .manual
        )
        // Exact duplicate of an existing bundle row -> should be suppressed automatically.
        let dupImport = ManualEntry(
            date: "2026-04-08",
            source: "Sample Bank Card",
            merchant: "あおばスーパー",
            amount: 12000,
            group: "Living",
            category: "Groceries",
            origin: .csvImport
        )
        let override = CategoryOverride(
            scope: .merchant(foldedKey: TextFold.key("SAMPLE SHOP"), displayMerchant: "SAMPLE SHOP"),
            group: "Living",
            category: "Household"
        )
        let mods = LocalModifications(
            manualEntries: [manual],
            importedEntries: [dupImport],
            categoryOverrides: [override]
        )

        let applied = LocalDataApplier.apply(
            baseItems: bundle.items,
            modifications: mods,
            config: bundle.layerConfig,
            layers: bundle.layers
        )

        #expect(applied.supersededImportCount == 1)
        #expect(applied.allItems.count == bundle.items.count + 1)
        let shops = applied.allItems.filter { $0.merchant == "SAMPLE SHOP" }
        #expect(shops.count == 2)
        #expect(shops.allSatisfy { $0.category == "Household" && $0.layer == "Day-to-day" })
    }

    @Test func parsesPayPayCSVSkipsTopUpsAndDeduplicates() throws {
        let csv = """
        \u{FEFF}取引日,出金金額（円）,入金金額（円）,海外出金金額,通貨,取引内容,取引先,取引方法,支払い区分,利用者,取引番号
        2026/04/13 12:34:56,"1,250",-,-,-,支払い,あおばスーパー,PayPay残高,-,-,TX001
        2026/04/13 15:00:00,"3,400",-,-,-,支払い,さくら珈琲店,PayPayカード（クレジット）,1回払い,-,TX002
        2026/04/13 16:00:00,-,"10,000",-,-,チャージ,サンプル銀行,銀行口座,-,-,TX003
        2026/04/14 09:00:00,"2,000",-,-,-,送った金額,サンプル太郎,PayPay残高,-,-,TX004
        """
        let bundle = makeSampleBundle()
        let categorizer = Categorizer(rules: bundle.rules)
        let first = try PayPayCSVParser.parse(csvText: csv, categorizer: categorizer)

        #expect(first.entries.count == 3)
        #expect(first.skippedNonSpending == 1) // チャージ skipped
        #expect(first.skippedDuplicates == 0)

        let supermarket = first.entries.first { $0.merchant == "あおばスーパー" }
        #expect(supermarket?.source == "PayPay")
        #expect(supermarket?.amount == 1250)
        #expect(supermarket?.category == "Groceries")

        let coffee = first.entries.first { $0.merchant == "さくら珈琲店" }
        #expect(coffee?.source == "PayPay Card")
        #expect(coffee?.amount == 3400)
        #expect(coffee?.category == "Coffee")

        let transfer = first.entries.first { $0.merchant == "サンプル太郎" }
        #expect(transfer?.group == "People")

        // Re-importing the exact same CSV with existingExternalIDs yields 0 new entries.
        let existingIDs = Set(first.entries.compactMap(\.externalID))
        let second = try PayPayCSVParser.parse(
            csvText: csv,
            categorizer: categorizer,
            existingExternalIDs: existingIDs
        )
        #expect(second.entries.isEmpty)
        #expect(second.skippedDuplicates == 3)
    }
}

@Suite("FinanceQueryEngine")
struct FinanceQueryEngineTests {
    @Test func answersPaydayCategoryComparisonAndMerchantQuestions() {
        let bundle = makeSampleBundle()
        let totals = MonthTotals.compute(items: bundle.items, config: bundle.layerConfig, layers: bundle.layers)
        let payday = PaydayView.compute(timeline: bundle.timeline, today: "2026-04-14")
        let plan = PlanSummary.compute(
            plan: bundle.plan,
            planWindow: bundle.planWindow,
            totalsByMonth: totals,
            selectedMonth: "2026-04",
            currentMonth: "2026-04",
            inProgressMonth: "2026-04"
        )
        let subs = SubscriptionSummary.compute(from: bundle.subs)
        let ctx = FinanceQueryEngine.Context(
            bundle: bundle,
            allItems: bundle.items,
            totalsByMonth: totals,
            timeline: bundle.timeline,
            payday: payday,
            planSummary: plan,
            subscriptionSummary: subs,
            today: "2026-04-14"
        )

        let paydayQ = FinanceQueryEngine.answer("How much is left until payday?", context: ctx)
        #expect(paydayQ.headline == "¥198,200")

        let catQ = FinanceQueryEngine.answer("How much did I spend on dining in March?", context: ctx)
        #expect(catQ.headline == "¥22,000")

        let cmpQ = FinanceQueryEngine.answer("Compare February and March", context: ctx)
        #expect(cmpQ.headline == "+¥8,000")

        let debtQ = FinanceQueryEngine.answer("How much debt do I owe?", context: ctx)
        #expect(debtQ.headline == "¥120,000")

        let subQ = FinanceQueryEngine.answer("What subscriptions am I paying?", context: ctx)
        #expect(subQ.headline == "¥5,700/mo")

        let shopQ = FinanceQueryEngine.answer("How much at はな食堂 all time?", context: ctx)
        #expect(shopQ.headline == "¥56,500")
    }
}
