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

        // April salary marked done on actual arrival date, actual amount, next cleared.
        #expect(reconciled[2].done == true)
        #expect(reconciled[2].date == "2026-04-24")
        #expect(reconciled[2].amount == -285000)
        #expect(reconciled[2].estimate == nil)
        #expect(reconciled[2].next == nil)

        // May salary is now marked next.
        #expect(reconciled[5].next == true)
        #expect(reconciled[5].done == nil)

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
}
