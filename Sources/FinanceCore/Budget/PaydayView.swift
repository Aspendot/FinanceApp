import Foundation

/// Cashflow summary for the current period leading up to the next payday.
public struct PaydayView: Codable, Sendable, Equatable {
    /// Total money in (`-sum` of `ins`).
    public var inSum: Int
    /// Total money out (`sum` of `outs`).
    public var outSum: Int
    /// Total borrowed money (`-sum` of `borrowed`).
    public var borrowedSum: Int
    /// Remaining cash before borrowing (`inSum - outSum`).
    public var left: Int
    /// Remaining cash including borrowed funds (`left + borrowedSum`).
    public var leftIfBorrowed: Int
    /// Whole Japan-time calendar days from `today` to `next.date`.
    public var daysToPayday: Int
    public var ins: [TimelineEntry]
    public var outs: [TimelineEntry]
    public var borrowed: [TimelineEntry]
    public var next: TimelineEntry

    public init(
        inSum: Int,
        outSum: Int,
        borrowedSum: Int,
        left: Int,
        leftIfBorrowed: Int,
        daysToPayday: Int,
        ins: [TimelineEntry],
        outs: [TimelineEntry],
        borrowed: [TimelineEntry],
        next: TimelineEntry
    ) {
        self.inSum = inSum
        self.outSum = outSum
        self.borrowedSum = borrowedSum
        self.left = left
        self.leftIfBorrowed = leftIfBorrowed
        self.daysToPayday = daysToPayday
        self.ins = ins
        self.outs = outs
        self.borrowed = borrowed
        self.next = next
    }

    /// Computes the payday view up to the first entry marked `next == true`.
    /// Returns nil when no entry is marked `next == true` or either date is invalid.
    public static func compute(timeline: [TimelineEntry], today: String) -> PaydayView? {
        guard let next = timeline.first(where: { $0.next == true }),
              let nextDay = JST.dayNumber(next.date),
              let todayDay = JST.dayNumber(today)
        else {
            return nil
        }

        let period = timeline.filter { $0.next != true && $0.date < next.date }
        let ins = period.filter { $0.amount < 0 && $0.borrowed != true && $0.cardBilled != true }
        let outs = period.filter { $0.amount > 0 && $0.cardBilled != true }
        let borrowed = period.filter { $0.borrowed == true }

        let inSum = -ins.reduce(0) { $0 + $1.amount }
        let outSum = outs.reduce(0) { $0 + $1.amount }
        let borrowedSum = -borrowed.reduce(0) { $0 + $1.amount }
        let left = inSum - outSum
        let leftIfBorrowed = left + borrowedSum

        return PaydayView(
            inSum: inSum,
            outSum: outSum,
            borrowedSum: borrowedSum,
            left: left,
            leftIfBorrowed: leftIfBorrowed,
            daysToPayday: nextDay - todayDay,
            ins: ins,
            outs: outs,
            borrowed: borrowed,
            next: next
        )
    }

    /// Convenience overload converting a `Date` to a Japan-time "YYYY-MM-DD" day.
    public static func compute(timeline: [TimelineEntry], today: Date) -> PaydayView? {
        compute(timeline: timeline, today: JST.day(today))
    }

    /// Sums layered spending items dated on or after `day` ("YYYY-MM-DD").
    ///
    /// When `config` is nil, an item counts if its `layer` is non-nil and non-empty.
    /// Pass `config` (and optionally `layers`) to resolve layers for items whose `layer`
    /// field was omitted in the bundle.
    public static func spentSince(
        day: String,
        items: [BudgetItem],
        config: LayerConfig? = nil,
        layers: [LayerDefinition] = []
    ) -> Int {
        var total = 0
        for item in items where item.date >= day {
            let resolved: String?
            if let config {
                resolved = config.resolvedLayer(for: item, layers: layers)
            } else {
                resolved = item.layer.flatMap { $0.isEmpty ? nil : $0 }
            }
            if resolved != nil {
                total += item.amount
            }
        }
        return total
    }
}

/// Live estimated balance for one bank account after post-coverage bank rows and unsettled debit notices.
public struct LiveAccountBalance: Identifiable, Sendable, Equatable {
    public var id: String { source }
    public var source: String
    public var label: String
    /// Confirmed balance exported by the PC pipeline as of `asOf`.
    public var confirmedBalance: Int
    /// Last statement date included in `confirmedBalance`.
    public var asOf: String
    /// Net change from confirmed post-coverage bank rows (`in - out`).
    public var postCoverageDelta: Int
    /// Net outflow from unsettled debit-card email notices linked to this bank account.
    public var pendingDebitOutflow: Int
    /// Live estimated balance (`confirmedBalance + postCoverageDelta - pendingDebitOutflow`).
    public var estimatedBalance: Int

    public init(
        source: String,
        label: String,
        confirmedBalance: Int,
        asOf: String,
        postCoverageDelta: Int,
        pendingDebitOutflow: Int,
        estimatedBalance: Int
    ) {
        self.source = source
        self.label = label
        self.confirmedBalance = confirmedBalance
        self.asOf = asOf
        self.postCoverageDelta = postCoverageDelta
        self.pendingDebitOutflow = pendingDebitOutflow
        self.estimatedBalance = estimatedBalance
    }
}

/// Single source of truth for real bank cash on hand and cash left until next payday after unpaid bills.
public struct LiveCashSummary: Sendable, Equatable {
    public var accounts: [LiveAccountBalance]
    /// Sum of confirmed bank balances from the bundle.
    public var confirmedBankCash: Int
    /// Sum of live estimated bank balances after post-coverage bank rows and pending debit notices.
    public var estimatedBankCash: Int
    /// Total unsettled debit-card email notices already subtracted from `estimatedBankCash`.
    public var pendingDebitOutflow: Int
    /// Scheduled bills before next payday that have not yet been paid (`done != true`).
    public var remainingBillsSum: Int
    public var remainingBillsCount: Int
    /// Scheduled bills marked paid only on the phone (no bank row yet), held back from cash left so checking
    /// a bill off manually never creates phantom extra cash before the bank debit posts.
    public var phoneCheckedBillsSum: Int
    /// Total scheduled bills still expected to leave bank accounts (`remainingBillsSum + phoneCheckedBillsSum`).
    public var unsettledBillsSum: Int { remainingBillsSum + phoneCheckedBillsSum }
    /// Confirmed non-borrowed inflows before next payday not yet received (`done != true` and `estimate != true`).
    public var remainingInflowsSum: Int
    /// Estimated or unconfirmed inflows before next payday (e.g. an unconfirmed bonus), kept OUT of
    /// guaranteed `cashLeftUntilPayday` so headline cash stays conservative.
    public var estimatedInflowsSum: Int
    /// Optional credit/borrowing headroom before next payday not yet drawn (`done != true`),
    /// combining standing usable credit rooms and unsettled planned borrowings.
    public var openBorrowedSum: Int
    /// Itemized sources making up `openBorrowedSum` (standing credit rooms + planned timeline borrowings).
    public var creditSources: [ComingUpCreditSource]
    /// Estimated cash left in banks until next payday after all unsettled bills (`estimatedBankCash + remainingInflowsSum - unsettledBillsSum`).
    public var cashLeftUntilPayday: Int
    /// Cash left if optional credit headroom were used (`cashLeftUntilPayday + openBorrowedSum`).
    public var cashLeftIfBorrowed: Int
    /// True whenever pending debit notices, post-coverage rows, phone checkoffs, or estimate bills are involved.
    public var isEstimate: Bool
    /// `BillCheckoff.key` values for bills whose bank debit already matched a post-`asOf` bank outflow,
    /// so timeline running balances avoid double-subtracting those entries.
    public var postBalanceMatchedKeys: Set<String>

    public init(
        accounts: [LiveAccountBalance],
        confirmedBankCash: Int,
        estimatedBankCash: Int,
        pendingDebitOutflow: Int,
        remainingBillsSum: Int,
        remainingBillsCount: Int,
        phoneCheckedBillsSum: Int,
        remainingInflowsSum: Int,
        estimatedInflowsSum: Int = 0,
        openBorrowedSum: Int,
        creditSources: [ComingUpCreditSource] = [],
        cashLeftUntilPayday: Int,
        cashLeftIfBorrowed: Int,
        isEstimate: Bool,
        postBalanceMatchedKeys: Set<String> = []
    ) {
        self.accounts = accounts
        self.confirmedBankCash = confirmedBankCash
        self.estimatedBankCash = estimatedBankCash
        self.pendingDebitOutflow = pendingDebitOutflow
        self.remainingBillsSum = remainingBillsSum
        self.remainingBillsCount = remainingBillsCount
        self.phoneCheckedBillsSum = phoneCheckedBillsSum
        self.remainingInflowsSum = remainingInflowsSum
        self.estimatedInflowsSum = estimatedInflowsSum
        self.openBorrowedSum = openBorrowedSum
        self.creditSources = creditSources
        self.cashLeftUntilPayday = cashLeftUntilPayday
        self.cashLeftIfBorrowed = cashLeftIfBorrowed
        self.isEstimate = isEstimate
        self.postBalanceMatchedKeys = postBalanceMatchedKeys
    }

    /// Returns true when an open timeline inflow should be counted in guaranteed `cashLeftUntilPayday`.
    /// Regular scheduled paydays (`payday == true`) stay counted for up to 5 days after their target date
    /// to cover normal bank/aggregator posting lag even when the PC export marks them `estimate: true`;
    /// non-payday estimated inflows (such as an unconfirmed bonus) stay out of guaranteed cash.
    @inline(never)
    public static func isConfirmedPendingInflow(
        _ entry: TimelineEntry,
        lastPayday: String?,
        today: String?
    ) -> Bool {
        guard entry.amount < 0,
              entry.done != true,
              entry.borrowed != true,
              entry.event != true,
              entry.cardBilled != true
        else { return false }
        if let lastPayday, entry.date < lastPayday { return false }
        if entry.payday == true {
            guard let today,
                  let todayNum = JST.dayNumber(today),
                  let entryNum = JST.dayNumber(entry.date)
            else { return true }
            return todayNum - entryNum <= 5
        }
        return entry.estimate != true
    }

    /// Returns true when a phone-checked bill should still hold cash back from `cashLeftUntilPayday`.
    /// Manual bills without a bank match rule release at the next pay cycle so they never hold cash forever;
    /// bank-matched bills release once their bank posting window passes (even within the same pay cycle).
    public static func isPhoneCheckedHoldActive(
        for entry: TimelineEntry,
        lastPayday: String?,
        today: String?
    ) -> Bool {
        if let lastPayday, entry.date < lastPayday {
            guard entry.match != nil else { return false }
        }
        if let match = entry.match,
           let today,
           let todayNum = JST.dayNumber(today),
           let entryNum = JST.dayNumber(entry.date)
        {
            let maxWindow = match.window.count == 2 ? max(match.window[1], 7) : 10
            if todayNum - entryNum > maxWindow {
                return false
            }
        }
        return true
    }

    public static func compute(
        accountBalances: [AccountBalance],
        creditRooms: [CreditRoom] = [],
        sourceLabels: [String: String],
        bankRows: [TimelineReconciler.BankRow],
        pendingItems: [BudgetItem],
        payday: PaydayView?,
        phoneCheckedBillKeys: Set<String> = [],
        lastPayday: String? = nil,
        consumedBankRows: [TimelineReconciler.BankRow] = [],
        notices: [Notice] = [],
        today: String? = nil
    ) -> LiveCashSummary? {
        guard !accountBalances.isEmpty else { return nil }

        // Build a multiset of rows already consumed by `TimelineReconciler` so the fallback
        // hold release below can never double-consume a single bank debit.
        struct RowSignature: Hashable {
            let source: String
            let date: String
            let amount: Int
        }
        var consumedCounts: [RowSignature: Int] = [:]
        for row in consumedBankRows {
            consumedCounts[RowSignature(source: row.source, date: row.date, amount: row.amount), default: 0] += 1
        }

        var liveAccounts: [LiveAccountBalance] = []
        var anyPostCoverageRows = false
        var postBalanceOutflows: [(dayNum: Int, amount: Int, foldedDescription: String)] = []

        for account in accountBalances {
            let resolvedLabel = sourceLabels[account.source] ?? account.label
            let bankNames: Set<String> = [account.source, account.label, resolvedLabel]

            // BankRow uses positive = money out, negative = money in.
            // Strictly honor `AccountBalance.asOf`: every confirmed bank row strictly after `asOf` adjusts balance.
            var matchingBankRows = bankRows.filter { row in
                row.date > account.asOf && bankNames.contains(row.source)
            }

            // When `asOfRowAmounts` is exported, also include any intraday rows on `account.asOf`
            // that remain after subtracting the multiset already baked into `account.balance`,
            // honoring `isPostSnapshotIntraday` even on partial bank feeds.
            if let snapshotAmounts = account.asOfRowAmounts {
                var snapshotPool: [Int: Int] = [:]
                for amt in snapshotAmounts { snapshotPool[amt, default: 0] += 1 }
                let sameDayRows = bankRows.filter { row in
                    row.date == account.asOf && bankNames.contains(row.source)
                }
                for row in sameDayRows {
                    if row.isPostSnapshotIntraday {
                        matchingBankRows.append(row)
                    } else if let remaining = snapshotPool[row.amount], remaining > 0 {
                        snapshotPool[row.amount] = remaining - 1
                    } else {
                        matchingBankRows.append(row)
                    }
                }
            }

            if !matchingBankRows.isEmpty {
                anyPostCoverageRows = true
                for row in matchingBankRows where row.amount > 0 {
                    let sig = RowSignature(source: row.source, date: row.date, amount: row.amount)
                    if let used = consumedCounts[sig], used > 0 {
                        consumedCounts[sig] = used - 1
                        continue
                    }
                    if let dayNum = JST.dayNumber(row.date) {
                        postBalanceOutflows.append((dayNum, row.amount, TextFold.key(row.description)))
                    }
                }
            }
            let postDelta = -matchingBankRows.reduce(0) { $0 + $1.amount }

            // Only unsettled debit-card notices linked to this bank reduce bank cash immediately
            // (including aggregator receipts like Apple that preserved `fundingSource`).
            // Deferred credit cards are paid via their scheduled monthly bills instead.
            var debitSourceNames = Set<String>()
            for rawKey in account.debitNoticeSources ?? [] where !rawKey.isEmpty {
                debitSourceNames.insert(rawKey)
                if let label = sourceLabels[rawKey], !label.isEmpty {
                    debitSourceNames.insert(label)
                }
            }
            let pendingOutflow: Int
            if debitSourceNames.isEmpty {
                pendingOutflow = 0
            } else {
                pendingOutflow = pendingItems
                    .filter { item in
                        guard item.isPending && item.date >= account.asOf else { return false }
                        if debitSourceNames.contains(item.source) { return true }
                        if let funding = item.fundingSource, debitSourceNames.contains(funding) { return true }
                        return false
                    }
                    .reduce(0) { $0 + $1.amount }
            }

            let estimated = account.balance + postDelta - pendingOutflow
            liveAccounts.append(LiveAccountBalance(
                source: account.source,
                label: account.label,
                confirmedBalance: account.balance,
                asOf: account.asOf,
                postCoverageDelta: postDelta,
                pendingDebitOutflow: pendingOutflow,
                estimatedBalance: estimated
            ))
        }

        let confirmedTotal = liveAccounts.reduce(0) { $0 + $1.confirmedBalance }
        let estimatedTotal = liveAccounts.reduce(0) { $0 + $1.estimatedBalance }
        let totalPendingDebit = liveAccounts.reduce(0) { $0 + $1.pendingDebitOutflow }

        // Release an unmatched manual bill (no `match` rule) only when an unconsumed post-asOf bank outflow
        // of the exact same positive amount posts near its due date AND shares a meaningful title token
        // (excluding generic platform/payment words like "amazon" or "apple"), so unrelated equal-amount
        // shop debits can never falsely clear a bill or release a hold.
        let genericBillWords: Set<String> = [
            "bill", "bills", "fee", "fees", "payment", "payments", "pay", "monthly",
            "plan", "card", "bank", "auto", "debit", "part", "tax", "with", "from",
            "amazon", "apple", "google", "rakuten", "yahoo", "line", "mercari", "merpay",
            "paypay", "store", "shop", "online", "service", "subscription", "premium", "plus", "pro",
        ]
        let tokenSeparators = CharacterSet(charactersIn: " /・+()（）「」『』,、:：-–—·•　")
        func descriptionMatchesEntry(_ foldedDesc: String, entry: TimelineEntry) -> Bool {
            guard !foldedDesc.isEmpty else { return false }
            let rawTokens = entry.item.components(separatedBy: tokenSeparators)
            for raw in rawTokens {
                let token = TextFold.key(raw)
                let minLen = token.allSatisfy(\.isASCII) ? 3 : 2
                guard token.count >= minLen, !genericBillWords.contains(token), !token.allSatisfy(\.isNumber) else {
                    continue
                }
                if foldedDesc.contains(token) { return true }
                if token.count >= 7, token.allSatisfy(\.isASCII), foldedDesc.contains(String(token.prefix(7))) {
                    return true
                }
            }
            return false
        }

        var availablePostOutflows = postBalanceOutflows
        func consumeMatchingPostOutflow(for entry: TimelineEntry) -> Bool {
            // Entries with an explicit `match` rule are settled exclusively by `TimelineReconciler`.
            guard entry.match == nil, entry.amount > 0, let entryDay = JST.dayNumber(entry.date) else { return false }
            if let idx = availablePostOutflows.firstIndex(where: {
                $0.amount == entry.amount
                    && (-2...5).contains($0.dayNum - entryDay)
                    && descriptionMatchesEntry($0.foldedDescription, entry: entry)
            }) {
                availablePostOutflows.remove(at: idx)
                return true
            }
            return false
        }

        var postBalanceMatchedKeys = Set<String>()
        let remainingBills = (payday?.outs ?? []).filter { entry in
            guard entry.done != true else { return false }
            if entry.match == nil, consumeMatchingPostOutflow(for: entry) {
                postBalanceMatchedKeys.insert(BillCheckoff.key(for: entry))
                return false
            }
            return true
        }
        let remainingBillsSum = remainingBills.reduce(0) { $0 + $1.amount }
        let phoneCheckedBills = (payday?.outs ?? []).filter { entry in
            let isPhoneChecked = entry.phoneChecked == true
                || BillCheckoff.matches(entry, in: phoneCheckedBillKeys)
            guard entry.done == true, isPhoneChecked else {
                return false
            }
            guard isPhoneCheckedHoldActive(for: entry, lastPayday: lastPayday, today: today) else {
                return false
            }
            // Once the debit actually posts after account.asOf, release the temporary phone hold.
            if consumeMatchingPostOutflow(for: entry) {
                postBalanceMatchedKeys.insert(BillCheckoff.key(for: entry))
                return false
            }
            return true
        }
        let phoneCheckedSum = phoneCheckedBills.reduce(0) { $0 + $1.amount }

        let openInflows = payday?.ins.filter { entry in
            guard entry.done != true && entry.borrowed != true else { return false }
            if let lastPayday, entry.date < lastPayday { return false }
            return true
        } ?? []
        var confirmedInflowsSum = 0
        var estimatedInflowsSum = 0
        for entry in openInflows {
            if isConfirmedPendingInflow(entry, lastPayday: lastPayday, today: today) {
                confirmedInflowsSum += -entry.amount
            } else {
                estimatedInflowsSum += -entry.amount
            }
        }

        // Build a 1-to-1 mutable pool of split-tender notices (e.g. Merpay credit vs points/balance) so
        // BOTH pending items and posted bank rows subtract only the credit-funded portion, without
        // letting an unrelated older split notice inflate credit room on a later full-credit purchase.
        struct SplitNoticeSlot {
            let sourceNames: Set<String>
            let date: String
            let dayNum: Int?
            let amount: Int
            let foldedMerchant: String
            let creditAmount: Int
            var used: Bool = false
        }
        struct FullCreditNoticeSlot {
            let sourceNames: Set<String>
            let date: String
            let dayNum: Int?
            let amount: Int
            let foldedMerchant: String
        }
        struct DatedCreditNotice {
            let sourceNames: Set<String>
            let date: String
            let amount: Int
            let foldedMerchant: String
            let receivedSeconds: Int64
            var used: Bool = false
        }

        func parseISOTimestampSeconds(_ text: String) -> Int64? {
            guard text.count >= 19, let tIdx = text.firstIndex(of: "T") else { return nil }
            let datePart = String(text[..<tIdx])
            guard let dayNum = JST.dayNumber(datePart) else { return nil }
            let afterT = String(text[text.index(after: tIdx)...])
            let hms = String(afterT.prefix(8)).split(separator: ":").compactMap { Int($0) }
            guard hms.count == 3, (0...23).contains(hms[0]), (0...59).contains(hms[1]), (0...60).contains(hms[2]) else {
                return nil
            }
            let rest = afterT.dropFirst(min(8, afterT.count))
            var offsetSeconds = 0
            if rest.contains("Z") || rest.contains("z") {
                offsetSeconds = 0
            } else if let signIdx = rest.firstIndex(where: { $0 == "+" || $0 == "-" }) {
                let sign = rest[signIdx] == "-" ? -1 : 1
                let tz = rest[rest.index(after: signIdx)...].split(separator: ":")
                if let tzH = tz.first.flatMap({ Int($0.prefix(2)) }) {
                    let tzM = tz.count >= 2 ? (Int(tz[1].prefix(2)) ?? 0) : 0
                    offsetSeconds = sign * (tzH * 3600 + tzM * 60)
                }
            }
            return Int64(dayNum) * 86_400 + Int64(hms[0] * 3600 + hms[1] * 60 + hms[2] - offsetSeconds)
        }

        func creditMerchantsAgree(_ a: String, _ b: String) -> Bool {
            guard !a.isEmpty, !b.isEmpty else { return false }
            if a == b || a.hasPrefix(b) || b.hasPrefix(a) { return true }
            return min(a.count, b.count) >= 4 && (a.contains(b) || b.contains(a))
        }

        let creditKeys = ["credit", "deferred"]
        var splitPool: [SplitNoticeSlot] = []
        var fullCreditNotices: [FullCreditNoticeSlot] = []
        var datedCreditNotices: [DatedCreditNotice] = []
        for notice in notices.sorted(by: { ($0.day, $0.receivedAt, $0.messageID) < ($1.day, $1.receivedAt, $1.messageID) }) {
            guard let amount = notice.amount else { continue }
            let srcLabel = sourceLabels[notice.source.rawValue] ?? notice.source.rawValue
            let names: Set<String> = [notice.source.rawValue, srcLabel]
            let rawMerch = (notice.merchant ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let foldedMerch = rawMerch == PendingBuilder.missingMerchantPlaceholder ? "" : TextFold.key(rawMerch)
            if let sec = parseISOTimestampSeconds(notice.receivedAt),
               [.purchase, .refund, .settlement].contains(notice.kind)
            {
                datedCreditNotices.append(DatedCreditNotice(
                    sourceNames: names,
                    date: notice.day,
                    amount: amount,
                    foldedMerchant: foldedMerch,
                    receivedSeconds: sec
                ))
            }
            if let parts = notice.parts, !parts.isEmpty {
                let hasExplicitCredit = creditKeys.contains { parts[$0] != nil }
                let hasNonCredit = parts.keys.contains { !creditKeys.contains($0) }
                if hasExplicitCredit || hasNonCredit {
                    let creditAmount = creditKeys.reduce(0) { $0 + (parts[$1] ?? 0) }
                    if creditAmount != amount {
                        splitPool.append(SplitNoticeSlot(
                            sourceNames: names,
                            date: notice.day,
                            dayNum: JST.dayNumber(notice.day),
                            amount: amount,
                            foldedMerchant: foldedMerch,
                            creditAmount: creditAmount
                        ))
                        continue
                    }
                }
            }
            if [.purchase, .settlement].contains(notice.kind) {
                fullCreditNotices.append(FullCreditNoticeSlot(
                    sourceNames: names,
                    date: notice.day,
                    dayNum: JST.dayNumber(notice.day),
                    amount: amount,
                    foldedMerchant: foldedMerch
                ))
            }
        }

        func hasMatchingFullCreditNotice(
            sources: Set<String>,
            date: String,
            dayNum: Int?,
            amount: Int,
            folded: String,
            allowDateSlack: Bool
        ) -> Bool {
            fullCreditNotices.contains { slot in
                guard slot.amount == amount, !slot.sourceNames.isDisjoint(with: sources) else { return false }
                let dateMatches: Bool
                if slot.date == date {
                    dateMatches = true
                } else if allowDateSlack, let d1 = dayNum, let d2 = slot.dayNum {
                    dateMatches = abs(d1 - d2) <= 2
                } else {
                    dateMatches = false
                }
                guard dateMatches else { return false }
                if !folded.isEmpty && !slot.foldedMerchant.isEmpty {
                    return creditMerchantsAgree(folded, slot.foldedMerchant)
                }
                return slot.date == date
            }
        }

        func consumeCreditComponent(
            sources: Set<String>,
            date: String,
            amount: Int,
            merchant: String,
            allowDateSlack: Bool,
            roomAsOf: String
        ) -> Int {
            let trimmed = merchant.trimmingCharacters(in: .whitespacesAndNewlines)
            let folded = trimmed == PendingBuilder.missingMerchantPlaceholder ? "" : TextFold.key(trimmed)
            let targetDay = JST.dayNumber(date)

            // Pass 1: exact date + merchant agreement.
            if !folded.isEmpty,
               let idx = splitPool.indices.first(where: { i in
                   let s = splitPool[i]
                   guard !s.used, s.amount == amount, s.date == date, !s.sourceNames.isDisjoint(with: sources) else {
                       return false
                   }
                   return creditMerchantsAgree(folded, s.foldedMerchant)
               })
            {
                splitPool[idx].used = true
                return splitPool[idx].creditAmount
            }

            // If an explicit full-credit notice matches this purchase, do not borrow an unrelated split notice.
            if hasMatchingFullCreditNotice(
                sources: sources, date: date, dayNum: targetDay, amount: amount,
                folded: folded, allowDateSlack: allowDateSlack
            ) {
                return amount
            }

            // Pass 2: exact date + amount ONLY when either side lacks a merchant name (never crossing two
            // distinct same-day merchants with the same total).
            if let idx = splitPool.indices.first(where: { i in
                let s = splitPool[i]
                guard !s.used, s.amount == amount, s.date == date, !s.sourceNames.isDisjoint(with: sources) else {
                    return false
                }
                return folded.isEmpty || s.foldedMerchant.isEmpty
            }) {
                splitPool[idx].used = true
                return splitPool[idx].creditAmount
            }

            // Pass 3: posted bank rows may settle 1-3 days after the email notice date, but require
            // merchant agreement (or an on/post-snapshot merchantless split within 1 day) so an
            // unrelated older split notice can never inflate credit room on a newer full-credit buy.
            if allowDateSlack, let targetDay {
                let candidates = splitPool.indices.compactMap { i -> (idx: Int, dist: Int)? in
                    let s = splitPool[i]
                    guard !s.used, s.amount == amount, !s.sourceNames.isDisjoint(with: sources),
                          let sDay = s.dayNum else { return nil }
                    let dist = abs(targetDay - sDay)
                    guard dist <= 3 else { return nil }
                    if !folded.isEmpty && !s.foldedMerchant.isEmpty {
                        guard creditMerchantsAgree(folded, s.foldedMerchant) else { return nil }
                        return (i, dist)
                    }
                    guard dist <= 1, s.date >= roomAsOf else { return nil }
                    return (i, dist)
                }
                if let best = candidates.min(by: { ($0.dist, $0.idx) < ($1.dist, $1.idx) }) {
                    splitPool[best.idx].used = true
                    return splitPool[best.idx].creditAmount
                }
            }
            return amount
        }

        var creditSources: [ComingUpCreditSource] = []
        for room in creditRooms {
            var liveAvailable = room.available
            if let asOf = room.asOf, !asOf.isEmpty, let keys = room.sourceKeys, !keys.isEmpty {
                var names = Set<String>()
                for rawKey in keys where !rawKey.isEmpty {
                    names.insert(rawKey)
                    if let label = sourceLabels[rawKey], !label.isEmpty {
                        names.insert(label)
                    }
                }
                var snapshotPool: [Int: Int]? = room.asOfRowAmounts.map { amounts in
                    var counts: [Int: Int] = [:]
                    for a in amounts { counts[a, default: 0] += 1 }
                    return counts
                }

                var postBankRows = bankRows.filter { $0.date > asOf && names.contains($0.source) }
                var postPendingItems = pendingItems.filter { item in
                    guard item.isPending && item.date > asOf else { return false }
                    if names.contains(item.source) { return true }
                    if let funding = item.fundingSource, names.contains(funding) { return true }
                    return false
                }
                if var pool = snapshotPool {
                    let sameDayBank = bankRows.filter { $0.date == asOf && names.contains($0.source) }
                    for row in sameDayBank {
                        if let rem = pool[row.amount], rem > 0 {
                            pool[row.amount] = rem - 1
                        } else {
                            postBankRows.append(row)
                        }
                    }
                    // On snapshot day, consume non-split pending items against `asOfRowAmounts` before
                    // split-tender notices so a full-credit snapshot charge absorbs the snapshot slot
                    // rather than mis-reserving a same-amount partial-credit purchase.
                    let sameDayPending = pendingItems.filter { item in
                        guard item.isPending && item.date == asOf else { return false }
                        return names.contains(item.source)
                            || (item.fundingSource.map { names.contains($0) } ?? false)
                    }
                    let hasSplitSlot: (BudgetItem) -> Bool = { item in
                        let trimmed = item.merchant.trimmingCharacters(in: .whitespacesAndNewlines)
                        let folded = trimmed == PendingBuilder.missingMerchantPlaceholder ? "" : TextFold.key(trimmed)
                        return splitPool.contains { slot in
                            !slot.used && slot.amount == item.amount && slot.date == item.date
                                && slot.creditAmount != item.amount
                                && (folded.isEmpty || slot.foldedMerchant.isEmpty
                                    || creditMerchantsAgree(folded, slot.foldedMerchant))
                        }
                    }
                    let orderedSameDayPending = sameDayPending.filter { !hasSplitSlot($0) }
                        + sameDayPending.filter { hasSplitSlot($0) }
                    for item in orderedSameDayPending {
                        if let rem = pool[item.amount], rem > 0 {
                            pool[item.amount] = rem - 1
                        } else {
                            postPendingItems.append(item)
                        }
                    }
                    snapshotPool = pool
                } else if let ts = room.asOfTimestamp, let overrideSec = parseISOTimestampSeconds(ts) {
                    // When a phone balance override recorded its exact timestamp, include same-day
                    // charges received strictly AFTER the override so spending later that day still
                    // draws down live credit room immediately.
                    var postOverridePool = datedCreditNotices.filter {
                        $0.date == asOf && $0.receivedSeconds > overrideSec && !$0.sourceNames.isDisjoint(with: names)
                    }
                    func consumePostOverride(amount: Int, merchant: String) -> Bool {
                        let trimmed = merchant.trimmingCharacters(in: .whitespacesAndNewlines)
                        let folded = trimmed == PendingBuilder.missingMerchantPlaceholder ? "" : TextFold.key(trimmed)
                        if !folded.isEmpty,
                           let idx = postOverridePool.indices.first(where: {
                               !postOverridePool[$0].used
                                   && postOverridePool[$0].amount == amount
                                   && creditMerchantsAgree(folded, postOverridePool[$0].foldedMerchant)
                           })
                        {
                            postOverridePool[idx].used = true
                            return true
                        }
                        if let idx = postOverridePool.indices.first(where: {
                            !postOverridePool[$0].used
                                && postOverridePool[$0].amount == amount
                                && (folded.isEmpty || postOverridePool[$0].foldedMerchant.isEmpty)
                        }) {
                            postOverridePool[idx].used = true
                            return true
                        }
                        return false
                    }
                    for row in bankRows where row.date == asOf && names.contains(row.source) {
                        if consumePostOverride(amount: row.amount, merchant: row.resolvedMerchant ?? row.description) {
                            postBankRows.append(row)
                        }
                    }
                    for item in pendingItems where item.isPending && item.date == asOf
                        && (names.contains(item.source) || (item.fundingSource.map { names.contains($0) } ?? false))
                    {
                        if consumePostOverride(amount: item.amount, merchant: item.merchant) {
                            postPendingItems.append(item)
                        }
                    }
                }

                let postBankSpend = postBankRows.reduce(0) { total, row in
                    total + consumeCreditComponent(
                        sources: names,
                        date: row.date,
                        amount: row.amount,
                        merchant: row.resolvedMerchant ?? row.description,
                        allowDateSlack: true,
                        roomAsOf: asOf
                    )
                }
                let postPendingSpend = postPendingItems.reduce(0) { total, item in
                    var itemSources: Set<String> = [item.source]
                    if let funding = item.fundingSource { itemSources.insert(funding) }
                    return total + consumeCreditComponent(
                        sources: itemSources.union(names),
                        date: item.date,
                        amount: item.amount,
                        merchant: item.merchant,
                        allowDateSlack: false,
                        roomAsOf: asOf
                    )
                }
                let raw = room.available - postBankSpend - postPendingSpend
                let capped = room.limit.map { min($0, raw) } ?? raw
                liveAvailable = max(0, capped)
            } else if let limit = room.limit {
                liveAvailable = max(0, min(limit, liveAvailable))
            }
            if liveAvailable > 0 {
                creditSources.append(ComingUpCreditSource(item: room.label, shortLabel: room.label, amount: liveAvailable))
            }
        }
        let openBorrowed = payday?.borrowed.filter { $0.done != true && $0.amount < 0 } ?? []
        for entry in openBorrowed {
            creditSources.append(ComingUpCreditSource(item: entry.item, amount: -entry.amount))
        }
        let openBorrowedSum = creditSources.reduce(0) { $0 + $1.amount }

        let cashLeft = estimatedTotal + confirmedInflowsSum - remainingBillsSum - phoneCheckedSum
        let hasEstimateLine = remainingBills.contains { $0.estimate == true }
            || openInflows.contains { isConfirmedPendingInflow($0, lastPayday: lastPayday, today: today) && $0.estimate == true }
        let isEstimate = totalPendingDebit != 0 || anyPostCoverageRows || phoneCheckedSum != 0 || hasEstimateLine

        return LiveCashSummary(
            accounts: liveAccounts,
            confirmedBankCash: confirmedTotal,
            estimatedBankCash: estimatedTotal,
            pendingDebitOutflow: totalPendingDebit,
            remainingBillsSum: remainingBillsSum,
            remainingBillsCount: remainingBills.count,
            phoneCheckedBillsSum: phoneCheckedSum,
            remainingInflowsSum: confirmedInflowsSum,
            estimatedInflowsSum: estimatedInflowsSum,
            openBorrowedSum: openBorrowedSum,
            creditSources: creditSources,
            cashLeftUntilPayday: cashLeft,
            cashLeftIfBorrowed: cashLeft + openBorrowedSum,
            isEstimate: isEstimate,
            postBalanceMatchedKeys: postBalanceMatchedKeys
        )
    }
}
