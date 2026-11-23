import Testing
@testable import FinanceCore

// Invented notices and rows.

private func notice(_ id: String, _ source: NoticeSource = .mufgDebit, kind: NoticeKind = .purchase,
                    received: String = "2026-01-15T12:00:00+09:00", at: String? = nil, on: String? = nil,
                    amount: Int?, merchant: String? = "SAMPLE STORE", ref: String? = nil) -> Notice {
    Notice(messageID: id, source: source, kind: kind, receivedAt: received, occurredAt: at, occurredOn: on,
           amount: amount, currency: "JPY", merchant: merchant, reference: ref, parser: "test/1")
}

private func row(_ id: String, _ source: NoticeSource = .mufgDebit, date: String = "2026-01-15",
                 amount: Int, merchant: String = "SAMPLE S", ref: String? = nil) -> StatementRow {
    StatementRow(id: id, source: source, date: date, amount: amount, merchant: merchant, reference: ref)
}

@Suite("Matcher")
struct MatcherTests {
    @Test func dayNumbers() {
        #expect(JST.dayNumber("1970-01-01") == 0)
        #expect(JST.dayNumber("2026-01-15") == 20468)
        #expect(JST.dayNumber("2024-03-01")! - JST.dayNumber("2024-02-28")! == 2)
        #expect(JST.dayNumber("2026-1-15") == nil)
    }

    @Test func referenceWinsOverAmountAndDate() {
        let r = Matcher.match(
            notices: [notice("n1", .docomoDebit, at: "2026-01-15T09:00:00+09:00", amount: 500, ref: "000111")],
            rows: [row("r1", .docomoDebit, amount: 500, ref: "000999"), row("r2", .docomoDebit, date: "2026-01-16", amount: 500, ref: "000111")])
        #expect(r.pairs == [MatchPair(noticeID: "n1", rowID: "r2", rule: .reference, merchantAgrees: true, dayOffset: 1)])
        #expect(r.rowOnly == ["r1"])
    }

    @Test func lateMufgNoticeStillMatches() {
        let r = Matcher.match(notices: [notice("n1", received: "2026-01-16T08:00:00+09:00", amount: 1200)],
                              rows: [row("r1", date: "2026-01-15", amount: 1200)])
        #expect(r.pairs.map(\.rowID) == ["r1"])
        #expect(r.pairs.first?.dayOffset == -1)
    }

    @Test func closerDayWinsBothWays() {
        let r = Matcher.match(
            notices: [notice("n1", received: "2026-01-14T12:00:00+09:00", amount: 500, merchant: "SHOP A"),
                      notice("n2", received: "2026-01-15T12:00:00+09:00", amount: 500, merchant: "SHOP B")],
            rows: [row("r1", date: "2026-01-15", amount: 500, merchant: "OTHER")])
        #expect(r.pairs.map(\.noticeID) == ["n2"])
        #expect(r.noticeOnly == ["n1"])
    }

    @Test func identicalPurchasesPairInOrder() {
        let r = Matcher.match(
            notices: [notice("n2", amount: 150), notice("n1", amount: 150)],
            rows: [row("r2", amount: 150), row("r1", amount: 150)])
        #expect(r.pairs.map { "\($0.noticeID)-\($0.rowID)" } == ["n1-r1", "n2-r2"])
        #expect(r.pairs.allSatisfy { $0.rule == .interchangeable })
        #expect(r.ambiguous.isEmpty)
    }

    @Test func realTieStaysUnresolved() {
        let r = Matcher.match(
            notices: [notice("n1", amount: 800, merchant: "SHOP A"), notice("n2", amount: 800, merchant: "SHOP B")],
            rows: [row("r1", amount: 800, merchant: "OTHER")])
        #expect(r.pairs.isEmpty)
        #expect(r.ambiguous == [AmbiguousGroup(noticeIDs: ["n1", "n2"], rowIDs: ["r1"])])
        #expect(r.rowOnly.isEmpty)
    }

    @Test func merchantAgreementBreaksATie() {
        let r = Matcher.match(
            notices: [notice("n1", amount: 800, merchant: "SAMPLE STORE"), notice("n2", amount: 800, merchant: "OTHER SHOP")],
            rows: [row("r1", amount: 800, merchant: "SAMPLE S")])
        #expect(r.pairs.map(\.noticeID) == ["n1"])
        #expect(r.noticeOnly == ["n2"])
    }

    @Test func outsideTheWindowIsNoticeOnly() {
        let r = Matcher.match(notices: [notice("n1", amount: 300)], rows: [row("r1", date: "2026-01-18", amount: 300)])
        #expect(r.noticeOnly == ["n1"])
        #expect(r.rowOnly == ["r1"])
    }

    @Test func docomoSettlements() {
        let purchase = notice("n1", .docomoDebit, at: "2026-01-10T10:00:00+09:00", amount: 1000, ref: "000111")
        let adjustment = notice("n2", .docomoDebit, kind: .settlement, on: "2026-01-10", amount: 1000, ref: "000111")
        let newCharge = notice("n3", .docomoDebit, kind: .settlement, on: "2026-01-12", amount: 2500, ref: "000222")
        let r = Matcher.match(notices: [purchase, adjustment, newCharge],
                              rows: [row("r1", .docomoDebit, date: "2026-01-10", amount: 1000),
                                     row("r2", .docomoDebit, date: "2026-01-12", amount: 2500)])
        #expect(r.adjustments == ["n2"])
        #expect(Set(r.pairs.map { "\($0.noticeID)-\($0.rowID)" }) == ["n1-r1", "n3-r2"])
    }

    @Test func nonSpendingIsSetAside() {
        let r = Matcher.match(
            notices: [notice("n1", .merpay, kind: .decline, amount: 600), notice("n2", .merpay, kind: .topUp, amount: 10000),
                      notice("n3", .merpay, kind: .billPaid, amount: nil)],
            rows: [row("r1", .merpay, amount: 600)])
        #expect(r.notSpending == ["n1", "n2", "n3"])
        #expect(r.rowOnly == ["r1"])
    }

    @Test func inputOrderDoesNotMatter() {
        let notices = [notice("n1", amount: 150), notice("n2", amount: 150), notice("n3", amount: 900, merchant: "X"),
                       notice("n4", received: "2026-01-16T09:00:00+09:00", amount: 900, merchant: "Y")]
        let rows = [row("r1", amount: 150), row("r2", amount: 150), row("r3", date: "2026-01-16", amount: 900, merchant: "Z")]
        let a = Matcher.match(notices: notices, rows: rows)
        let b = Matcher.match(notices: notices.reversed(), rows: rows.reversed())
        #expect(a == b)
        #expect(a.pairs.contains { $0.noticeID == "n4" && $0.rowID == "r3" })
    }
}
