import Foundation
import Testing
@testable import FinanceCore

// Invented fixtures for TimelineMatch decoding, TimelineReconciler and cycle roll.

@Suite("TimelineReconciler")
struct TimelineReconcilerTests {
    @Test func bundlesWithoutAndWithMatchDecodeCleanly() throws {
        let legacyJSON = """
        {
          "format": "finance-bundle/1",
          "generatedAt": "2026-04-01T00:00:00+09:00",
          "asOf": "2026-04-01",
          "timeline": [
            { "date": "2026-04-10", "item": "Rent", "amount": 80000 }
          ]
        }
        """
        let legacy = try DataBundle.decode(from: Data(legacyJSON.utf8))
        #expect(legacy.timeline.count == 1)
        #expect(legacy.timeline[0].match == nil)

        let withMatchJSON = """
        {
          "format": "finance-bundle/1",
          "generatedAt": "2026-04-01T00:00:00+09:00",
          "asOf": "2026-04-01",
          "timeline": [
            {
              "date": "2026-04-27",
              "item": "Apartment rent",
              "amount": 80000,
              "match": {
                "source": "Sample Bank",
                "pattern": "口座振替 SAMPLE\\\\(ヤチン",
                "dir": "out",
                "window": [-10, 10]
              }
            }
          ]
        }
        """
        let decoded = try DataBundle.decode(from: Data(withMatchJSON.utf8))
        let match = try #require(decoded.timeline.first?.match)
        #expect(match == TimelineMatch(
            source: "Sample Bank",
            pattern: #"口座振替 SAMPLE\(ヤチン"#,
            dir: "out",
            window: [-10, 10]
        ))

        let roundTripped = try DataBundle.decode(from: try JSONEncoder().encode(decoded))
        #expect(roundTripped.timeline == decoded.timeline)
    }

    @Test func fixedBillMatchedInsideWindow() {
        let timeline = [
            TimelineEntry(
                date: "2026-04-27",
                item: "Apartment rent",
                amount: 80000,
                match: TimelineMatch(
                    source: "Sample Bank",
                    pattern: #"口座振替 SAMPLE\(ヤチン"#,
                    dir: "out",
                    window: [-10, 10]
                )
            ),
        ]
        let rows = [
            TimelineReconciler.BankRow(
                source: "Sample Bank",
                date: "2026-04-28",
                amount: 80000,
                description: "口座振替 SAMPLE(ヤチン"
            ),
        ]

        let reconciled = TimelineReconciler.reconcile(timeline: timeline, bankRows: rows)
        #expect(reconciled.count == 1)
        #expect(reconciled[0].done == true)
        #expect(reconciled[0].date == "2026-04-28")
        #expect(reconciled[0].amount == 80000)
        #expect(reconciled[0].estimate == nil)
    }

    @Test func variableBillReplacesEstimatedAmountAndClearsEstimate() {
        let timeline = [
            TimelineEntry(
                date: "2026-04-16",
                item: "Electricity",
                amount: 9500,
                note: "Monthly estimate",
                estimate: true,
                match: TimelineMatch(
                    source: "Sample Bank",
                    pattern: "口座振替 SAMPLE デンキ",
                    dir: "out",
                    window: [-7, 7]
                )
            ),
        ]
        let rows = [
            TimelineReconciler.BankRow(
                source: "Sample Bank",
                date: "2026-04-18",
                amount: 11200,
                description: "口座振替 SAMPLE デンキ"
            ),
        ]

        let reconciled = TimelineReconciler.reconcile(timeline: timeline, bankRows: rows)
        #expect(reconciled[0].done == true)
        #expect(reconciled[0].date == "2026-04-18")
        #expect(reconciled[0].amount == 11200)
        #expect(reconciled[0].estimate == nil)
        #expect(reconciled[0].note == "Monthly estimate")
    }

    @Test func ignoresRowsOutsideWindowWrongDirectionOrWrongSource() {
        let timeline = [
            TimelineEntry(
                date: "2026-04-15",
                item: "Mobile plan",
                amount: 4500,
                estimate: true,
                match: TimelineMatch(
                    source: "Sample Bank",
                    pattern: "SAMPLE TELECOM",
                    dir: "out",
                    window: [-5, 5]
                )
            ),
            TimelineEntry(
                date: "2026-04-25",
                item: "Salary",
                amount: -250000,
                match: TimelineMatch(
                    source: "Sample Bank",
                    pattern: "給料",
                    dir: "in",
                    window: [-5, 5]
                )
            ),
        ]
        let rows = [
            // Too early (-6 days)
            TimelineReconciler.BankRow(source: "Sample Bank", date: "2026-04-09", amount: 4500, description: "SAMPLE TELECOM"),
            // Too late (+6 days)
            TimelineReconciler.BankRow(source: "Sample Bank", date: "2026-04-21", amount: 4500, description: "SAMPLE TELECOM"),
            // Wrong direction (money in instead of out)
            TimelineReconciler.BankRow(source: "Sample Bank", date: "2026-04-15", amount: -4500, description: "SAMPLE TELECOM"),
            // Zero amount matches neither in nor out
            TimelineReconciler.BankRow(source: "Sample Bank", date: "2026-04-15", amount: 0, description: "SAMPLE TELECOM"),
            // Wrong source
            TimelineReconciler.BankRow(source: "Other Bank", date: "2026-04-15", amount: 4500, description: "SAMPLE TELECOM"),
            // Wrong direction for salary (positive instead of negative)
            TimelineReconciler.BankRow(source: "Sample Bank", date: "2026-04-25", amount: 250000, description: "振込 給料"),
        ]

        let reconciled = TimelineReconciler.reconcile(timeline: timeline, bankRows: rows)
        #expect(reconciled == timeline)
        #expect(reconciled[0].done == nil)
        #expect(reconciled[0].estimate == true)
        #expect(reconciled[1].done == nil)
    }

    @Test func competingEntriesAwardRowToNearestAndLeaveOtherOpen() {
        let rule = TimelineMatch(
            source: "Sample Bank",
            pattern: "口座振替 SAMPLE UTILITY",
            dir: "out",
            window: [-10, 10]
        )
        let timeline = [
            TimelineEntry(date: "2026-04-10", item: "Utility A", amount: 5000, match: rule),
            TimelineEntry(date: "2026-04-18", item: "Utility B", amount: 5000, match: rule),
        ]
        // 2026-04-17 is 7 days from Utility A, 1 day from Utility B: Utility B must win.
        let rows = [
            TimelineReconciler.BankRow(
                source: "Sample Bank",
                date: "2026-04-17",
                amount: 5400,
                description: "口座振替 SAMPLE UTILITY"
            ),
        ]

        let reconciled = TimelineReconciler.reconcile(timeline: timeline, bankRows: rows)
        #expect(reconciled[0].done == nil)
        #expect(reconciled[0].date == "2026-04-10")
        #expect(reconciled[0].amount == 5000)

        #expect(reconciled[1].done == true)
        #expect(reconciled[1].date == "2026-04-17")
        #expect(reconciled[1].amount == 5400)
    }

    @Test func equidistantRowsBreakTieToEarliestDate() {
        let timeline = [
            TimelineEntry(
                date: "2026-04-15",
                item: "Utility",
                amount: 5000,
                match: TimelineMatch(source: "Sample Bank", pattern: "SAMPLE GAS", dir: "out", window: [-5, 5])
            ),
        ]
        let rows = [
            TimelineReconciler.BankRow(source: "Sample Bank", date: "2026-04-17", amount: 5300, description: "SAMPLE GAS"),
            TimelineReconciler.BankRow(source: "Sample Bank", date: "2026-04-13", amount: 5100, description: "SAMPLE GAS"),
        ]

        let reconciled = TimelineReconciler.reconcile(timeline: timeline, bankRows: rows)
        #expect(reconciled[0].done == true)
        #expect(reconciled[0].date == "2026-04-13")
        #expect(reconciled[0].amount == 5100)
    }

    @Test func invalidRegexIsSkippedWithoutCrashing() {
        let timeline = [
            TimelineEntry(
                date: "2026-04-15",
                item: "Broken rule",
                amount: 3000,
                match: TimelineMatch(source: "Sample Bank", pattern: "[unclosed(", dir: "out", window: [-5, 5])
            ),
            TimelineEntry(
                date: "2026-04-15",
                item: "Valid rule",
                amount: 4000,
                match: TimelineMatch(source: "Sample Bank", pattern: "SAMPLE CLOUD", dir: "out", window: [-5, 5])
            ),
        ]
        let rows = [
            TimelineReconciler.BankRow(source: "Sample Bank", date: "2026-04-15", amount: 4000, description: "SAMPLE CLOUD"),
        ]

        let reconciled = TimelineReconciler.reconcile(timeline: timeline, bankRows: rows)
        #expect(reconciled[0].done == nil)
        #expect(reconciled[1].done == true)
        #expect(reconciled[1].amount == 4000)
    }

    @Test func earlySalaryRollsCycleToFollowingPaydayAndUpdatesPaydayView() throws {
        let salaryMatch = TimelineMatch(
            source: "Sample Bank",
            pattern: "給料",
            dir: "in",
            window: [-5, 5]
        )
        let timeline = [
            TimelineEntry(date: "2026-03-25", item: "Monthly salary", amount: -280000, payday: true, done: true),
            TimelineEntry(date: "2026-04-01", item: "April rent", amount: 80000, done: true),
            TimelineEntry(date: "2026-04-25", item: "Monthly salary", amount: -280000, payday: true, next: true, estimate: true, match: salaryMatch),
            TimelineEntry(date: "2026-05-01", item: "May rent", amount: 80000),
            TimelineEntry(date: "2026-05-15", item: "May phone", amount: 5000),
            TimelineEntry(date: "2026-05-25", item: "Monthly salary", amount: -280000, payday: true, match: salaryMatch),
        ]
        let rows = [
            TimelineReconciler.BankRow(
                source: "Sample Bank",
                date: "2026-04-24",
                amount: -285000,
                description: "振込 給料 SAMPLE CORP"
            ),
        ]

        let reconciled = TimelineReconciler.reconcile(timeline: timeline, bankRows: rows)

        // The finished cycle (March salary, April rent) is dropped from the plan.
        #expect(reconciled.map(\.date) == ["2026-04-24", "2026-05-01", "2026-05-15", "2026-05-25"])

        // April salary marked done on actual arrival date, actual amount, next cleared.
        let april = try #require(reconciled.first(where: { $0.date == "2026-04-24" }))
        #expect(april.done == true)
        #expect(april.amount == -285000)
        #expect(april.estimate == nil)
        #expect(april.next == nil)

        // May salary is now marked next.
        let may = try #require(reconciled.first(where: { $0.date == "2026-05-25" }))
        #expect(may.next == true)
        #expect(may.done == nil)

        // PaydayView immediately reflects the new cycle (Apr 24 -> May 25) without double-counting March.
        let view = try #require(PaydayView.compute(timeline: reconciled, today: "2026-04-24"))
        #expect(view.next.date == "2026-05-25")
        #expect(view.daysToPayday == 31)
        #expect(view.inSum == 285000)
        #expect(view.outSum == 85000)
        #expect(view.left == 200000)
        #expect(view.ins.map(\.date) == ["2026-04-24"])
        #expect(view.outs.map(\.item) == ["May rent", "May phone"])

        // ComingUp places the arrived salary on 2026-04-24.
        let groups = ComingUp.groups(timeline: reconciled, today: "2026-04-24")
        let todayGroup = try #require(groups.first(where: { $0.date == "2026-04-24" }))
        #expect(todayGroup.hasPayday == true)
        #expect(todayGroup.entries.first?.done == true)
    }

    @Test func alreadyDoneEntriesRemainUntouchedAndDoNotConsumeRows() {
        let match = TimelineMatch(source: "Sample Bank", pattern: "口座振替 SAMPLE", dir: "out", window: [-10, 10])
        let timeline = [
            TimelineEntry(date: "2026-04-10", item: "Already paid", amount: 5000, done: true, estimate: false, match: match),
            TimelineEntry(date: "2026-04-12", item: "Open bill", amount: 5000, match: match),
        ]
        let rows = [
            TimelineReconciler.BankRow(source: "Sample Bank", date: "2026-04-10", amount: 6200, description: "口座振替 SAMPLE"),
        ]

        let reconciled = TimelineReconciler.reconcile(timeline: timeline, bankRows: rows)
        // Done entry keeps its original amount and date.
        #expect(reconciled[0] == timeline[0])
        // Open entry is still allowed to consume the row.
        #expect(reconciled[1].done == true)
        #expect(reconciled[1].date == "2026-04-10")
        #expect(reconciled[1].amount == 6200)
    }

    @Test func bankLayeringPreservesRawBankDescriptionForTimelineMatching() throws {
        let json = """
        {
          "format": "finance-bundle/1",
          "generatedAt": "2026-04-01T00:00:00+09:00",
          "asOf": "2026-03-31",
          "coverage": {
            "mufg_debit": { "start": "2026-01-01", "end": "2026-03-31" },
            "bank_main": { "start": "2026-01-01", "end": "2026-03-31" }
          },
          "sourceLabels": {
            "mufg_debit": "Sample Debit",
            "bank_main": "Main Bank"
          },
          "noticeSourceMatches": {
            "mufg_debit": ["bank_main"]
          },
          "statementLineRules": {
            "bank_main": [
              { "pattern": "^デビット1\\\\s+(\\\\d{6})\\\\s+(.+)$", "referenceGroup": 1, "merchantGroup": 2 }
            ]
          },
          "timeline": [
            {
              "date": "2026-04-06",
              "item": "Sample subscription",
              "amount": 1500,
              "estimate": true,
              "match": {
                "source": "Main Bank",
                "pattern": "^デビット1\\\\s+\\\\d{6}\\\\s+SAMPLE-S",
                "dir": "out",
                "window": [-5, 5]
              }
            }
          ]
        }
        """
        let bundle = try DataBundle.decode(from: Data(json.utf8))
        let txs = [
            BankTransaction(
                id: "tx-sub",
                connectedAccountID: "acc-bank",
                date: "2026-04-06",
                amount: 1650,
                description: "デビット1 123456 SAMPLE-SUB"
            ),
        ]
        let notices = [
            Notice(
                messageID: "n-sub",
                source: .mufgDebit,
                kind: .purchase,
                receivedAt: "2026-04-05T12:00:00+09:00",
                occurredOn: "2026-04-05",
                amount: 1650,
                currency: "JPY",
                merchant: "SAMPLE SUBSCRIPTION STORE",
                reference: "123456",
                parser: "test/1"
            ),
        ]

        let layered = BankLayering.build(
            bundle: bundle,
            bankTransactions: txs,
            accountMapping: ["acc-bank": "bank_main"],
            notices: notices,
            categorizer: Categorizer(rules: bundle.rules),
            config: bundle.layerConfig
        )

        // Display item uses the notice's merchant, while bankRows keeps the raw bank text.
        #expect(layered.bankItems.first?.merchant == "SAMPLE SUBSCRIPTION STORE")
        #expect(layered.bankRows.first?.description == "デビット1 123456 SAMPLE-SUB")

        let reconciled = TimelineReconciler.reconcile(timeline: bundle.timeline, bankRows: layered.bankRows)
        #expect(reconciled[0].done == true)
        #expect(reconciled[0].amount == 1650)
        #expect(reconciled[0].estimate == nil)
    }

    @Test func moneyBeforeTheCurrentPaydayStillCountsWhenNothingRolls() throws {
        // The PC keeps money that arrived just before payday in this cycle's plan; without a roll it stays counted.
        let timeline = [
            TimelineEntry(date: "2026-04-21", item: "Sample cashback", amount: -50000, done: true),
            TimelineEntry(date: "2026-04-24", item: "Monthly salary", amount: -280000, payday: true, done: true),
            TimelineEntry(date: "2026-05-01", item: "May rent", amount: 80000),
            TimelineEntry(date: "2026-05-25", item: "Monthly salary", amount: -280000, payday: true, next: true, estimate: true),
        ]
        let reconciled = TimelineReconciler.reconcile(timeline: timeline, bankRows: [])
        #expect(reconciled.count == 4)
        let view = try #require(PaydayView.compute(timeline: reconciled, today: "2026-04-26"))
        #expect(view.inSum == 330000)
        #expect(view.left == 250000)
    }

    @Test func amountBoundsDisambiguateSharedDescriptorsAndPendingNoticesPreventDoubleCount() throws {
        let timeline = [
            TimelineEntry(date: "2026-03-25", item: "Salary", amount: -300_000, payday: true, done: true),
            TimelineEntry(
                date: "2026-04-14",
                item: "App Pro",
                amount: 3_000,
                match: TimelineMatch(source: "Sample Bank", pattern: "APP\\.COM/BILL", dir: "out", window: [-5, 5], minAmount: 2_500, maxAmount: 3_500)
            ),
            TimelineEntry(
                date: "2026-04-15",
                item: "App Basic",
                amount: 650,
                match: TimelineMatch(source: "Sample Bank", pattern: "APP\\.COM/BILL", dir: "out", window: [-5, 5], minAmount: 500, maxAmount: 800)
            ),
            TimelineEntry(
                date: "2026-04-15",
                item: "Card Gym",
                amount: 0,
                match: TimelineMatch(source: "Sample Card", pattern: "SAMPLE GYM", dir: "out", window: [-5, 5], minAmount: 2_500, maxAmount: 3_500),
                cardBilled: true,
                billedAmount: 3_000
            ),
            TimelineEntry(date: "2026-04-25", item: "Salary", amount: -300_000, payday: true, next: true),
        ]
        let balances = [
            AccountBalance(source: "sample_bank", label: "Sample Bank", balance: 100_000, asOf: "2026-04-12", debitNoticeSources: ["sample_debit"]),
        ]
        let labels = ["sample_bank": "Sample Bank", "sample_debit": "Sample Debit", "sample_card": "Sample Card"]
        let pending = [
            BudgetItem(date: "2026-04-14", source: "Sample Debit", merchant: "APP.COM/BILL", amount: 3_000, group: "Subscriptions", category: "Apps", isPending: true),
            BudgetItem(date: "2026-04-15", source: "Sample Card", merchant: "SAMPLE GYM", amount: 3_058, group: "Other", category: "Gym", isPending: true),
        ]

        let reconciled = TimelineReconciler.reconcilePendingNotices(
            timeline: timeline,
            pendingItems: pending,
            accountBalances: balances,
            sourceLabels: labels
        )
        #expect(reconciled[1].done == true)
        #expect(reconciled[1].amount == 3_000)
        // App Basic (¥650) must NOT be matched by the ¥3,000 APP.COM/BILL notice.
        #expect(reconciled[2].done == nil)
        // Card-billed gym marks done and updates billedAmount without adding to cash amount.
        #expect(reconciled[3].done == true)
        #expect(reconciled[3].amount == 0)
        #expect(reconciled[3].billedAmount == 3_058)

        let payday = try #require(PaydayView.compute(timeline: reconciled, today: "2026-04-15"))
        // Card Gym is excluded from outs; App Pro is already done; only App Basic (¥650) remains unpaid.
        let live = try #require(LiveCashSummary.compute(
            accountBalances: balances,
            sourceLabels: labels,
            bankRows: [],
            pendingItems: pending,
            payday: payday
        ))
        // Bank cash: 100,000 - 3,000 (pending App Pro debit) = 97,000.
        // Remaining bills: 650 (App Basic only — App Pro is NOT subtracted a second time, Card Gym is ¥0).
        #expect(live.estimatedBankCash == 97_000)
        #expect(live.remainingBillsSum == 650)
        #expect(live.cashLeftUntilPayday == 96_350)
    }
}
