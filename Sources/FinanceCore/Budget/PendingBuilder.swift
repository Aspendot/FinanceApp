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
        /// Underlying card/debit source key when an aggregator receipt (e.g. Apple) suppressed a card notice.
        let fundingSourceID: String?
    }

    /// Returns candidate notices after bundle-level filtering, plus pre-bundle unmatched notices.
    static func postBundleCandidates(
        notices: [Notice],
        bundle: DataBundle,
        applyCancellations: Bool = true,
        confirmedPurchaseIDs: Set<String> = []
    ) -> (candidates: [CandidateNotice], unmatched: [Notice]) {
        let sorted = notices.sorted { $0.messageID < $1.messageID }

        // Keep only purchase, refund, settlement and cancellation notices with a yen amount.
        let eligible = sorted.filter(isPaymentNotice)

        // Pair cancellations with purchases of the same source and reference.
        var purchasesBySourceRef: [String: [String]] = [:]
        var allPurchaseSourceRefs: Set<String> = []
        var coveredPurchaseIDs = confirmedPurchaseIDs
        for notice in eligible where notice.kind == .purchase {
            if let r = nonEmpty(notice.reference) {
                let key = "\(notice.source.rawValue)|\(r)"
                purchasesBySourceRef[key, default: []].append(notice.messageID)
                allPurchaseSourceRefs.insert(key)
                if let coverage = bundle.coverage[notice.source.rawValue], notice.day < coverage.end {
                    coveredPurchaseIDs.insert(notice.messageID)
                }
            }
        }

        var calledOff: Set<String> = []
        for notice in eligible where applyCancellations && notice.kind == .cancellation {
            let refs = [notice.reference, notice.relatedReference].compactMap(nonEmpty)
            for r in refs {
                let key = "\(notice.source.rawValue)|\(r)"
                if let purchaseID = purchasesBySourceRef[key]?.first(where: { !calledOff.contains($0) }) {
                    if coveredPurchaseIDs.contains(purchaseID) { break }
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

        // Link Apple receipts 1-to-1 ONLY to post-coverage card/debit notices so an already-covered
        // historical debit notice (e.g. from days before coverage end) can never steal a newer Apple
        // receipt, and two separate card debits never collapse onto a single Apple receipt.
        let ordered = surviving.sorted {
            ($0.notice.day, $0.notice.receivedAt, $0.notice.messageID)
                < ($1.notice.day, $1.notice.receivedAt, $1.notice.messageID)
        }

        func isPostCoverage(_ notice: Notice) -> Bool {
            guard let cov = bundle.coverage[notice.source.rawValue] else { return true }
            return notice.day >= cov.end
        }

        let appleReceipts = ordered.filter { $0.notice.source == .apple && isPostCoverage($0.notice) }
        var appleReceiptIDByOrderID: [String: String] = [:]
        for receipt in appleReceipts {
            if let orderID = nonEmpty(receipt.notice.reference), appleReceiptIDByOrderID[orderID] == nil {
                appleReceiptIDByOrderID[orderID] = receipt.notice.messageID
            }
        }
        let appleByAmount: [(messageID: String, amount: Int, dayNumber: Int?)] = appleReceipts.map {
            ($0.notice.messageID, $0.amount, JST.dayNumber($0.notice.day))
        }

        var fundingSourceByAppleReceiptID: [String: String] = [:]
        var claimedAppleReceiptIDs = Set<String>()
        var suppressedCardNoticeIDs = Set<String>()

        // Pass 1: exact orderID matches first (post-coverage card notices only).
        for (notice, _) in ordered where notice.source != .apple && isPostCoverage(notice) {
            if let orderID = nonEmpty(notice.orderID),
               let receiptID = appleReceiptIDByOrderID[orderID],
               claimedAppleReceiptIDs.insert(receiptID).inserted
            {
                suppressedCardNoticeIDs.insert(notice.messageID)
                fundingSourceByAppleReceiptID[receiptID] = notice.source.rawValue
            }
        }
        // Pass 2: nearest unclaimed Apple receipt by amount and ±3 days for post-coverage Apple-branded card notices.
        for (notice, amount) in ordered where notice.source != .apple && isPostCoverage(notice) && !suppressedCardNoticeIDs.contains(notice.messageID) {
            guard isAppleBillingDescriptor(notice.merchant ?? ""), let noticeDay = JST.dayNumber(notice.day) else { continue }
            let hits = appleByAmount.compactMap { receipt -> (id: String, dist: Int)? in
                guard !claimedAppleReceiptIDs.contains(receipt.messageID),
                      receipt.amount == amount,
                      let receiptDay = receipt.dayNumber
                else { return nil }
                let dist = abs(noticeDay - receiptDay)
                return dist <= 3 ? (receipt.messageID, dist) : nil
            }
            if let best = hits.min(by: { ($0.dist, $0.id) < ($1.dist, $1.id) }),
               claimedAppleReceiptIDs.insert(best.id).inserted
            {
                suppressedCardNoticeIDs.insert(notice.messageID)
                fundingSourceByAppleReceiptID[best.id] = notice.source.rawValue
            }
        }

        // Multiset of confirmed statement bundle items (excluding phone manual entries) preserving full
        // folded text, annotation-stripped base text, and normalized raw base text for uncovered-window
        // deduplication. Requires exact folded equality or a bank-style truncation prefix (>= 7 folded chars,
        func extractBundleApprovalRef(for item: BudgetItem) -> String? {
            if let ref = item.reference?.trimmingCharacters(in: .whitespacesAndNewlines), !ref.isEmpty {
                return ref
            }
            let full = TextFold.key(item.merchant)
            guard full.contains("nonameyet") else { return nil }
            let base = TextFold.key(stripTrailingAnnotation(item.merchant))
            guard base.count >= 6 else { return nil }
            let suffix = String(base.suffix(6))
            return suffix.allSatisfy({ $0.isASCII && $0.isNumber }) ? suffix : nil
        }

        func boundaryRefsCompatible(_ noticeRef: String?, _ bundleRef: String?) -> Bool {
            guard let n = noticeRef, !n.isEmpty, let b = bundleRef, !b.isEmpty else { return true }
            return n == b
        }

        // never matching short prefixes like "CAFE" against "CAFE ROASTERS" or branch suffixes like "CAFE1234 WEST").
        var bundlePool: [BoundaryKey: [(full: String, base: String, rawBase: String, reference: String?)]] = [:]
        for item in bundle.items where item.isManual != true {
            let key = BoundaryKey(source: item.source, date: item.date, amount: item.amount)
            let rawBase = stripTrailingAnnotation(item.merchant)
            let full = TextFold.key(item.merchant)
            let base = TextFold.key(rawBase)
            let ref = extractBundleApprovalRef(for: item)
            bundlePool[key, default: []].append((full: full, base: base, rawBase: rawBase, reference: ref))
        }

        func consumeBundleDuplicate(
            key: BoundaryKey,
            noticeMerchant: String?,
            noticeReference: String? = nil,
            exactOnly: Bool = false
        ) -> Bool {
            guard var entries = bundlePool[key], !entries.isEmpty else { return false }
            let nRef: String? = {
                guard let raw = noticeReference?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
                return raw
            }()
            // Exact approval-reference match takes precedence over merchant or empty fallbacks.
            if let nRef, let refIdx = entries.firstIndex(where: { $0.reference == nRef }) {
                entries.remove(at: refIdx)
                bundlePool[key] = entries
                return true
            }
            let rawNotice = noticeMerchant == missingMerchantPlaceholder ? "" : (noticeMerchant ?? "")
            let strippedNotice = stripTrailingAnnotation(rawNotice)
            let foldedNotice = TextFold.key(rawNotice)
            let foldedNoticeBase = TextFold.key(strippedNotice)
            // Prefer exact or bank-truncation merchant match on ref-compatible items first.
            if !foldedNotice.isEmpty,
               let exactIdx = entries.firstIndex(where: {
                   boundaryRefsCompatible(nRef, $0.reference) && merchantsMatchForBoundaryDedupe(
                       rawA: strippedNotice,
                       foldedFullA: foldedNotice,
                       foldedBaseA: foldedNoticeBase,
                       rawB: $0.rawBase,
                       foldedFullB: $0.full,
                       foldedBaseB: $0.base
                   )
               })
            {
                entries.remove(at: exactIdx)
                bundlePool[key] = entries
                return true
            }
            // Only allow fallback deduplication when either side has no merchant text at all
            // and approval references do not conflict.
            if !exactOnly,
               let emptyIdx = entries.firstIndex(where: {
                   boundaryRefsCompatible(nRef, $0.reference) && (foldedNotice.isEmpty || $0.full.isEmpty)
               })
            {
                entries.remove(at: emptyIdx)
                bundlePool[key] = entries
                return true
            }
            return false
        }

        func jstHour(from isoTimestamp: String) -> Int? {
            guard let tIndex = isoTimestamp.firstIndex(of: "T") else { return nil }
            let afterT = String(isoTimestamp[isoTimestamp.index(after: tIndex)...])
            let hm = afterT.prefix(8).split(separator: ":")
            guard hm.count >= 2, let rawH = Int(hm[0]), let rawM = Int(hm[1]),
                  (0...23).contains(rawH), (0...59).contains(rawM) else { return nil }
            let rest = afterT.dropFirst(min(8, afterT.count))
            var offsetMinutes = 9 * 60
            if rest.contains("Z") || rest.contains("z") {
                offsetMinutes = 0
            } else if let signIdx = rest.firstIndex(where: { $0 == "+" || $0 == "-" }) {
                let sign = rest[signIdx] == "-" ? -1 : 1
                let tzParts = rest[rest.index(after: signIdx)...].split(separator: ":")
                if let tzH = tzParts.first.flatMap({ Int($0.prefix(2)) }) {
                    let tzM = tzParts.count >= 2 ? (Int(tzParts[1].prefix(2)) ?? 0) : 0
                    offsetMinutes = sign * (tzH * 60 + tzM)
                }
            }
            let totalJST = rawH * 60 + rawM + (9 * 60 - offsetMinutes)
            return (((totalJST % 1440) + 1440) % 1440) / 60
        }

        var candidates: [CandidateNotice] = []
        var unmatched: [Notice] = []

        for (notice, amount) in ordered {
            if suppressedCardNoticeIDs.contains(notice.messageID) {
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
                // Deduplicate against already-exported bundle items across the entire uncovered window
                // (not only on the exact coverage.end day), preventing double-counting when a manual
                // extract includes rows newer than its header read date.
                let key = BoundaryKey(source: sourceLabel, date: day, amount: amount)
                if consumeBundleDuplicate(key: key, noticeMerchant: notice.merchant, noticeReference: notice.reference) {
                    continue
                }
                // Email-only debit notices for late-night purchases on `coverage.end` can arrive
                // overnight (00:03) or in a next-morning batch (09:02 JST). Avoid emitting a duplicate
                // pending item when an unconsumed bundle item with the same merchant already exists on `coverage.end`.
                if notice.occurredAt == nil && notice.occurredOn == nil,
                   let nextAfterCoverage = JST.addingDays(1, to: coverage.end),
                   day == nextAfterCoverage,
                   let hour = jstHour(from: notice.receivedAt),
                   hour < 10
                {
                    let prevKey = BoundaryKey(source: sourceLabel, date: coverage.end, amount: amount)
                    if consumeBundleDuplicate(key: prevKey, noticeMerchant: notice.merchant, noticeReference: notice.reference, exactOnly: true) {
                        continue
                    }
                }
            } else {
                let key = BoundaryKey(source: sourceLabel, date: day, amount: amount)
                if consumeBundleDuplicate(key: key, noticeMerchant: notice.merchant, noticeReference: notice.reference) {
                    continue
                }
            }

            candidates.append(CandidateNotice(
                notice: notice,
                sourceID: sourceID,
                sourceLabel: sourceLabel,
                day: day,
                amount: amount,
                fundingSourceID: fundingSourceByAppleReceiptID[notice.messageID]
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
            isPending: true,
            fundingSource: candidate.fundingSourceID
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

    /// Strips a trailing space-separated parenthetical annotation (such as `"MERCHANT (note)"` -> `"MERCHANT"`).
    static func stripTrailingAnnotation(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix(")") else { return trimmed }
        var depth = 0
        var openIdx: String.Index?
        var idx = trimmed.endIndex
        while idx > trimmed.startIndex {
            idx = trimmed.index(before: idx)
            let ch = trimmed[idx]
            if ch == ")" {
                depth += 1
            } else if ch == "(" {
                depth -= 1
                if depth == 0 {
                    openIdx = idx
                    break
                }
            }
        }
        guard let openIdx, openIdx > trimmed.startIndex else { return trimmed }
        let beforeOpen = trimmed.index(before: openIdx)
        guard trimmed[beforeOpen].isWhitespace else { return trimmed }
        let base = trimmed[..<openIdx].trimmingCharacters(in: .whitespacesAndNewlines)
        return base.isEmpty ? trimmed : base
    }

    /// Collapses whitespace after NFKC compatibility folding and lowercasing, preserving word boundaries.
    static func normalizeMerchantSpacing(_ raw: String) -> String {
        raw.precomposedStringWithCompatibilityMapping
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// True when `shortFolded` is a bank-style truncation prefix of `longFolded` (>= 7 folded chars,
    /// allowing mid-word cuts and 8-char corporate/country suffixes while rejecting short prefixes like
    /// `"CAFE"` -> `"CAFEBLUE"` or distinct branch extensions like `"CAFE1234"` -> `"CAFE1234 WEST"`).
    static func isBankTruncationPrefix(
        shortRaw: String,
        shortFolded: String,
        longRaw: String,
        longFolded: String
    ) -> Bool {
        guard shortFolded.count >= 7, longFolded.hasPrefix(shortFolded) else { return false }
        let sNorm = normalizeMerchantSpacing(shortRaw)
        let lNorm = normalizeMerchantSpacing(longRaw)
        if lNorm.hasPrefix(sNorm + " ") {
            let shortTrimmed = shortRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard shortTrimmed.count == 8 else { return false }
            let suffixPart = lNorm.dropFirst(sNorm.count + 1)
            let tailWords = suffixPart.split(separator: " ").map(String.init)
            let corpCountrySuffixes: Set<String> = ["jp", "jpn", "japan", "co", "inc", "ltd", "llc", "corp"]
            return !tailWords.isEmpty && tailWords.allSatisfy { corpCountrySuffixes.contains($0) }
        }
        return true
    }

    /// Shared strict boundary merchant matcher used by both `PendingBuilder` and `BankLayering`.
    static func merchantsMatchForBoundaryDedupe(
        rawA: String,
        foldedFullA: String,
        foldedBaseA: String,
        rawB: String,
        foldedFullB: String,
        foldedBaseB: String
    ) -> Bool {
        guard !foldedFullA.isEmpty, !foldedFullB.isEmpty else { return false }
        if foldedFullA == foldedFullB
            || (!foldedBaseB.isEmpty && foldedFullA == foldedBaseB)
            || (!foldedBaseA.isEmpty && foldedBaseA == foldedFullB)
            || (!foldedBaseA.isEmpty && !foldedBaseB.isEmpty && foldedBaseA == foldedBaseB)
        {
            return true
        }
        let aFold = foldedBaseA.isEmpty ? foldedFullA : foldedBaseA
        let bFold = foldedBaseB.isEmpty ? foldedFullB : foldedBaseB
        if isBankTruncationPrefix(shortRaw: rawB, shortFolded: bFold, longRaw: rawA, longFolded: aFold) {
            return true
        }
        if isBankTruncationPrefix(shortRaw: rawA, shortFolded: aFold, longRaw: rawB, longFolded: bFold) {
            return true
        }
        return false
    }

    private static let appleASCIIBillingRegex: NSRegularExpression = {
        let pattern = #"(?<![a-z])(?:"#
            + #"apple\.com(?=$|[ /])|"#
            + #"apple\.co(?=$|[ /]|\.jp(?=$|[ /]))|"#
            + #"apple *com *bill(?![a-z\-])|"#
            + #"apple *bill(?![a-z\-])|"#
            + #"apple *サ-ビス|"#
            + #"apple *store(?![a-z\-])|"#
            + #"app *store(?![a-z\-])|"#
            + #"apple *music(?![a-z\-])|"#
            + #"apple *tv(?![a-z\-])|"#
            + #"apple *one(?![a-z\-])|"#
            + #"apple *care(?![a-z\-])|"#
            + #"icloud(?:$|\+| *[0-9]| *(?:storage|plus|mail|drive|backup|ストレ-ジ|メ-ル|ドライブ|バツクアツプ)(?![a-z\-]))|"#
            + #"itunes(?:$|[\./\+]| *(?:store|bill|card|gift|music|ストア|ビル)(?![a-z\-]))"#
            + #")"#
        return try! NSRegularExpression(pattern: pattern, options: [])
    }()

    private static let appleKanaBillingRegex: NSRegularExpression = {
        let pattern = #"(?<![ァ-ヶぁ-ん])(?:アツプル *サ-ビス|アツプル *ストア|アツプル *ジヤパン)"#
        return try! NSRegularExpression(pattern: pattern, options: [])
    }()

    /// Preserves word-separating single spaces while applying `TextFold`'s NFKC, dash, and small-kana
    /// normalization so `"D APPLE.CO"` keeps its word boundary while `"PINEAPPLE.COM"`, `"APPLE.CO-OP"`,
    /// `"APPLE BILLBOARD CAFE"`, and control-character separators do not match.
    private static func spacePreservingFold(_ raw: String) -> String {
        let tokens = raw
            .precomposedStringWithCompatibilityMapping
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .map { TextFold.key(String($0)) }
            .filter { !$0.isEmpty }
        return tokens.joined(separator: " ")
    }

    /// True only for Apple billing descriptors (never ordinary merchants like `"APPLE PARK CAFE"`,
    /// `"APPLE BILLBOARD CAFE"`, `"ICLOUD REPAIR SHOP"`, `"PINEAPPLE.COM CAFE"`, `"SNAPPLE.COM"`,
    /// `"GRAPPLE.CO JP"`, `"HAPPSTORE"`, `"APPLE PAY ..."`, or `"MOBILE SUICA APPLE"`).
    static func isAppleBillingDescriptor(_ raw: String) -> Bool {
        let spaced = spacePreservingFold(raw)
        guard !spaced.isEmpty else { return false }
        if spaced == "apple" || spaced == "アツプル" { return true }
        let range = NSRange(spaced.startIndex..<spaced.endIndex, in: spaced)
        return appleASCIIBillingRegex.firstMatch(in: spaced, options: [], range: range) != nil
            || appleKanaBillingRegex.firstMatch(in: spaced, options: [], range: range) != nil
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
