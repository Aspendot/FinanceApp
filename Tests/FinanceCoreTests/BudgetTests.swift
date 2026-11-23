import Foundation
import Testing
@testable import FinanceCore

// Invented bundles, rules and timelines.

private func decodeBundle(_ json: String) throws -> DataBundle {
    try DataBundle.decode(from: Data(json.utf8))
}

@Suite("DataBundle")
struct DataBundleTests {
    @Test func decodesMinimalBundleAndIgnoresUnknownKeys() throws {
        let json = """
        {
          "format": "finance-bundle/1",
          "generatedAt": "2026-02-01T09:00:00+09:00",
          "asOf": "2026-02-01",
          "unknownTopLevel": { "ignored": true }
        }
        """
        let bundle = try decodeBundle(json)
        #expect(bundle.format == "finance-bundle/1")
        #expect(bundle.generatedAt == "2026-02-01T09:00:00+09:00")
        #expect(bundle.asOf == "2026-02-01")
        #expect(bundle.coverage.isEmpty)
        #expect(bundle.sourceLabels.isEmpty)
        #expect(bundle.items.isEmpty)
        #expect(bundle.timeline.isEmpty)
        #expect(bundle.debts.isEmpty)
        #expect(bundle.subs.isEmpty)
        #expect(bundle.plan.isEmpty)
        #expect(bundle.notes == nil)
        #expect(bundle.afterNote == nil)
        #expect(bundle.planWindow == nil)
        #expect(bundle.layers.isEmpty)
        #expect(bundle.layerConfig == LayerConfig())
        #expect(bundle.rules == RuleSet())
    }

    @Test func decodesFullBundle() throws {
        let json = """
        {
          "format": "finance-bundle/1",
          "generatedAt": "2026-02-01T09:00:00+09:00",
          "asOf": "2026-02-01",
          "coverage": {
            "mufg_debit": { "start": "2026-01-01", "end": "2026-01-31" }
          },
          "sourceLabels": {
            "mufg_debit": "Bank Card"
          },
          "items": [
            {
              "date": "2026-01-10",
              "source": "Bank Card",
              "merchant": "SAMPLE MART",
              "amount": 2000,
              "group": "Living",
              "category": "Groceries",
              "layer": "Day-to-day",
              "extraField": 123
            }
          ],
          "timeline": [
            {
              "date": "2026-01-25",
              "item": "Monthly salary",
              "amount": -250000,
              "note": "after tax",
              "payday": true,
              "done": true,
              "next": false,
              "borrowed": false,
              "estimate": false,
              "event": false,
              "label": "Payday"
            },
            {
              "date": "2026-02-25",
              "item": "Next salary",
              "amount": -250000,
              "payday": true,
              "next": true
            }
          ],
          "debts": [
            {
              "name": "Sample Card",
              "balance": 50000,
              "limit": 200000,
              "lines": ["Monthly 10,000"]
            }
          ],
          "subs": [
            {
              "name": "Sample Cloud",
              "monthly": 1000,
              "via": "Bank Card",
              "status": "active"
            }
          ],
          "plan": [
            {
              "category": "Groceries",
              "now": 35000,
              "target": 30000,
              "status": "over",
              "note": "watch snacks"
            }
          ],
          "notes": ["Check phone bill"],
          "afterNote": "Review next month",
          "planWindow": ["2026-01", "2026-02"],
          "layers": [
            { "key": "Rent", "color": "#111111" },
            { "key": "Bills & taxes", "color": "#222222" },
            { "key": "Subscriptions", "color": "#333333" },
            { "key": "Day-to-day", "color": "#444444" }
          ],
          "layerConfig": {
            "notSpendingGroups": ["Income", "Transfers"],
            "rentCategories": ["Rent"],
            "billGroups": ["Bills"],
            "subscriptionGroups": ["Subscriptions"],
            "subscriptionCategories": ["Phone bill"],
            "incomeGroup": "Income",
            "peopleGroup": "People",
            "debtGroup": "Debt"
          },
          "rules": {
            "rules": [
              { "pattern": "sample mart", "group": "Living", "category": "Groceries" }
            ],
            "amountRules": [
              {
                "whenCategory": "Groceries",
                "merchantPattern": "sample mart",
                "minAmount": 10000,
                "maxAmount": 50000,
                "fromDate": "2026-01-01",
                "group": "Living",
                "category": "Bulk groceries"
              }
            ],
            "learned": {
              "samplecafe": { "group": "Living", "category": "Coffee" }
            }
          }
        }
        """
        let bundle = try decodeBundle(json)
        #expect(bundle.coverage["mufg_debit"] == CoverageRange(start: "2026-01-01", end: "2026-01-31"))
        #expect(bundle.sourceLabels["mufg_debit"] == "Bank Card")
        #expect(bundle.items.count == 1)
        #expect(bundle.items[0].isPending == false)
        #expect(bundle.items[0].layer == "Day-to-day")
        #expect(bundle.timeline.count == 2)
        #expect(bundle.timeline[0].label == "Payday")
        #expect(bundle.timeline[0].done == true)
        #expect(bundle.debts == [DebtEntry(name: "Sample Card", balance: 50000, limit: 200000, lines: ["Monthly 10,000"])])
        #expect(bundle.subs == [SubscriptionEntry(name: "Sample Cloud", monthly: 1000, via: "Bank Card", status: "active")])
        #expect(bundle.plan == [PlanEntry(category: "Groceries", now: 35000, target: 30000, status: "over", note: "watch snacks")])
        #expect(bundle.notes == ["Check phone bill"])
        #expect(bundle.afterNote == "Review next month")
        #expect(bundle.planWindow == ["2026-01", "2026-02"])
        #expect(bundle.layers.count == 4)
        #expect(bundle.layerConfig.incomeGroup == "Income")
        #expect(bundle.layerConfig.peopleGroup == "People")
        #expect(bundle.layerConfig.debtGroup == "Debt")
        #expect(bundle.rules.rules.count == 1)
        #expect(bundle.rules.amountRules.count == 1)
        #expect(bundle.rules.learned["samplecafe"] == CategoryPair(group: "Living", category: "Coffee"))
    }

    @Test func rejectsUnsupportedFormatWithPlainEnglishError() {
        let json = """
        {
          "format": "finance-bundle/99",
          "generatedAt": "2026-02-01T09:00:00+09:00",
          "asOf": "2026-02-01"
        }
        """
        do {
            _ = try decodeBundle(json)
            Issue.record("Expected unsupportedFormat error")
        } catch let error as DataBundleError {
            #expect(error == .unsupportedFormat("finance-bundle/99"))
            let message = error.localizedDescription
            #expect(message.contains("finance-bundle/99"))
            #expect(message.contains("finance-bundle/1"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

@Suite("Categorizer")
struct CategorizerTests {
    @Test func recordsInvalidRegexIndexesWithoutCrashing() throws {
        let json = """
        {
          "format": "finance-bundle/1",
          "generatedAt": "2026-02-01T00:00:00+09:00",
          "asOf": "2026-02-01",
          "rules": {
            "rules": [
              { "pattern": "[unclosed", "group": "Broken", "category": "Bad" },
              { "pattern": "sample mart", "group": "Living", "category": "Groceries" },
              { "pattern": "(also broken", "group": "Broken", "category": "Bad2" }
            ],
            "amountRules": [
              { "merchantPattern": "[bad", "minAmount": 100, "group": "Broken", "category": "Never" },
              { "whenCategory": "Groceries", "minAmount": 5000, "group": "Living", "category": "Bulk groceries" }
            ],
            "learned": {}
          }
        }
        """
        let bundle = try decodeBundle(json)
        let categorizer = Categorizer(rules: bundle.rules)
        #expect(categorizer.invalidRuleIndexes == [0, 2])
        #expect(categorizer.invalidAmountRuleIndexes == [0])

        let small = categorizer.categorize(merchant: "SAMPLE MART", amount: 1000, date: "2026-01-15")
        #expect(small == ("Living", "Groceries"))

        let large = categorizer.categorize(merchant: "SAMPLE MART", amount: 6000, date: "2026-01-15")
        #expect(large == ("Living", "Bulk groceries"))

        let unknown = categorizer.categorize(merchant: "UNKNOWN SHOP", amount: 500, date: "2026-01-15")
        #expect(unknown == ("Other", "Uncategorized"))
    }

    @Test func learnedBeatsRulesAndUsesTextFold() throws {
        let json = """
        {
          "format": "finance-bundle/1",
          "generatedAt": "2026-02-01T00:00:00+09:00",
          "asOf": "2026-02-01",
          "rules": {
            "rules": [
              { "pattern": "ｻﾝﾌﾟﾙ|サンプル", "group": "Living", "category": "Groceries" }
            ],
            "amountRules": [],
            "learned": {
              "サンプル商店": { "group": "Living", "category": "Snacks" }
            }
          }
        }
        """
        let bundle = try decodeBundle(json)
        let categorizer = Categorizer(rules: bundle.rules)

        // Half-width kana with spaces folds to the learned key.
        let hit = categorizer.categorize(merchant: "ｻﾝﾌﾟﾙ 商店", amount: 500, date: "2026-01-15")
        #expect(hit == ("Living", "Snacks"))

        // Different merchant falls back to regex rules.
        let fromRule = categorizer.categorize(merchant: "サンプル市場", amount: 1200, date: "2026-01-15")
        #expect(fromRule == ("Living", "Groceries"))
    }

    @Test func amountRuleWithMerchantPatternBeatsLearnedUsingRulesBase() throws {
        let json = """
        {
          "format": "finance-bundle/1",
          "generatedAt": "2026-02-01T00:00:00+09:00",
          "asOf": "2026-02-01",
          "rules": {
            "rules": [
              { "pattern": "sample mart", "group": "Living", "category": "Groceries" }
            ],
            "amountRules": [
              {
                "whenCategory": "Groceries",
                "minAmount": 5000,
                "group": "Living",
                "category": "Plain bulk"
              },
              {
                "whenCategory": "Groceries",
                "merchantPattern": "sample mart",
                "minAmount": 5000,
                "maxAmount": 20000,
                "fromDate": "2026-01-15",
                "group": "Living",
                "category": "Monthly stockup"
              }
            ],
            "learned": {
              "samplemart": { "group": "Living", "category": "Snacks" }
            }
          }
        }
        """
        let bundle = try decodeBundle(json)
        let categorizer = Categorizer(rules: bundle.rules)

        // Below minAmount: learned wins.
        #expect(categorizer.categorize(merchant: "SAMPLE MART", amount: 1000, date: "2026-01-20") == ("Living", "Snacks"))

        // Before fromDate: first amountRule does not match learned base "Snacks", second fails fromDate.
        #expect(categorizer.categorize(merchant: "SAMPLE MART", amount: 8000, date: "2026-01-10") == ("Living", "Snacks"))

        // Above maxAmount: second amountRule does not match.
        #expect(categorizer.categorize(merchant: "SAMPLE MART", amount: 30000, date: "2026-01-20") == ("Living", "Snacks"))

        // Inside range and on/after fromDate: merchantPattern rule checks whenCategory against rules base "Groceries" and beats learned.
        #expect(categorizer.categorize(merchant: "SAMPLE MART", amount: 8000, date: "2026-01-15") == ("Living", "Monthly stockup"))
    }
}

@Suite("Layers and MonthTotals")
struct LayerAndMonthTotalsTests {
    @Test func layerEdgesAndCustomLayerOrder() throws {
        let json = """
        {
          "format": "finance-bundle/1",
          "generatedAt": "2026-02-01T00:00:00+09:00",
          "asOf": "2026-02-01",
          "layers": [
            { "key": "Housing", "color": "#111111" },
            { "key": "Utilities", "color": "#222222" },
            { "key": "Recurring", "color": "#333333" },
            { "key": "Daily", "color": "#444444" }
          ],
          "layerConfig": {
            "notSpendingGroups": ["Income", "Transfers"],
            "rentCategories": ["Rent"],
            "billGroups": ["Bills"],
            "subscriptionGroups": ["Subs"],
            "subscriptionCategories": ["Phone bill"]
          }
        }
        """
        let bundle = try decodeBundle(json)
        let config = bundle.layerConfig

        func item(group: String, category: String) -> BudgetItem {
            BudgetItem(date: "2026-01-10", source: "Card", merchant: "SAMPLE", amount: 1000, group: group, category: category)
        }

        // Default keys when layers array is omitted.
        #expect(config.layer(for: item(group: "Income", category: "Rent")) == nil)
        #expect(config.layer(for: item(group: "Bills", category: "Rent")) == "Rent")
        #expect(config.layer(for: item(group: "Bills", category: "Electricity")) == "Bills & taxes")
        #expect(config.layer(for: item(group: "Subs", category: "Streaming")) == "Subscriptions")
        #expect(config.layer(for: item(group: "Living", category: "Phone bill")) == "Subscriptions")
        #expect(config.layer(for: item(group: "Living", category: "Groceries")) == "Day-to-day")

        // Custom keys read in order from bundle.layers.
        #expect(bundle.layer(for: item(group: "Transfers", category: "Move")) == nil)
        #expect(bundle.layer(for: item(group: "Living", category: "Rent")) == "Housing")
        #expect(bundle.layer(for: item(group: "Bills", category: "Electricity")) == "Utilities")
        #expect(bundle.layer(for: item(group: "Living", category: "Phone bill")) == "Recurring")
        #expect(bundle.layer(for: item(group: "Living", category: "Groceries")) == "Daily")
    }

    @Test func monthTotalsWithRefundsAndNonSpendingBuckets() throws {
        let json = """
        {
          "format": "finance-bundle/1",
          "generatedAt": "2026-02-01T00:00:00+09:00",
          "asOf": "2026-02-01",
          "items": [
            { "date": "2026-01-05", "source": "Bank", "merchant": "NORTH APARTMENTS", "amount": 80000, "group": "Housing", "category": "Rent" },
            { "date": "2026-01-10", "source": "Card", "merchant": "SAMPLE MART", "amount": 4000, "group": "Living", "category": "Groceries" },
            { "date": "2026-01-12", "source": "Card", "merchant": "SAMPLE MART", "amount": 3000, "group": "Living", "category": "Groceries" },
            { "date": "2026-01-14", "source": "Card", "merchant": "SAMPLE MART", "amount": -1000, "group": "Living", "category": "Groceries" },
            { "date": "2026-01-18", "source": "Card", "merchant": "METRO TELECOM", "amount": 5000, "group": "Living", "category": "Phone bill" },
            { "date": "2026-01-20", "source": "Bank", "merchant": "SAMPLE LOAN", "amount": 20000, "group": "Debt", "category": "Loan payment" },
            { "date": "2026-01-21", "source": "Bank", "merchant": "FAMILY", "amount": 10000, "group": "People", "category": "Family" },
            { "date": "2026-01-22", "source": "Bank", "merchant": "OWN TRANSFER", "amount": 50000, "group": "Transfers", "category": "Internal" },
            { "date": "2026-01-25", "source": "Bank", "merchant": "SAMPLE EMPLOYER", "amount": -250000, "group": "Income", "category": "Salary" },
            { "date": "2026-02-01", "source": "Card", "merchant": "DEMO CAFE", "amount": 500, "group": "Living", "category": "Coffee" }
          ],
          "layerConfig": {
            "notSpendingGroups": ["Income", "Transfers", "People", "Debt"],
            "rentCategories": ["Rent"],
            "billGroups": ["Bills"],
            "subscriptionGroups": ["Subs"],
            "subscriptionCategories": ["Phone bill"],
            "peopleGroup": "People",
            "debtGroup": "Debt"
          }
        }
        """
        let bundle = try decodeBundle(json)
        let months = MonthTotals.compute(items: bundle.items, config: bundle.layerConfig, layers: bundle.layers)

        let jan = try #require(months["2026-01"])
        #expect(jan.layers == [
            "Rent": 80000,
            "Day-to-day": 6000,
            "Subscriptions": 5000,
        ])
        // Two positive purchases (+4000, +3000) and one refund (-1000): sum 6000, positive count 2.
        #expect(jan.categories["Groceries"] == CategoryTotal(sum: 6000, count: 2))
        #expect(jan.categories["Rent"] == CategoryTotal(sum: 80000, count: 1))
        #expect(jan.categories["Phone bill"] == CategoryTotal(sum: 5000, count: 1))
        // Non-spending items do not appear in categories.
        #expect(jan.categories["Salary"] == nil)
        #expect(jan.categories["Internal"] == nil)
        #expect(jan.categories["Loan payment"] == nil)
        #expect(jan.categories["Family"] == nil)
        // Income falls back to first of notSpendingGroups ("Income").
        #expect(jan.income == 250000)
        #expect(jan.debt == 20000)
        #expect(jan.people == 10000)
        #expect(jan.total == 91000)
        #expect(jan.left == 250000 - 91000 - 20000 - 10000)

        let feb = try #require(months["2026-02"])
        #expect(feb.total == 500)
        #expect(feb.income == 0)
        #expect(feb.left == -500)
    }
}

@Suite("PaydayView and ComingUp")
struct PaydayAndComingUpTests {
    @Test func paydayPeriodWithInsOutsAndBorrowing() throws {
        let json = """
        {
          "format": "finance-bundle/1",
          "generatedAt": "2026-02-01T00:00:00+09:00",
          "asOf": "2026-01-28",
          "timeline": [
            { "date": "2026-01-25", "item": "Salary", "amount": -200000, "payday": true, "done": true },
            { "date": "2026-01-27", "item": "Rent", "amount": 80000 },
            { "date": "2026-01-30", "item": "Phone bill", "amount": 5000 },
            { "date": "2026-02-01", "item": "Friend loan", "amount": -30000, "borrowed": true },
            { "date": "2026-02-02", "item": "Reminder", "amount": 0, "event": true },
            { "date": "2026-02-05", "item": "Next salary", "amount": -200000, "payday": true, "next": true },
            { "date": "2026-02-10", "item": "After next", "amount": 10000 }
          ]
        }
        """
        let bundle = try decodeBundle(json)
        let view = try #require(PaydayView.compute(timeline: bundle.timeline, today: "2026-01-28"))

        #expect(view.inSum == 200000)
        #expect(view.outSum == 85000)
        #expect(view.borrowedSum == 30000)
        #expect(view.left == 115000)
        #expect(view.leftIfBorrowed == 145000)
        // Jan 28 -> Feb 05 crosses month boundary: 31 - 28 + 5 = 8 days.
        #expect(view.daysToPayday == 8)
        #expect(view.ins.map(\.item) == ["Salary"])
        #expect(view.outs.map(\.item) == ["Rent", "Phone bill"])
        #expect(view.borrowed.map(\.item) == ["Friend loan"])
        #expect(view.next.item == "Next salary")
    }

    @Test func paydayReturnsNilWithoutNextAndHandlesMonthAndLeapBoundaries() {
        let noNext = [TimelineEntry(date: "2026-01-25", item: "Salary", amount: -200000, payday: true)]
        #expect(PaydayView.compute(timeline: noNext, today: "2026-01-20") == nil)

        // Leap year: 2024-02-27 -> 2024-03-02 is 4 days (Feb has 29 days).
        let leap = [TimelineEntry(date: "2024-03-02", item: "Payday", amount: -100000, payday: true, next: true)]
        #expect(PaydayView.compute(timeline: leap, today: "2024-02-27")?.daysToPayday == 4)

        // Non-leap year: 2026-02-27 -> 2026-03-02 is 3 days.
        let regular = [TimelineEntry(date: "2026-03-02", item: "Payday", amount: -100000, payday: true, next: true)]
        #expect(PaydayView.compute(timeline: regular, today: "2026-02-27")?.daysToPayday == 3)

        // Year boundary: 2026-12-30 -> 2027-01-03 is 4 days.
        let newYear = [TimelineEntry(date: "2027-01-03", item: "Payday", amount: -100000, payday: true, next: true)]
        #expect(PaydayView.compute(timeline: newYear, today: "2026-12-30")?.daysToPayday == 4)

        // Date overload uses JST calendar day (2026-01-31T20:00:00Z is 2026-02-01T05:00:00+09:00).
        let utcEvening = ISO8601DateFormatter().date(from: "2026-01-31T20:00:00Z")!
        let feb = [TimelineEntry(date: "2026-02-05", item: "Payday", amount: -100000, payday: true, next: true)]
        #expect(PaydayView.compute(timeline: feb, today: utcEvening)?.daysToPayday == 4)
    }

    @Test func spentSinceCountsOnlyLayeredItemsOnOrAfterDay() {
        let items = [
            BudgetItem(date: "2026-01-24", source: "Card", merchant: "OLD", amount: 5000, group: "Living", category: "Groceries", layer: "Day-to-day"),
            BudgetItem(date: "2026-01-25", source: "Bank", merchant: "SALARY", amount: -200000, group: "Income", category: "Salary", layer: nil),
            BudgetItem(date: "2026-01-25", source: "Card", merchant: "SAMPLE MART", amount: 2000, group: "Living", category: "Groceries", layer: "Day-to-day"),
            BudgetItem(date: "2026-01-26", source: "Card", merchant: "REFUND", amount: -500, group: "Living", category: "Groceries", layer: "Day-to-day"),
            BudgetItem(date: "2026-01-27", source: "Card", merchant: "PHONE", amount: 3000, group: "Living", category: "Phone bill", layer: "Subscriptions"),
        ]
        #expect(PaydayView.spentSince(day: "2026-01-25", items: items) == 4500)
    }

    @Test func comingUpGroupsByDateAscendingAndKeepsDayOrder() {
        let timeline = [
            TimelineEntry(date: "2026-02-05", item: "Second on 5th", amount: 1000),
            TimelineEntry(date: "2026-01-25", item: "Salary", amount: -200000, payday: true),
            TimelineEntry(date: "2026-02-01", item: "Rent", amount: 80000),
            TimelineEntry(date: "2026-02-01", item: "Internet", amount: 5000),
            TimelineEntry(date: "2026-02-05", item: "Third on 5th", amount: 2000),
        ]
        let groups = ComingUp.groups(timeline: timeline, today: "2026-02-01")

        #expect(groups.map(\.date) == ["2026-01-25", "2026-02-01", "2026-02-05"])

        #expect(groups[0].isPast == true)
        #expect(groups[0].isToday == false)
        #expect(groups[0].hasPayday == true)

        #expect(groups[1].isPast == false)
        #expect(groups[1].isToday == true)
        #expect(groups[1].hasPayday == false)
        #expect(groups[1].entries.map(\.item) == ["Rent", "Internet"])

        #expect(groups[2].isPast == false)
        #expect(groups[2].isToday == false)
        #expect(groups[2].hasPayday == false)
        #expect(groups[2].entries.map(\.item) == ["Second on 5th", "Third on 5th"])
    }
}
