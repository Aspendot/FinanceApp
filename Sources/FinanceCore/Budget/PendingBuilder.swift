import Foundation

/// Output of `PendingBuilder.build`: pending budget items and pre-coverage notices for review.
public struct PendingResult: Sendable, Equatable {
    /// Pending spending items dated on or after their source's coverage end.
    public var items: [BudgetItem]
    /// Gmail message ID of the notice that produced each item in `items`, in the same order.
    public var noticeIDs: [String]
    /// Eligible notices dated before their source's coverage end.
    public var unmatched: [Notice]

    public init(items: [BudgetItem] = [], noticeIDs: [String] = [], unmatched: [Notice] = []) {
        self.items = items
        self.noticeIDs = noticeIDs
        self.unmatched = unmatched
    }
}

/// Converts live `Notice` records into pending `BudgetItem`s using the same rules as the PC pipeline.
public enum PendingBuilder {
    public static let missingMerchantPlaceholder = "(no merchant name in the notice)"

    /// Keeps recent history and any older notices that may still affect pending totals.
    public static func retainNotices(_ newestFirst: [Notice], bundle: DataBundle?, historyLimit: Int) -> [Notice] {
        let limit = max(0, historyLimit)
        guard newestFirst.count > limit else { return newestFirst }

        func isUncovered(_ notice: Notice) -> Bool {
            guard let coverage = bundle?.coverage[notice.source.rawValue] else { return true }
            return notice.day >= coverage.end
        }

        func references(_ notice: Notice) -> [String] {
            [notice.reference, notice.relatedReference].compactMap(nonEmpty).map { "\(notice.source.rawValue)|\($0)" }
        }

        let pending = newestFirst.filter { isPaymentNotice($0) && isUncovered($0) }
        let pendingRefs = Set(pending.flatMap(references))
        let receiptOrders = Set(pending.filter { $0.source == .apple }.compactMap { nonEmpty($0.reference) })
        let cardOrders = Set(pending.filter { $0.source != .apple }.compactMap { nonEmpty($0.orderID) })
        let receiptDays = pending.filter { $0.source == .apple }.compactMap { JST.dayNumber($0.day) }
        let appleCardDays = pending.filter {
            $0.source != .apple && TextFold.key($0.merchant ?? "").contains("apple")
        }.compactMap { JST.dayNumber($0.day) }

        return Array(newestFirst.prefix(limit)) + newestFirst.dropFirst(limit).filter { notice in
            guard isPaymentNotice(notice) else { return false }
            if isUncovered(notice) || !pendingRefs.isDisjoint(with: references(notice)) {
                return true
            }
            let isReceipt = notice.source == .apple
            let orders = isReceipt ? cardOrders : receiptOrders
            if let order = nonEmpty(isReceipt ? notice.reference : notice.orderID), orders.contains(order) {
                return true
            }
            guard isReceipt || TextFold.key(notice.merchant ?? "").contains("apple"),
                  let day = JST.dayNumber(notice.day) else { return false }
            let otherDays = isReceipt ? appleCardDays : receiptDays
            return otherDays.contains { abs($0 - day) <= 3 }
        }
    }

    private static func isPaymentNotice(_ notice: Notice) -> Bool {
        guard notice.amount != nil else { return false }
        switch notice.kind {
        case .purchase, .refund, .settlement, .cancellation: return true
        default: return false
        }
    }

    /// Returns only the pending items from `build(notices:bundle:categorizer:config:)`.
    public static func items(
        notices: [Notice],
        bundle: DataBundle,
        categorizer: Categorizer,
        config: LayerConfig
    ) -> [BudgetItem] {
        build(notices: notices, bundle: bundle, categorizer: categorizer, config: config).items
    }

    /// One post-bundle candidate notice after cancellations, settlements, Apple deduplication,
    /// and bundle coverage filtering.
    struct CandidateNotice: Sendable {
        let notice: Notice
        let sourceID: String
        let sourceLabel: String
        let day: String
        let amount: Int
    }

    /// Returns candidate notices after bundle-level filtering, plus pre-bundle unmatched notices.
    static func postBundleCandidates(
        notices: [Notice],
        bundle: DataBundle
    ) -> (candidates: [CandidateNotice], unmatched: [Notice]) {
        let sorted = notices.sorted { $0.messageID < $1.messageID }

        // Keep only purchase, refund, settlement and cancellation notices with a yen amount.
        let eligible = sorted.filter(isPaymentNotice)

        // Pair cancellations with purchases of the same source and reference.
        var purchasesBySourceRef: [String: [String]] = [:]
        var allPurchaseSourceRefs: Set<String> = []
        for notice in eligible where notice.kind == .purchase {
            if let r = nonEmpty(notice.reference) {
                let key = "\(notice.source.rawValue)|\(r)"
                purchasesBySourceRef[key, default: []].append(notice.messageID)
                allPurchaseSourceRefs.insert(key)
            }
        }

        var calledOff: Set<String> = []
        for notice in eligible where notice.kind == .cancellation {
            let refs = [notice.reference, notice.relatedReference].compactMap(nonEmpty)
            for r in refs {
                let key = "\(notice.source.rawValue)|\(r)"
                if let purchaseID = purchasesBySourceRef[key]?.first(where: { !calledOff.contains($0) }) {
                    calledOff.insert(purchaseID)
                    calledOff.insert(notice.messageID)
                    break
                }
            }
        }

        // Latest settlement (by receivedAt, then messageID) with the same source and
        // reference as a purchase replaces that purchase's amount and is not emitted itself.
        var settledAmount: [String: Int] = [:]
        for notice in eligible.sorted(by: { ($0.receivedAt, $0.messageID) < ($1.receivedAt, $1.messageID) })
        where notice.kind == .settlement && !calledOff.contains(notice.messageID) {
            if let r = nonEmpty(notice.reference), let amount = notice.amount {
                let key = "\(notice.source.rawValue)|\(r)"
                if allPurchaseSourceRefs.contains(key) {
                    settledAmount[key] = amount
                }
            }
        }

        var surviving: [(notice: Notice, amount: Int)] = []
        for notice in eligible where !calledOff.contains(notice.messageID) {
            if notice.kind == .settlement, let r = nonEmpty(notice.reference),
               allPurchaseSourceRefs.contains("\(notice.source.rawValue)|\(r)") {
                continue
            }
            let amount: Int
            if notice.kind == .purchase, let r = nonEmpty(notice.reference),
               let updated = settledAmount["\(notice.source.rawValue)|\(r)"] {
                amount = updated
            } else if let original = notice.amount {
                amount = original
            } else {
                continue
            }
            surviving.append((notice, amount))
        }

        // Apple receipts used to suppress duplicate card notices.
        let appleReceipts = surviving.filter { $0.notice.source == .apple }
        let appleOrderIDs = Set(appleReceipts.compactMap { nonEmpty($0.notice.reference) })
        let appleByAmount: [(amount: Int, dayNumber: Int?)] = appleReceipts.map {
            ($0.amount, JST.dayNumber($0.notice.day))
        }

        func isAppleDuplicate(_ notice: Notice, amount: Int) -> Bool {
            guard notice.source != .apple else { return false }
            if let orderID = nonEmpty(notice.orderID), appleOrderIDs.contains(orderID) {
                return true
            }
            let foldedMerchant = TextFold.key(notice.merchant ?? "")
            guard foldedMerchant.contains("apple"), let noticeDay = JST.dayNumber(notice.day) else {
                return false
            }
            return appleByAmount.contains { receipt in
                guard receipt.amount == amount, let receiptDay = receipt.dayNumber else {
                    return false
                }
                return abs(noticeDay - receiptDay) <= 3
            }
        }

        // Multiset of existing bundle items for boundary-day deduplication.
        var boundaryPool: [BoundaryKey: Int] = [:]
        for item in bundle.items {
            let key = BoundaryKey(source: item.source, date: item.date, amount: item.amount)
            boundaryPool[key, default: 0] += 1
        }

        let ordered = surviving.sorted {
            ($0.notice.day, $0.notice.receivedAt, $0.notice.messageID)
                < ($1.notice.day, $1.notice.receivedAt, $1.notice.messageID)
        }

        var candidates: [CandidateNotice] = []
        var unmatched: [Notice] = []

        for (notice, amount) in ordered {
            if isAppleDuplicate(notice, amount: amount) {
                continue
            }

            let sourceID = notice.source.rawValue
            let sourceLabel = bundle.sourceLabels[sourceID] ?? sourceID
            let day = notice.day

            if let coverage = bundle.coverage[sourceID] {
                if day < coverage.end {
                    unmatched.append(notice)
                    continue
                }
                if day == coverage.end {
                    let key = BoundaryKey(source: sourceLabel, date: day, amount: amount)
                    if let remaining = boundaryPool[key], remaining > 0 {
                        boundaryPool[key] = remaining - 1
                        continue
                    }
                }
            }

            candidates.append(CandidateNotice(
                notice: notice,
                sourceID: sourceID,
                sourceLabel: sourceLabel,
                day: day,
                amount: amount
            ))
        }

        return (candidates, unmatched)
    }

    static func makePendingItem(
        from candidate: CandidateNotice,
        bundle: DataBundle,
        categorizer: Categorizer,
        config: LayerConfig
    ) -> BudgetItem {
        let merchant = nonEmpty(candidate.notice.merchant) ?? missingMerchantPlaceholder
        let (group, category) = categorizer.categorize(merchant: merchant, amount: candidate.amount, date: candidate.day)
        let layer = config.layer(group: group, category: category, layers: bundle.layers)

        return BudgetItem(
            date: candidate.day,
            source: candidate.sourceLabel,
            merchant: merchant,
            amount: candidate.amount,
            group: group,
            category: category,
            layer: layer,
            isPending: true
        )
    }

    /// Turns live notices into pending `BudgetItem`s and collects pre-coverage notices in `unmatched`.
    public static func build(
        notices: [Notice],
        bundle: DataBundle,
        categorizer: Categorizer,
        config: LayerConfig
    ) -> PendingResult {
        let (candidates, unmatched) = postBundleCandidates(notices: notices, bundle: bundle)
        let pendingItems = candidates.map { makePendingItem(from: $0, bundle: bundle, categorizer: categorizer, config: config) }
        let noticeIDs = candidates.map(\.notice.messageID)
        return PendingResult(items: pendingItems, noticeIDs: noticeIDs, unmatched: unmatched)
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }
}

private struct BoundaryKey: Hashable {
    let source: String
    let date: String
    let amount: Int
}
