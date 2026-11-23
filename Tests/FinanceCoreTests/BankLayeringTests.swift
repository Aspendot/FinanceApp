import Foundation
import Testing
@testable import FinanceCore

// Invented fixtures for BankTransaction, JST date arithmetic and BankLayering.

private func makeNotice(
    _ id: String,
    source: NoticeSource = .mufgDebit,
    kind: NoticeKind = .purchase,
    received: String = "2026-04-05T12:00:00+09:00",
    on: String = "2026-04-05",
    amount: Int? = 2000,
    merchant: String? = "SAMPLE MART",
    ref: String? = nil
) -> Notice {
    Notice(
        messageID: id,
        source: source,
        kind: kind,
        receivedAt: received,
        occurredOn: on,
        amount: amount,
        currency: "JPY",
        merchant: merchant,
        reference: ref,
        parser: "test/1"
    )
}

private func makeLayeringBundle(
    noticeSourceMatches: [String: [String]]? = nil
) throws -> DataBundle {
    let matchesJSON: String
    if let noticeSourceMatches {
        let data = try JSONEncoder().encode(noticeSourceMatches)
        matchesJSON = ",\n  \"noticeSourceMatches\": " + String(decoding: data, as: UTF8.self)
    } else {
        matchesJSON = ""
    }

    let json = """
    {
      "format": "finance-bundle/1",
      "generatedAt": "2026-04-01T00:00:00+09:00",
      "asOf": "2026-03-31",
      "coverage": {
        "mufg_debit": { "start": "2026-01-01", "end": "2026-03-31" },
        "docomo_debit": { "start": "2026-01-01", "end": "2026-03-31" },
        "bank_main": { "start": "2026-01-01", "end": "2026-03-31" }
      },
      "sourceLabels": {
        "mufg_debit": "Sample Debit",
        "docomo_debit": "Card Two",
        "bank_main": "Main Bank"
      },
      "items": [
        {
          "date": "2026-03-31",
          "source": "Sample Debit",
          "merchant": "SAMPLE MART",
          "amount": 1500,
          "group": "Living",
          "category": "Groceries",
          "layer": "Day-to-day"
        }
      ],
      "layers": [
        { "key": "Rent", "color": "#111111" },
        { "key": "Bills & taxes", "color": "#222222" },
        { "key": "Subscriptions", "color": "#333333" },
        { "key": "Day-to-day", "color": "#444444" }
      ],
      "layerConfig": {
        "notSpendingGroups": ["Income"],
        "rentCategories": ["Rent"],
        "billGroups": ["Bills"],
        "subscriptionGroups": ["Subs"],
        "subscriptionCategories": ["Phone bill"],
        "incomeGroup": "Income"
      },
      "rules": {
        "rules": [
          { "pattern": "sample mart|ｻﾝﾌﾟﾙﾏｰﾄ", "group": "Living", "category": "Groceries" },
          { "pattern": "sample employer|ｷｭｳﾖ", "group": "Income", "category": "Salary" }
        ],
        "amountRules": [],
        "learned": {}
      }\(matchesJSON)
    }
    """
    return try DataBundle.decode(from: Data(json.utf8))
}

@Suite("BankTransaction and BankLayering")
struct BankLayeringTests {
    @Test func signedAmountFollowsAppConvention() {
        #expect(BankTransaction.signedAmount(value: 3500, side: .expense) == 3500)
        #expect(BankTransaction.signedAmount(value: 250000, side: .income) == -250000)
        #expect(BankTransaction.signedAmount(value: 0, rawSide: "EXPENSE") == 0)
        #expect(BankTransaction.signedAmount(value: 1200, rawSide: "income") == -1200)
        #expect(BankTransaction.signedAmount(value: -100, side: .expense) == nil)
        #expect(BankTransaction.signedAmount(value: 100, rawSide: "UNKNOWN") == nil)
    }

    @Test func mappedSourcePrefersSubAccountAndTreatsEmptyAsIgnore() {
        let mapping = [
            "parent-1": "bank_main",
            "sub-1": "mufg_debit",
            "sub-ignored": "",
        ]
        let withSub = BankTransaction(
            id: "t1", connectedAccountID: "parent-1", connectedSubAccountID: "sub-1",
            date: "2026-04-02", amount: 1000, description: "SAMPLE MART"
        )
        let parentOnly = BankTransaction(
            id: "t2", connectedAccountID: "parent-1", connectedSubAccountID: nil,
            date: "2026-04-02", amount: 1000, description: "SAMPLE MART"
        )
        let ignoredSub = BankTransaction(
            id: "t3", connectedAccountID: "parent-1", connectedSubAccountID: "sub-ignored",
            date: "2026-04-02", amount: 1000, description: "SAMPLE MART"
        )
        let unmapped = BankTransaction(
            id: "t4", connectedAccountID: "parent-2", connectedSubAccountID: nil,
            date: "2026-04-02", amount: 1000, description: "SAMPLE MART"
        )

        #expect(withSub.mappedSource(using: mapping) == "mufg_debit")
        #expect(parentOnly.mappedSource(using: mapping) == "bank_main")
        #expect(ignoredSub.mappedSource(using: mapping) == nil)
        #expect(unmapped.mappedSource(using: mapping) == nil)
    }

    @Test func jstAddingDaysHandlesMonthLeapAndYearBoundaries() {
        #expect(JST.addingDays(-7, to: "2026-03-05") == "2026-02-26")
        #expect(JST.addingDays(-7, to: "2024-03-05") == "2024-02-27")
        #expect(JST.addingDays(3, to: "2026-12-30") == "2027-01-02")
        #expect(JST.addingDays(0, to: "2026-04-15") == "2026-04-15")
        #expect(JST.addingDays(1, to: "not-a-date") == nil)
    }

    @Test func bundleDecodesWithAndWithoutNoticeSourceMatches() throws {
        let withoutMatches = try makeLayeringBundle(noticeSourceMatches: nil)
        #expect(withoutMatches.noticeSourceMatches == nil)

        let withMatches = try makeLayeringBundle(noticeSourceMatches: ["docomo_debit": ["bank_main"]])
        #expect(withMatches.noticeSourceMatches == ["docomo_debit": ["bank_main"]])

        let encoded = try JSONEncoder().encode(withMatches)
        let roundTripped = try DataBundle.decode(from: encoded)
        #expect(roundTripped.noticeSourceMatches == ["docomo_debit": ["bank_main"]])
    }

    @Test func layersBankTransactionsAfterCoverageAndPreservesRawDescription() throws {
        let bundle = try makeLayeringBundle()
        let categorizer = Categorizer(rules: bundle.rules)
        let mapping = ["acc-debit": "mufg_debit", "acc-bank": "bank_main"]

        let txs = [
            // On or before bundle coverage end (2026-03-31): skipped.
            BankTransaction(id: "old-1", connectedAccountID: "acc-debit", date: "2026-03-31", amount: 1500, description: "SAMPLE MART"),
            // Unmapped account: ignored.
            BankTransaction(id: "ign-1", connectedAccountID: "acc-other", date: "2026-04-02", amount: 900, description: "SAMPLE MART"),
            // After coverage end: confirmed spending item with verbatim description.
            BankTransaction(id: "tx-1", connectedAccountID: "acc-debit", date: "2026-04-02", amount: 2400, description: "  ｻﾝﾌﾟﾙﾏｰﾄ  支店  "),
            // After coverage end: confirmed income (negative yen, nil spending layer).
            BankTransaction(id: "tx-2", connectedAccountID: "acc-bank", date: "2026-04-25", amount: -250000, description: "ｷｭｳﾖ SAMPLE EMPLOYER"),
        ]

        let result = BankLayering.build(
            bundle: bundle,
            bankTransactions: txs,
            accountMapping: mapping,
            notices: [],
            categorizer: categorizer,
            config: bundle.layerConfig
        )

        #expect(result.bankItems.count == 2)
        #expect(result.bankTransactionIDs == ["tx-1", "tx-2"])

        #expect(result.bankItems[0].isPending == false)
        #expect(result.bankItems[0].source == "Sample Debit")
        #expect(result.bankItems[0].merchant == "  ｻﾝﾌﾟﾙﾏｰﾄ  支店  ")
        #expect(result.bankItems[0].amount == 2400)
        #expect(result.bankItems[0].category == "Groceries")
        #expect(result.bankItems[0].layer == "Day-to-day")

        #expect(result.bankItems[1].isPending == false)
        #expect(result.bankItems[1].source == "Main Bank")
        #expect(result.bankItems[1].amount == -250000)
        #expect(result.bankItems[1].group == "Income")
        #expect(result.bankItems[1].layer == nil)

        #expect(result.effectiveCoverage["mufg_debit"]?.end == "2026-04-02")
        #expect(result.effectiveCoverage["bank_main"]?.end == "2026-04-25")
    }

    @Test func matchesNoticesWithinZeroToThreeDaysAndDropsOlderUnmatchedNotices() throws {
        let bundle = try makeLayeringBundle()
        let categorizer = Categorizer(rules: bundle.rules)
        let mapping = ["acc-debit": "mufg_debit"]

        let txs = [
            // Matches n1 (+0 days)
            BankTransaction(id: "tx-0", connectedAccountID: "acc-debit", date: "2026-04-05", amount: 1000, description: "SAMPLE MART"),
            // Matches n2 (+3 days)
            BankTransaction(id: "tx-3", connectedAccountID: "acc-debit", date: "2026-04-08", amount: 2000, description: "DEMO CAFE"),
            // Latest MF row sets effective coverage to 2026-04-12.
            BankTransaction(id: "tx-latest", connectedAccountID: "acc-debit", date: "2026-04-12", amount: 5000, description: "OTHER SHOP"),
        ]

        let notices = [
            // Matched at offset 0.
            makeNotice("n1", source: .mufgDebit, on: "2026-04-05", amount: 1000, merchant: "SAMPLE MART"),
            // Matched at offset +3.
            makeNotice("n2", source: .mufgDebit, on: "2026-04-05", amount: 2000, merchant: "DEMO CAFE"),
            // Older notice (2026-04-03) with no match: drops out of pending under extended coverage 2026-04-12.
            makeNotice("n-old", source: .mufgDebit, on: "2026-04-03", amount: 7777, merchant: "OLD SHOP"),
            // Notice on 2026-04-13 (after effective coverage): stays pending.
            makeNotice("n-new", source: .mufgDebit, on: "2026-04-13", amount: 3000, merchant: "NEW SHOP"),
            // Notice on 2026-04-12 (boundary of effective coverage, unmatched): stays pending.
            makeNotice("n-boundary", source: .mufgDebit, on: "2026-04-12", amount: 900, merchant: "BOUNDARY SHOP"),
            // Notice on 2026-04-13 with amount 5000: tx-latest is on 2026-04-12 (offset -1), MUST NOT match!
            makeNotice("n-after-tx", source: .mufgDebit, on: "2026-04-13", amount: 5000, merchant: "OTHER SHOP"),
        ]

        let result = BankLayering.build(
            bundle: bundle,
            bankTransactions: txs,
            accountMapping: mapping,
            notices: notices,
            categorizer: categorizer,
            config: bundle.layerConfig
        )

        #expect(result.matchedPairs.map(\.noticeID) == ["n1", "n2"])
        #expect(result.matchedPairs.map(\.dayOffset) == [0, 3])
        #expect(result.unmatched.map(\.messageID) == ["n-old"])
        #expect(result.pendingNoticeIDs == ["n-boundary", "n-after-tx", "n-new"])
        #expect(result.pendingItems.allSatisfy { $0.isPending })

        // Input order does not change output.
        let reversed = BankLayering.build(
            bundle: bundle,
            bankTransactions: txs.reversed(),
            accountMapping: mapping,
            notices: notices.reversed(),
            categorizer: categorizer,
            config: bundle.layerConfig
        )
        #expect(reversed == result)
    }

    @Test func leavesRealTiesUnresolvedAndPending() throws {
        let bundle = try makeLayeringBundle()
        let categorizer = Categorizer(rules: bundle.rules)
        let mapping = ["acc-debit": "mufg_debit"]

        // Two notices on the same day with the same amount and distinct merchants
        // competing for one bank row whose description matches neither.
        let txs = [
            BankTransaction(id: "tx-tie", connectedAccountID: "acc-debit", date: "2026-04-06", amount: 1800, description: "BANK DEBIT"),
        ]
        let notices = [
            makeNotice("n-a", source: .mufgDebit, on: "2026-04-05", amount: 1800, merchant: "ALPHA SHOP"),
            makeNotice("n-b", source: .mufgDebit, on: "2026-04-05", amount: 1800, merchant: "BETA SHOP"),
        ]

        let result = BankLayering.build(
            bundle: bundle,
            bankTransactions: txs,
            accountMapping: mapping,
            notices: notices,
            categorizer: categorizer,
            config: bundle.layerConfig
        )

        #expect(result.matchedPairs.isEmpty)
        #expect(result.ambiguous.count == 1)
        #expect(result.ambiguous[0].noticeIDs == ["n-a", "n-b"])
        #expect(result.ambiguous[0].rowIDs == ["tx-tie"])
        // Both tied notices remain pending rather than being guessed or silently dropped.
        #expect(result.pendingNoticeIDs == ["n-a", "n-b"])
        #expect(result.unmatched.isEmpty)
    }

    @Test func matchesCrossSourceNoticesUsingNoticeSourceMatchesTable() throws {
        let bundle = try makeLayeringBundle(noticeSourceMatches: [
            "docomo_debit": ["bank_main"],
        ])
        let categorizer = Categorizer(rules: bundle.rules)
        let mapping = ["acc-bank": "bank_main"]

        let txs = [
            BankTransaction(id: "bank-1", connectedAccountID: "acc-bank", date: "2026-04-07", amount: 4200, description: "CARD DEBIT SETTLEMENT"),
        ]
        let notices = [
            // Card notice settled on bank_main 2 days later: matched and removed from pending.
            makeNotice("card-1", source: .docomoDebit, on: "2026-04-05", amount: 4200, merchant: "SAMPLE SHOP"),
            // Unsettled card notice on 2026-04-06: docomo_debit's own coverage is still 2026-03-31, so stays pending.
            makeNotice("card-2", source: .docomoDebit, on: "2026-04-06", amount: 1500, merchant: "PENDING SHOP"),
            // Card notice 4 days before bank-1 (outside 0...3 window): does not match.
            makeNotice("card-3", source: .docomoDebit, on: "2026-04-03", amount: 4200, merchant: "EARLY SHOP"),
        ]

        let result = BankLayering.build(
            bundle: bundle,
            bankTransactions: txs,
            accountMapping: mapping,
            notices: notices,
            categorizer: categorizer,
            config: bundle.layerConfig
        )

        #expect(result.matchedPairs.count == 1)
        #expect(result.matchedPairs[0].noticeID == "card-1")
        #expect(result.matchedPairs[0].transactionID == "bank-1")
        #expect(result.matchedPairs[0].dayOffset == 2)
        #expect(result.pendingNoticeIDs == ["card-3", "card-2"])
    }

    @Test func dataDrivenStatementLineRulesExtractApprovalNumberAndMerchantPrefix() throws {
        var bundle = try makeLayeringBundle(noticeSourceMatches: [
            "mufg_debit": ["bank_main"],
            "docomo_debit": ["bank_main"],
        ])
        // Invented rules for debit lines: one with marker + 6-digit ref + 8-char prefix,
        // one with marker + 6-digit ref and no merchant.
        bundle.statementLineRules = [
            "bank_main": [
                StatementLineRule(pattern: "^デビット\\d+\\s+(\\d{6})\\s+(.+)$", referenceGroup: 1, merchantGroup: 2),
                StatementLineRule(pattern: "^デビット\\s+(\\d{6})$", referenceGroup: 1, merchantGroup: nil),
            ],
        ]
        let categorizer = Categorizer(rules: bundle.rules)
        let mapping = ["acc-bank": "bank_main"]

        // Two same-day same-amount debit rows with different approval numbers and merchant prefixes,
        // plus one merchantless debit row and one interest row.
        let txs = [
            BankTransaction(id: "tx-a", connectedAccountID: "acc-bank", date: "2026-04-06", amount: 1200, description: "デビット1 123456 SAMPLE-M"),
            BankTransaction(id: "tx-b", connectedAccountID: "acc-bank", date: "2026-04-06", amount: 1200, description: "デビット1 234567 DEMO-CAF"),
            BankTransaction(id: "tx-c", connectedAccountID: "acc-bank", date: "2026-04-06", amount: 1500, description: "デビット 654321"),
            BankTransaction(id: "tx-d", connectedAccountID: "acc-bank", date: "2026-04-06", amount: 1500, description: "デビット 777777"),
            BankTransaction(id: "tx-int", connectedAccountID: "acc-bank", date: "2026-04-06", amount: -12, description: "利息"),
        ]
        let notices = [
            // Matched by merchant prefix even without a reference.
            makeNotice("n-prefix-a", source: .mufgDebit, on: "2026-04-05", amount: 1200, merchant: "SAMPLE MART TOKYO", ref: nil),
            makeNotice("n-prefix-b", source: .mufgDebit, on: "2026-04-05", amount: 1200, merchant: "DEMO CAFE", ref: nil),
            // Merchantless bank lines broken apart by 6-digit approval number.
            makeNotice("n-ref-c", source: .docomoDebit, on: "2026-04-05", amount: 1500, merchant: "SHOP ONE", ref: "654321"),
            makeNotice("n-ref-d", source: .docomoDebit, on: "2026-04-05", amount: 1500, merchant: "SHOP TWO", ref: "777777"),
        ]

        let result = BankLayering.build(
            bundle: bundle,
            bankTransactions: txs,
            accountMapping: mapping,
            notices: notices,
            categorizer: categorizer,
            config: bundle.layerConfig
        )

        #expect(result.ambiguous.isEmpty)
        #expect(result.pendingItems.isEmpty)
        let byNotice = Dictionary(uniqueKeysWithValues: result.matchedPairs.map { ($0.noticeID, $0) })
        #expect(byNotice["n-prefix-a"]?.transactionID == "tx-a")
        #expect(byNotice["n-prefix-a"]?.merchantAgrees == true)
        #expect(byNotice["n-prefix-b"]?.transactionID == "tx-b")
        #expect(byNotice["n-prefix-b"]?.merchantAgrees == true)
        #expect(byNotice["n-ref-c"]?.transactionID == "tx-c")
        #expect(byNotice["n-ref-c"]?.referenceAgrees == true)
        #expect(byNotice["n-ref-d"]?.transactionID == "tx-d")
        #expect(byNotice["n-ref-d"]?.referenceAgrees == true)

        // Displayed bank item descriptions stay verbatim.
        let merchantsByTxID = Dictionary(uniqueKeysWithValues: zip(result.bankTransactionIDs, result.bankItems.map(\.merchant)))
        #expect(merchantsByTxID["tx-a"] == "デビット1 123456 SAMPLE-M")
        #expect(merchantsByTxID["tx-c"] == "デビット 654321")
        #expect(merchantsByTxID["tx-int"] == "利息")
    }
}
