import Foundation
import Testing
@testable import FinanceCore

// Invented bundle and notices for pending-item construction.

private func makeNotice(
    _ id: String,
    source: NoticeSource = .merpay,
    kind: NoticeKind = .purchase,
    received: String = "2026-02-05T12:00:00+09:00",
    at: String? = nil,
    on: String? = nil,
    amount: Int? = 1000,
    merchant: String? = "SAMPLE MART",
    ref: String? = nil,
    relatedRef: String? = nil,
    orderID: String? = nil
) -> Notice {
    Notice(
        messageID: id,
        source: source,
        kind: kind,
        receivedAt: received,
        occurredAt: at,
        occurredOn: on,
        amount: amount,
        currency: "JPY",
        merchant: merchant,
        reference: ref,
        relatedReference: relatedRef,
        orderID: orderID,
        parser: "test/1"
    )
}

private func makeBundle() throws -> DataBundle {
    let json = """
    {
      "format": "finance-bundle/1",
      "generatedAt": "2026-02-01T00:00:00+09:00",
      "asOf": "2026-02-01",
      "coverage": {
        "merpay": { "start": "2026-01-01", "end": "2026-01-31" },
        "docomo_debit": { "start": "2026-01-01", "end": "2026-01-31" },
        "mufg_debit": { "start": "2026-01-01", "end": "2026-01-31" }
      },
      "sourceLabels": {
        "merpay": "Wallet Card",
        "docomo_debit": "Net Debit",
        "apple": "Apple Receipt"
      },
      "items": [
        {
          "date": "2026-01-31",
          "source": "Wallet Card",
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
        "subscriptionCategories": ["Phone bill"]
      },
      "rules": {
        "rules": [
          { "pattern": "sample mart", "group": "Living", "category": "Groceries" },
          { "pattern": "sample cloud", "group": "Subs", "category": "Cloud" },
          { "pattern": "metro telecom", "group": "Living", "category": "Phone bill" }
        ],
        "amountRules": [],
        "learned": {}
      }
    }
    """
    return try DataBundle.decode(from: Data(json.utf8))
}

@Suite("PendingBuilder")
struct PendingBuilderTests {
    @Test func cancellationPairRemovesBothByReferenceAndRelatedReference() throws {
        let bundle = try makeBundle()
        let categorizer = Categorizer(rules: bundle.rules)

        let notices = [
            // Cancelled via same reference.
            makeNotice("n1", source: .merpay, kind: .purchase, on: "2026-02-02", amount: 1000, ref: "R1"),
            makeNotice("n2", source: .merpay, kind: .cancellation, on: "2026-02-02", amount: -1000, ref: "R1"),
            // Cancelled via relatedReference.
            makeNotice("n3", source: .merpay, kind: .purchase, on: "2026-02-03", amount: 2000, ref: "R2"),
            makeNotice("n4", source: .merpay, kind: .cancellation, on: "2026-02-03", amount: -2000, ref: "C9", relatedRef: "R2"),
            // Different source with same reference must NOT cancel.
            makeNotice("n5", source: .docomoDebit, kind: .purchase, on: "2026-02-04", amount: 3000, ref: "R3"),
            makeNotice("n6", source: .merpay, kind: .cancellation, on: "2026-02-04", amount: -3000, ref: "R3"),
        ]

        let items = PendingBuilder.items(notices: notices, bundle: bundle, categorizer: categorizer, config: bundle.layerConfig)
        #expect(items.count == 2)
        #expect(items[0].source == "Net Debit")
        #expect(items[0].amount == 3000)
        #expect(items[1].source == "Wallet Card")
        #expect(items[1].amount == -3000)
    }

    @Test func settlementReplacesPurchaseAmountAndIsNotEmittedItself() throws {
        let bundle = try makeBundle()
        let categorizer = Categorizer(rules: bundle.rules)

        let notices = [
            makeNotice("n1", source: .docomoDebit, kind: .purchase, received: "2026-02-02T10:00:00+09:00", on: "2026-02-02", amount: 5000, ref: "AUTH1"),
            makeNotice("n2", source: .docomoDebit, kind: .settlement, received: "2026-02-03T10:00:00+09:00", on: "2026-02-02", amount: 5200, ref: "AUTH1"),
            makeNotice("n3", source: .docomoDebit, kind: .settlement, received: "2026-02-04T10:00:00+09:00", on: "2026-02-02", amount: 5300, ref: "AUTH1"),
            // Standalone settlement with no purchase becomes pending.
            makeNotice("n4", source: .docomoDebit, kind: .settlement, received: "2026-02-05T10:00:00+09:00", on: "2026-02-05", amount: 4000, merchant: "METRO TELECOM", ref: "AUTH2"),
        ]

        let items = PendingBuilder.items(notices: notices, bundle: bundle, categorizer: categorizer, config: bundle.layerConfig)
        #expect(items.count == 2)
        #expect(items[0].date == "2026-02-02")
        #expect(items[0].amount == 5300)
        #expect(items[0].isPending == true)
        #expect(items[1].date == "2026-02-05")
        #expect(items[1].amount == 4000)
        #expect(items[1].layer == "Subscriptions")
    }

    @Test func boundaryDayDuplicateIsSkippedAndSecondIdenticalNoticeStays() throws {
        let bundle = try makeBundle()
        let categorizer = Categorizer(rules: bundle.rules)

        // Bundle has one Wallet Card item on 2026-01-31 for 1500.
        let notices = [
            makeNotice("n1", source: .merpay, on: "2026-01-31", amount: 1500),
            makeNotice("n2", source: .merpay, on: "2026-01-31", amount: 1500),
            makeNotice("n3", source: .merpay, on: "2026-01-31", amount: 2500),
        ]

        let result = PendingBuilder.build(notices: notices, bundle: bundle, categorizer: categorizer, config: bundle.layerConfig)
        #expect(result.unmatched.isEmpty)
        #expect(result.items.map(\.amount) == [1500, 2500])
    }

    @Test func appleDuplicatesAreSkippedByOrderIDOrAmountWithinThreeDays() throws {
        let bundle = try makeBundle()
        let categorizer = Categorizer(rules: bundle.rules)

        let notices = [
            // Apple receipts.
            makeNotice("a1", source: .apple, on: "2026-02-02", amount: 1000, merchant: "SAMPLE CLOUD", ref: "ORD100"),
            makeNotice("a2", source: .apple, on: "2026-02-05", amount: 1200, merchant: "SAMPLE CLOUD", ref: "ORD200"),
            // Card notice matching ORD100 by orderID (even with a non-Apple merchant string).
            makeNotice("c1", source: .merpay, on: "2026-02-02", amount: 1000, merchant: "DIGITAL STORE", orderID: "ORD100"),
            // Card notice matching a2 by full-width "Apple" + same amount + 3 days later.
            makeNotice("c2", source: .mufgDebit, on: "2026-02-08", amount: 1200, merchant: "ＡＰＰＬＥ.ＣＯＭ／ＢＩＬＬ"),
            // Card notice 4 days later: outside 3-day window, so NOT skipped.
            makeNotice("c3", source: .mufgDebit, on: "2026-02-09", amount: 1200, merchant: "APPLE.COM/BILL"),
            // Card notice with same amount within 3 days, but merchant does not contain "apple": NOT skipped.
            makeNotice("c4", source: .mufgDebit, on: "2026-02-06", amount: 1200, merchant: "SAMPLE MART"),
        ]

        let items = PendingBuilder.items(notices: notices, bundle: bundle, categorizer: categorizer, config: bundle.layerConfig)
        #expect(items.count == 4)
        #expect(items.map(\.source) == ["Apple Receipt", "Apple Receipt", "mufg_debit", "mufg_debit"])
        #expect(items.map(\.date) == ["2026-02-02", "2026-02-05", "2026-02-06", "2026-02-09"])
    }

    @Test func noticeBeforeCoverageEndGoesToUnmatchedAndMetadataDefaultsWork() throws {
        let bundle = try makeBundle()
        let categorizer = Categorizer(rules: bundle.rules)

        let notices = [
            // Before coverage end (2026-01-31): goes to unmatched.
            makeNotice("u1", source: .merpay, on: "2026-01-20", amount: 1000),
            // Non-spending kinds and nil amounts are ignored completely.
            makeNotice("ig1", source: .merpay, kind: .decline, on: "2026-02-02", amount: 1000),
            makeNotice("ig2", source: .merpay, kind: .cardCheck, on: "2026-02-02", amount: 1),
            makeNotice("ig3", source: .merpay, kind: .topUp, on: "2026-02-02", amount: 10000),
            makeNotice("ig4", source: .merpay, kind: .purchase, on: "2026-02-02", amount: nil),
            // Blank merchant and source without a label in sourceLabels.
            makeNotice("p1", source: .mufgDebit, on: "2026-02-03", amount: 2000, merchant: nil),
        ]

        let result = PendingBuilder.build(notices: notices, bundle: bundle, categorizer: categorizer, config: bundle.layerConfig)
        #expect(result.unmatched.map(\.messageID) == ["u1"])
        #expect(result.items == [
            BudgetItem(
                date: "2026-02-03",
                source: "mufg_debit",
                merchant: "(no merchant name in the notice)",
                amount: 2000,
                group: "Other",
                category: "Uncategorized",
                layer: "Day-to-day",
                isPending: true
            ),
        ])

        // Reversed input order produces identical output.
        let reversed = PendingBuilder.build(notices: notices.reversed(), bundle: bundle, categorizer: categorizer, config: bundle.layerConfig)
        #expect(reversed == result)
    }

    @Test func noticeIDsAlignOneToOneWithPendingItems() throws {
        let bundle = try makeBundle()
        let categorizer = Categorizer(rules: bundle.rules)

        let notices = [
            // Pre-coverage notice: unmatched, not in noticeIDs.
            makeNotice("old-1", source: .merpay, on: "2026-01-15", amount: 500),
            // Boundary-day duplicate of bundle item: skipped, not in noticeIDs.
            makeNotice("dup-1", source: .merpay, on: "2026-01-31", amount: 1500),
            // Second identical boundary-day notice: kept with its messageID.
            makeNotice("keep-boundary", source: .merpay, on: "2026-01-31", amount: 1500),
            // Purchase replaced by a later settlement: keeps the original purchase messageID.
            makeNotice("buy-settled", source: .docomoDebit, kind: .purchase, received: "2026-02-02T10:00:00+09:00", on: "2026-02-02", amount: 3000, ref: "REF1"),
            makeNotice("settle-1", source: .docomoDebit, kind: .settlement, received: "2026-02-03T10:00:00+09:00", on: "2026-02-02", amount: 3200, ref: "REF1"),
            // Cancelled pair: neither appears in items or noticeIDs.
            makeNotice("buy-cancel", source: .merpay, kind: .purchase, on: "2026-02-03", amount: 1000, ref: "REF2"),
            makeNotice("cancel-1", source: .merpay, kind: .cancellation, on: "2026-02-03", amount: -1000, ref: "REF2"),
            // Apple receipt and duplicate card notice: only Apple receipt appears.
            makeNotice("apple-1", source: .apple, on: "2026-02-04", amount: 1200, merchant: "SAMPLE CLOUD", ref: "ORD9"),
            makeNotice("card-apple-dup", source: .merpay, on: "2026-02-04", amount: 1200, merchant: "DIGITAL STORE", orderID: "ORD9"),
            // Standalone settlement with no purchase: keeps its own messageID.
            makeNotice("settle-solo", source: .docomoDebit, kind: .settlement, on: "2026-02-05", amount: 4000, merchant: "METRO TELECOM", ref: "REF3"),
        ]

        let result = PendingBuilder.build(notices: notices, bundle: bundle, categorizer: categorizer, config: bundle.layerConfig)
        #expect(result.items.count == 4)
        #expect(result.noticeIDs == ["keep-boundary", "buy-settled", "apple-1", "settle-solo"])
        #expect(result.items.map(\.amount) == [1500, 3200, 1200, 4000])
        #expect(result.unmatched.map(\.messageID) == ["old-1"])

        // Input order must not change items or noticeIDs.
        let reversed = PendingBuilder.build(notices: notices.reversed(), bundle: bundle, categorizer: categorizer, config: bundle.layerConfig)
        #expect(reversed == result)
    }
}
