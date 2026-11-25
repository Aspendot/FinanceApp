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
            BudgetItem(date: "2026-03-05", source: "Debit", merchant: "SAMPLE P", amount: 600, group: "Subscriptions", category: "Other subs", layer: "Subscriptions"),
            BudgetItem(date: "2026-03-07", source: "Debit", merchant: "SAMPLE SHOP JP", amount: 3_000, group: "Shopping", category: "Online shopping", layer: "Day-to-day"),
            BudgetItem(date: "2026-03-10", source: "Bank", merchant: "電話 SAMPLETEL", amount: 5_000, group: "Fixed bills", category: "Internet", layer: "Bills & taxes"),
            BudgetItem(date: "2026-03-12", source: "Debit", merchant: "SAMPLECO", amount: 18_000, group: "Subscriptions", category: "AI", layer: "Subscriptions"),
        ]
        let primeSub = SubscriptionSummary.compute(from: [SubscriptionEntry(name: "Sample Prime", monthly: 600, status: "Check")]).running[0]
        let primeHist = SubscriptionHistory.compute(for: primeSub, allItems: items, months: ["2026-03"], today: "2026-04-14", config: cfg, layers: Self.sampleLayers)
        #expect(primeHist.matchedItems.count == 1)
        #expect(primeHist.matchedItems[0].merchant == "SAMPLE P")

        let fiberSub = SubscriptionSummary.compute(from: [SubscriptionEntry(name: "Fiber internet (billed by SampleTel)", monthly: 5_000, status: "Keep")]).running[0]
        let fiberHist = SubscriptionHistory.compute(for: fiberSub, allItems: items, months: ["2026-03"], today: "2026-04-14", config: cfg, layers: Self.sampleLayers)
        #expect(fiberHist.matchedItems.count == 1)

        let aiSub = SubscriptionSummary.compute(from: [SubscriptionEntry(name: "Sample AI (SampleCorp)", monthly: 18_000, status: "Keep")]).running[0]
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

    @Test("LiveCashSummary tracks real bank balances, pending debits, deferred cards, and phone bill checkoffs without double-counting")
    func liveCashSummaryReconcilesExactBankCash() {
        let balances = [
            AccountBalance(source: "main_bank", label: "Main Bank", balance: 230_000, asOf: "2026-04-12", debitNoticeSources: ["main_debit"]),
            AccountBalance(source: "sub_bank", label: "Sub Bank", balance: 5_000, asOf: "2026-04-12", debitNoticeSources: ["sub_debit"]),
        ]
        let sourceLabels = [
            "main_bank": "Main Bank",
            "sub_bank": "Sub Bank",
            "main_debit": "Main Debit",
            "sub_debit": "Sub Debit",
            "credit_card": "Deferred Card",
        ]
        let timeline = [
            TimelineEntry(date: "2026-03-25", item: "Salary", amount: -300_000, payday: true, done: true),
            TimelineEntry(date: "2026-04-15", item: "Electric", amount: 10_000, done: true),
            TimelineEntry(date: "2026-04-20", item: "Rent", amount: 80_000),
            TimelineEntry(date: "2026-04-25", item: "Salary", amount: -300_000, payday: true, next: true),
        ]
        let payday = PaydayView.compute(timeline: timeline, today: "2026-04-14")!
        let phoneCheckedKey = BillCheckoff.key(for: timeline[1]) // Electric marked paid on phone only (no bank row yet)

        let postBankRows = [
            TimelineReconciler.BankRow(source: "Main Bank", date: "2026-04-13", amount: 3_000, description: "SUPERMARKET"),
            // Same-day row on asOf must NOT be subtracted again (already in confirmed balance).
            TimelineReconciler.BankRow(source: "Main Bank", date: "2026-04-12", amount: 9_999, description: "ALREADY IN BALANCE"),
        ]
        let pendingItems = [
            BudgetItem(date: "2026-04-14", source: "Main Debit", merchant: "CAFE", amount: 1_500, group: "Living", category: "Dining", layer: "Day-to-day", isPending: true),
            BudgetItem(date: "2026-04-14", source: "Sub Debit", merchant: "KONBINI", amount: 500, group: "Living", category: "Groceries", layer: "Day-to-day", isPending: true),
            // Deferred credit card purchase must NOT reduce bank cash until its scheduled bill.
            BudgetItem(date: "2026-04-14", source: "Deferred Card", merchant: "ONLINE SHOP", amount: 12_000, group: "Living", category: "Shopping", layer: "Day-to-day", isPending: true),
        ]

        let live = LiveCashSummary.compute(
            accountBalances: balances,
            sourceLabels: sourceLabels,
            bankRows: postBankRows,
            pendingItems: pendingItems,
            payday: payday,
            phoneCheckedBillKeys: [phoneCheckedKey]
        )!

        // Main Bank: 230,000 - 3,000 (post row) - 1,500 (pending debit) = 225,500
        // Sub Bank: 5,000 - 500 (pending debit) = 4,500
        // Total estimated bank cash = 230,000
        #expect(live.confirmedBankCash == 235_000)
        #expect(live.estimatedBankCash == 230_000)
        #expect(live.pendingDebitOutflow == 2_000)
        #expect(live.remainingBillsSum == 80_000)
        #expect(live.phoneCheckedBillsSum == 10_000)
        // Cash left = 230,000 - 80,000 (unpaid Rent) - 10,000 (phone-checked Electric) = 140,000
        #expect(live.cashLeftUntilPayday == 140_000)

        // CashFlowForecast starts from real bank cash minus phone-only checkoffs (230,000 - 10,000 = 220,000).
        let forecast = CashFlowForecast.project(
            today: "2026-04-14",
            days: 30,
            payday: payday,
            paydayBreakdown: nil,
            timeline: timeline,
            allItems: pendingItems,
            subscriptionSummary: SubscriptionSummary.compute(from: []),
            config: Self.sampleConfig,
            layers: Self.sampleLayers,
            liveCash: live
        )
        #expect(forecast.startingCashEstimate == 220_000)
    }

    @Test("Alerts suppress consecutive-day routine convenience-store buys, active-sub collisions, pre-stop charges, and substring word traps")
    func alertPrecisionEliminatesFalsePositives() {
        let items = [
            // Consecutive-day routine convenience store purchases -> NOT duplicates.
            BudgetItem(date: "2026-04-12", source: "Sample Debit", merchant: "KONBINI", amount: 500, group: "Food", category: "Convenience stores", layer: "Day-to-day"),
            BudgetItem(date: "2026-04-13", source: "Sample Debit", merchant: "KONBINI", amount: 500, group: "Food", category: "Convenience stores", layer: "Day-to-day"),
            // Same-day identical charge -> IS a possible duplicate.
            BudgetItem(date: "2026-04-13", source: "Sample Debit", merchant: "BAR SAMPLE", amount: 900, group: "Going out", category: "Bars", layer: "Day-to-day"),
            BudgetItem(date: "2026-04-13", source: "Sample Debit", merchant: "BAR SAMPLE", amount: 900, group: "Going out", category: "Bars", layer: "Day-to-day"),
            // Active subscription must NOT trigger stopped API credits alert.
            BudgetItem(date: "2026-04-10", source: "Sample Debit", merchant: "SAMPLECO", amount: 18_000, group: "Subscriptions", category: "AI", layer: "Subscriptions"),
            // Pre-stop charge on a cancelled sub (stoppedDate 2026-04-10) must NOT alert.
            BudgetItem(date: "2026-04-05", source: "Sample Debit", merchant: "CHAT PLUS", amount: 1_000, group: "Subscriptions", category: "Apps", layer: "Subscriptions"),
            // Post-stop charge on a cancelled sub MUST alert.
            BudgetItem(date: "2026-04-12", source: "Sample Debit", merchant: "STREAMING PRO", amount: 2_000, group: "Subscriptions", category: "Apps", layer: "Subscriptions"),
            // "PAWSOME" contains "aws" inside the word -> must NOT match stopped short-token subscription.
            BudgetItem(date: "2026-04-13", source: "Sample Debit", merchant: "PAWSOME MART", amount: 3_000, group: "Food", category: "Convenience stores", layer: "Day-to-day"),
        ]
        let subs = [
            SubscriptionEntry(name: "Sample AI (SampleCorp)", monthly: 18_000, status: "Keep"),
            SubscriptionEntry(name: "SampleCorp API credits", monthly: 5_000, status: "Stopped", stoppedDate: "2026-04-01"),
            SubscriptionEntry(name: "Chat Plus", monthly: 1_000, status: "Cancelled", stoppedDate: "2026-04-10"),
            SubscriptionEntry(name: "Streaming Pro", monthly: 2_000, status: "Cancelled", stoppedDate: "2026-04-10"),
            SubscriptionEntry(name: "AWS", monthly: 20_000, status: "Stopped", stoppedDate: "2026-04-01"),
        ]
        let bundle = DataBundle(
            generatedAt: "2026-04-14T10:00:00+09:00",
            asOf: "2026-04-14",
            items: items,
            subs: subs,
            layers: Self.sampleLayers,
            layerConfig: Self.sampleConfig
        )
        let subSummary = SubscriptionSummary.compute(from: subs)
        let planSummary = PlanSummary.compute(plan: [], planWindow: nil, totalsByMonth: [:], selectedMonth: "2026-04", currentMonth: "2026-04", inProgressMonth: "2026-04")
        let alerts = SpendingInsights.detectAlerts(
            bundle: bundle,
            allItems: items,
            notices: [],
            timeline: [],
            planSummary: planSummary,
            subscriptionSummary: subSummary,
            today: "2026-04-14"
        )

        let dupAlerts = alerts.filter { $0.kind == .possibleDuplicate }
        #expect(dupAlerts.count == 1)
        #expect(dupAlerts[0].detail.contains("BAR SAMPLE"))

        let subAlerts = alerts.filter { $0.kind == .cancelledSubscriptionCharge }
        #expect(subAlerts.count == 1)
        #expect(subAlerts[0].detail.contains("STREAMING PRO"))
    }

    @Test("Audit regressions: unequal interchangeable matching, CRLF CSV, overdue rollover, LiveCash post-asOf rows, PayCycle guard, multiset delete")
    func auditHardeningRegressions() throws {
        // 1. 3 identical notices vs 2 identical bank rows must NOT reuse a row or crash.
        let bundle = DataBundle(
            generatedAt: "2026-04-14T10:00:00+09:00",
            asOf: "2026-04-01",
            coverage: ["mufg_debit": CoverageRange(start: "2026-01-01", end: "2026-04-01")],
            sourceLabels: ["mufg_debit": "Sample Debit"],
            items: [],
            layers: Self.sampleLayers,
            layerConfig: Self.sampleConfig
        )
        let bankTxs = [
            BankTransaction(id: "tx-1", connectedAccountID: "acc-1", date: "2026-04-05", amount: 1_000, description: "SAMPLE SHOP"),
            BankTransaction(id: "tx-2", connectedAccountID: "acc-1", date: "2026-04-05", amount: 1_000, description: "SAMPLE SHOP"),
        ]
        let threeNotices = ["n-1", "n-2", "n-3"].map { id in
            Notice(
                messageID: id,
                source: .mufgDebit,
                kind: .purchase,
                receivedAt: "2026-04-05T10:00:00+09:00",
                occurredOn: "2026-04-05",
                amount: 1_000,
                currency: "JPY",
                merchant: "SAMPLE SHOP",
                reference: nil,
                parser: "test"
            )
        }
        let layered = BankLayering.build(
            bundle: bundle,
            bankTransactions: bankTxs,
            accountMapping: ["acc-1": "mufg_debit"],
            notices: threeNotices,
            categorizer: Categorizer(rules: RuleSet()),
            config: Self.sampleConfig
        )
        #expect(layered.matchedPairs.count == 2)
        #expect(Set(layered.matchedPairs.map(\.transactionID)).count == 2)
        #expect(layered.pendingNoticeIDs.count == 1)

        // Statement Matcher must also never reuse a row when 3 notices face 2 identical rows.
        let stmtRows = [
            StatementRow(id: "r-1", source: .mufgDebit, date: "2026-04-05", amount: 1_000, merchant: "SAMPLE SHOP"),
            StatementRow(id: "r-2", source: .mufgDebit, date: "2026-04-05", amount: 1_000, merchant: "SAMPLE SHOP"),
        ]
        let matchReport = Matcher.match(notices: threeNotices, rows: stmtRows)
        #expect(matchReport.pairs.count == 2)
        #expect(Set(matchReport.pairs.map(\.rowID)).count == 2)

        // 2. PayPay CSV with CRLF line endings + overlapping external ID pool handling.
        let crlfCSV = [
            "取引日,出金金額（円）,入金金額（円）,取引内容,取引先,取引方法,取引番号",
            "2026/04/10 10:00:00,500,-,支払い,SAMPLE COFFEE,PayPay残高,TX-OLD",
            "2026/04/10 14:00:00,500,-,支払い,SAMPLE COFFEE,PayPay残高,TX-NEW",
        ].joined(separator: "\r\n")
        let existingCoffee = BudgetItem(date: "2026-04-10", source: "PayPay", merchant: "SAMPLE COFFEE", amount: 500, group: "Food", category: "Coffee", layer: "Day-to-day")
        let csvResult = try PayPayCSVParser.parse(
            csvText: crlfCSV,
            categorizer: Categorizer(rules: RuleSet()),
            existingItems: [existingCoffee],
            existingExternalIDs: ["paypay:TX-OLD"]
        )
        #expect(csvResult.entries.count == 1)
        #expect(csvResult.entries[0].externalID == "paypay:TX-NEW")
        #expect(csvResult.skippedDuplicates == 1)

        // 3. Salary rollover must preserve unpaid overdue bills instead of silently dropping them.
        let rolloverTimeline = [
            TimelineEntry(date: "2026-04-24", item: "Overdue Rent", amount: 80_000),
            TimelineEntry(
                date: "2026-04-25",
                item: "Salary",
                amount: -300_000,
                payday: true,
                next: true,
                match: TimelineMatch(source: "Sample Bank", pattern: "SALARY", dir: "in", window: [-3, 3])
            ),
            TimelineEntry(date: "2026-05-25", item: "Salary", amount: -300_000, payday: true),
        ]
        let salaryRow = TimelineReconciler.BankRow(source: "Sample Bank", date: "2026-04-25", amount: -300_000, description: "SALARY DEPOSIT")
        let reconciled = TimelineReconciler.reconcile(timeline: rolloverTimeline, bankRows: [salaryRow])
        #expect(reconciled.contains(where: { $0.item == "Overdue Rent" && $0.done != true }))
        #expect(reconciled.contains(where: { $0.date == "2026-05-25" && $0.next == true }))

        // 4. JST.dayNumber rejects impossible dates like Feb 31, and PayCycle survives malformed dates.
        #expect(JST.dayNumber("2026-02-31") == nil)
        #expect(JST.dayNumber("2026-02-28") != nil)
        let badTimeline = [TimelineEntry(date: "2026-04-xx", item: "Salary", amount: -300_000, payday: true, next: true)]
        let safeCycles = PayCycleBuilder.payCycles(items: [], timeline: badTimeline, config: Self.sampleConfig, today: "2026-04-14")
        #expect(safeCycles.isEmpty)

        // 5. Deleting 1 of 2 identical same-day local entries only hides 1 copy.
        let copyA = BudgetItem(date: "2026-04-14", source: "Cash", merchant: "BAKERY", amount: 500, group: "Food", category: "Coffee", layer: "Day-to-day")
        let copyB = copyA
        let fp = CategoryOverride.transactionFingerprint(for: copyA)
        let mods = LocalModifications(deletedEntryFingerprintCounts: [fp: 1])
        let applied = LocalDataApplier.apply(baseItems: [copyA, copyB], modifications: mods, config: Self.sampleConfig, layers: Self.sampleLayers)
        #expect(applied.allItems.count == 1)

        // 6. LiveCash releases phone checkoff hold once exact-amount post-asOf bank outflow posts.
        let bal = [AccountBalance(source: "bank", label: "Main Bank", balance: 200_000, asOf: "2026-04-12")]
        let tl = [
            TimelineEntry(date: "2026-03-25", item: "Salary", amount: -300_000, payday: true, done: true),
            TimelineEntry(date: "2026-04-14", item: "Water", amount: 4_000, done: true),
            TimelineEntry(date: "2026-04-25", item: "Salary", amount: -300_000, payday: true, next: true),
        ]
        let pv = PaydayView.compute(timeline: tl, today: "2026-04-14")!
        let settledRow = TimelineReconciler.BankRow(source: "Main Bank", date: "2026-04-14", amount: 4_000, description: "WATER BILL")
        let liveAfterClear = LiveCashSummary.compute(
            accountBalances: bal,
            sourceLabels: ["bank": "Main Bank"],
            bankRows: [settledRow],
            pendingItems: [],
            payday: pv,
            phoneCheckedBillKeys: [BillCheckoff.key(for: tl[1])],
            lastPayday: "2026-03-25"
        )!
        #expect(liveAfterClear.estimatedBankCash == 196_000)
        #expect(liveAfterClear.phoneCheckedBillsSum == 0)
        #expect(liveAfterClear.cashLeftUntilPayday == 196_000)

        // 7. FinanceQueryEngine matches LiveCash headline & ignores substring word traps ("lower" vs "owe").
        let queryCtx = FinanceQueryEngine.Context(
            bundle: bundle,
            allItems: [copyA],
            totalsByMonth: MonthTotals.compute(items: [copyA], config: Self.sampleConfig, layers: Self.sampleLayers),
            timeline: tl,
            payday: pv,
            liveCash: liveAfterClear,
            effectiveDebts: [DebtEntry(name: "Sample Loan", balance: 50_000)],
            planSummary: PlanSummary.compute(plan: [], planWindow: nil, totalsByMonth: [:], selectedMonth: "2026-04", currentMonth: "2026-04", inProgressMonth: "2026-04"),
            subscriptionSummary: SubscriptionSummary.compute(from: []),
            today: "2026-04-14"
        )
        let paydayAns = FinanceQueryEngine.answer("How much is left until payday?", context: queryCtx)
        #expect(paydayAns.headline == "¥196,000")
        let lowerAns = FinanceQueryEngine.answer("How much did I spend on power?", context: queryCtx)
        #expect(lowerAns.headline != "¥50,000")
    }

    @Test("Card-billed subscriptions never double-count in PaydayView, CashFlowForecast, Alerts, or Queries, and exact brand subs match history")
    func cardBilledSubscriptionsAndExactBrandMatching() throws {
        let timeline = [
            TimelineEntry(date: "2026-03-25", item: "Salary", amount: -300_000, payday: true, done: true, recurring: true),
            TimelineEntry(date: "2026-04-10", item: "Cloud Storage", amount: 0, recurring: false, cardBilled: true, billedAmount: 1_800),
            TimelineEntry(date: "2026-04-12", item: "Deferred Card bill", amount: 50_000, recurring: true),
            TimelineEntry(date: "2026-04-25", item: "Salary", amount: -300_000, payday: true, next: true, recurring: true),
        ]
        let payday = try #require(PaydayView.compute(timeline: timeline, today: "2026-04-14"))
        #expect(payday.outSum == 50_000)
        #expect(payday.outs.map(\.item) == ["Deferred Card bill"])

        let items = [
            BudgetItem(date: "2026-04-01", source: "Sample Card", merchant: "Google", amount: 490, group: "Subscriptions", category: "Other subs", layer: "Subscriptions"),
            BudgetItem(date: "2026-04-10", source: "Sample Debit", merchant: "GOOGLE PLAY", amount: 4_000, group: "Subscriptions", category: "AI subs", layer: "Subscriptions"),
        ]
        let bundle = DataBundle(
            generatedAt: "2026-04-14T10:00:00+09:00",
            asOf: "2026-04-14",
            items: items,
            timeline: timeline,
            subs: [SubscriptionEntry(name: "Google (Sample Card)", monthly: 490, via: "Sample Card", status: "Check")],
            layers: Self.sampleLayers,
            layerConfig: Self.sampleConfig
        )
        let subSummary = SubscriptionSummary.compute(from: bundle.subs)
        let hist = SubscriptionHistory.compute(
            for: subSummary.running[0],
            allItems: items,
            months: ["2026-04"],
            today: "2026-04-14",
            config: Self.sampleConfig,
            layers: Self.sampleLayers
        )
        #expect(hist.matchedItems.count == 1)
        #expect(hist.matchedItems[0].amount == 490)

        let alerts = SpendingInsights.detectAlerts(
            bundle: bundle,
            allItems: items,
            notices: [],
            timeline: timeline,
            planSummary: PlanSummary.compute(plan: [], planWindow: nil, totalsByMonth: [:], selectedMonth: "2026-04", currentMonth: "2026-04", inProgressMonth: "2026-04"),
            subscriptionSummary: subSummary,
            today: "2026-04-14"
        )
        // Past-date card-billed item must NOT trigger an Overdue cash alert.
        #expect(!alerts.contains(where: { $0.title.contains("Cloud Storage") }))

        let forecast = CashFlowForecast.project(
            today: "2026-04-14",
            days: 30,
            payday: payday,
            paydayBreakdown: nil,
            timeline: timeline,
            allItems: items,
            subscriptionSummary: subSummary,
            config: Self.sampleConfig,
            layers: Self.sampleLayers,
            startingCashOverride: 100_000
        )
        #expect(!forecast.points.flatMap(\.events).contains(where: { $0.title.contains("Cloud Storage") }))
    }

    @Test("ComingUp.runningBalances steps down from live bank cash, reserves overdue bills, ignores card/event/borrowed rows, and reconciles to LiveCashSummary")
    func comingUpRunningBalanceMatchesLiveCashToTheYen() throws {
        let timeline = [
            TimelineEntry(date: "2026-04-10", item: "Salary", amount: -300_000, payday: true, done: true),
            TimelineEntry(date: "2026-04-10", item: "Card room", amount: -38_000, borrowed: true),
            TimelineEntry(date: "2026-04-13", item: "Overdue Utility", amount: 9_900),
            TimelineEntry(date: "2026-04-14", item: "Already Paid Sub", amount: 1_400, done: true),
            TimelineEntry(date: "2026-04-14", item: "Internet", amount: 7_700),
            TimelineEntry(date: "2026-04-14", item: "Card Gym", amount: 0, done: true, cardBilled: true, billedAmount: 3_050),
            TimelineEntry(date: "2026-04-14", item: "Trip reminder", amount: 0, event: true),
            TimelineEntry(date: "2026-04-16", item: "Rent", amount: 80_000),
            TimelineEntry(date: "2026-04-25", item: "Salary", amount: -300_000, payday: true, next: true),
            TimelineEntry(date: "2026-04-26", item: "Next Cycle Sub", amount: 4_000),
        ]
        let balances = [
            AccountBalance(source: "main_bank", label: "Main Bank", balance: 200_000, asOf: "2026-04-12", debitNoticeSources: ["main_debit"]),
        ]
        let labels = ["main_bank": "Main Bank", "main_debit": "Main Debit"]
        let pending = [
            BudgetItem(date: "2026-04-13", source: "Main Debit", merchant: "CAFE", amount: 2_000, group: "Living", category: "Dining", isPending: true),
        ]

        let payday = try #require(PaydayView.compute(timeline: timeline, today: "2026-04-14"))
        let live = try #require(LiveCashSummary.compute(
            accountBalances: balances,
            sourceLabels: labels,
            bankRows: [],
            pendingItems: pending,
            payday: payday,
            lastPayday: "2026-04-10"
        ))
        let groups = ComingUp.groups(timeline: timeline, today: "2026-04-14")
        let running = try #require(ComingUp.runningBalances(
            groups: groups,
            today: "2026-04-14",
            liveCash: live,
            lastPayday: "2026-04-10"
        ))

        // Cash now = 200,000 - 2,000 pending debit = 198,000.
        #expect(running.cashNow == 198_000)
        // Overdue Utility (9,900) reserved before today's bills -> 188,100 entering today.
        #expect(running.overdueUnpaidSum == 9_900)
        #expect(running.startingTodayCash == 188_100)

        // Past groups (Apr 10, Apr 13) carry no balance lines.
        #expect(running.balanceAfter[0] == [nil, nil])
        #expect(running.balanceAfter[1] == [nil])

        // Today (Apr 14): Paid sub -> nil, Internet -> 180,400, Card Gym -> nil, Event -> nil.
        #expect(running.balanceAfter[2] == [nil, 180_400, nil, nil])

        // Apr 16 Rent (80,000) -> 100,400, which MUST equal live.cashLeftUntilPayday to the exact yen.
        #expect(running.balanceAfter[3] == [100_400])
        #expect(live.cashLeftUntilPayday == 100_400)
        #expect(running.cashAfterBills == 100_400)

        // Open credit/borrowing room before next payday reconciles with LiveCashSummary.cashLeftIfBorrowed.
        #expect(running.openCreditSources == [
            ComingUpCreditSource(item: "Card room", shortLabel: "Card room", amount: 38_000),
        ])
        #expect(running.openCreditSum == 38_000)
        #expect(running.totalWithCredit == 138_400)
        #expect(running.totalWithCredit == live.cashLeftIfBorrowed)

        // Apr 25 Payday Salary (+300,000) -> 400,400; Apr 26 Sub (4,000) -> 396,400.
        #expect(running.balanceAfter[4] == [400_400])
        #expect(running.balanceAfter[5] == [396_400])

        // Compact label extraction strips descriptive suffix after ":" and skips settled (done) borrowings.
        #expect(ComingUpCreditSource.compactLabel(for: "Card A: usable room") == "Card A")
        #expect(ComingUpCreditSource.compactLabel(for: "Loan B: borrow ¥10,000 again") == "Loan B")
        let mixedTimeline = [
            TimelineEntry(date: "2026-04-10", item: "Salary", amount: -300_000, payday: true, done: true),
            TimelineEntry(date: "2026-04-14", item: "Card A: usable room", amount: -38_000, borrowed: true),
            TimelineEntry(date: "2026-04-15", item: "Loan B: borrow ¥10,000 again", amount: -10_000, borrowed: true),
            TimelineEntry(date: "2026-04-16", item: "Loan C: already drawn", amount: -5_000, done: true, borrowed: true),
            TimelineEntry(date: "2026-04-20", item: "Rent", amount: 80_000),
            TimelineEntry(date: "2026-04-25", item: "Salary", amount: -300_000, payday: true, next: true),
            TimelineEntry(date: "2026-04-28", item: "Next cycle loan: borrow", amount: -10_000, borrowed: true),
        ]
        let mixedPayday = try #require(PaydayView.compute(timeline: mixedTimeline, today: "2026-04-14"))
        let mixedLive = try #require(LiveCashSummary.compute(
            accountBalances: balances,
            sourceLabels: labels,
            bankRows: [],
            pendingItems: pending,
            payday: mixedPayday,
            lastPayday: "2026-04-10"
        ))
        let mixedGroups = ComingUp.groups(timeline: mixedTimeline, today: "2026-04-14")
        let mixedRunning = try #require(ComingUp.runningBalances(
            groups: mixedGroups,
            today: "2026-04-14",
            liveCash: mixedLive,
            lastPayday: "2026-04-10"
        ))
        #expect(mixedRunning.openCreditSources.map(\.shortLabel) == ["Card A", "Loan B"])
        #expect(mixedRunning.openCreditSum == 48_000)
        #expect(mixedRunning.cashAfterBills == mixedLive.cashLeftUntilPayday)
        #expect(mixedRunning.totalWithCredit == mixedLive.cashLeftIfBorrowed)

        // Standing CreditRoom snapshots contribute to LiveCashSummary without needing a dated timeline row,
        // and draw down live on charges strictly after their asOf date.
        let rooms = [
            CreditRoom(label: "Card A", available: 38_000, asOf: "2026-04-14", sourceKeys: ["card_a"]),
        ]
        let roomTimeline = [
            TimelineEntry(date: "2026-04-10", item: "Salary", amount: -300_000, payday: true, done: true),
            TimelineEntry(date: "2026-04-15", item: "Loan B: borrow ¥10,000 again", amount: -10_000, borrowed: true),
            TimelineEntry(date: "2026-04-20", item: "Rent", amount: 80_000),
            TimelineEntry(date: "2026-04-25", item: "Salary", amount: -300_000, payday: true, next: true),
        ]
        let roomPayday = try #require(PaydayView.compute(timeline: roomTimeline, today: "2026-04-14"))
        let roomLabels = ["main_bank": "Main Bank", "main_debit": "Main Debit", "card_a": "Card A"]
        let roomPending = pending + [
            // Same-day charge on asOf must NOT double-subtract from confirmed available balance.
            BudgetItem(date: "2026-04-14", source: "Card A", merchant: "ALREADY COUNTED", amount: 3_000, group: "Living", category: "Other", isPending: true),
            // Strictly post-asOf charge draws down live usable room.
            BudgetItem(date: "2026-04-15", source: "Card A", merchant: "NEW SPEND", amount: 2_000, group: "Living", category: "Other", isPending: true),
        ]
        let roomLive = try #require(LiveCashSummary.compute(
            accountBalances: balances,
            creditRooms: rooms,
            sourceLabels: roomLabels,
            bankRows: [],
            pendingItems: roomPending,
            payday: roomPayday,
            lastPayday: "2026-04-10"
        ))
        // Card A: 38,000 - 2,000 (Apr 15) = 36,000; Loan B: 10,000 -> total credit room 46,000.
        #expect(roomLive.creditSources.map(\.shortLabel) == ["Card A", "Loan B"])
        #expect(roomLive.creditSources.map(\.amount) == [36_000, 10_000])
        #expect(roomLive.openBorrowedSum == 46_000)
        #expect(roomLive.cashLeftIfBorrowed == roomLive.cashLeftUntilPayday + 46_000)
    }

    @Test("v0.6.9 C1/M5/M6: MF non-spending rules, StatementLineRule itemSource + merchant extraction, ref conflict rejection, and late-night receipt-only matching")
    func bankLayeringAccountingAndMatchingHardening() throws {
        var bundle = DataBundle(
            generatedAt: "2026-04-12T10:00:00+09:00",
            asOf: "2026-04-12",
            coverage: [
                "main_bank": CoverageRange(start: "2026-01-01", end: "2026-04-12"),
                "main_debit": CoverageRange(start: "2026-01-01", end: "2026-04-12"),
            ],
            sourceLabels: [
                "main_bank": "Main Bank",
                "main_debit": "Main Debit",
            ],
            layers: Self.sampleLayers,
            layerConfig: LayerConfig(
                notSpendingGroups: ["Income", "People", "Debt", "Excluded", "Hidden", "Transfers"],
                rentCategories: ["Rent"],
                billGroups: ["Bills"],
                subscriptionGroups: ["Subscriptions"],
                subscriptionCategories: [],
                incomeGroup: "Income",
                peopleGroup: "People",
                debtGroup: "Debt"
            ),
            rules: RuleSet(rules: [
                CategoryRule(pattern: "^給料$", group: "Income", category: "Salary"),
                CategoryRule(pattern: "カード請求|ウォレット請求", group: "Hidden", category: "Card settlement"),
                CategoryRule(pattern: "ジブンフリコミ", group: "Transfers", category: "Own transfer"),
                CategoryRule(pattern: "SAMPLEMA", group: "Living", category: "Convenience stores"),
            ]),
            noticeSourceMatches: ["main_debit": ["main_bank"]],
            statementLineRules: [
                "main_bank": [
                    StatementLineRule(pattern: #"^デビット\d* (\d{6}) (.+)$"#, referenceGroup: 1, merchantGroup: 2, itemSource: "Main Debit"),
                ],
            ]
        )
        bundle.accountBalances = [
            AccountBalance(source: "main_bank", label: "Main Bank", balance: 200_000, asOf: "2026-04-12", debitNoticeSources: ["main_debit"], asOfRowAmounts: []),
        ]
        let txs = [
            BankTransaction(id: "tx-sal", connectedAccountID: "acc", date: "2026-04-15", amount: -350_000, description: "給料"),
            BankTransaction(id: "tx-card", connectedAccountID: "acc", date: "2026-04-15", amount: 50_000, description: "カード請求"),
            BankTransaction(id: "tx-self", connectedAccountID: "acc", date: "2026-04-15", amount: 10_000, description: "ジブンフリコミ"),
            BankTransaction(id: "tx-deb", connectedAccountID: "acc", date: "2026-04-14", amount: 800, description: "デビット1 111222 SAMPLEMA"),
            BankTransaction(id: "tx-night", connectedAccountID: "acc", date: "2026-04-13", amount: 4_500, description: "デビット1 333444 NIGHTDIN"),
        ]
        let notices = [
            // Conflicting approval ref (999999 vs 111222) MUST NOT match tx-deb.
            Notice(messageID: "n-bad-ref", source: .mufgDebit, kind: .purchase, receivedAt: "2026-04-14T10:00:00+09:00", occurredOn: "2026-04-14", amount: 800, merchant: "SAMPLEMA", reference: "999999", parser: "test/1"),
            // Receipt-only notice (no occurredAt / occurredOn) received after midnight matches prior-day bank row (-1).
            Notice(messageID: "n-late", source: .mufgDebit, kind: .purchase, receivedAt: "2026-04-14T00:03:00+09:00", amount: 4_500, merchant: "NIGHTDIN", parser: "test/1"),
        ]
        bundle.coverage["mufg_debit"] = CoverageRange(start: "2026-01-01", end: "2026-04-12")
        bundle.sourceLabels["mufg_debit"] = "Main Debit"
        bundle.noticeSourceMatches = ["mufg_debit": ["main_bank"]]

        let layered = BankLayering.build(
            bundle: bundle,
            bankTransactions: txs,
            accountMapping: ["acc": "main_bank"],
            notices: notices,
            categorizer: Categorizer(rules: bundle.rules),
            config: bundle.layerConfig
        )

        // Salary, card settlement, and self-transfer stay out of spending layers (layer == nil).
        let salItem = try #require(layered.bankItems.first { $0.merchant == "給料" })
        #expect(salItem.group == "Income" && salItem.layer == nil)
        let cardItem = try #require(layered.bankItems.first { $0.merchant == "カード請求" })
        #expect(cardItem.group == "Hidden" && cardItem.layer == nil)
        let selfItem = try #require(layered.bankItems.first { $0.merchant == "ジブンフリコミ" })
        #expect(selfItem.group == "Transfers" && selfItem.layer == nil)

        // Debit row uses clean extracted merchant & itemSource, while BankRow keeps "Main Bank".
        let debItem = try #require(layered.bankItems.first { $0.amount == 800 })
        #expect(debItem.merchant == "SAMPLEMA")
        #expect(debItem.category == "Convenience stores")
        #expect(debItem.source == "Main Debit")
        let debRow = try #require(layered.bankRows.first { $0.amount == 800 })
        #expect(debRow.source == "Main Bank")
        #expect(debRow.description == "デビット1 111222 SAMPLEMA")

        // Conflicting ref stays unmatched; late-night receipt-only notice reconciles at offset -1.
        #expect(layered.matchedPairs.map(\.noticeID) == ["n-late"])
        #expect(layered.matchedPairs[0].dayOffset == -1)
        #expect(layered.pendingNoticeIDs == ["n-bad-ref"])
    }

    @Test("v0.6.9 H1/M4/Sol-6: Phone checkoff round-trip preserves hold, survives re-estimate via stable ID, upgrades on bank debit, and never double-consumes a bank row")
    func phoneCheckoffRoundTripAndSingleRowConsumption() throws {
        let reestimated = TimelineEntry(
            id: "rec:elec:2026-04",
            date: "2026-04-15",
            item: "Electric",
            amount: 10_500, // re-estimated from 10,000
            done: true,
            phoneChecked: true,
            match: TimelineMatch(source: "Main Bank", pattern: "ELEC", dir: "out", window: [-3, 5])
        )
        let otherBill = TimelineEntry(
            id: "rec:other:2026-04",
            date: "2026-04-15",
            item: "Other Bill",
            amount: 5_000,
            match: TimelineMatch(source: "Main Bank", pattern: "OTHER", dir: "out", window: [-3, 5])
        )
        let unrelatedHold = TimelineEntry(
            id: "rec:hold:2026-04",
            date: "2026-04-15",
            item: "Manual Hold",
            amount: 5_000
        )
        let nextPay = TimelineEntry(id: "rec:salary:2026-04", date: "2026-04-25", item: "Salary", amount: -300_000, payday: true, next: true)

        let checkoffs = [
            BillCheckoff(key: "id:rec:elec:2026-04"),
            BillCheckoff(key: "id:rec:hold:2026-04"),
        ]
        // 1. Round-tripped phoneChecked stays in phoneCheckedKeys and holds cash even after amount change.
        let applied = LocalDataApplier.applyBillCheckoffs(timeline: [reestimated, otherBill, unrelatedHold, nextPay], checkoffs: checkoffs)
        #expect(applied.phoneCheckedKeys.contains("id:rec:elec:2026-04"))
        #expect(applied.phoneCheckedKeys.contains("id:rec:hold:2026-04"))

        // 2. Unchecking clears done + phoneChecked immediately.
        let unchecked = LocalDataApplier.applyBillCheckoffs(timeline: [reestimated], checkoffs: [])
        #expect(unchecked.timeline[0].done == nil)
        #expect(unchecked.timeline[0].phoneChecked == nil)

        // 3. One ¥5,000 bank row for OTHER settles otherBill via TimelineReconciler and must NOT also release unrelatedHold.
        let bankRows = [
            TimelineReconciler.BankRow(source: "Main Bank", date: "2026-04-15", amount: 5_000, description: "OTHER UTILITY"),
        ]
        let recResult = TimelineReconciler.reconcileWithMetadata(timeline: [reestimated, otherBill, unrelatedHold, nextPay], bankRows: bankRows)
        #expect(recResult.usedRowIndices == [0])
        let consumed = recResult.usedRowIndices.map { bankRows[$0] }
        let postChecked = LocalDataApplier.applyBillCheckoffs(timeline: recResult.timeline, checkoffs: checkoffs)
        let payday = try #require(PaydayView.compute(timeline: postChecked.timeline, today: "2026-04-16"))
        let balances = [AccountBalance(source: "main_bank", label: "Main Bank", balance: 100_000, asOf: "2026-04-14")]
        let live = try #require(LiveCashSummary.compute(
            accountBalances: balances,
            sourceLabels: ["main_bank": "Main Bank"],
            bankRows: bankRows,
            pendingItems: [],
            payday: payday,
            phoneCheckedBillKeys: postChecked.phoneCheckedKeys,
            consumedBankRows: consumed
        ))
        // Bank cash = 100,000 - 5,000 = 95,000; BOTH elec (10,500) AND unrelatedHold (5,000) stay held!
        #expect(live.estimatedBankCash == 95_000)
        #expect(live.phoneCheckedBillsSum == 15_500)
        #expect(live.cashLeftUntilPayday == 79_500)

        // 4. When real ELEC debit arrives, TimelineReconciler clears phoneChecked -> bank-confirmed Paid.
        let elecRow = TimelineReconciler.BankRow(source: "Main Bank", date: "2026-04-16", amount: 10_500, description: "ELEC BILL")
        let settledElec = TimelineReconciler.reconcile(timeline: [reestimated, nextPay], bankRows: [elecRow])
        #expect(settledElec[0].done == true)
        #expect(settledElec[0].phoneChecked == nil)
    }

    @Test("v0.6.9 H2: Snapshot-day intraday debit preserves live cash and spending when posting on asOf")
    func snapshotDayIntradayDebitNeverVanishes() throws {
        let bundle = DataBundle(
            generatedAt: "2026-04-12T03:00:00+09:00",
            asOf: "2026-04-12",
            coverage: [
                "main_bank": CoverageRange(start: "2026-01-01", end: "2026-04-12"),
                "mufg_debit": CoverageRange(start: "2026-01-01", end: "2026-04-12"),
            ],
            sourceLabels: ["main_bank": "Main Bank", "mufg_debit": "Main Debit"],
            items: [
                BudgetItem(date: "2026-04-12", source: "Main Debit", merchant: "MORNING SUB", amount: 850, group: "Subs", category: "Media", layer: "Subscriptions"),
            ],
            timeline: [
                TimelineEntry(date: "2026-04-25", item: "Salary", amount: -300_000, payday: true, next: true),
            ],
            layers: Self.sampleLayers,
            layerConfig: Self.sampleConfig,
            noticeSourceMatches: ["mufg_debit": ["main_bank"]],
            accountBalances: [
                AccountBalance(source: "main_bank", label: "Main Bank", balance: 200_000, asOf: "2026-04-12", debitNoticeSources: ["mufg_debit"], asOfRowAmounts: [850]),
            ]
        )
        let afternoonNotice = Notice(
            messageID: "n-pm",
            source: .mufgDebit,
            kind: .purchase,
            receivedAt: "2026-04-12T15:00:00+09:00",
            occurredOn: "2026-04-12",
            amount: 1_200,
            merchant: "LUNCH CAFE",
            parser: "test/1"
        )
        let morningTx = BankTransaction(id: "tx-am", connectedAccountID: "acc", date: "2026-04-12", amount: 850, description: "MORNING SUB")
        let afternoonTx = BankTransaction(id: "tx-pm", connectedAccountID: "acc", date: "2026-04-12", amount: 1_200, description: "LUNCH CAFE")

        // Step A: before afternoonTx posts -> cash drops to 198,800 via pending notice.
        let layeredBefore = BankLayering.build(
            bundle: bundle, bankTransactions: [morningTx], accountMapping: ["acc": "main_bank"],
            notices: [afternoonNotice], categorizer: Categorizer(rules: bundle.rules), config: bundle.layerConfig
        )
        let payday = try #require(PaydayView.compute(timeline: bundle.timeline, today: "2026-04-12"))
        let liveBefore = try #require(LiveCashSummary.compute(
            accountBalances: bundle.accountBalances!, sourceLabels: bundle.sourceLabels,
            bankRows: layeredBefore.allBankRows, pendingItems: layeredBefore.pendingItems, payday: payday
        ))
        #expect(layeredBefore.bankItems.isEmpty)
        #expect(layeredBefore.pendingItems.count == 1)
        #expect(liveBefore.estimatedBankCash == 198_800)

        // Step B: after afternoonTx posts on the SAME day (2026-04-12) -> cash stays 198,800 and item stays visible!
        let layeredAfter = BankLayering.build(
            bundle: bundle, bankTransactions: [morningTx, afternoonTx], accountMapping: ["acc": "main_bank"],
            notices: [afternoonNotice], categorizer: Categorizer(rules: bundle.rules), config: bundle.layerConfig
        )
        let liveAfter = try #require(LiveCashSummary.compute(
            accountBalances: bundle.accountBalances!, sourceLabels: bundle.sourceLabels,
            bankRows: layeredAfter.allBankRows, pendingItems: layeredAfter.pendingItems, payday: payday
        ))
        #expect(layeredAfter.pendingItems.isEmpty)
        #expect(layeredAfter.bankItems.count == 1)
        #expect(layeredAfter.bankItems[0].amount == 1_200)
        #expect(layeredAfter.bankItems[0].merchant == "LUNCH CAFE")
        #expect(liveAfter.estimatedBankCash == 198_800)
        #expect(liveAfter.cashLeftUntilPayday == liveBefore.cashLeftUntilPayday)
    }

    @Test("v0.6.9 H3: Apple receipt keeps debit fundingSource for live cash, reconciles with APPLE.CO bank row, and deduplicates across uncovered window")
    func appleReceiptFundingSourceAndDeduplication() throws {
        let bundle = DataBundle(
            generatedAt: "2026-04-14T10:00:00+09:00",
            asOf: "2026-04-12",
            coverage: [
                "apple": CoverageRange(start: "2026-01-01", end: "2026-04-10"),
                "mufg_debit": CoverageRange(start: "2026-01-01", end: "2026-04-12"),
                "main_bank": CoverageRange(start: "2026-01-01", end: "2026-04-12"),
            ],
            sourceLabels: ["apple": "Apple", "mufg_debit": "Main Debit", "main_bank": "Main Bank"],
            items: [
                // Item already in bundle AFTER coverage.end (e.g. manual extract newer than header date):
                BudgetItem(date: "2026-04-13", source: "Apple", merchant: "Already Exported App", amount: 1_500, group: "Subs", category: "Apps", layer: "Subscriptions"),
            ],
            timeline: [
                TimelineEntry(date: "2026-04-25", item: "Salary", amount: -300_000, payday: true, next: true),
            ],
            layers: Self.sampleLayers,
            layerConfig: Self.sampleConfig,
            noticeSourceMatches: ["mufg_debit": ["main_bank"], "apple": ["main_bank"]],
            accountBalances: [
                AccountBalance(source: "main_bank", label: "Main Bank", balance: 100_000, asOf: "2026-04-12", debitNoticeSources: ["mufg_debit"]),
            ]
        )
        let notices = [
            // Already exported on 2026-04-13 -> must be deduplicated across entire uncovered window!
            Notice(messageID: "a-dup", source: .apple, kind: .purchase, receivedAt: "2026-04-13T12:00:00+09:00", occurredOn: "2026-04-13", amount: 1_500, merchant: "Already Exported App", reference: "ORD-DUP", parser: "apple/1"),
            // New Apple purchase on 2026-04-14 paid via MUFG debit -> Apple wins merchant, MUFG debit preserved in fundingSource.
            Notice(messageID: "a-new", source: .apple, kind: .purchase, receivedAt: "2026-04-14T12:00:00+09:00", occurredOn: "2026-04-14", amount: 2_100, merchant: "Cloud Suite", reference: "ORD-NEW", parser: "apple/1"),
            Notice(messageID: "d-new", source: .mufgDebit, kind: .purchase, receivedAt: "2026-04-14T12:01:00+09:00", occurredOn: "2026-04-14", amount: 2_100, merchant: "APPLE.COM/BILL", parser: "mufg_debit/1"),
        ]
        let pending = PendingBuilder.build(notices: notices, bundle: bundle, categorizer: Categorizer(rules: bundle.rules), config: bundle.layerConfig)
        #expect(pending.items.count == 1)
        #expect(pending.items[0].merchant == "Cloud Suite")
        #expect(pending.items[0].fundingSource == "mufg_debit")

        let payday = try #require(PaydayView.compute(timeline: bundle.timeline, today: "2026-04-14"))
        let livePending = try #require(LiveCashSummary.compute(
            accountBalances: bundle.accountBalances!, sourceLabels: bundle.sourceLabels,
            bankRows: [], pendingItems: pending.items, payday: payday
        ))
        // Live cash subtracts ¥2,100 even though Apple suppressed the debit notice!
        #expect(livePending.estimatedBankCash == 97_900)

        // When APPLE.CO posts on main_bank, Apple receipt reconciles cleanly -> 1 bank item keeping "Cloud Suite", 0 pending.
        let bankTx = BankTransaction(id: "tx-apple", connectedAccountID: "acc", date: "2026-04-15", amount: 2_100, description: "デビット1 555666 APPLE.CO")
        let layered = BankLayering.build(
            bundle: bundle, bankTransactions: [bankTx], accountMapping: ["acc": "main_bank"],
            notices: notices, categorizer: Categorizer(rules: bundle.rules), config: bundle.layerConfig
        )
        #expect(layered.pendingItems.isEmpty)
        #expect(layered.bankItems.count == 1)
        #expect(layered.bankItems[0].merchant == "Cloud Suite")
    }

    @Test("v0.6.9 H4/M7/M9/Ask: Estimated bonus excluded from hero, CreditRoom split-tender + limit cap, PayPay wallet burn, and JST query fixes")
    func estimatedInflowsCreditRoomRunwayAndQueryHardening() throws {
        // 1. Estimated inflow stays out of guaranteed hero cash and ComingUp running balance.
        let tl = [
            TimelineEntry(date: "2026-04-10", item: "Salary", amount: -300_000, payday: true, done: true),
            TimelineEntry(date: "2026-04-16", item: "Rent", amount: 80_000),
            TimelineEntry(date: "2026-04-20", item: "Winter bonus", amount: -250_000, estimate: true),
            TimelineEntry(date: "2026-04-25", item: "Salary", amount: -300_000, payday: true, next: true),
        ]
        let payday = try #require(PaydayView.compute(timeline: tl, today: "2026-04-14"))
        let splitNotice = Notice(
            messageID: "m-split", source: .merpay, kind: .purchase,
            receivedAt: "2026-04-15T12:00:00+09:00", occurredOn: "2026-04-15",
            amount: 3_000, merchant: "SPLIT SHOP",
            parts: ["credit": 1_000, "points": 2_000], parser: "merpay/1"
        )
        let pendingSplit = [
            BudgetItem(date: "2026-04-15", source: "Merpay", merchant: "SPLIT SHOP", amount: 3_000, group: "Living", category: "Other", isPending: true),
            // Large refund should cap CreditRoom at limit (300,000), not exceed it.
            BudgetItem(date: "2026-04-15", source: "Card B", merchant: "REFUND", amount: -50_000, group: "Living", category: "Other", isPending: true),
        ]
        let rooms = [
            CreditRoom(label: "Merpay", available: 45_000, limit: 300_000, asOf: "2026-04-14", sourceKeys: ["merpay"]),
            CreditRoom(label: "Card B", available: 290_000, limit: 300_000, asOf: "2026-04-14", sourceKeys: ["card_b"]),
        ]
        let live = try #require(LiveCashSummary.compute(
            accountBalances: [AccountBalance(source: "main_bank", label: "Main Bank", balance: 200_000, asOf: "2026-04-14")],
            creditRooms: rooms,
            sourceLabels: ["main_bank": "Main Bank", "merpay": "Merpay", "card_b": "Card B"],
            bankRows: [],
            pendingItems: pendingSplit,
            payday: payday,
            lastPayday: "2026-04-10",
            notices: [splitNotice],
            today: "2026-04-14"
        ))
        // Hero cash = 200,000 - 80,000 = 120,000 (bonus 250,000 kept in estimatedInflowsSum!).
        #expect(live.cashLeftUntilPayday == 120_000)
        #expect(live.estimatedInflowsSum == 250_000)
        // Merpay room decreased by ONLY ¥1,000 credit part (not ¥2,000 points) -> 44,000; Card B capped at 300,000.
        #expect(live.creditSources.first(where: { $0.shortLabel == "Merpay" })?.amount == 44_000)
        #expect(live.creditSources.first(where: { $0.shortLabel == "Card B" })?.amount == 300_000)

        let groups = ComingUp.groups(timeline: tl, today: "2026-04-14")
        let running = try #require(ComingUp.runningBalances(groups: groups, today: "2026-04-14", liveCash: live, lastPayday: "2026-04-10"))
        #expect(running.cashAfterBills == live.cashLeftUntilPayday)

        // 2. Debt extractMonthlyPayment skips credit-room summary line and reads actual bill/payment line (invented figures).
        let cardDebtLines = [
            "Card A room ¥24,000 (¥200,000 cap, ¥176,000 balance)",
            "May bill ¥42,500 on May 26",
        ]
        #expect(SpendingInsights.extractMonthlyPayment(from: cardDebtLines) == 42_500)

        // 3. CashFlowForecast does NOT drop "PayWallet" spending when "PayWallet Card bill" is on the timeline.
        let walletItems = [
            BudgetItem(date: "2026-04-05", source: "PayWallet", merchant: "LUNCH", amount: 14_000, group: "Living", category: "Dining", layer: "Day-to-day"),
            BudgetItem(date: "2026-04-06", source: "PayWallet Card", merchant: "ONLINE", amount: 20_000, group: "Living", category: "Shopping", layer: "Day-to-day"),
        ]
        let cardTimeline = [
            TimelineEntry(date: "2026-04-20", item: "PayWallet Card bill", amount: 20_000, recurring: true),
            TimelineEntry(date: "2026-04-25", item: "Salary", amount: -300_000, payday: true, next: true, recurring: true),
        ]
        let forecast = CashFlowForecast.project(
            today: "2026-04-14",
            days: 30,
            payday: PaydayView.compute(timeline: cardTimeline, today: "2026-04-14"),
            paydayBreakdown: nil,
            timeline: cardTimeline,
            allItems: walletItems,
            subscriptionSummary: SubscriptionSummary.compute(from: []),
            config: Self.sampleConfig,
            layers: Self.sampleLayers,
            startingCashOverride: 100_000
        )
        #expect(forecast.excludedDeferredCardSources.contains("PayWallet Card"))
        #expect(!forecast.excludedDeferredCardSources.contains("PayWallet"))
        #expect(forecast.baselineDailyBurn > 0)

        // 4. FinanceQueryEngine: "this month" resolves JST todayMonth even if no rows exist yet,
        //    sourceAnswer passes exact `source:` filter, and upcomingBillsAnswer includes phoneChecked holds.
        let qBundle = DataBundle(
            generatedAt: "2026-05-01T09:00:00+09:00",
            asOf: "2026-04-30",
            items: walletItems,
            timeline: [
                TimelineEntry(id: "rec:elec:2026-05", date: "2026-05-10", item: "Electric", amount: 9_000, done: true, phoneChecked: true),
                TimelineEntry(id: "rec:sal:2026-05", date: "2026-05-25", item: "Salary", amount: -300_000, payday: true, next: true),
            ],
            layers: Self.sampleLayers,
            layerConfig: Self.sampleConfig
        )
        let qTotals = MonthTotals.compute(items: walletItems, config: Self.sampleConfig, layers: Self.sampleLayers)
        let qCtx = FinanceQueryEngine.Context(
            bundle: qBundle,
            allItems: walletItems,
            totalsByMonth: qTotals,
            timeline: qBundle.timeline,
            payday: PaydayView.compute(timeline: qBundle.timeline, today: "2026-05-01"),
            planSummary: PlanSummary.compute(plan: [], planWindow: nil, totalsByMonth: qTotals, selectedMonth: "2026-05", currentMonth: "2026-05", inProgressMonth: "2026-05"),
            subscriptionSummary: SubscriptionSummary.compute(from: []),
            today: "2026-05-01"
        )
        let thisMonthAns = FinanceQueryEngine.answer("Where did my money go this month?", context: qCtx)
        #expect(thisMonthAns.subtitle.contains("May 2026"))
        let billsAns = FinanceQueryEngine.answer("What bills are still unpaid?", context: qCtx)
        #expect(billsAns.headline == "¥9,000")
        let srcAns = FinanceQueryEngine.answer("How much did I spend on PayWallet last month?", context: qCtx)
        #expect(srcAns.action == .openPayments(month: "2026-04", category: nil, query: nil, source: "PayWallet"))

        // 5. Overdue grace window: auto-matched bill 1 day past due gets calm "Not posted" warning; 5 days past gets "Overdue" urgent.
        let graceTimeline = [
            TimelineEntry(date: "2026-04-13", item: "Electricity", amount: 10_000, match: TimelineMatch(source: "Main Bank", pattern: "ELEC", dir: "out", window: [-3, 5])),
            TimelineEntry(date: "2026-04-08", item: "Water", amount: 4_000, match: TimelineMatch(source: "Main Bank", pattern: "WATER", dir: "out", window: [-3, 5])),
        ]
        let graceAlerts = SpendingInsights.detectAlerts(
            bundle: qBundle, allItems: [], notices: [], timeline: graceTimeline,
            planSummary: qCtx.planSummary, subscriptionSummary: qCtx.subscriptionSummary, today: "2026-04-14"
        )
        let elecAlert = try #require(graceAlerts.first { $0.title.contains("Electricity") })
        #expect(elecAlert.badge == "Not posted")
        #expect(elecAlert.severity == .warning)
        let waterAlert = try #require(graceAlerts.first { $0.title.contains("Water") })
        #expect(waterAlert.badge == "Overdue")
        #expect(waterAlert.severity == .urgent)
    }

    @Test("v0.6.9 Round 2: Apple orderID vs bank approval ref, 1-to-1 Apple dedupe, non-Apple rejection, and Apple pending timeline reconciliation")
    func appleMatchingWithStatementRulesOneToOneDedupeAndTimelineSettlement() throws {
        let bundle = DataBundle(
            generatedAt: "2026-04-14T10:00:00+09:00",
            asOf: "2026-04-12",
            coverage: [
                "apple": CoverageRange(start: "2026-01-01", end: "2026-04-12"),
                "mufg_debit": CoverageRange(start: "2026-01-01", end: "2026-04-12"),
                "main_bank": CoverageRange(start: "2026-01-01", end: "2026-04-12"),
            ],
            sourceLabels: ["apple": "Apple", "mufg_debit": "Main Debit", "main_bank": "Main Bank"],
            timeline: [
                TimelineEntry(
                    id: "rec:plan:2026-04", date: "2026-04-14", item: "Cloud App Plan", amount: 2_200,
                    match: TimelineMatch(source: "Main Bank", pattern: #"APPLE\.CO|APPLE\.COM/BILL"#, dir: "out", window: [-2, 4], minAmount: 1_800, maxAmount: 2_600)
                ),
                TimelineEntry(id: "rec:sal:2026-04", date: "2026-04-25", item: "Salary", amount: -300_000, payday: true, next: true),
            ],
            layers: Self.sampleLayers,
            layerConfig: Self.sampleConfig,
            noticeSourceMatches: ["mufg_debit": ["main_bank"], "apple": ["main_bank"]],
            statementLineRules: [
                "main_bank": [
                    StatementLineRule(pattern: #"^デビット\d* (\d{6}) (.+)$"#, referenceGroup: 1, merchantGroup: 2, itemSource: "Main Debit"),
                ],
            ],
            accountBalances: [
                AccountBalance(source: "main_bank", label: "Main Bank", balance: 100_000, asOf: "2026-04-12", debitNoticeSources: ["mufg_debit"]),
            ]
        )
        let notices = [
            Notice(messageID: "a-1", source: .apple, kind: .purchase, receivedAt: "2026-04-14T12:00:00+09:00", occurredOn: "2026-04-14", amount: 2_200, merchant: "Cloud App Plan", reference: "MN72K9XYZ", parser: "apple/1"),
            Notice(messageID: "d-1", source: .mufgDebit, kind: .purchase, receivedAt: "2026-04-14T12:01:00+09:00", occurredOn: "2026-04-14", amount: 2_200, merchant: "APPLE.COM/BILL", reference: "555666", parser: "mufg_debit/1"),
            // Second distinct ¥2,200 Apple debit without its own Apple receipt must NOT be silently dropped!
            Notice(messageID: "d-2", source: .mufgDebit, kind: .purchase, receivedAt: "2026-04-14T18:00:00+09:00", occurredOn: "2026-04-14", amount: 2_200, merchant: "APPLE.COM/BILL", reference: "777888", parser: "mufg_debit/1"),
        ]

        // 1. Strict 1-to-1 suppression: d-1 paired with a-1, d-2 survives!
        let pending = PendingBuilder.build(notices: notices, bundle: bundle, categorizer: Categorizer(rules: bundle.rules), config: bundle.layerConfig)
        #expect(pending.items.count == 2)
        #expect(pending.items.contains(where: { $0.source == "Apple" && $0.merchant == "Cloud App Plan" && $0.fundingSource == "mufg_debit" }))
        #expect(pending.items.contains(where: { $0.source == "Main Debit" && $0.merchant == "APPLE.COM/BILL" }))

        // 2. Pending Apple receipt settles the scheduled APPLE.COM/BILL timeline bill so cash isn't double-subtracted.
        let singleApple = [notices[0], notices[1]]
        let pendingOne = PendingBuilder.build(notices: singleApple, bundle: bundle, categorizer: Categorizer(rules: bundle.rules), config: bundle.layerConfig)
        let reconciledTl = TimelineReconciler.reconcilePendingNotices(
            timeline: bundle.timeline, pendingItems: pendingOne.items,
            accountBalances: bundle.accountBalances!, sourceLabels: bundle.sourceLabels
        )
        #expect(reconciledTl[0].done == true)
        let paydayBeforePost = try #require(PaydayView.compute(timeline: reconciledTl, today: "2026-04-14"))
        let liveBeforePost = try #require(LiveCashSummary.compute(
            accountBalances: bundle.accountBalances!, sourceLabels: bundle.sourceLabels,
            bankRows: [], pendingItems: pendingOne.items, payday: paydayBeforePost
        ))
        // 100,000 - 2,200 (once via pending debit, bill already marked done!) = 97,800.
        #expect(liveBeforePost.estimatedBankCash == 97_800)
        #expect(liveBeforePost.cashLeftUntilPayday == 97_800)

        // 3. Unrelated equal-amount cafe debit MUST NOT match the Apple receipt!
        let cafeTx = BankTransaction(id: "tx-cafe", connectedAccountID: "acc", date: "2026-04-14", amount: 2_200, description: "デビット1 111222 CAFE SHOP")
        let layeredCafe = BankLayering.build(
            bundle: bundle, bankTransactions: [cafeTx], accountMapping: ["acc": "main_bank"],
            notices: singleApple, categorizer: Categorizer(rules: bundle.rules), config: bundle.layerConfig
        )
        #expect(layeredCafe.matchedPairs.isEmpty)
        #expect(layeredCafe.pendingItems.count == 1)

        // 4. Real APPLE.CO bank row with 6-digit approval ref 555666 reconciles against Apple Order ID MN72K9XYZ -> single ¥2,200 deduction!
        let appleTx = BankTransaction(id: "tx-apple", connectedAccountID: "acc", date: "2026-04-15", amount: 2_200, description: "デビット1 555666 APPLE.CO")
        let layeredPosted = BankLayering.build(
            bundle: bundle, bankTransactions: [appleTx], accountMapping: ["acc": "main_bank"],
            notices: singleApple, categorizer: Categorizer(rules: bundle.rules), config: bundle.layerConfig
        )
        #expect(layeredPosted.pendingItems.isEmpty)
        #expect(layeredPosted.bankItems.count == 1)
        #expect(layeredPosted.bankItems[0].merchant == "Cloud App Plan")
        let postedTl = TimelineReconciler.reconcile(timeline: bundle.timeline, bankRows: layeredPosted.bankRows)
        let paydayAfterPost = try #require(PaydayView.compute(timeline: postedTl, today: "2026-04-15"))
        let liveAfterPost = try #require(LiveCashSummary.compute(
            accountBalances: bundle.accountBalances!, sourceLabels: bundle.sourceLabels,
            bankRows: layeredPosted.allBankRows, pendingItems: layeredPosted.pendingItems, payday: paydayAfterPost
        ))
        #expect(liveAfterPost.estimatedBankCash == 97_800)
        #expect(liveAfterPost.cashLeftUntilPayday == 97_800)
    }

    @Test("v0.6.9 Round 2: Midday repeat debit never claims yesterday's covered row, and partial intraday feed preserves new same-amount debit")
    func repeatDebitNegativeOffsetGuardAndPartialIntradayFeed() throws {
        let bundle = DataBundle(
            generatedAt: "2026-04-12T03:00:00+09:00",
            asOf: "2026-04-12",
            coverage: [
                "main_bank": CoverageRange(start: "2026-01-01", end: "2026-04-12"),
                "mufg_debit": CoverageRange(start: "2026-01-01", end: "2026-04-12"),
            ],
            sourceLabels: ["main_bank": "Main Bank", "mufg_debit": "Main Debit"],
            items: [
                BudgetItem(date: "2026-04-12", source: "Main Debit", merchant: "MORNING MART", amount: 550, group: "Living", category: "Convenience", layer: "Day-to-day"),
            ],
            timeline: [
                TimelineEntry(date: "2026-04-25", item: "Salary", amount: -300_000, payday: true, next: true),
            ],
            layers: Self.sampleLayers,
            layerConfig: Self.sampleConfig,
            noticeSourceMatches: ["mufg_debit": ["main_bank"]],
            accountBalances: [
                AccountBalance(source: "main_bank", label: "Main Bank", balance: 100_000, asOf: "2026-04-12", debitNoticeSources: ["mufg_debit"], asOfRowAmounts: [550]),
            ]
        )

        // 1. Midday repeat purchase on 2026-04-13 MUST NOT swallow already-covered 2026-04-12 row at offset -1.
        let coveredRow = BankTransaction(id: "tx-cov", connectedAccountID: "acc", date: "2026-04-12", amount: 550, description: "MORNING MART")
        let middayNotice = Notice(messageID: "n-noon", source: .mufgDebit, kind: .purchase, receivedAt: "2026-04-13T12:00:00+09:00", amount: 550, merchant: "MORNING MART", parser: "test/1")
        let layeredMidday = BankLayering.build(
            bundle: bundle, bankTransactions: [coveredRow], accountMapping: ["acc": "main_bank"],
            notices: [middayNotice], categorizer: Categorizer(rules: bundle.rules), config: bundle.layerConfig
        )
        #expect(layeredMidday.matchedPairs.isEmpty)
        #expect(layeredMidday.pendingItems.count == 1)

        // 2. Partial MF feed on asOf (returns ONLY new afternoon CAFE ¥550, missing MORNING MART ¥550):
        //    still emits CAFE as an intraday row and deducts ¥550 from live bank cash!
        let afternoonNotice = Notice(messageID: "n-cafe", source: .mufgDebit, kind: .purchase, receivedAt: "2026-04-12T15:00:00+09:00", occurredOn: "2026-04-12", amount: 550, merchant: "AFTERNOON CAFE", parser: "test/1")
        let partialRow = BankTransaction(id: "tx-pm-only", connectedAccountID: "acc", date: "2026-04-12", amount: 550, description: "AFTERNOON CAFE")
        let layeredPartial = BankLayering.build(
            bundle: bundle, bankTransactions: [partialRow], accountMapping: ["acc": "main_bank"],
            notices: [afternoonNotice], categorizer: Categorizer(rules: bundle.rules), config: bundle.layerConfig
        )
        #expect(layeredPartial.bankItems.count == 1)
        #expect(layeredPartial.bankItems[0].merchant == "AFTERNOON CAFE")
        let payday = try #require(PaydayView.compute(timeline: bundle.timeline, today: "2026-04-12"))
        let livePartial = try #require(LiveCashSummary.compute(
            accountBalances: bundle.accountBalances!, sourceLabels: bundle.sourceLabels,
            bankRows: layeredPartial.allBankRows, pendingItems: layeredPartial.pendingItems, payday: payday
        ))
        #expect(livePartial.estimatedBankCash == 99_450)
    }

    @Test("v0.6.9 Round 2: Custom reminder round-trip dedupe, duplicate preservation, immediate delete, payday morning/lag, hold expiry, Merpay split posting, and Ask bill routing")
    func roundTwoTimelineCreditRoomNotesAndQueryFixes() throws {
        // 1. CustomReminder stable ID deduplicates PC round-trip, preserves distinct duplicates, and respects deletedCustomReminderIDs.
        let rem1 = CustomReminder(date: "2026-04-20", title: "Dentist", amount: 5_000)
        let rem2 = CustomReminder(date: "2026-04-20", title: "Dentist", amount: 5_000)
        let pcRoundTrip = TimelineEntry(id: "rem:\(rem1.id.uuidString)", date: "2026-04-20", item: "Dentist", amount: 5_000, recurring: false)
        let merged = LocalDataApplier.mergeCustomReminders(timeline: [pcRoundTrip], reminders: [rem1, rem2])
        #expect(merged.count == 2)
        let afterDelete = LocalDataApplier.mergeCustomReminders(
            timeline: [pcRoundTrip], reminders: [rem2], deletedIDs: ["rem:\(rem1.id.uuidString)"]
        )
        #expect(afterDelete.count == 1)
        #expect(afterDelete[0].id == "rem:\(rem2.id.uuidString)")

        // 2. PayCycle stays on prior cycle on payday morning before salary posts, and advances once done == true.
        let morningTl = [
            TimelineEntry(id: "s1", date: "2026-03-25", item: "Salary", amount: -300_000, payday: true, done: true),
            TimelineEntry(id: "s2", date: "2026-04-25", item: "Salary", amount: -300_000, payday: true, next: true),
        ]
        let cyclesBefore = PayCycleBuilder.payCycles(items: [], timeline: morningTl, config: Self.sampleConfig, today: "2026-04-25")
        #expect(cyclesBefore.last?.startDate == "2026-03-25")
        var paidTl = morningTl
        paidTl[1].done = true
        paidTl[1].next = nil
        let cyclesAfter = PayCycleBuilder.payCycles(items: [], timeline: paidTl, config: Self.sampleConfig, today: "2026-04-25")
        #expect(cyclesAfter.last?.startDate == "2026-04-25")

        // 3. Day-after-payday MF lag (1 day) keeps salary in confirmed inflows even when exported with `estimate: true`;
        //    unrelated shop debit doesn't clear manual bill; prior-cycle manual hold expires.
        let lagTl = [
            TimelineEntry(id: "old-hold", date: "2026-03-28", item: "Cash Tax", amount: 40_000, done: true, phoneChecked: true),
            TimelineEntry(id: "sal-lag", date: "2026-04-25", item: "Salary", amount: -300_000, payday: true, estimate: true),
            TimelineEntry(id: "man-bill", date: "2026-04-26", item: "Gym Pass", amount: 4_500),
            TimelineEntry(id: "sal-next", date: "2026-05-25", item: "Salary", amount: -300_000, payday: true, next: true, estimate: true),
        ]
        let lagPayday = try #require(PaydayView.compute(timeline: lagTl, today: "2026-04-26"))
        let unrelatedDebit = TimelineReconciler.BankRow(source: "Main Bank", date: "2026-04-26", amount: 4_500, description: "COFFEE ROASTER")
        let lagLive = try #require(LiveCashSummary.compute(
            accountBalances: [AccountBalance(source: "main_bank", label: "Main Bank", balance: 100_000, asOf: "2026-04-24")],
            sourceLabels: ["main_bank": "Main Bank"],
            bankRows: [unrelatedDebit],
            pendingItems: [],
            payday: lagPayday,
            lastPayday: "2026-04-25",
            today: "2026-04-26"
        ))
        // Bank = 100,000 - 4,500 = 95,500; old-hold expired (0); man-bill NOT cleared by COFFEE ROASTER (-4,500); lag salary kept (+300,000) -> 391,000!
        #expect(lagLive.phoneCheckedBillsSum == 0)
        #expect(lagLive.remainingBillsSum == 4_500)
        #expect(lagLive.remainingInflowsSum == 300_000)
        #expect(lagLive.cashLeftUntilPayday == 391_000)
        let lagGroups = ComingUp.groups(timeline: lagTl, today: "2026-04-26")
        let lagRunning = try #require(ComingUp.runningBalances(groups: lagGroups, today: "2026-04-26", liveCash: lagLive, lastPayday: "2026-04-25"))
        #expect(lagRunning.cashAfterBills == lagLive.cashLeftUntilPayday)

        // 4. Merpay split-tender 1-to-1 matching for duplicate totals, merchantless notices, bank posting, and snapshot-day asOfRowAmounts.
        let splitNotices = [
            Notice(messageID: "s-1", source: .merpay, kind: .purchase, receivedAt: "2026-04-15T10:00:00+09:00", occurredOn: "2026-04-15", amount: 3_000, merchant: "SHOP A", parts: ["credit": 1_000, "points": 2_000], parser: "merpay/1"),
            Notice(messageID: "s-2", source: .merpay, kind: .purchase, receivedAt: "2026-04-15T12:00:00+09:00", occurredOn: "2026-04-15", amount: 3_000, merchant: nil, parts: ["credit": 2_500, "points": 500], parser: "merpay/1"),
        ]
        let postedSplitRow = TimelineReconciler.BankRow(source: "Merpay", date: "2026-04-15", amount: 3_000, description: "SHOP A")
        let pendingSplits = [
            // Same-day already-counted charge (matches asOfRowAmounts [1200]) must NOT subtract again.
            BudgetItem(date: "2026-04-14", source: "Merpay", merchant: "MORNING", amount: 1_200, group: "Living", category: "Other", isPending: true),
            // Same-day NEW post-snapshot charge on asOf (2026-04-14) MUST subtract!
            BudgetItem(date: "2026-04-14", source: "Merpay", merchant: "EVENING", amount: 500, group: "Living", category: "Other", isPending: true),
            // Second ¥3,000 merchantless split notice on 2026-04-15 -> uses credit: 2,500!
            BudgetItem(date: "2026-04-15", source: "Merpay", merchant: PendingBuilder.missingMerchantPlaceholder, amount: 3_000, group: "Living", category: "Other", isPending: true),
        ]
        let splitRoom = CreditRoom(label: "Merpay", available: 40_000, limit: 300_000, asOf: "2026-04-14", sourceKeys: ["merpay", "merpay_mf"], asOfRowAmounts: [1_200])
        let splitLive = try #require(LiveCashSummary.compute(
            accountBalances: [AccountBalance(source: "main_bank", label: "Main Bank", balance: 100_000, asOf: "2026-04-14")],
            creditRooms: [splitRoom],
            sourceLabels: ["main_bank": "Main Bank", "merpay": "Merpay", "merpay_mf": "Merpay"],
            bankRows: [postedSplitRow],
            pendingItems: pendingSplits,
            payday: lagPayday,
            notices: splitNotices,
            today: "2026-04-15"
        ))
        // 40,000 - 1,000 (posted split credit) - 500 (same-day new) - 2,500 (pending merchantless split) = 36,000!
        #expect(splitLive.creditSources.first(where: { $0.shortLabel == "Merpay" })?.amount == 36_000)

        // 5. extractMonthlyPayment skips limit/paid clauses, handles middle-dot/comma/unpaid, and picks the actual upcoming bill (invented figures).
        #expect(SpendingInsights.extractMonthlyPayment(from: ["Limit ¥250,000, monthly repayment ¥12,000"]) == 12_000)
        #expect(SpendingInsights.extractMonthlyPayment(from: ["¥250,000 limit · ¥12,000 monthly"]) == 12_000)
        #expect(SpendingInsights.extractMonthlyPayment(from: [
            "Apr bill ¥41,200 paid; May bill ¥39,500 due May 26",
        ]) == 39_500)
        #expect(SpendingInsights.extractMonthlyPayment(from: [
            "Apr bill ¥41,200 paid Apr 20, May bill ¥39,500 on May 26",
        ]) == 39_500)
        #expect(SpendingInsights.extractMonthlyPayment(from: ["Upcoming unpaid bill ¥5,000"]) == 5_000)

        // 6. Ask Finance routes "Which bills are due before payday?" to upcomingBillsAnswer,
        //    routes "How much is left after bills?" to paydayAnswer, and excludes expired phone holds.
        let qBundle = DataBundle(
            generatedAt: "2026-04-14T09:00:00+09:00", asOf: "2026-04-14",
            timeline: [
                TimelineEntry(id: "s0", date: "2026-03-25", item: "Salary", amount: -300_000, payday: true, done: true),
                TimelineEntry(id: "old-p", date: "2026-03-20", item: "Expired Manual Hold", amount: 4_000, done: true, phoneChecked: true),
                TimelineEntry(id: "b1", date: "2026-04-18", item: "Rent", amount: 80_000),
                TimelineEntry(id: "s1", date: "2026-04-25", item: "Salary", amount: -300_000, payday: true, next: true),
            ],
            layers: Self.sampleLayers, layerConfig: Self.sampleConfig
        )
        let qCtx = FinanceQueryEngine.Context(
            bundle: qBundle, allItems: [], totalsByMonth: [:], timeline: qBundle.timeline,
            payday: PaydayView.compute(timeline: qBundle.timeline, today: "2026-04-14"),
            planSummary: PlanSummary.compute(plan: [], planWindow: nil, totalsByMonth: [:], selectedMonth: "2026-04", currentMonth: "2026-04", inProgressMonth: "2026-04"),
            subscriptionSummary: SubscriptionSummary.compute(from: []),
            today: "2026-04-14"
        )
        let dueAns = FinanceQueryEngine.answer("Which bills are due before payday?", context: qCtx)
        #expect(dueAns.headline == "¥80,000")
        #expect(dueAns.rows.contains(where: { $0.label.contains("Rent") }))
        #expect(!dueAns.rows.contains(where: { $0.label.contains("Expired Manual Hold") }))
        let cashLeftAns = FinanceQueryEngine.answer("How much is left after bills?", context: qCtx)
        #expect(cashLeftAns.subtitle.contains("2026-04-25"))
    }

    @Test("v0.6.9 Round 3: Equal-rank ties with one-sided refs, snapshot-day same-shop repeats, Apple service/descriptor/coverage guards, local duplicate reminders, holidays, and usage sub disambiguation")
    func roundThreeHardeningRegressions() throws {
        // 1. Equal-rank ties with one-sided references (MUFG bank refs vs ref-less notices, Merpay notice refs vs ref-less rows,
        //    and Apple receipt + APPLE.COM/BILL notice vs 2 APPLE.CO bank rows) must pair cleanly with ZERO double-counting.
        let tieBundle = DataBundle(
            generatedAt: "2026-04-14T10:00:00+09:00",
            asOf: "2026-04-12",
            coverage: [
                "main_bank": CoverageRange(start: "2026-01-01", end: "2026-04-12"),
                "mufg_debit": CoverageRange(start: "2026-01-01", end: "2026-04-12"),
                "merpay": CoverageRange(start: "2026-01-01", end: "2026-04-12"),
                "merpay_mf": CoverageRange(start: "2026-01-01", end: "2026-04-12"),
                "apple": CoverageRange(start: "2026-01-01", end: "2026-04-12"),
            ],
            sourceLabels: [
                "main_bank": "Main Bank", "mufg_debit": "Main Debit",
                "merpay": "Merpay", "merpay_mf": "Merpay", "apple": "Apple",
            ],
            layers: Self.sampleLayers,
            layerConfig: Self.sampleConfig,
            noticeSourceMatches: ["mufg_debit": ["main_bank"], "merpay": ["merpay_mf"], "apple": ["main_bank"]],
            statementLineRules: [
                "main_bank": [
                    StatementLineRule(pattern: #"^デビット\d* (\d{6}) (.+)$"#, referenceGroup: 1, merchantGroup: 2, itemSource: "Main Debit"),
                ],
            ],
            accountBalances: [
                AccountBalance(source: "main_bank", label: "Main Bank", balance: 100_000, asOf: "2026-04-12", debitNoticeSources: ["mufg_debit"], asOfRowAmounts: []),
            ]
        )

        let tieTxs = [
            // Two identical MUFG debits with distinct 6-digit approval refs vs ref-less notices:
            BankTransaction(id: "tx-m1", connectedAccountID: "acc", date: "2026-04-14", amount: 500, description: "デビット1 111111 MART-ONE"),
            BankTransaction(id: "tx-m2", connectedAccountID: "acc", date: "2026-04-14", amount: 500, description: "デビット1 222222 MART-ONE"),
            // Two identical Apple bank rows vs 1 Apple receipt + 1 APPLE.COM/BILL notice:
            BankTransaction(id: "tx-a1", connectedAccountID: "acc", date: "2026-04-14", amount: 3_000, description: "デビット1 333333 APPLE.CO"),
            BankTransaction(id: "tx-a2", connectedAccountID: "acc", date: "2026-04-14", amount: 3_000, description: "デビット1 444444 APPLE.CO"),
            // PINEAPPLE CAFE must NEVER match Apple receipt!
            BankTransaction(id: "tx-pine", connectedAccountID: "acc", date: "2026-04-14", amount: 1_200, description: "デビット1 555555 PINEAPPLE CAFE"),
            // Two identical Merpay bank rows (no ref) vs 2 Merpay notices (distinct tx refs):
            BankTransaction(id: "tx-mp1", connectedAccountID: "mp", date: "2026-04-14", amount: 1_000, description: "SHOP-X"),
            BankTransaction(id: "tx-mp2", connectedAccountID: "mp", date: "2026-04-14", amount: 1_000, description: "SHOP-X"),
        ]
        let tieNotices = [
            Notice(messageID: "n-m1", source: .mufgDebit, kind: .purchase, receivedAt: "2026-04-14T09:00:00+09:00", occurredOn: "2026-04-14", amount: 500, merchant: "MART-ONE", parser: "test/1"),
            Notice(messageID: "n-m2", source: .mufgDebit, kind: .purchase, receivedAt: "2026-04-14T15:00:00+09:00", occurredOn: "2026-04-14", amount: 500, merchant: "MART-ONE", parser: "test/1"),
            Notice(messageID: "n-a-rcpt", source: .apple, kind: .purchase, receivedAt: "2026-04-14T10:00:00+09:00", occurredOn: "2026-04-14", amount: 3_000, merchant: "Cloud App", reference: "ORD-A1", parser: "apple/1"),
            Notice(messageID: "n-a-d1", source: .mufgDebit, kind: .purchase, receivedAt: "2026-04-14T10:01:00+09:00", occurredOn: "2026-04-14", amount: 3_000, merchant: "APPLE.COM/BILL", parser: "mufg_debit/1"),
            Notice(messageID: "n-a-d2", source: .mufgDebit, kind: .purchase, receivedAt: "2026-04-14T14:00:00+09:00", occurredOn: "2026-04-14", amount: 3_000, merchant: "APPLE.COM/BILL", parser: "mufg_debit/1"),
            // Apple receipt for ¥1,200 must stay pending and NOT match PINEAPPLE CAFE!
            Notice(messageID: "n-pine-rcpt", source: .apple, kind: .purchase, receivedAt: "2026-04-14T11:00:00+09:00", occurredOn: "2026-04-14", amount: 1_200, merchant: "Music App", reference: "ORD-M1", parser: "apple/1"),
            // Merpay identical purchases with distinct refs:
            Notice(messageID: "n-mp1", source: .merpay, kind: .purchase, receivedAt: "2026-04-14T12:00:00+09:00", occurredOn: "2026-04-14", amount: 1_000, merchant: "SHOP-X", reference: "MP-1", parser: "merpay/1"),
            Notice(messageID: "n-mp2", source: .merpay, kind: .purchase, receivedAt: "2026-04-14T13:00:00+09:00", occurredOn: "2026-04-14", amount: 1_000, merchant: "SHOP-X", reference: "MP-2", parser: "merpay/1"),
            // Old covered MUFG Apple notice (before coverage.end 2026-04-12) must NOT steal n-pine-rcpt!
            Notice(messageID: "n-old-cov", source: .mufgDebit, kind: .purchase, receivedAt: "2026-04-11T10:00:00+09:00", occurredOn: "2026-04-11", amount: 1_200, merchant: "APPLE.COM/BILL", parser: "mufg_debit/1"),
        ]
        let tieResult = BankLayering.build(
            bundle: tieBundle,
            bankTransactions: tieTxs,
            accountMapping: ["acc": "main_bank", "mp": "merpay_mf"],
            notices: tieNotices,
            categorizer: Categorizer(rules: RuleSet()),
            config: Self.sampleConfig
        )
        #expect(tieResult.ambiguous.isEmpty)
        #expect(tieResult.matchedPairs.count == 6) // 2 MART-ONE + 2 APPLE + 2 Merpay
        #expect(tieResult.pendingNoticeIDs == ["n-pine-rcpt"])
        #expect(tieResult.pendingItems[0].fundingSource == nil) // Not stolen by n-old-cov!

        // 2. Snapshot-day same-shop repeat: BOTH partial feed (stays pending) AND full feed (pairs cleanly without tie!).
        let snapBundle = DataBundle(
            generatedAt: "2026-04-12T08:00:00+09:00",
            asOf: "2026-04-12",
            coverage: ["main_bank": CoverageRange(start: "2026-01-01", end: "2026-04-12"), "mufg_debit": CoverageRange(start: "2026-01-01", end: "2026-04-12")],
            sourceLabels: ["main_bank": "Main Bank", "mufg_debit": "Main Debit"],
            items: [
                BudgetItem(date: "2026-04-12", source: "Main Debit", merchant: "SAME SHOP", amount: 600, group: "Living", category: "Other", layer: "Day-to-day"),
            ],
            timeline: [TimelineEntry(date: "2026-04-25", item: "Salary", amount: -300_000, payday: true, next: true)],
            layers: Self.sampleLayers,
            layerConfig: Self.sampleConfig,
            noticeSourceMatches: ["mufg_debit": ["main_bank"]],
            accountBalances: [
                AccountBalance(source: "main_bank", label: "Main Bank", balance: 50_000, asOf: "2026-04-12", debitNoticeSources: ["mufg_debit"], asOfRowAmounts: [600]),
            ]
        )
        let snapAmRow = BankTransaction(id: "tx-am", connectedAccountID: "acc", date: "2026-04-12", amount: 600, description: "SAME SHOP")
        let snapPmRow = BankTransaction(id: "tx-pm", connectedAccountID: "acc", date: "2026-04-12", amount: 600, description: "SAME SHOP")
        let snapAmNotice = Notice(messageID: "n-am", source: .mufgDebit, kind: .purchase, receivedAt: "2026-04-12T07:00:00+09:00", occurredOn: "2026-04-12", amount: 600, merchant: "SAME SHOP", parser: "test/1")
        let snapPmNotice = Notice(messageID: "n-pm", source: .mufgDebit, kind: .purchase, receivedAt: "2026-04-12T15:00:00+09:00", occurredOn: "2026-04-12", amount: 600, merchant: "SAME SHOP", parser: "test/1")
        let snapPayday = try #require(PaydayView.compute(timeline: snapBundle.timeline, today: "2026-04-12"))

        // Partial feed (only morning covered row present): afternoon notice stays pending -> cash = 49,400!
        let snapPartial = BankLayering.build(
            bundle: snapBundle, bankTransactions: [snapAmRow], accountMapping: ["acc": "main_bank"],
            notices: [snapAmNotice, snapPmNotice], categorizer: Categorizer(rules: RuleSet()), config: Self.sampleConfig
        )
        let snapLivePartial = try #require(LiveCashSummary.compute(
            accountBalances: snapBundle.accountBalances!, sourceLabels: snapBundle.sourceLabels,
            bankRows: snapPartial.allBankRows, pendingItems: snapPartial.pendingItems, payday: snapPayday
        ))
        #expect(snapPartial.pendingItems.count == 1)
        #expect(snapLivePartial.estimatedBankCash == 49_400)

        // Full feed (both morning & afternoon rows present): pairs cleanly -> 0 pending, 1 intraday bankItem, cash = 49,400!
        let snapFull = BankLayering.build(
            bundle: snapBundle, bankTransactions: [snapAmRow, snapPmRow], accountMapping: ["acc": "main_bank"],
            notices: [snapAmNotice, snapPmNotice], categorizer: Categorizer(rules: RuleSet()), config: Self.sampleConfig
        )
        let snapLiveFull = try #require(LiveCashSummary.compute(
            accountBalances: snapBundle.accountBalances!, sourceLabels: snapBundle.sourceLabels,
            bankRows: snapFull.allBankRows, pendingItems: snapFull.pendingItems, payday: snapPayday
        ))
        #expect(snapFull.pendingItems.isEmpty)
        #expect(snapFull.bankItems.count == 1)
        #expect(snapLiveFull.estimatedBankCash == 49_400)

        // 3. Unrelated ¥900 Apple game receipt MUST NOT settle scheduled "Stream Plus" ¥900 APPLE.COM/BILL bill,
        //    and a pre-asOf Apple receipt MUST NOT settle a bank-linked bill without deducting cash.
        let appleBillTl = [
            TimelineEntry(
                id: "rec:stream:2026-04", date: "2026-04-14", item: "Stream Plus", amount: 900,
                match: TimelineMatch(source: "Main Bank", pattern: #"APPLE\.CO|APPLE\.COM/BILL"#, dir: "out", window: [-3, 5], minAmount: 800, maxAmount: 1_000)
            ),
        ]
        let unrelatedGame = BudgetItem(date: "2026-04-14", source: "Apple", merchant: "Arcade Quest", amount: 900, group: "Living", category: "Games", isPending: true, fundingSource: "mufg_debit")
        let preAsOfStream = BudgetItem(date: "2026-04-11", source: "Apple", merchant: "Stream Plus", amount: 900, group: "Subs", category: "Media", isPending: true, fundingSource: "mufg_debit")
        let settledByGame = TimelineReconciler.reconcilePendingNotices(
            timeline: appleBillTl, pendingItems: [unrelatedGame, preAsOfStream],
            accountBalances: tieBundle.accountBalances!, sourceLabels: tieBundle.sourceLabels
        )
        #expect(settledByGame[0].done != true)

        // 4. Two identical local custom reminders with distinct UUIDs BOTH appear BEFORE any PC round-trip!
        let dupA = CustomReminder(date: "2026-04-20", title: "Library fee", amount: 2_000)
        let dupB = CustomReminder(date: "2026-04-20", title: "Library fee", amount: 2_000)
        let preRoundTrip = LocalDataApplier.mergeCustomReminders(timeline: [], reminders: [dupA, dupB])
        #expect(preRoundTrip.count == 2)

        // 5. Payday-morning PayCycle stays marked `isInProgress == true`.
        let morningPayTl = [
            TimelineEntry(id: "p1", date: "2026-03-25", item: "Salary", amount: -300_000, payday: true, done: true),
            TimelineEntry(id: "p2", date: "2026-04-25", item: "Salary", amount: -300_000, payday: true, next: true),
        ]
        let morningCycles = PayCycleBuilder.payCycles(items: [], timeline: morningPayTl, config: Self.sampleConfig, today: "2026-04-25")
        #expect(morningCycles.last?.isInProgress == true)

        // 6. CashFlowForecast shifts bank bills off Jan 11 (Coming of Age Day) & respects `rollBusinessDay: false`.
        let holTl = [
            TimelineEntry(id: "h-bank", date: "2026-12-11", item: "Utility Auto", amount: 5_000, note: "Bank auto-debit", recurring: true, rollBusinessDay: true),
            TimelineEntry(id: "h-card", date: "2026-12-11", item: "Cloud Fixed", amount: 1_000, note: "Debit card", recurring: true, rollBusinessDay: false),
            TimelineEntry(id: "h-sal", date: "2026-12-25", item: "Salary", amount: -300_000, payday: true, next: true, recurring: true, rollBusinessDay: true),
        ]
        let holForecast = CashFlowForecast.project(
            today: "2026-12-15", days: 45,
            payday: PaydayView.compute(timeline: holTl, today: "2026-12-15"),
            paydayBreakdown: nil, timeline: holTl, allItems: [],
            subscriptionSummary: SubscriptionSummary.compute(from: []),
            config: Self.sampleConfig, layers: Self.sampleLayers, startingCashOverride: 100_000
        )
        let janEvents = holForecast.points.flatMap(\.events).filter { $0.date.hasPrefix("2027-01-") }
        #expect(janEvents.contains(where: { $0.title == "Utility Auto" && $0.date == "2027-01-12" })) // Rolled off Mon Jan 11 holiday!
        #expect(janEvents.contains(where: { $0.title == "Cloud Fixed" && $0.date == "2027-01-11" }))  // Fixed calendar day!

        // 7. Usage-based subscription "Vendor API (metered)" matches plain vendor & API charges but not "VENDOR PRO".
        let apiSub = SubscriptionItem(
            entry: SubscriptionEntry(name: "Vendor API (metered)", monthly: 2_000, via: "Card", status: "Keep"),
            isOff: false, countsAsSaving: false, displayStatus: "Keep", tone: .good
        )
        let vendorItems = [
            BudgetItem(date: "2026-04-05", source: "Card", merchant: "VENDOR API", amount: 1_800, group: "Subs", category: "Tools", layer: "Subscriptions"),
            BudgetItem(date: "2026-04-06", source: "Card", merchant: "VENDOR PRO", amount: 3_000, group: "Subs", category: "Tools", layer: "Subscriptions"),
            BudgetItem(date: "2026-04-07", source: "Card", merchant: "VENDOR", amount: 2_200, group: "Subs", category: "Tools", layer: "Subscriptions"),
        ]
        let apiHistory = SubscriptionHistory.compute(
            for: apiSub, allItems: vendorItems, months: ["2026-04"],
            today: "2026-04-14", config: Self.sampleConfig, layers: Self.sampleLayers
        )
        #expect(apiHistory.matchedItems.count == 2)
        #expect(!apiHistory.matchedItems.contains(where: { $0.merchant == "VENDOR PRO" }))
    }

    @Test("v0.6.9 Round 4: Posted/pending Apple game guard, Merpay split isolation & same-day override timestamp, 09:02 MUFG match, stale hold expiry, Runway lag/holiday/nominalDay, and debt paid qualifiers")
    func roundFourHardeningRegressions() throws {
        // 1. Posted APPLE.CO debit resolved to "Arcade Quest" AND unattributed pending APPLE.COM/BILL
        //    must BOTH leave scheduled "Stream Plus" open; only a matching "Stream Plus" receipt settles it.
        let appleTl = [
            TimelineEntry(
                id: "rec:stream:2026-04", date: "2026-04-14", item: "Stream Plus", amount: 900,
                match: TimelineMatch(source: "Main Bank", pattern: #"APPLE\.CO|APPLE\.COM/BILL"#, dir: "out", window: [-3, 5], minAmount: 800, maxAmount: 1_000)
            ),
        ]
        let appleBundle = DataBundle(
            generatedAt: "2026-04-14T10:00:00+09:00", asOf: "2026-04-12",
            coverage: ["main_bank": CoverageRange(start: "2026-01-01", end: "2026-04-12"), "mufg_debit": CoverageRange(start: "2026-01-01", end: "2026-04-12"), "apple": CoverageRange(start: "2026-01-01", end: "2026-04-12")],
            sourceLabels: ["main_bank": "Main Bank", "mufg_debit": "Main Debit", "apple": "Apple"],
            items: [], timeline: appleTl, layers: Self.sampleLayers, layerConfig: Self.sampleConfig,
            noticeSourceMatches: ["mufg_debit": ["main_bank"], "apple": ["main_bank"]],
            statementLineRules: ["main_bank": [StatementLineRule(pattern: #"^デビット\d* (\d{6}) (.+)$"#, referenceGroup: 1, merchantGroup: 2, itemSource: "Main Debit")]],
            accountBalances: [AccountBalance(source: "main_bank", label: "Main Bank", balance: 50_000, asOf: "2026-04-12", debitNoticeSources: ["mufg_debit"])]
        )
        let postedGameTx = BankTransaction(id: "tx-game", connectedAccountID: "acc", date: "2026-04-14", amount: 900, description: "デビット1 123456 APPLE.CO")
        let gameNotices = [
            Notice(messageID: "a-game", source: .apple, kind: .purchase, receivedAt: "2026-04-14T11:00:00+09:00", occurredOn: "2026-04-14", amount: 900, merchant: "Arcade Quest", reference: "ORD-G1", parser: "apple/1"),
            Notice(messageID: "d-game", source: .mufgDebit, kind: .purchase, receivedAt: "2026-04-14T11:01:00+09:00", occurredOn: "2026-04-14", amount: 900, merchant: "APPLE.COM/BILL", parser: "mufg_debit/1"),
        ]
        let layeredGame = BankLayering.build(
            bundle: appleBundle, bankTransactions: [postedGameTx], accountMapping: ["acc": "main_bank"],
            notices: gameNotices, categorizer: Categorizer(rules: RuleSet()), config: Self.sampleConfig
        )
        #expect(layeredGame.bankRows.first?.resolvedMerchant == "Arcade Quest")
        let afterPostedGame = TimelineReconciler.reconcile(timeline: appleTl, bankRows: layeredGame.bankRows)
        #expect(afterPostedGame[0].done != true)

        let genericPendingApple = BudgetItem(date: "2026-04-14", source: "Main Debit", merchant: "APPLE.COM/BILL", amount: 900, group: "Digital", category: "Apple", isPending: true)
        let afterGenericPending = TimelineReconciler.reconcilePendingNotices(
            timeline: appleTl, pendingItems: [genericPendingApple],
            accountBalances: appleBundle.accountBalances!, sourceLabels: appleBundle.sourceLabels
        )
        #expect(afterGenericPending[0].done != true)

        // 2. Old unrelated split notice does NOT inflate credit room on a later full-credit purchase,
        //    and a same-day post-override purchase (received after `asOfTimestamp`) DOES reduce credit room.
        let oldSplit = Notice(messageID: "n-old-split", source: .merpay, kind: .purchase, receivedAt: "2026-04-13T10:00:00+09:00", occurredOn: "2026-04-13", amount: 3_000, merchant: "OLD SHOP", parts: ["credit": 1_000, "points": 2_000], parser: "merpay/1")
        let newFull = Notice(messageID: "n-new-full", source: .merpay, kind: .purchase, receivedAt: "2026-04-15T15:00:00+09:00", occurredOn: "2026-04-15", amount: 3_000, merchant: "NEW SHOP", parser: "merpay/1")
        let preOverride = Notice(messageID: "n-pre-ov", source: .merpay, kind: .purchase, receivedAt: "2026-04-15T08:00:00+09:00", occurredOn: "2026-04-15", amount: 700, merchant: "MORNING CAFE", parser: "merpay/1")
        let roomWithTs = CreditRoom(
            label: "Card A", available: 40_000, limit: 200_000,
            asOf: "2026-04-15", sourceKeys: ["merpay", "merpay_mf"],
            asOfTimestamp: "2026-04-15T10:00:00+09:00"
        )
        let fullCreditBankRow = TimelineReconciler.BankRow(source: "Merpay", date: "2026-04-16", amount: 3_000, description: "NEW SHOP")
        let preOvPending = BudgetItem(date: "2026-04-15", source: "Merpay", merchant: "MORNING CAFE", amount: 700, group: "Food", category: "Cafe", isPending: true)
        let postOvPending = BudgetItem(date: "2026-04-15", source: "Merpay", merchant: "NEW SHOP", amount: 3_000, group: "Food", category: "Dining", isPending: true)
        let payRef = try #require(PaydayView.compute(timeline: [TimelineEntry(date: "2026-04-25", item: "Salary", amount: -300_000, payday: true, next: true)], today: "2026-04-16"))
        let roomLive = try #require(LiveCashSummary.compute(
            accountBalances: [AccountBalance(source: "main_bank", label: "Main Bank", balance: 100_000, asOf: "2026-04-14")],
            creditRooms: [roomWithTs],
            sourceLabels: ["main_bank": "Main Bank", "merpay": "Merpay", "merpay_mf": "Merpay"],
            bankRows: [fullCreditBankRow],
            pendingItems: [preOvPending, postOvPending],
            payday: payRef,
            notices: [oldSplit, preOverride, newFull],
            today: "2026-04-16"
        ))
        // 40,000 - 3,000 (posted full-credit on Apr 16, NOT borrowing oldSplit's 1,000!) - 3,000 (post-override 15:00 on Apr 15; 08:00 excluded) = 34,000!
        #expect(roomLive.creditSources.first(where: { $0.shortLabel == "Card A" })?.amount == 34_000)

        // 3. Legacy debt override without per-debt date is frozen onto previous `updatedAt` before a new edit.
        var legacyMods = LocalModifications(
            debtBalanceOverrides: ["Card A": 100_000],
            debtBalanceOverrideDates: [:],
            updatedAt: ISO8601DateFormatter().date(from: "2026-04-10T10:00:00+09:00")
        )
        legacyMods.stampLegacyDebtOverrideDates()
        #expect(legacyMods.debtBalanceOverrideDates["Card A"] == "2026-04-10")

        // 4. Next-morning 09:02 JST MUFG debit email matches post-cutoff bank row at offset -1,
        //    and overnight 00:03 email on coverage.end+1 deduplicates against coverage.end bundle item.
        let mufgBundle = DataBundle(
            generatedAt: "2026-04-12T10:00:00+09:00", asOf: "2026-04-12",
            coverage: ["main_bank": CoverageRange(start: "2026-01-01", end: "2026-04-12"), "mufg_debit": CoverageRange(start: "2026-01-01", end: "2026-04-12")],
            sourceLabels: ["main_bank": "Main Bank", "mufg_debit": "Main Debit"],
            items: [BudgetItem(date: "2026-04-12", source: "Main Debit", merchant: "LATE STORE", amount: 1_300, group: "Food", category: "Store", layer: "Day-to-day")],
            timeline: [TimelineEntry(date: "2026-04-25", item: "Salary", amount: -300_000, payday: true, next: true)],
            layers: Self.sampleLayers, layerConfig: Self.sampleConfig,
            noticeSourceMatches: ["mufg_debit": ["main_bank"]],
            statementLineRules: ["main_bank": [StatementLineRule(pattern: #"^デビット\d* (\d{6}) (.+)$"#, referenceGroup: 1, merchantGroup: 2, itemSource: "Main Debit")]]
        )
        let morning0902Row = BankTransaction(id: "tx-gp", connectedAccountID: "acc", date: "2026-04-14", amount: 4_000, description: "デビット1 654321 CLOUD SUB")
        let morning0902Notice = Notice(messageID: "n-0902", source: .mufgDebit, kind: .purchase, receivedAt: "2026-04-15T09:02:00+09:00", amount: 4_000, merchant: "CLOUD SUB", parser: "mufg_debit/1")
        let overnightCoveredNotice = Notice(messageID: "n-0003", source: .mufgDebit, kind: .purchase, receivedAt: "2026-04-13T00:03:00+09:00", amount: 1_300, merchant: "LATE STORE", parser: "mufg_debit/1")
        let mufgLayered = BankLayering.build(
            bundle: mufgBundle, bankTransactions: [morning0902Row], accountMapping: ["acc": "main_bank"],
            notices: [overnightCoveredNotice, morning0902Notice], categorizer: Categorizer(rules: RuleSet()), config: Self.sampleConfig
        )
        #expect(mufgLayered.pendingItems.isEmpty)
        #expect(mufgLayered.matchedPairs.count == 1)

        // 5. Stale bank-linked phone hold expires after its posting window even within the same pay cycle.
        let staleHold = TimelineEntry(
            id: "rec:stale:2026-04", date: "2026-04-02", item: "Stale Utility", amount: 3_500,
            done: true, phoneChecked: true,
            match: TimelineMatch(source: "Main Bank", pattern: "UTIL", dir: "out", window: [-3, 5])
        )
        #expect(!LiveCashSummary.isPhoneCheckedHoldActive(for: staleHold, lastPayday: "2026-03-25", today: "2026-04-18"))
        #expect(LiveCashSummary.isPhoneCheckedHoldActive(for: staleHold, lastPayday: "2026-03-25", today: "2026-04-06"))

        // 6. CashFlowForecast: lagging payday included on day 0, Sep 22 2026 Citizens' Holiday rolled,
        //    and nominalDay prevents shifted-payday projection drift (Apr 3 for nominal day 5 -> Jun 5).
        let runwayTl = [
            TimelineEntry(id: "sal-lag", date: "2026-04-03", item: "Salary", amount: -300_000, payday: true, estimate: true, recurring: true, rollBusinessDay: true, nominalDay: 5),
            TimelineEntry(id: "sal-next", date: "2026-05-01", item: "Salary", amount: -300_000, payday: true, next: true, estimate: true, recurring: true, rollBusinessDay: true, nominalDay: 5),
        ]
        let lagForecast = CashFlowForecast.project(
            today: "2026-04-04", days: 90,
            payday: PaydayView.compute(timeline: runwayTl, today: "2026-04-04"),
            paydayBreakdown: nil, timeline: runwayTl, allItems: [],
            subscriptionSummary: SubscriptionSummary.compute(from: []),
            config: Self.sampleConfig, layers: Self.sampleLayers, startingCashOverride: 50_000
        )
        #expect(lagForecast.points.first?.events.contains(where: { $0.amount == -300_000 }) == true)
        let junSalary = lagForecast.points.flatMap(\.events).first { $0.date.hasPrefix("2026-06-") && $0.amount == -300_000 }
        #expect(junSalary?.date == "2026-06-05")

        let swTl = [
            TimelineEntry(id: "bill-sw", date: "2026-08-22", item: "Bank Auto", amount: 10_000, recurring: true, rollBusinessDay: true, nominalDay: 22),
            TimelineEntry(id: "sal-sw", date: "2026-09-25", item: "Salary", amount: -300_000, payday: true, next: true, recurring: true, rollBusinessDay: true, nominalDay: 25),
        ]
        let swForecast = CashFlowForecast.project(
            today: "2026-09-01", days: 45,
            payday: PaydayView.compute(timeline: swTl, today: "2026-09-01"),
            paydayBreakdown: nil, timeline: swTl, allItems: [],
            subscriptionSummary: SubscriptionSummary.compute(from: []),
            config: Self.sampleConfig, layers: Self.sampleLayers, startingCashOverride: 50_000
        )
        let sepAuto = swForecast.points.flatMap(\.events).first { $0.title == "Bank Auto" && $0.date.hasPrefix("2026-09-") }
        // Sep 21 (Respect for the Aged Day), Sep 22 (Citizens' Holiday), Sep 23 (Autumnal Equinox) -> rolls to Thu Sep 24!
        #expect(sepAuto?.date == "2026-09-24")

        // 7. Debt extractMonthlyPayment keeps standalone ", paid" / "· paid" bound to the preceding amount.
        #expect(SpendingInsights.extractMonthlyPayment(from: ["Minimum ¥4,000, paid, monthly repayment ¥14,000"]) == 14_000)
        #expect(SpendingInsights.extractMonthlyPayment(from: ["Apr bill ¥41,200 · paid"]) == nil)
    }

    @Test("v0.6.9 Round 5: Annotated bundle dedupe, strict Apple billing descriptor, lagging estimated salary flag, zero-baseline metered sub, and future payoff clause")
    func roundFiveHardeningRegressions() throws {
        // 1. A bundle item with a trailing parenthetical note ("STREAMAPP (annual promo note)") still
        //    deduplicates a matching coverage-day notice ("STREAMAPPSTORE") and snapshot-day MF row.
        let annotatedBundle = DataBundle(
            generatedAt: "2026-04-18T10:00:00+09:00", asOf: "2026-04-18",
            coverage: ["main_bank": CoverageRange(start: "2026-01-01", end: "2026-04-18"), "mufg_debit": CoverageRange(start: "2026-01-01", end: "2026-04-18")],
            sourceLabels: ["main_bank": "Main Bank", "mufg_debit": "Main Debit"],
            items: [
                BudgetItem(
                    date: "2026-04-18", source: "Main Debit",
                    merchant: "STREAMAPP (annual promo note)",
                    amount: 1_200, group: "Subs", category: "Media", layer: "Subscriptions"
                ),
            ],
            timeline: [TimelineEntry(date: "2026-05-25", item: "Salary", amount: -300_000, payday: true, next: true)],
            layers: Self.sampleLayers, layerConfig: Self.sampleConfig,
            noticeSourceMatches: ["mufg_debit": ["main_bank"]],
            statementLineRules: ["main_bank": [StatementLineRule(pattern: #"^デビット\d* (\d{6}) (.+)$"#, referenceGroup: 1, merchantGroup: 2, itemSource: "Main Debit")]],
            accountBalances: [
                AccountBalance(source: "main_bank", label: "Main Bank", balance: 80_000, asOf: "2026-04-18", debitNoticeSources: ["mufg_debit"], asOfRowAmounts: [1_200]),
            ]
        )
        let streamNotice = Notice(
            messageID: "n-stream", source: .mufgDebit, kind: .purchase,
            receivedAt: "2026-04-18T07:00:00+09:00", occurredOn: "2026-04-18",
            amount: 1_200, merchant: "STREAMAPPSTORE", parser: "mufg_debit/1"
        )
        let streamTx = BankTransaction(id: "tx-stream", connectedAccountID: "acc", date: "2026-04-18", amount: 1_200, description: "デビット1 123456 STREAMAPP")
        let streamLayered = BankLayering.build(
            bundle: annotatedBundle, bankTransactions: [streamTx], accountMapping: ["acc": "main_bank"],
            notices: [streamNotice], categorizer: Categorizer(rules: RuleSet()), config: Self.sampleConfig
        )
        #expect(streamLayered.pendingItems.isEmpty)
        #expect(streamLayered.bankItems.isEmpty)

        // 2. Non-Apple merchant starting with "APPLE" ("APPLE PARK CAFE") never matches or suppresses an Apple receipt,
        //    while genuine Japanese/ASCII descriptors ("Appleサービス", "APPLE COM BILL") do match.
        let cafeBundle = DataBundle(
            generatedAt: "2026-04-14T10:00:00+09:00", asOf: "2026-04-12",
            coverage: ["main_bank": CoverageRange(start: "2026-01-01", end: "2026-04-12"), "mufg_debit": CoverageRange(start: "2026-01-01", end: "2026-04-12"), "apple": CoverageRange(start: "2026-01-01", end: "2026-04-12")],
            sourceLabels: ["main_bank": "Main Bank", "mufg_debit": "Main Debit", "apple": "Apple"],
            layers: Self.sampleLayers, layerConfig: Self.sampleConfig,
            noticeSourceMatches: ["mufg_debit": ["main_bank"], "apple": ["main_bank"]],
            statementLineRules: ["main_bank": [StatementLineRule(pattern: #"^デビット\d* (\d{6}) (.+)$"#, referenceGroup: 1, merchantGroup: 2, itemSource: "Main Debit")]]
        )
        let cafeTx = BankTransaction(id: "tx-cafe", connectedAccountID: "acc", date: "2026-04-14", amount: 1_200, description: "デビット1 222222 APPLE PARK CAFE")
        let cafeNotice = Notice(messageID: "n-cafe", source: .mufgDebit, kind: .purchase, receivedAt: "2026-04-14T10:00:00+09:00", occurredOn: "2026-04-14", amount: 1_200, merchant: "APPLE PARK CAFE", parser: "mufg_debit/1")
        let appReceipt = Notice(messageID: "n-app-rcpt", source: .apple, kind: .purchase, receivedAt: "2026-04-14T10:05:00+09:00", occurredOn: "2026-04-14", amount: 1_200, merchant: "Photo Pro", reference: "ORD-P1", parser: "apple/1")
        let cafeLayered = BankLayering.build(
            bundle: cafeBundle, bankTransactions: [cafeTx], accountMapping: ["acc": "main_bank"],
            notices: [cafeNotice, appReceipt], categorizer: Categorizer(rules: RuleSet()), config: Self.sampleConfig
        )
        #expect(cafeLayered.matchedPairs.count == 1)
        #expect(cafeLayered.matchedPairs[0].noticeID == "n-cafe")
        #expect(cafeLayered.pendingNoticeIDs == ["n-app-rcpt"])
        #expect(cafeLayered.pendingItems[0].fundingSource == nil)

        // 3. LiveCashSummary keeps isEstimate == true when cashLeft includes an estimated lagging salary.
        let estSalaryTl = [
            TimelineEntry(id: "sal-lag", date: "2026-04-25", item: "Salary", amount: -300_000, payday: true, estimate: true),
            TimelineEntry(id: "sal-next", date: "2026-05-25", item: "Salary", amount: -300_000, payday: true, next: true, estimate: true),
        ]
        let estSalaryPayday = try #require(PaydayView.compute(timeline: estSalaryTl, today: "2026-04-26"))
        let estSalaryLive = try #require(LiveCashSummary.compute(
            accountBalances: [AccountBalance(source: "main_bank", label: "Main Bank", balance: 40_000, asOf: "2026-04-25")],
            sourceLabels: ["main_bank": "Main Bank"],
            bankRows: [], pendingItems: [], payday: estSalaryPayday, today: "2026-04-26"
        ))
        #expect(estSalaryLive.remainingInflowsSum == 300_000)
        #expect(estSalaryLive.isEstimate == true)

        // 4. Zero-baseline metered subscription ("Vendor API (metered)", monthly: 0) still rejects "VENDOR PRO",
        //    and metered entries never absorb fixed subscription-category charges ("VENDOR SUB" / category "Software subscriptions").
        let zeroApiSub = SubscriptionItem(
            entry: SubscriptionEntry(name: "Vendor API (metered)", monthly: 0, via: "Card", status: "Stopped"),
            isOff: true, countsAsSaving: false, displayStatus: "Stopped", tone: .good
        )
        let zeroVendorItems = [
            BudgetItem(date: "2026-04-05", source: "Card", merchant: "VENDOR API", amount: 1_500, group: "Subs", category: "Tools", layer: "Subscriptions"),
            BudgetItem(date: "2026-04-06", source: "Card", merchant: "VENDOR PRO", amount: 3_000, group: "Subs", category: "Tools", layer: "Subscriptions"),
            BudgetItem(date: "2026-04-07", source: "Card", merchant: "VENDOR SUB", amount: 2_500, group: "Subs", category: "Tools", layer: "Subscriptions"),
            BudgetItem(date: "2026-04-08", source: "Card", merchant: "VENDOR", amount: 18_000, group: "Subs", category: "Software subscriptions", layer: "Subscriptions"),
        ]
        let zeroHistory = SubscriptionHistory.compute(
            for: zeroApiSub, allItems: zeroVendorItems, months: ["2026-04"],
            today: "2026-04-14", config: Self.sampleConfig, layers: Self.sampleLayers
        )
        #expect(zeroHistory.matchedItems.map { $0.merchant } == ["VENDOR API"])

        // 5. Future payoff clauses ("paid off in March") do not discard the preceding monthly payment figure.
        #expect(SpendingInsights.extractMonthlyPayment(from: ["Monthly ¥9,000; paid off in March"]) == 9_000)
    }

    @Test("v0.6.9 Round 6: Pre-baked post-asOf deposit dedupe, strict boundary merchant dedupe, Apple token/descriptor boundaries, business-day payday rolling, legacy reminder tombstones, metered vs consumer plan separation, and single-clause payoff")
    func roundSixHardeningRegressions() throws {
        // 1. A post-cutoff deposit already present in `bundle.items` is never double-emitted into `bankItems`,
        //    and when `account.asOf` reflects that snapshot date (`asOfRowAmounts`), `LiveCashSummary` never double-counts it.
        let aheadBundle = DataBundle(
            generatedAt: "2026-04-25T10:00:00+09:00", asOf: "2026-04-24",
            coverage: ["sec_bank": CoverageRange(start: "2026-01-01", end: "2026-04-22")],
            sourceLabels: ["sec_bank": "Second Bank"],
            items: [
                BudgetItem(date: "2026-04-24", source: "Second Bank", merchant: "TRANSFER IN", amount: -10_000, group: "Income", category: "Other"),
            ],
            timeline: [TimelineEntry(date: "2026-05-25", item: "Salary", amount: -300_000, payday: true, next: true)],
            layers: Self.sampleLayers, layerConfig: Self.sampleConfig,
            accountBalances: [
                AccountBalance(source: "sec_bank", label: "Second Bank", balance: 15_000, asOf: "2026-04-24", asOfRowAmounts: [-10_000]),
            ]
        )
        let dupDepositTx = BankTransaction(id: "tx-dep", connectedAccountID: "sec", date: "2026-04-24", amount: -10_000, description: "TRANSFER IN")
        let aheadLayered = BankLayering.build(
            bundle: aheadBundle, bankTransactions: [dupDepositTx], accountMapping: ["sec": "sec_bank"],
            notices: [], categorizer: Categorizer(rules: RuleSet()), config: Self.sampleConfig
        )
        #expect(aheadLayered.bankItems.isEmpty)
        let aheadPayday = try #require(PaydayView.compute(timeline: aheadBundle.timeline, today: "2026-04-25"))
        let aheadCash = try #require(LiveCashSummary.compute(
            accountBalances: aheadBundle.accountBalances!, sourceLabels: aheadBundle.sourceLabels,
            bankRows: aheadLayered.allBankRows, pendingItems: aheadLayered.pendingItems, payday: aheadPayday, today: "2026-04-25"
        ))
        #expect(aheadCash.estimatedBankCash == 15_000)

        // 2. Same-day ¥800 "CAFE" bundle item must NOT swallow Japanese bookstore or "CAFE ROASTERS" notice.
        let cafeDedupeBundle = DataBundle(
            generatedAt: "2026-04-20T10:00:00+09:00", asOf: "2026-04-20",
            coverage: ["mufg_debit": CoverageRange(start: "2026-01-01", end: "2026-04-20")],
            sourceLabels: ["mufg_debit": "Main Debit"],
            items: [
                BudgetItem(date: "2026-04-20", source: "Main Debit", merchant: "CAFE", amount: 800, group: "Food", category: "Cafe", layer: "Day-to-day"),
            ],
            layers: Self.sampleLayers, layerConfig: Self.sampleConfig
        )
        let jpBookNotice = Notice(messageID: "n-jpbook", source: .mufgDebit, kind: .purchase, receivedAt: "2026-04-20T14:00:00+09:00", occurredOn: "2026-04-20", amount: 800, merchant: "書店センター", parser: "mufg_debit/1")
        let cafeRoastNotice = Notice(messageID: "n-roast", source: .mufgDebit, kind: .purchase, receivedAt: "2026-04-20T15:00:00+09:00", occurredOn: "2026-04-20", amount: 800, merchant: "CAFE ROASTERS", parser: "mufg_debit/1")
        let pendingRes = PendingBuilder.build(
            notices: [jpBookNotice, cafeRoastNotice], bundle: cafeDedupeBundle,
            categorizer: Categorizer(rules: RuleSet()), config: Self.sampleConfig
        )
        #expect(pendingRes.items.count == 2)

        // 3. Word-boundary Apple service token ("Airline Arcade" / "Online Quest" must NOT settle "Stream (ACME)" or "Stream (NOVA)"),
        //    and strict Apple descriptors reject lookalike merchant names.
        let streamTl = [
            TimelineEntry(
                id: "rec:stream:2026-04", date: "2026-04-12", item: "Stream (WAVE)", amount: 800,
                match: TimelineMatch(source: "Main Bank", pattern: #"APPLE\.CO|APPLE\.COM/BILL"#, dir: "out", window: [-2, 4], minAmount: 700, maxAmount: 900)
            ),
        ]
        let airlineRow = TimelineReconciler.BankRow(source: "Main Bank", date: "2026-04-12", amount: 800, description: "APPLE.CO", resolvedMerchant: "Heatwave Arcade")
        let onlineRow = TimelineReconciler.BankRow(source: "Main Bank", date: "2026-04-12", amount: 800, description: "APPLE.CO", resolvedMerchant: "Microwave Quest")
        #expect(TimelineReconciler.reconcile(timeline: streamTl, bankRows: [airlineRow])[0].done != true)
        #expect(TimelineReconciler.reconcile(timeline: streamTl, bankRows: [onlineRow])[0].done != true)

        let nonAppleNames = [
            "PINEAPPLE.COM CAFE", "SNAPPLE.COM", "GRAPPLE.CO JP", "PINEAPPLE STORE",
            "HAPPSTORE", "APPLE PAY SHOP", "APPLE.COFFEE", "APPLE BILLBOARD CAFE", "ICLOUD REPAIR SHOP",
        ]
        let nonAppleNotices = nonAppleNames.enumerated().map { idx, merch in
            Notice(messageID: "na-\(idx)", source: .mufgDebit, kind: .purchase, receivedAt: "2026-04-14T10:0\(idx):00+09:00", occurredOn: "2026-04-14", amount: 1_100 + idx, merchant: merch, parser: "mufg_debit/1")
        }
        let matchingReceipts = nonAppleNames.enumerated().map { idx, _ in
            Notice(messageID: "rc-\(idx)", source: .apple, kind: .purchase, receivedAt: "2026-04-14T10:0\(idx):30+09:00", occurredOn: "2026-04-14", amount: 1_100 + idx, merchant: "App \(idx)", reference: "ORD-\(idx)", parser: "apple/1")
        }
        let descBundle = DataBundle(
            generatedAt: "2026-04-14T10:00:00+09:00", asOf: "2026-04-12",
            coverage: ["mufg_debit": CoverageRange(start: "2026-01-01", end: "2026-04-12"), "apple": CoverageRange(start: "2026-01-01", end: "2026-04-12")],
            sourceLabels: ["mufg_debit": "Main Debit", "apple": "Apple"],
            layers: Self.sampleLayers, layerConfig: Self.sampleConfig
        )
        let descPending = PendingBuilder.build(
            notices: nonAppleNotices + matchingReceipts, bundle: descBundle,
            categorizer: Categorizer(rules: RuleSet()), config: Self.sampleConfig
        )
        #expect(descPending.items.count == nonAppleNames.count * 2) // None collapsed onto Apple receipts!

        // 4. Business-day helper rolls Sunday Oct 25, 2026 earlier to Friday Oct 23, 2026.
        #expect(CashFlowForecast.adjustBankBusinessDay("2026-10-25", moveEarlier: true) == "2026-10-23")

        // 5. Legacy ID-less timeline reminder is removed by its `legacy:` tombstone.
        let legacyRem = TimelineEntry(id: nil, date: "2026-04-20", item: "Water Slip", amount: 4_000)
        let legacyTombstone = "legacy:\(BillCheckoff.legacyKey(for: legacyRem))"
        let afterLegacyDel = LocalDataApplier.mergeCustomReminders(timeline: [legacyRem], reminders: [], deletedIDs: [legacyTombstone])
        #expect(afterLegacyDel.isEmpty)

        // 6. Active fixed consumer plan ("Vendor Plus") must NOT absorb metered API credit charges
        //    or suppress stopped-API alerts for the same vendor.
        let consumerSub = SubscriptionEntry(name: "Vendor Plus", monthly: 2_500, via: "Card", status: "Keep")
        let apiStoppedSub = SubscriptionEntry(name: "Vendor API credits", monthly: 5_000, via: "Card", status: "Stopped", stoppedDate: "2026-04-01")
        let apiCharge = BudgetItem(date: "2026-04-15", source: "Card", merchant: "VENDOR", amount: 2_000, group: "Subs", category: "Developer APIs", layer: "Subscriptions")
        let consumerSubItem = SubscriptionItem(entry: consumerSub, isOff: false, countsAsSaving: false, displayStatus: "Keep", tone: .good)
        let consumerHist = SubscriptionHistory.compute(for: consumerSubItem, allItems: [apiCharge], months: ["2026-04"], today: "2026-04-20", config: Self.sampleConfig, layers: Self.sampleLayers)
        #expect(consumerHist.matchedItems.isEmpty)
        let alertBundle = DataBundle(
            generatedAt: "2026-04-20T10:00:00+09:00", asOf: "2026-04-20",
            items: [apiCharge], subs: [consumerSub, apiStoppedSub],
            layers: Self.sampleLayers, layerConfig: Self.sampleConfig
        )
        let alerts = SpendingInsights.detectAlerts(
            bundle: alertBundle, allItems: [apiCharge], notices: [], timeline: [],
            planSummary: PlanSummary.compute(plan: [], planWindow: nil, totalsByMonth: [:], selectedMonth: "2026-04", currentMonth: "2026-04", inProgressMonth: "2026-04"),
            subscriptionSummary: SubscriptionSummary.compute(from: [consumerSub, apiStoppedSub]),
            today: "2026-04-20"
        )
        #expect(alerts.contains(where: { $0.kind == .cancelledSubscriptionCharge }))

        // 7. Single-clause future payoff phrasings preserve the monthly payment figure.
        #expect(SpendingInsights.extractMonthlyPayment(from: ["Monthly ¥9,000 until paid off in March"]) == 9_000)
        #expect(SpendingInsights.extractMonthlyPayment(from: ["Monthly ¥9,000 (paid off by March)"]) == 9_000)
    }

    @Test("v0.6.9 Round 7: Strict BankLayering CAFE vs CAFEBLUE, stale account.asOf dedupe with bank-channel & merchantless rows, manual item non-suppression, Apple timeline descriptor/token boundaries, and appliedPhoneDeletions round-trip")
    func roundSevenHardeningRegressions() throws {
        // 1. BankLayering must NOT swallow a distinct same-day "CAFEBLUE" debit into a covered "CAFE" row
        //    (both on snapshot day with a partial feed and after a stale cutoff).
        let snapCafeBundle = DataBundle(
            generatedAt: "2026-04-20T10:00:00+09:00", asOf: "2026-04-20",
            coverage: ["main_bank": CoverageRange(start: "2026-01-01", end: "2026-04-20")],
            sourceLabels: ["main_bank": "Main"],
            items: [
                BudgetItem(date: "2026-04-20", source: "Main debit", merchant: "CAFE", amount: 800, group: "Food", category: "Cafe", layer: "Day-to-day"),
            ],
            timeline: [TimelineEntry(date: "2026-05-25", item: "Salary", amount: -300_000, payday: true, next: true)],
            layers: Self.sampleLayers, layerConfig: Self.sampleConfig,
            statementLineRules: ["main_bank": [StatementLineRule(pattern: #"^デビット\d* (\d{6}) (.+)$"#, referenceGroup: 1, merchantGroup: 2, itemSource: "Main debit")]],
            accountBalances: [
                AccountBalance(source: "main_bank", label: "Main", balance: 14_000, asOf: "2026-04-20", asOfRowAmounts: [800]),
            ]
        )
        let cafeBlueTx = BankTransaction(id: "tx-cb", connectedAccountID: "acc", date: "2026-04-20", amount: 800, description: "デビット1 777777 CAFEBLUE")
        let snapLayered = BankLayering.build(
            bundle: snapCafeBundle, bankTransactions: [cafeBlueTx], accountMapping: ["acc": "main_bank"],
            notices: [], categorizer: Categorizer(rules: RuleSet()), config: Self.sampleConfig
        )
        #expect(snapLayered.bankItems.count == 1)
        let snapPayday = try #require(PaydayView.compute(timeline: snapCafeBundle.timeline, today: "2026-04-20"))
        let snapCash = try #require(LiveCashSummary.compute(
            accountBalances: snapCafeBundle.accountBalances!, sourceLabels: snapCafeBundle.sourceLabels,
            bankRows: snapLayered.allBankRows, pendingItems: snapLayered.pendingItems, payday: snapPayday, today: "2026-04-20"
        ))
        #expect(snapCash.estimatedBankCash == 13_200)

        let staleCafeBundle = DataBundle(
            generatedAt: "2026-04-21T10:00:00+09:00", asOf: "2026-04-18",
            coverage: ["main_bank": CoverageRange(start: "2026-01-01", end: "2026-04-18")],
            sourceLabels: ["main_bank": "Main"],
            items: [
                BudgetItem(date: "2026-04-20", source: "Main debit", merchant: "CAFE", amount: 800, group: "Food", category: "Cafe", layer: "Day-to-day"),
            ],
            timeline: [TimelineEntry(date: "2026-05-25", item: "Salary", amount: -300_000, payday: true, next: true)],
            layers: Self.sampleLayers, layerConfig: Self.sampleConfig,
            statementLineRules: ["main_bank": [StatementLineRule(pattern: #"^デビット\d* (\d{6}) (.+)$"#, referenceGroup: 1, merchantGroup: 2, itemSource: "Main debit")]],
            accountBalances: [
                AccountBalance(source: "main_bank", label: "Main", balance: 14_000, asOf: "2026-04-18"),
            ]
        )
        let staleLayered = BankLayering.build(
            bundle: staleCafeBundle, bankTransactions: [cafeBlueTx], accountMapping: ["acc": "main_bank"],
            notices: [], categorizer: Categorizer(rules: RuleSet()), config: Self.sampleConfig
        )
        #expect(staleLayered.bankItems.count == 1)
        let staleCash = try #require(LiveCashSummary.compute(
            accountBalances: staleCafeBundle.accountBalances!, sourceLabels: staleCafeBundle.sourceLabels,
            bankRows: staleLayered.allBankRows, pendingItems: staleLayered.pendingItems, payday: snapPayday, today: "2026-04-21"
        ))
        #expect(staleCash.estimatedBankCash == 13_200)

        // 2. Post-cutoff "<Account> bank" source alias and merchantless debit lines already in `bundle.items`
        //    do not emit duplicate `bankItems`, while `isManual: true` rows still emit real bank items,
        //    and `LiveCashSummary` strictly adjusts any confirmed bank row dated after `account.asOf`.
        let mixedBankBundle = DataBundle(
            generatedAt: "2026-04-25T10:00:00+09:00", asOf: "2026-04-24",
            coverage: ["sec_bank": CoverageRange(start: "2026-01-01", end: "2026-04-21")],
            sourceLabels: ["sec_bank": "Second", "sec_debit": "Second debit"],
            items: [
                BudgetItem(date: "2026-04-23", source: "Second debit", merchant: "BOOK SHOP", amount: 1_400, group: "Shopping", category: "Books", layer: "Day-to-day"),
                BudgetItem(date: "2026-04-24", source: "Second bank", merchant: "TRANSFER IN", amount: -10_000, group: "Income", category: "Other"),
                BudgetItem(date: "2026-04-25", source: "Second bank", merchant: "MANUAL ENTRY", amount: 4_300, group: "Food", category: "Cafe", layer: "Day-to-day", isManual: true),
            ],
            timeline: [TimelineEntry(date: "2026-05-25", item: "Salary", amount: -300_000, payday: true, next: true)],
            layers: Self.sampleLayers, layerConfig: Self.sampleConfig,
            statementLineRules: ["sec_bank": [StatementLineRule(pattern: #"^デビット (\d{6})$"#, referenceGroup: 1, itemSource: "Second debit")]],
            accountBalances: [
                AccountBalance(source: "sec_bank", label: "Second", balance: 14_000, asOf: "2026-04-24", debitNoticeSources: ["sec_debit"], asOfRowAmounts: [-10_000]),
            ]
        )
        let secTxs = [
            BankTransaction(id: "tx-s1", connectedAccountID: "s", date: "2026-04-23", amount: 1_400, description: "デビット 123456"),
            BankTransaction(id: "tx-s2", connectedAccountID: "s", date: "2026-04-24", amount: -10_000, description: "TRANSFER IN"),
            BankTransaction(id: "tx-s3", connectedAccountID: "s", date: "2026-04-25", amount: 4_300, description: "MANUAL ENTRY"),
        ]
        let secLayered = BankLayering.build(
            bundle: mixedBankBundle, bankTransactions: secTxs, accountMapping: ["s": "sec_bank"],
            notices: [], categorizer: Categorizer(rules: RuleSet()), config: Self.sampleConfig
        )
        // Apr 23 & Apr 24 confirmed rows are already in `bundle.items`, so only Apr 25 (whose bundle entry is `isManual`) emits in `bankItems`.
        #expect(secLayered.bankItems.count == 1)
        #expect(secLayered.bankItems[0].amount == 4_300)
        let secPayday = try #require(PaydayView.compute(timeline: mixedBankBundle.timeline, today: "2026-04-25"))
        let secCash = try #require(LiveCashSummary.compute(
            accountBalances: mixedBankBundle.accountBalances!, sourceLabels: mixedBankBundle.sourceLabels,
            bankRows: secLayered.allBankRows, pendingItems: secLayered.pendingItems, payday: secPayday, today: "2026-04-25"
        ))
        #expect(secCash.estimatedBankCash == 9_700)

        // 3. Apple-backed timeline matching rejects "PINEAPPLE.COM CAFE" and settles on "WAVE Premium" with "D APPLE.CO".
        let appleTl = [
            TimelineEntry(
                id: "rec:stream:2026-04", date: "2026-04-12", item: "Stream (WAVE)", amount: 800,
                match: TimelineMatch(source: "Main Bank", pattern: #"APPLE\.CO|APPLE\.COM/BILL"#, dir: "out", window: [-2, 4], minAmount: 700, maxAmount: 900)
            ),
        ]
        let pineappleRow = TimelineReconciler.BankRow(source: "Main Bank", date: "2026-04-12", amount: 800, description: "PINEAPPLE.COM CAFE")
        #expect(TimelineReconciler.reconcile(timeline: appleTl, bankRows: [pineappleRow])[0].done != true)
        let wavePremRow = TimelineReconciler.BankRow(source: "Main Bank", date: "2026-04-12", amount: 800, description: "D APPLE.CO", resolvedMerchant: "WAVE Premium")
        #expect(TimelineReconciler.reconcile(timeline: appleTl, bankRows: [wavePremRow])[0].done == true)

        // 4. Synced `appliedBundleDeletions` keeps one surviving duplicate after a single deletion round-trips through PC.
        let dupItem = BudgetItem(date: "2026-04-15", source: "Cash", merchant: "Coffee Shop", amount: 500, group: "Food", category: "Cafe", layer: "Day-to-day")
        let fp = CategoryOverride.transactionFingerprint(for: dupItem)
        let modsWithOneDel = LocalModifications(
            deletedEntryFingerprints: [fp],
            deletedEntryFingerprintCounts: [fp: 1]
        )
        // Before PC rebuild: 2 bundle copies - 1 local deletion = 1 survivor.
        let beforePC = LocalDataApplier.apply(baseItems: [dupItem, dupItem], modifications: modsWithOneDel, config: Self.sampleConfig, layers: Self.sampleLayers)
        #expect(beforePC.allItems.count == 1)
        // After PC rebuild: 1 surviving copy in bundle + appliedBundleDeletions[fp] = 1 -> still 1 survivor.
        let afterPC = LocalDataApplier.apply(baseItems: [dupItem], modifications: modsWithOneDel, config: Self.sampleConfig, layers: Self.sampleLayers, appliedBundleDeletions: [fp: 1])
        #expect(afterPC.allItems.count == 1)
    }

    @Test("v0.6.9 Round 8: Manual item never conceals pending debit notice, stale-asOf snapshot debit emission, 8-char branch suffix separation, and iCloud/APPLE.CO-OP settlement guards")
    func roundEightHardeningRegressions() throws {
        // 1. A phone manual entry (`isManual: true`) in `bundle.items` must NOT conceal a real pending debit notice.
        let manualNoticeBundle = DataBundle(
            generatedAt: "2026-04-20T10:00:00+09:00", asOf: "2026-04-19",
            coverage: ["main_bank": CoverageRange(start: "2026-01-01", end: "2026-04-19"), "mufg_debit": CoverageRange(start: "2026-01-01", end: "2026-04-19")],
            sourceLabels: ["main_bank": "Main", "mufg_debit": "Main debit"],
            items: [
                BudgetItem(date: "2026-04-20", source: "Main debit", merchant: "CORNER SHOP", amount: 4_300, group: "Food", category: "Cafe", layer: "Day-to-day", isManual: true),
            ],
            timeline: [TimelineEntry(date: "2026-05-25", item: "Salary", amount: -300_000, payday: true, next: true)],
            layers: Self.sampleLayers, layerConfig: Self.sampleConfig,
            accountBalances: [
                AccountBalance(source: "main_bank", label: "Main", balance: 20_000, asOf: "2026-04-19", debitNoticeSources: ["mufg_debit"]),
            ]
        )
        let cornerNotice = Notice(
            messageID: "n-corner", source: .mufgDebit, kind: .purchase,
            receivedAt: "2026-04-20T11:00:00+09:00", occurredOn: "2026-04-20",
            amount: 4_300, merchant: "CORNER SHOP", parser: "mufg_debit/1"
        )
        let manualLayered = BankLayering.build(
            bundle: manualNoticeBundle, bankTransactions: [], accountMapping: [:],
            notices: [cornerNotice], categorizer: Categorizer(rules: RuleSet()), config: Self.sampleConfig
        )
        #expect(manualLayered.pendingItems.count == 1)
        let manPayday = try #require(PaydayView.compute(timeline: manualNoticeBundle.timeline, today: "2026-04-20"))
        let manCash = try #require(LiveCashSummary.compute(
            accountBalances: manualNoticeBundle.accountBalances!, sourceLabels: manualNoticeBundle.sourceLabels,
            bankRows: manualLayered.allBankRows, pendingItems: manualLayered.pendingItems, payday: manPayday, today: "2026-04-20"
        ))
        #expect(manCash.estimatedBankCash == 15_700)

        // 2. Snapshot-day distinct debit (`CAFEBLUE`) emits & deducts cash even when `account.asOf < coverage.end`,
        //    and an 8-char prefix (`CAFE1234`) does NOT swallow a distinct branch (`CAFE1234 WEST`).
        let splitSnapBundle = DataBundle(
            generatedAt: "2026-04-24T10:00:00+09:00", asOf: "2026-04-24",
            coverage: ["main_bank": CoverageRange(start: "2026-01-01", end: "2026-04-24")],
            sourceLabels: ["main_bank": "Main"],
            items: [
                BudgetItem(date: "2026-04-20", source: "Main debit", merchant: "CAFE", amount: 800, group: "Food", category: "Cafe", layer: "Day-to-day"),
            ],
            timeline: [TimelineEntry(date: "2026-05-25", item: "Salary", amount: -300_000, payday: true, next: true)],
            layers: Self.sampleLayers, layerConfig: Self.sampleConfig,
            statementLineRules: ["main_bank": [StatementLineRule(pattern: #"^デビット\d* (\d{6}) (.+)$"#, referenceGroup: 1, merchantGroup: 2, itemSource: "Main debit")]],
            accountBalances: [
                AccountBalance(source: "main_bank", label: "Main", balance: 20_000, asOf: "2026-04-20", asOfRowAmounts: [800]),
            ]
        )
        let splitTx = BankTransaction(id: "tx-split", connectedAccountID: "acc", date: "2026-04-20", amount: 800, description: "デビット1 123456 CAFEBLUE")
        let splitLayered = BankLayering.build(
            bundle: splitSnapBundle, bankTransactions: [splitTx], accountMapping: ["acc": "main_bank"],
            notices: [], categorizer: Categorizer(rules: RuleSet()), config: Self.sampleConfig
        )
        #expect(splitLayered.bankItems.count == 1)
        let splitCash = try #require(LiveCashSummary.compute(
            accountBalances: splitSnapBundle.accountBalances!, sourceLabels: splitSnapBundle.sourceLabels,
            bankRows: splitLayered.allBankRows, pendingItems: splitLayered.pendingItems, payday: manPayday, today: "2026-04-24"
        ))
        #expect(splitCash.estimatedBankCash == 19_200)

        let branchSnapBundle = DataBundle(
            generatedAt: "2026-04-20T10:00:00+09:00", asOf: "2026-04-20",
            coverage: ["main_bank": CoverageRange(start: "2026-01-01", end: "2026-04-20")],
            sourceLabels: ["main_bank": "Main"],
            items: [
                BudgetItem(date: "2026-04-20", source: "Main debit", merchant: "CAFE1234", amount: 800, group: "Food", category: "Cafe", layer: "Day-to-day"),
            ],
            timeline: [TimelineEntry(date: "2026-05-25", item: "Salary", amount: -300_000, payday: true, next: true)],
            layers: Self.sampleLayers, layerConfig: Self.sampleConfig,
            statementLineRules: ["main_bank": [StatementLineRule(pattern: #"^デビット\d* (\d{6}) (.+)$"#, referenceGroup: 1, merchantGroup: 2, itemSource: "Main debit")]],
            accountBalances: [
                AccountBalance(source: "main_bank", label: "Main", balance: 20_000, asOf: "2026-04-20", asOfRowAmounts: [800]),
            ]
        )
        let branchTx = BankTransaction(id: "tx-branch", connectedAccountID: "acc", date: "2026-04-20", amount: 800, description: "デビット1 654321 CAFE1234 WEST")
        let branchLayered = BankLayering.build(
            bundle: branchSnapBundle, bankTransactions: [branchTx], accountMapping: ["acc": "main_bank"],
            notices: [], categorizer: Categorizer(rules: RuleSet()), config: Self.sampleConfig
        )
        #expect(branchLayered.bankItems.count == 1)
        let branchCash = try #require(LiveCashSummary.compute(
            accountBalances: branchSnapBundle.accountBalances!, sourceLabels: branchSnapBundle.sourceLabels,
            bankRows: branchLayered.allBankRows, pendingItems: branchLayered.pendingItems, payday: manPayday, today: "2026-04-20"
        ))
        #expect(branchCash.estimatedBankCash == 19_200)

        // 3. `Appleサービス|iCloud` rejects "ICLOUD REPAIR SHOP", and "APPLE.CO-OP" rejects Apple billing settlement.
        let cloudTl = [
            TimelineEntry(
                id: "rec:cloud:2026-04", date: "2026-04-16", item: "Cloud Backup Plan", amount: 1_250,
                match: TimelineMatch(source: "Card", pattern: #"Appleサービス|iCloud"#, dir: "out", window: [-2, 3], minAmount: 1_000, maxAmount: 1_500)
            ),
            TimelineEntry(
                id: "rec:stream:2026-04", date: "2026-04-12", item: "Stream (WAVE)", amount: 800,
                match: TimelineMatch(source: "Main Bank", pattern: #"APPLE\.CO|APPLE\.COM/BILL"#, dir: "out", window: [-2, 4], minAmount: 700, maxAmount: 900)
            ),
        ]
        let icloudRepairRow = TimelineReconciler.BankRow(source: "Card", date: "2026-04-16", amount: 1_250, description: "ICLOUD REPAIR SHOP")
        let coopRow = TimelineReconciler.BankRow(source: "Main Bank", date: "2026-04-12", amount: 800, description: "APPLE.CO-OP", resolvedMerchant: "WAVE Premium")
        let recOut = TimelineReconciler.reconcile(timeline: cloudTl, bankRows: [icloudRepairRow, coopRow])
        #expect(recOut[0].done != true)
        #expect(recOut[1].done != true)
    }

    @Test("v0.6.9 Round 9: Cross-script snapshot debit preserved on partial feed and confirmed post-asOf ledger row still adjusts bank cash")
    func roundNineHardeningRegressions() throws {
        // 1. Cross-script distinct debit ("NEW CAFE") on snapshot date must NOT be swallowed by covered "旧店".
        let crossScriptBundle = DataBundle(
            generatedAt: "2026-04-24T10:00:00+09:00", asOf: "2026-04-24",
            coverage: ["main_bank": CoverageRange(start: "2026-01-01", end: "2026-04-24")],
            sourceLabels: ["main_bank": "Main"],
            items: [
                BudgetItem(date: "2026-04-20", source: "Main debit", merchant: "旧店", amount: 800, group: "Food", category: "Cafe", layer: "Day-to-day"),
            ],
            timeline: [TimelineEntry(date: "2026-05-25", item: "Salary", amount: -300_000, payday: true, next: true)],
            layers: Self.sampleLayers, layerConfig: Self.sampleConfig,
            statementLineRules: ["main_bank": [StatementLineRule(pattern: #"^デビット\d* (\d{6}) (.+)$"#, referenceGroup: 1, merchantGroup: 2, itemSource: "Main debit")]],
            accountBalances: [
                AccountBalance(source: "main_bank", label: "Main", balance: 20_000, asOf: "2026-04-20", asOfRowAmounts: [800]),
            ]
        )
        let newCafeTx = BankTransaction(id: "tx-nc", connectedAccountID: "acc", date: "2026-04-20", amount: 800, description: "デビット1 222222 NEW CAFE")
        let crossLayered = BankLayering.build(
            bundle: crossScriptBundle, bankTransactions: [newCafeTx], accountMapping: ["acc": "main_bank"],
            notices: [], categorizer: Categorizer(rules: RuleSet()), config: Self.sampleConfig
        )
        #expect(crossLayered.bankItems.count == 1)
        let payday = try #require(PaydayView.compute(timeline: crossScriptBundle.timeline, today: "2026-04-24"))
        let crossCash = try #require(LiveCashSummary.compute(
            accountBalances: crossScriptBundle.accountBalances!, sourceLabels: crossScriptBundle.sourceLabels,
            bankRows: crossLayered.allBankRows, pendingItems: crossLayered.pendingItems, payday: payday, today: "2026-04-24"
        ))
        #expect(crossCash.estimatedBankCash == 19_200)

        // 2. A confirmed ledger row dated strictly after `account.asOf` prevents duplicate `bankItems`
        //    without suppressing the valid bank-cash deduction from the older balance snapshot.
        let postAsOfBundle = DataBundle(
            generatedAt: "2026-04-24T10:00:00+09:00", asOf: "2026-04-23",
            coverage: ["main_bank": CoverageRange(start: "2026-01-01", end: "2026-04-20")],
            sourceLabels: ["main_bank": "Main"],
            items: [
                BudgetItem(date: "2026-04-23", source: "Main debit", merchant: "BOOK SHOP", amount: 800, group: "Shopping", category: "Books", layer: "Day-to-day"),
            ],
            timeline: [TimelineEntry(date: "2026-05-25", item: "Salary", amount: -300_000, payday: true, next: true)],
            layers: Self.sampleLayers, layerConfig: Self.sampleConfig,
            statementLineRules: ["main_bank": [StatementLineRule(pattern: #"^デビット\d* (\d{6}) (.+)$"#, referenceGroup: 1, merchantGroup: 2, itemSource: "Main debit")]],
            accountBalances: [
                AccountBalance(source: "main_bank", label: "Main", balance: 20_000, asOf: "2026-04-20"),
            ]
        )
        let bookTx = BankTransaction(id: "tx-bk", connectedAccountID: "acc", date: "2026-04-23", amount: 800, description: "デビット1 333333 BOOK SHOP")
        let postAsOfLayered = BankLayering.build(
            bundle: postAsOfBundle, bankTransactions: [bookTx], accountMapping: ["acc": "main_bank"],
            notices: [], categorizer: Categorizer(rules: RuleSet()), config: Self.sampleConfig
        )
        #expect(postAsOfLayered.bankItems.isEmpty)
        let postAsOfCash = try #require(LiveCashSummary.compute(
            accountBalances: postAsOfBundle.accountBalances!, sourceLabels: postAsOfBundle.sourceLabels,
            bankRows: postAsOfLayered.allBankRows, pendingItems: postAsOfLayered.pendingItems, payday: payday, today: "2026-04-24"
        ))
        #expect(postAsOfCash.estimatedBankCash == 19_200)
    }

    @Test("v0.6.9 Round 10: Annotated CAFEBLUE never swallows CAFE, unbalanced '(' in annotated rent matches snapshot row, and approval-less debit refunds reconcile cleanly")
    func roundTenHardeningRegressions() throws {
        let paydayTimeline = [TimelineEntry(date: "2026-05-25", item: "Salary", amount: -300_000, payday: true, next: true)]
        let bankRules: [String: [StatementLineRule]] = [
            "main_bank": [
                StatementLineRule(pattern: #"^デビット\d* (\d{6}) (.+)$"#, referenceGroup: 1, merchantGroup: 2, itemSource: "Main debit"),
                StatementLineRule(pattern: #"^デビット\d* (.+)$"#, merchantGroup: 1, itemSource: "Main debit"),
            ],
        ]

        // 1. Covered `"CAFEBLUE (card receipt)"` must NOT swallow a distinct same-day `"CAFE"` debit.
        let annotBundle = DataBundle(
            generatedAt: "2026-04-20T10:00:00+09:00", asOf: "2026-04-20",
            coverage: ["main_bank": CoverageRange(start: "2026-01-01", end: "2026-04-20")],
            sourceLabels: ["main_bank": "Main"],
            items: [
                BudgetItem(date: "2026-04-20", source: "Main debit", merchant: "CAFEBLUE (card receipt)", amount: 800, group: "Food", category: "Cafe", layer: "Day-to-day"),
            ],
            timeline: paydayTimeline, layers: Self.sampleLayers, layerConfig: Self.sampleConfig,
            statementLineRules: bankRules,
            accountBalances: [
                AccountBalance(source: "main_bank", label: "Main", balance: 20_000, asOf: "2026-04-20", asOfRowAmounts: [800]),
            ]
        )
        let cafeTx = BankTransaction(id: "tx-cafe", connectedAccountID: "acc", date: "2026-04-20", amount: 800, description: "デビット1 555555 CAFE")
        let annotLayered = BankLayering.build(
            bundle: annotBundle, bankTransactions: [cafeTx], accountMapping: ["acc": "main_bank"],
            notices: [], categorizer: Categorizer(rules: RuleSet()), config: Self.sampleConfig
        )
        #expect(annotLayered.bankItems.count == 1)
        let payday = try #require(PaydayView.compute(timeline: paydayTimeline, today: "2026-04-20"))
        let annotCash = try #require(LiveCashSummary.compute(
            accountBalances: annotBundle.accountBalances!, sourceLabels: annotBundle.sourceLabels,
            bankRows: annotLayered.allBankRows, pendingItems: annotLayered.pendingItems, payday: payday, today: "2026-04-20"
        ))
        #expect(annotCash.estimatedBankCash == 19_200)

        // 2. Annotated rent item whose embedded verbatim bank text contains unbalanced `(` OR balanced `(...)`
        //    must match the covered snapshot-day bank row (never double-counted), while an inner `(` fragment
        //    such as `"CO"` is never mistakenly swallowed as a match.
        let unbalancedBankText = "口座振替4 SAMPLE(HOUSING(CO"
        let balancedBankText = "Transfer Cafe (MAIN)"
        let rentBundle = DataBundle(
            generatedAt: "2026-04-27T10:00:00+09:00", asOf: "2026-04-27",
            coverage: ["main_bank": CoverageRange(start: "2026-01-01", end: "2026-04-27")],
            sourceLabels: ["main_bank": "Main"],
            items: [
                BudgetItem(date: "2026-04-27", source: "Main bank", merchant: "Rent (May 2026 lease · \(unbalancedBankText))", amount: 75_000, group: "Fixed bills", category: "Rent", layer: "Fixed"),
                BudgetItem(date: "2026-04-27", source: "Main bank", merchant: "Rent (May 2026 parking · \(balancedBankText))", amount: 800, group: "Fixed bills", category: "Rent", layer: "Fixed"),
                BudgetItem(date: "2026-04-27", source: "Main debit", merchant: "BOOKSTORE", amount: -2_400, group: "Shopping", category: "Books", layer: "Day-to-day"),
            ],
            timeline: paydayTimeline, layers: Self.sampleLayers, layerConfig: Self.sampleConfig,
            statementLineRules: bankRules,
            accountBalances: [
                AccountBalance(source: "main_bank", label: "Main", balance: 100_000, asOf: "2026-04-27", asOfRowAmounts: [75_000, 800, -2_400]),
            ]
        )
        let rentAndRefundTxs = [
            BankTransaction(id: "tx-rent", connectedAccountID: "acc", date: "2026-04-27", amount: 75_000, description: unbalancedBankText),
            BankTransaction(id: "tx-bal", connectedAccountID: "acc", date: "2026-04-27", amount: 800, description: balancedBankText),
            BankTransaction(id: "tx-ref", connectedAccountID: "acc", date: "2026-04-27", amount: -2_400, description: "デビット3 BOOKSTORE"),
        ]
        let rentLayered = BankLayering.build(
            bundle: rentBundle, bankTransactions: rentAndRefundTxs, accountMapping: ["acc": "main_bank"],
            notices: [], categorizer: Categorizer(rules: RuleSet()), config: Self.sampleConfig
        )
        #expect(rentLayered.bankItems.isEmpty)
        let rentPayday = try #require(PaydayView.compute(timeline: paydayTimeline, today: "2026-04-27"))
        let rentCash = try #require(LiveCashSummary.compute(
            accountBalances: rentBundle.accountBalances!, sourceLabels: rentBundle.sourceLabels,
            bankRows: rentLayered.allBankRows, pendingItems: rentLayered.pendingItems, payday: rentPayday, today: "2026-04-27"
        ))
        #expect(rentCash.estimatedBankCash == 100_000)

        // Inner `(` fragment ("CO") must NOT match `"Rent (May 2026 lease · 口座振替4 SAMPLE(HOUSING(CO)"` on a partial feed.
        let innerFragTx = BankTransaction(id: "tx-frag", connectedAccountID: "acc", date: "2026-04-27", amount: 75_000, description: "CO")
        let innerFragLayered = BankLayering.build(
            bundle: rentBundle, bankTransactions: [innerFragTx], accountMapping: ["acc": "main_bank"],
            notices: [], categorizer: Categorizer(rules: RuleSet()), config: Self.sampleConfig
        )
        #expect(innerFragLayered.bankItems.count == 1)

        // 3. Sol R12 H1 + H2 + Opus R12 L1 regressions:
        //    - Unnamed debit with approval 123456 never suppresses approval 654321 (snapshot OR post-cutoff),
        //      and when both approvals are present, 654321 (never 123456) is emitted as new.
        //    - Embedded bank text containing `·` (`UNIT · CO · MAIN`) never swallows a distinct `CO` debit.
        //    - Second trailing note (`(...) (note)`), padded whitespace, full-width `（）`, and trailing ` (CO`
        //      still match their exact embedded bank text cleanly.
        let docRules: [String: [StatementLineRule]] = [
            "sec_bank": [StatementLineRule(pattern: #"^デビット (\d{6})$"#, referenceGroup: 1, itemSource: "Second debit")],
            "main_bank": bankRules["main_bank"]!,
        ]
        let r12Bundle = DataBundle(
            generatedAt: "2026-04-27T10:00:00+09:00", asOf: "2026-04-27",
            coverage: [
                "sec_bank": CoverageRange(start: "2026-01-01", end: "2026-04-20"),
                "main_bank": CoverageRange(start: "2026-01-01", end: "2026-04-27"),
            ],
            sourceLabels: ["sec_bank": "Second", "main_bank": "Main"],
            items: [
                BudgetItem(date: "2026-04-20", source: "Second debit", merchant: "Second debit 123456 (no name yet)", amount: 800, group: "Food", category: "Cafe", layer: "Day-to-day"),
                BudgetItem(date: "2026-04-22", source: "Second debit", merchant: "Second debit 123456 (no name yet)", amount: 800, group: "Food", category: "Cafe", layer: "Day-to-day"),
                BudgetItem(date: "2026-04-27", source: "Main bank", merchant: "Rent (May lease · UNIT · CO · MAIN)", amount: 900, group: "Fixed bills", category: "Rent", layer: "Fixed"),
                BudgetItem(date: "2026-04-27", source: "Main bank", merchant: "  Rent （May parking · Transfer Cafe (MAIN)） (confirmed)  ", amount: 1_100, group: "Fixed bills", category: "Rent", layer: "Fixed"),
                BudgetItem(date: "2026-04-27", source: "Main bank", merchant: "Rent (May fee · SAMPLE (CO)", amount: 1_300, group: "Fixed bills", category: "Rent", layer: "Fixed"),
            ],
            timeline: paydayTimeline, layers: Self.sampleLayers, layerConfig: Self.sampleConfig,
            statementLineRules: docRules,
            accountBalances: [
                AccountBalance(source: "sec_bank", label: "Second", balance: 20_000, asOf: "2026-04-20", asOfRowAmounts: [800]),
                AccountBalance(source: "main_bank", label: "Main", balance: 50_000, asOf: "2026-04-27", asOfRowAmounts: [900, 1_100, 1_300]),
            ]
        )
        // Snapshot partial feed with ONLY 654321 + post-cutoff 654321 -> BOTH emitted and deduct cash!
        let r12Partial = BankLayering.build(
            bundle: r12Bundle,
            bankTransactions: [
                BankTransaction(id: "tx-s654", connectedAccountID: "s", date: "2026-04-20", amount: 800, description: "デビット 654321"),
                BankTransaction(id: "tx-p654", connectedAccountID: "s", date: "2026-04-22", amount: 800, description: "デビット 654321"),
                BankTransaction(id: "tx-co", connectedAccountID: "m", date: "2026-04-27", amount: 900, description: "CO"),
                BankTransaction(id: "tx-park", connectedAccountID: "m", date: "2026-04-27", amount: 1_100, description: "Transfer Cafe (MAIN)"),
                BankTransaction(id: "tx-sco", connectedAccountID: "m", date: "2026-04-27", amount: 1_300, description: "SAMPLE (CO"),
            ],
            accountMapping: ["s": "sec_bank", "m": "main_bank"],
            notices: [], categorizer: Categorizer(rules: RuleSet()), config: Self.sampleConfig
        )
        #expect(Set(r12Partial.bankTransactionIDs) == Set(["tx-s654", "tx-p654", "tx-co"]))
        // Snapshot full feed with BOTH 654321 (sorted first) and 123456 -> ONLY 654321 emitted!
        let r12Both = BankLayering.build(
            bundle: r12Bundle,
            bankTransactions: [
                BankTransaction(id: "tx-a-654", connectedAccountID: "s", date: "2026-04-20", amount: 800, description: "デビット 654321"),
                BankTransaction(id: "tx-z-123", connectedAccountID: "s", date: "2026-04-20", amount: 800, description: "デビット 123456"),
            ],
            accountMapping: ["s": "sec_bank"],
            notices: [], categorizer: Categorizer(rules: RuleSet()), config: Self.sampleConfig
        )
        #expect(r12Both.bankTransactionIDs == ["tx-a-654"])

        // 4. Round 13 regressions (Sol R13 H1/H2/M1 + Opus R13 M1/M2/L3):
        //    - Enriched named debit carrying `reference: "123456"` still prevents `654321` from collapsing
        //      (both in BankLayering snapshot/post-cutoff AND for MUFG same-shop same-amount repeats).
        //    - Merchantless pending notice for `654321` is NOT discarded against a saved `123456` item in PendingBuilder.
        //    - Secondary `(confirmed · CO)` note never swallows a separate `CO` debit, and `"Transfer Cafe (WEST)"`
        //      never collapses onto `"Transfer Cafe"` inside a Rent annotation.
        let r13Bundle = DataBundle(
            generatedAt: "2026-04-27T10:00:00+09:00", asOf: "2026-04-27",
            coverage: [
                "sec_bank": CoverageRange(start: "2026-01-01", end: "2026-04-20"),
                "docomo_debit": CoverageRange(start: "2026-01-01", end: "2026-04-20"),
                "main_bank": CoverageRange(start: "2026-01-01", end: "2026-04-27"),
            ],
            sourceLabels: ["sec_bank": "Second", "docomo_debit": "Second debit", "main_bank": "Main"],
            items: [
                BudgetItem(date: "2026-04-20", source: "Second debit", merchant: "SHOP A", amount: 800, group: "Food", category: "Cafe", layer: "Day-to-day", reference: "123456"),
                BudgetItem(date: "2026-04-27", source: "Main debit", merchant: "SHOP A", amount: 150, group: "Food", category: "Cafe", layer: "Day-to-day", reference: "111111"),
                BudgetItem(date: "2026-04-27", source: "Main bank", merchant: "Rent (May lease · Transfer Cafe) (confirmed · CO)", amount: 900, group: "Fixed bills", category: "Rent", layer: "Fixed"),
                BudgetItem(date: "2026-04-27", source: "Main bank", merchant: "Rent（May fee · SAMPLE (CO）", amount: 1_300, group: "Fixed bills", category: "Rent", layer: "Fixed"),
            ],
            timeline: paydayTimeline, layers: Self.sampleLayers, layerConfig: Self.sampleConfig,
            statementLineRules: docRules,
            accountBalances: [
                AccountBalance(source: "sec_bank", label: "Second", balance: 20_000, asOf: "2026-04-20", debitNoticeSources: ["docomo_debit"], asOfRowAmounts: [800]),
                AccountBalance(source: "main_bank", label: "Main", balance: 50_000, asOf: "2026-04-27", asOfRowAmounts: [150, 900, 1_300]),
            ]
        )
        // Enriched Docomo debit (123456) + partial feed 654321 + MUFG repeat 222222 sorting BEFORE 111111 + secondary note CO + Transfer Cafe (WEST)
        let r13Layered = BankLayering.build(
            bundle: r13Bundle,
            bankTransactions: [
                BankTransaction(id: "tx-d654", connectedAccountID: "s", date: "2026-04-20", amount: 800, description: "デビット 654321"),
                BankTransaction(id: "tx-a-m222", connectedAccountID: "m", date: "2026-04-27", amount: 150, description: "デビット1 222222 SHOP A"),
                BankTransaction(id: "tx-z-m111", connectedAccountID: "m", date: "2026-04-27", amount: 150, description: "デビット1 111111 SHOP A"),
                BankTransaction(id: "tx-co2", connectedAccountID: "m", date: "2026-04-27", amount: 900, description: "CO"),
                BankTransaction(id: "tx-west", connectedAccountID: "m", date: "2026-04-27", amount: 900, description: "Transfer Cafe (WEST)"),
                BankTransaction(id: "tx-nospace", connectedAccountID: "m", date: "2026-04-27", amount: 1_300, description: "SAMPLE (CO"),
            ],
            accountMapping: ["s": "sec_bank", "m": "main_bank"],
            notices: [], categorizer: Categorizer(rules: RuleSet()), config: Self.sampleConfig
        )
        #expect(Set(r13Layered.bankTransactionIDs) == Set(["tx-d654", "tx-a-m222", "tx-co2", "tx-west"]))
        // Merchantless pending notice for 654321 must NOT be discarded against covered 123456 item!
        let n654 = Notice(messageID: "n-654", source: .docomoDebit, kind: .purchase, receivedAt: "2026-04-20T15:00:00+09:00", occurredOn: "2026-04-20", amount: 800, merchant: nil, reference: "654321", parser: "docomo_debit/1")
        let r13Pending = PendingBuilder.build(notices: [n654], bundle: r13Bundle, categorizer: Categorizer(rules: RuleSet()), config: Self.sampleConfig)
        #expect(r13Pending.items.count == 1)
    }
}
