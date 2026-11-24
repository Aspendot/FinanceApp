import Foundation
import Testing
@testable import FinanceCore

@Suite("v0.6.0 Engines: PayCycle, CashFlowForecast, DeepInspectors, ReceiptExtraction & LocalModifications")
struct V06FeaturesTests {
    private static let sampleLayers: [LayerDefinition] = [
        LayerDefinition(key: "Rent", color: "#2a78d6"),
        LayerDefinition(key: "Bills & taxes", color: "#eb6834"),
        LayerDefinition(key: "Subscriptions", color: "#1baf7a"),
        LayerDefinition(key: "Day-to-day", color: "#eda100"),
    ]

    private static let sampleConfig = LayerConfig(
        notSpendingGroups: ["Income", "Transfers"],
        rentCategories: ["Rent"],
        billGroups: ["Bills"],
        subscriptionGroups: ["Subscriptions"],
        subscriptionCategories: ["Mobile plan"],
        incomeGroup: "Income",
        peopleGroup: "People",
        debtGroup: "Debt"
    )

    @Test("LocalModifications decodes legacy v1 JSON cleanly and applies target, debt, and reminder overrides")
    func localModificationsBackwardsCompatibilityAndOverrides() throws {
        // Legacy v1 payload missing new v0.6 fields.
        let v1JSON = """
        {
          "version": 1,
          "manualEntries": [],
          "importedEntries": [],
          "categoryOverrides": [],
          "billCheckoffs": [],
          "dismissedAlertIDs": ["old-alert"]
        }
        """
        let decoded = try JSONDecoder().decode(LocalModifications.self, from: Data(v1JSON.utf8))
        #expect(decoded.version == 1)
        #expect(decoded.dismissedAlertIDs == ["old-alert"])
        #expect(decoded.targetOverrides.isEmpty)
        #expect(decoded.debtBalanceOverrides.isEmpty)
        #expect(decoded.customReminders.isEmpty)
        #expect(decoded.reviewedItemKeys.isEmpty)
        #expect(!decoded.isEmpty)

        // Plan overrides update existing categories and append new phone-set caps.
        let plan = [
            PlanEntry(category: "Dining", now: 20_000, target: 12_000, status: "Cut"),
            PlanEntry(category: "Coffee", now: 5_000, target: 3_000, status: "Cut"),
        ]
        let updatedPlan = LocalDataApplier.applyPlanOverrides(
            plan: plan,
            overrides: ["Dining": 9_500, "Books": 4_000],
            recentAverageByCategory: ["Books": 6_500]
        )
        #expect(updatedPlan.first(where: { $0.category == "Dining" })?.target == 9_500)
        #expect(updatedPlan.first(where: { $0.category == "Books" })?.target == 4_000)
        #expect(updatedPlan.first(where: { $0.category == "Books" })?.now == 6_500)

        // Debt overrides update matching balances.
        let debts = [
            DebtEntry(name: "Sample Card", balance: 64_000, limit: 200_000),
            DebtEntry(name: "Sample Loan", balance: 180_000),
        ]
        let updatedDebts = LocalDataApplier.applyDebtOverrides(
            debts: debts,
            overrides: ["Sample Card": 52_000]
        )
        #expect(updatedDebts[0].balance == 52_000)
        #expect(updatedDebts[1].balance == 180_000)

        // Custom reminders merge chronologically into timeline.
        let baseTimeline = [
            TimelineEntry(date: "2026-04-20", item: "Mobile bill", amount: 4_400),
            TimelineEntry(date: "2026-04-25", item: "Salary", amount: -290_000, payday: true, next: true),
        ]
        let reminder = CustomReminder(
            date: "2026-04-18",
            title: "Cancel Sample News trial",
            amount: 0,
            note: "Before renewal",
            isEvent: true
        )
        let merged = LocalDataApplier.mergeCustomReminders(timeline: baseTimeline, reminders: [reminder])
        #expect(merged.count == 3)
        #expect(merged[0].date == "2026-04-18")
        #expect(merged[0].event == true)
    }

    @Test("PayCycleBuilder splits cycles payday-to-day-before-payday and computes Pace Notch progress")
    func payCyclesAndPaceNotch() {
        let items: [BudgetItem] = [
            BudgetItem(date: "2026-02-25", source: "Sample Bank", merchant: "Sample Corp Salary", amount: -290_000, group: "Income", category: "Salary"),
            BudgetItem(date: "2026-03-01", source: "Sample Bank", merchant: "Sample Landlord", amount: 82_000, group: "Housing", category: "Rent", layer: "Rent"),
            BudgetItem(date: "2026-03-10", source: "Sample Bank", merchant: "Sample Market", amount: 18_000, group: "Living", category: "Groceries", layer: "Day-to-day"),
            BudgetItem(date: "2026-03-25", source: "Sample Bank", merchant: "Sample Corp Salary", amount: -290_000, group: "Income", category: "Salary"),
            BudgetItem(date: "2026-04-01", source: "Sample Bank", merchant: "Sample Landlord", amount: 82_000, group: "Housing", category: "Rent", layer: "Rent"),
            BudgetItem(date: "2026-04-08", source: "Sample Bank", merchant: "Sample Diner", amount: 6_500, group: "Living", category: "Dining", layer: "Day-to-day"),
        ]
        let timeline = [
            TimelineEntry(date: "2026-03-25", item: "Salary", amount: -290_000, payday: true, done: true),
            TimelineEntry(date: "2026-04-25", item: "Salary", amount: -290_000, payday: true, next: true),
        ]

        let cycles = PayCycleBuilder.payCycles(
            items: items,
            timeline: timeline,
            config: Self.sampleConfig,
            today: "2026-04-14"
        )
        #expect(cycles.count == 2)
        #expect(cycles[0].startDate == "2026-02-25")
        #expect(cycles[0].endDate == "2026-03-24")
        #expect(cycles[0].isInProgress == false)
        #expect(cycles[1].startDate == "2026-03-25")
        #expect(cycles[1].endDate == "2026-04-24")
        #expect(cycles[1].isInProgress == true)

        // Pace notch on 2026-04-14 inside Mar 25..Apr 24 (31 days, day 21 elapsed).
        let pace = cycles[1].paceProgress(on: "2026-04-14")
        #expect(pace != nil)
        #expect((pace ?? 0) > 0.65 && (pace ?? 0) < 0.70)
        #expect(cycles[0].paceProgress(on: "2026-04-14") == nil)

        let totals = PayCycleBuilder.totalsByPeriod(
            items: items,
            periods: cycles,
            config: Self.sampleConfig,
            layers: Self.sampleLayers
        )
        let activeTotals = totals[cycles[1].id]
        #expect(activeTotals?.income == 290_000)
        #expect(activeTotals?.total == 88_500)
        #expect(activeTotals?.left == 201_500)
    }

    @Test("CashFlowForecast projects 90 days and responds to What-If subscription cancellations and debt payments")
    func cashFlowRunwayAndWhatIf() {
        let timeline = [
            TimelineEntry(date: "2026-03-25", item: "Monthly salary", amount: -290_000, payday: true, done: true),
            TimelineEntry(date: "2026-04-01", item: "Apartment rent", amount: 82_000, done: true),
            TimelineEntry(date: "2026-04-16", item: "Sample Power", amount: 10_000),
            TimelineEntry(date: "2026-04-25", item: "Monthly salary", amount: -290_000, payday: true, next: true),
            TimelineEntry(date: "2026-05-01", item: "Apartment rent", amount: 82_000),
        ]
        let items = [
            BudgetItem(date: "2026-04-05", source: "Sample Card", merchant: "Sample Market", amount: 30_000, group: "Living", category: "Groceries", layer: "Day-to-day"),
            BudgetItem(date: "2026-03-26", source: "Sample Card", merchant: "Sample Diner", amount: 15_000, group: "Living", category: "Dining", layer: "Day-to-day"),
        ]
        let subs = SubscriptionSummary.compute(from: [
            SubscriptionEntry(name: "Sample Cloud", monthly: 3_000, via: "Sample Card", status: "Review"),
            SubscriptionEntry(name: "Sample Music", monthly: 1_500, via: "Sample Card", status: "Keep"),
        ])
        let payday = PaydayView.compute(timeline: timeline, today: "2026-04-14")
        let breakdown = payday.map {
            SpendingInsights.paydayBreakdown(
                payday: $0,
                lastPayday: "2026-03-25",
                items: items,
                config: Self.sampleConfig,
                layers: Self.sampleLayers
            )
        }

        let base = CashFlowForecast.project(
            today: "2026-04-14",
            days: 90,
            payday: payday,
            paydayBreakdown: breakdown,
            timeline: timeline,
            allItems: items,
            subscriptionSummary: subs,
            config: Self.sampleConfig,
            layers: Self.sampleLayers
        )
        #expect(base.points.count == 90)
        #expect(base.startingCashEstimate == 290_000 - 82_000 - 45_000)
        #expect(base.scenarioDelta == 0)

        let subID = subs.running[0].id
        let scenario = WhatIfScenario(
            cancelledSubscriptionIDs: [subID],
            extraMonthlyDebtPayment: 0,
            monthlyDayToDaySavings: 15_000
        )
        let whatIf = CashFlowForecast.project(
            today: "2026-04-14",
            days: 90,
            payday: payday,
            paydayBreakdown: breakdown,
            timeline: timeline,
            allItems: items,
            subscriptionSummary: subs,
            config: Self.sampleConfig,
            layers: Self.sampleLayers,
            scenario: scenario
        )
        // Cancelling ¥3,000/mo + ¥15,000/mo savings over 89 elapsed days ≈ +¥53,400.
        #expect(whatIf.cancelledSubsMonthlyTotal == 3_000)
        #expect(whatIf.scenarioDelta > 50_000 && whatIf.scenarioDelta < 56_000)
    }

    @Test("DeepInspectors compute subscription price jumps, debt ledger cashflow, and Review Inbox suggestions")
    func deepInspectorsAndReviewInbox() {
        let items: [BudgetItem] = [
            BudgetItem(date: "2026-01-14", source: "Sample App", merchant: "そらクラウド", amount: 1_300, group: "Subscriptions", category: "Cloud storage", layer: "Subscriptions"),
            BudgetItem(date: "2026-02-14", source: "Sample App", merchant: "そらクラウド", amount: 1_300, group: "Subscriptions", category: "Cloud storage", layer: "Subscriptions"),
            BudgetItem(date: "2026-03-14", source: "Sample App", merchant: "そらクラウド", amount: 1_500, group: "Subscriptions", category: "Cloud storage", layer: "Subscriptions"),
            BudgetItem(date: "2026-02-28", source: "Sample Bank", merchant: "Sample Card Revolving", amount: 15_000, group: "Debt", category: "Card balance"),
            BudgetItem(date: "2026-03-10", source: "Sample Bank", merchant: "Sample Card Revolving", amount: -10_000, group: "Debt", category: "Card balance"),
            BudgetItem(date: "2026-03-28", source: "Sample Bank", merchant: "Sample Card Revolving", amount: 15_000, group: "Debt", category: "Card balance"),
            BudgetItem(date: "2026-04-12", source: "Sample Bank", merchant: "あおばスーパー", amount: 4_200, group: "Living", category: "Groceries", layer: "Day-to-day"),
            BudgetItem(date: "2026-04-14", source: "Sample Bank", merchant: "あおばスーパー", amount: 2_100, group: "Other", category: "Uncategorized", layer: "Day-to-day", isPending: true),
        ]

        let subSummary = SubscriptionSummary.compute(from: [
            SubscriptionEntry(name: "そらクラウド", monthly: 1_500, via: "Sample App", status: "Check")
        ])
        let subHistory = SubscriptionHistory.compute(
            for: subSummary.running[0],
            allItems: items,
            months: ["2026-01", "2026-02", "2026-03", "2026-04"],
            today: "2026-04-14"
        )
        #expect(subHistory.matchedItems.count == 3)
        #expect(subHistory.last12MonthsSpend == 4_100)
        #expect(subHistory.priceChangeDelta == 200)

        let debt = DebtEntry(name: "Sample Card Revolving", balance: 64_000, limit: 200_000, lines: ["15.0% a year"])
        let debtHist = DebtHistory.compute(
            for: debt,
            allItems: items,
            config: Self.sampleConfig,
            months: ["2026-02", "2026-03", "2026-04"],
            today: "2026-04-14"
        )
        #expect(debtHist.ytdRepaid == 30_000)
        #expect(debtHist.ytdBorrowed == 10_000)
        #expect(debtHist.ytdNetProgress == 20_000)
        #expect(debtHist.estimatedMonthlyInterest == 800)

        let queue = ReviewInboxBuilder.build(
            allItems: items,
            alerts: [],
            availableCategories: [("Living", "Groceries"), ("Living", "Dining")],
            reviewedKeys: [],
            today: "2026-04-14"
        )
        #expect(queue.count == 1)
        #expect(queue[0].reason == .pendingEmail)
        #expect(queue[0].suggestions.first?.category == "Groceries")
    }

    @Test("ReceiptExtraction parses fenced AI JSON, batch arrays, duplicate detection, and Japanese offline OCR")
    func receiptExtractionAIAndOffline() {
        let categories = [
            (group: "Living", category: "Groceries"),
            (group: "Bills", category: "Utilities"),
            (group: "Living", category: "Dining"),
        ]
        let categorizer = Categorizer(rules: RuleSet(rules: [
            CategoryRule(pattern: "サンプルスーパー", group: "Living", category: "Groceries"),
        ]))
        let existing = [
            BudgetItem(date: "2026-04-14", source: "Cash", merchant: "サンプル食堂", amount: 1_250, group: "Living", category: "Dining", layer: "Day-to-day"),
        ]

        let aiResponse = """
        ```json
        {
          "items": [
            {
              "date": "2026-04-14",
              "merchant": "サンプル市上下水道局",
              "amount": 4820,
              "category": "Utilities",
              "source": "Cash",
              "note": "Water slip Mar-Apr",
              "lineItems": ["水道料金 4820"],
              "confidence": "high"
            },
            {
              "date": "2026-04-14",
              "merchant": "サンプル食堂",
              "amount": "¥1,250",
              "category": "Dining",
              "source": "Cash",
              "note": "Lunch"
            }
          ]
        }
        ```
        """
        let drafts = ReceiptExtraction.parseAIResponse(
            aiResponse,
            today: "2026-04-14",
            defaultSource: "Cash",
            availableCategories: categories,
            categorizer: categorizer,
            existingItems: existing
        )
        #expect(drafts.count == 2)
        #expect(drafts[0].merchant == "サンプル市上下水道局")
        #expect(drafts[0].amount == 4_820)
        #expect(drafts[0].group == "Bills")
        #expect(drafts[0].category == "Utilities")
        #expect(drafts[0].isPossibleDuplicate == false)
        #expect(drafts[0].isSelected == true)

        #expect(drafts[1].amount == 1_250)
        #expect(drafts[1].isPossibleDuplicate == true)
        #expect(drafts[1].isSelected == false)

        // Offline Japanese receipt OCR fallback (ignores お預り / お釣り, converts 令和8年 -> 2026).
        let ocrLines = [
            "領収書",
            "サンプルスーパー 駅前店",
            "令和8年4月13日 18:42",
            "牛乳 218",
            "おにぎり 320",
            "小計 ¥538",
            "合計 ¥581",
            "お預り ¥1,000",
            "お釣り ¥419",
        ]
        let offline = ReceiptExtraction.parseOfflineOCR(
            lines: ocrLines,
            today: "2026-04-14",
            defaultSource: "Cash",
            availableCategories: categories,
            categorizer: categorizer,
            existingItems: existing
        )
        #expect(offline.count == 1)
        #expect(offline[0].date == "2026-04-13")
        #expect(offline[0].amount == 581)
        #expect(offline[0].merchant == "サンプルスーパー 駅前店")
        #expect(offline[0].category == "Groceries")
    }

    @Test("Two-way sync deduplicates round-tripped manual entries and suppresses deleted entries immediately")
    func twoWaySyncManualEntryDedupAndDeletion() {
        let manual = ManualEntry(
            date: "2026-04-14",
            source: "Cash",
            merchant: "サンプルラーメン",
            amount: 950,
            group: "Living",
            category: "Dining",
            note: "Lunch"
        )
        let bundleItem = manual.asBudgetItem(config: Self.sampleConfig, layers: Self.sampleLayers)
        let mods = LocalModifications(manualEntries: [manual])

        // Once PC bundle absorbs the synced manual entry, applying LocalModifications must NOT double-count it.
        let applied = LocalDataApplier.apply(
            baseItems: [bundleItem],
            modifications: mods,
            config: Self.sampleConfig,
            layers: Self.sampleLayers
        )
        #expect(applied.allItems.count == 1)
        #expect(applied.supersededImportCount == 1)
        // Still tracked as local so the user can delete it from PaymentDetailSheet.
        let fp = CategoryOverride.transactionFingerprint(for: bundleItem)
        #expect(applied.localItemKeys.contains(fp))
        #expect(applied.localEntryByFingerprint[fp] == manual.id)

        // Deleting the entry adds its fingerprint to deletedEntryFingerprints -> hides bundle copy immediately.
        let afterDelete = LocalDataApplier.apply(
            baseItems: [bundleItem],
            modifications: LocalModifications(deletedEntryFingerprints: [fp]),
            config: Self.sampleConfig,
            layers: Self.sampleLayers
        )
        #expect(afterDelete.allItems.isEmpty)
    }

    @Test("PaydayBreakdown reconciles strictly to Day-to-day layer within active cycle and excludes Subscriptions")
    func paydayBreakdownReconcilesToDayToDay() {
        let timeline = [
            TimelineEntry(date: "2026-03-25", item: "Salary", amount: -290_000, payday: true, done: true),
            TimelineEntry(date: "2026-04-01", item: "Rent", amount: 80_000, done: true),
            TimelineEntry(date: "2026-04-25", item: "Salary", amount: -290_000, payday: true, next: true),
        ]
        let items = [
            BudgetItem(date: "2026-04-01", source: "Sample Bank", merchant: "Rent", amount: 80_000, group: "Housing", category: "Rent", layer: "Rent"),
            BudgetItem(date: "2026-04-03", source: "Sample Card", merchant: "Cloud Sub", amount: 4_000, group: "Subscriptions", category: "Cloud", layer: "Subscriptions"),
            BudgetItem(date: "2026-04-10", source: "Sample Bank", merchant: "Market", amount: 12_500, group: "Living", category: "Groceries", layer: "Day-to-day"),
            BudgetItem(date: "2026-04-26", source: "Sample Bank", merchant: "Next Cycle Market", amount: 9_900, group: "Living", category: "Groceries", layer: "Day-to-day"),
        ]
        let payday = PaydayView.compute(timeline: timeline, today: "2026-04-14")!
        let breakdown = SpendingInsights.paydayBreakdown(
            payday: payday,
            lastPayday: "2026-03-25",
            items: items,
            config: Self.sampleConfig,
            layers: Self.sampleLayers
        )
        #expect(breakdown.dayToDaySpentSincePayday == 12_500)
        #expect(breakdown.totalSpentSincePayday == 96_500)
        #expect(breakdown.estimatedRemainingDiscretionary == payday.left - 12_500)
    }

    @Test("CashFlowForecast never repeats one-offs and excludes deferred credit cards already billed on timeline")
    func cashFlowExcludesOneOffsAndDeferredCardDoubleCount() {
        let timeline = [
            TimelineEntry(date: "2026-03-25", item: "Salary", amount: -300_000, payday: true, done: true, recurring: true),
            TimelineEntry(date: "2026-03-26", item: "Pay back friend", amount: 80_000, done: true, recurring: false),
            TimelineEntry(date: "2026-04-20", item: "Deferred Card bill", amount: 40_000, recurring: true),
            TimelineEntry(date: "2026-04-23", item: "One-off tax part", amount: 40_000, recurring: false),
            TimelineEntry(date: "2026-04-25", item: "Salary", amount: -300_000, payday: true, next: true, recurring: true),
        ]
        let items = [
            BudgetItem(date: "2026-04-01", source: "Sample Debit", merchant: "Market", amount: 30_000, group: "Living", category: "Groceries", layer: "Day-to-day"),
            BudgetItem(date: "2026-04-02", source: "Deferred Card", merchant: "Online Shop", amount: 60_000, group: "Living", category: "Shopping", layer: "Day-to-day"),
        ]
        let payday = PaydayView.compute(timeline: timeline, today: "2026-04-14")
        let forecast = CashFlowForecast.project(
            today: "2026-04-14",
            days: 90,
            payday: payday,
            paydayBreakdown: nil,
            timeline: timeline,
            allItems: items,
            subscriptionSummary: SubscriptionSummary.compute(from: []),
            config: Self.sampleConfig,
            layers: Self.sampleLayers,
            startingCashOverride: 100_000
        )

        let projectedTitles = forecast.points.flatMap(\.events).filter(\.isProjectedRepeat).map(\.title)
        #expect(!projectedTitles.contains("Pay back friend"))
        #expect(!projectedTitles.contains("One-off tax part"))
        #expect(projectedTitles.contains("Deferred Card bill"))
        #expect(forecast.excludedDeferredCardSources == ["Deferred Card"])
        // Daily burn uses only Sample Debit (¥30,000 over 14d min span = ¥2,143/day), not ¥90,000/14d.
        #expect(forecast.baselineDailyBurn < 2_500)
    }

    @Test("LayerConfig keeps Excluded separate from Work and SubscriptionHistory avoids retail false positives")
    func excludedGroupAndSubscriptionMatchingPrecision() {
        let cfg = LayerConfig(
            notSpendingGroups: ["Income", "People", "Debt", "Work (repaid by employer)"],
            rentCategories: ["Rent"],
            billGroups: ["Fixed bills"],
            subscriptionGroups: ["Subscriptions"],
            incomeGroup: "Income",
            peopleGroup: "People",
            debtGroup: "Debt"
        )
        #expect(cfg.resolvedExcludedGroup == "Excluded")
        #expect(cfg.resolvedWorkGroup == "Work (repaid by employer)")
        #expect(cfg.layer(group: "Excluded", category: "Excluded", layers: Self.sampleLayers) == nil)

        let items = [
            BudgetItem(date: "2026-03-05", source: "Debit", merchant: "AMAZON P", amount: 600, group: "Subscriptions", category: "Other subs", layer: "Subscriptions"),
            BudgetItem(date: "2026-03-07", source: "Debit", merchant: "AMAZON CO JP", amount: 3_400, group: "Shopping", category: "Online shopping", layer: "Day-to-day"),
            BudgetItem(date: "2026-03-10", source: "Bank", merchant: "電話 KDDIリヨウキン", amount: 5_500, group: "Fixed bills", category: "Internet", layer: "Bills & taxes"),
            BudgetItem(date: "2026-03-12", source: "Debit", merchant: "ANTHROPI", amount: 18_000, group: "Subscriptions", category: "AI", layer: "Subscriptions"),
        ]
        let primeSub = SubscriptionSummary.compute(from: [SubscriptionEntry(name: "Amazon Prime", monthly: 600, status: "Check")]).running[0]
        let primeHist = SubscriptionHistory.compute(for: primeSub, allItems: items, months: ["2026-03"], today: "2026-04-14", config: cfg, layers: Self.sampleLayers)
        #expect(primeHist.matchedItems.count == 1)
        #expect(primeHist.matchedItems[0].merchant == "AMAZON P")

        let kddiSub = SubscriptionSummary.compute(from: [SubscriptionEntry(name: "Fiber internet (billed by KDDI)", monthly: 5_500, status: "Keep")]).running[0]
        let kddiHist = SubscriptionHistory.compute(for: kddiSub, allItems: items, months: ["2026-03"], today: "2026-04-14", config: cfg, layers: Self.sampleLayers)
        #expect(kddiHist.matchedItems.count == 1)

        let aiSub = SubscriptionSummary.compute(from: [SubscriptionEntry(name: "Claude (Anthropic)", monthly: 17_950, status: "Keep")]).running[0]
        let aiHist = SubscriptionHistory.compute(for: aiSub, allItems: items, months: ["2026-03"], today: "2026-04-14", config: cfg, layers: Self.sampleLayers)
        #expect(aiHist.matchedItems.count == 1)

        // ReceiptExtraction falls back to Categorizer when AI returns "Uncategorized" and parses array wrapped in prose.
        let categorizer = Categorizer(rules: RuleSet(rules: [
            CategoryRule(pattern: "サンプルストア", group: "Living", category: "Groceries")
        ]))
        let proseArray = """
        Here are the extracted transactions:
        [{"date":"2026-04-14","merchant":"サンプルストア","amount":1480,"category":"Uncategorized"}]
        """
        let drafts = ReceiptExtraction.parseAIResponse(
            proseArray,
            today: "2026-04-14",
            defaultSource: "Cash",
            availableCategories: [("Living", "Groceries"), ("Other", "Uncategorized")],
            categorizer: categorizer,
            existingItems: []
        )
        #expect(drafts.count == 1)
        #expect(drafts[0].category == "Groceries")
        #expect(drafts[0].group == "Living")
    }
}
