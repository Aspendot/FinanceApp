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
}
