import Foundation

/// Smart category suggestion attached to a Review Inbox card.
public struct CategorySuggestion: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var id: String { "\(group)|\(category)" }
    public var group: String
    public var category: String

    public init(group: String, category: String) {
        self.group = group
        self.category = category
    }
}

/// 12-month history and price-change diagnostics for a single subscription.
public struct SubscriptionHistory: Sendable, Equatable {
    public var subscription: SubscriptionItem
    public var matchedItems: [BudgetItem]
    public var monthlyPoints: [PlanMonthPoint]
    public var last12MonthsSpend: Int
    public var annualRunRate: Int
    public var averageCharge: Int?
    public var lastChargeDate: String?
    /// Latest charge minus prior median charge when abs(delta) >= ¥50.
    public var priceChangeDelta: Int?

    public init(
        subscription: SubscriptionItem,
        matchedItems: [BudgetItem],
        monthlyPoints: [PlanMonthPoint],
        last12MonthsSpend: Int,
        annualRunRate: Int,
        averageCharge: Int?,
        lastChargeDate: String?,
        priceChangeDelta: Int?
    ) {
        self.subscription = subscription
        self.matchedItems = matchedItems
        self.monthlyPoints = monthlyPoints
        self.last12MonthsSpend = last12MonthsSpend
        self.annualRunRate = annualRunRate
        self.averageCharge = averageCharge
        self.lastChargeDate = lastChargeDate
        self.priceChangeDelta = priceChangeDelta
    }

    public static func compute(
        for sub: SubscriptionItem,
        allItems: [BudgetItem],
        months: [String],
        today: String,
        config: LayerConfig? = nil,
        layers: [LayerDefinition] = []
    ) -> SubscriptionHistory {
        let recentMonths = Array(months.suffix(12))
        let monthSet = Set(recentMonths)
        let currentMonth = String(today.prefix(7))

        let matched = allItems
            .filter { item in
                Self.matchesItem(item, for: sub.entry, config: config, layers: layers, allowAnnualMultiplier: true)
            }
            .sorted { ($0.date, $0.amount) > ($1.date, $1.amount) }

        var byMonth: [String: Int] = [:]
        for item in matched {
            let m = String(item.date.prefix(7))
            if monthSet.contains(m) {
                byMonth[m, default: 0] += item.amount
            }
        }

        let points = recentMonths.map { m in
            PlanMonthPoint(
                month: m,
                spent: byMonth[m, default: 0],
                isSelected: m == recentMonths.last,
                isInProgress: m == currentMonth
            )
        }

        let last12Spend = points.reduce(0) { $0 + $1.spent }
        let avg: Int? = matched.isEmpty
            ? nil
            : Int((Double(matched.reduce(0) { $0 + $1.amount }) / Double(matched.count)).rounded())

        var priceDelta: Int? = nil
        if matched.count >= 2 {
            let latest = matched[0].amount
            let prior = Array(matched.dropFirst().prefix(5)).map(\.amount).sorted()
            let median = prior[prior.count / 2]
            if abs(latest - median) >= 50 && Double(latest) / Double(max(1, median)) < 3.0 {
                priceDelta = latest - median
            }
        }

        return SubscriptionHistory(
            subscription: sub,
            matchedItems: matched,
            monthlyPoints: points,
            last12MonthsSpend: last12Spend,
            annualRunRate: sub.entry.monthly * 12,
            averageCharge: avg,
            lastChargeDate: matched.first?.date,
            priceChangeDelta: priceDelta
        )
    }

    /// Matches a ledger `BudgetItem` to a `SubscriptionEntry` using folded vendor tokens,
    /// parenthetical billing aliases (e.g. `(Anthropic)`, `(billed by KDDI)`), Japanese card
    /// descriptor synonyms, and tighter amount bounds so retail orders don't pollute subscription views.
    static func matchesItem(
        _ item: BudgetItem,
        for entry: SubscriptionEntry,
        config: LayerConfig? = nil,
        layers: [LayerDefinition] = [],
        allowAnnualMultiplier: Bool = true
    ) -> Bool {
        guard item.amount > 0 else { return false }
        if let config, config.isNotSpending(group: item.group) {
            return false
        }

        let tokens = searchTokens(for: entry.name)
        guard !tokens.isEmpty else { return false }

        let foldedMerchant = TextFold.key(item.merchant)
        guard !foldedMerchant.isEmpty else { return false }

        let tokenHit = tokens.contains { token in
            guard !token.isEmpty else { return false }
            if foldedMerchant.contains(token) { return true }
            // Japanese bank debit rows often truncate ASCII descriptors to 8 chars (e.g. "ANTHROPI", "PONTAPAS").
            if token.count >= 7, token.allSatisfy(\.isASCII) {
                let truncated = String(token.prefix(7))
                if foldedMerchant.contains(truncated) { return true }
            }
            return false
        }
        guard tokenHit else { return false }

        // Prevent shopping purchases (e.g. Amazon retail orders) from matching digital subscription entries.
        let groupLower = item.group.lowercased()
        let catLower = item.category.lowercased()
        if groupLower == "shopping" || catLower.contains("online shopping") {
            let subLower = entry.name.lowercased()
            if subLower.contains("prime") || subLower.contains("aws") || subLower.contains("google") || subLower.contains("line") {
                return false
            }
        }

        if entry.monthly > 0 {
            let ratio = Double(item.amount) / Double(entry.monthly)
            let isYearly = (entry.status ?? "").lowercased().contains("year") || entry.name.lowercased().contains("yearly")
            let isUsageBased = entry.name.lowercased().contains("api") || entry.name.lowercased().contains("povo") || entry.name.lowercased().contains("aws")
            if isYearly {
                return allowAnnualMultiplier ? (ratio >= 0.4 && ratio <= 14.0) : (ratio >= 0.4 && ratio <= 2.5)
            }
            if isUsageBased {
                return ratio >= 0.15 && ratio <= 4.0
            }
            let inMonthlyBand = ratio >= 0.45 && ratio <= 2.2
            let inAnnualBand = allowAnnualMultiplier && (ratio >= 9.5 && ratio <= 13.5)
            return inMonthlyBand || inAnnualBand
        }
        return true
    }

    /// Extracts specific vendor tokens (including parenthetical billing names and standard JP descriptor aliases).
    static func searchTokens(for name: String) -> [String] {
        let stopWords: Set<String> = [
            "plan", "plus", "pro", "card", "mobile", "home", "internet", "free", "pass", "with",
            "extra", "yearly", "cycle", "night", "only", "last", "charge", "auto", "reload",
            "billed", "usage", "data", "api", "credits", "commuter", "rent", "dating", "gym",
            "sub", "monthly", "member", "paid", "check", "keep", "stop", "stopped", "review",
            "each", "year", "months", "per", "all", "limits", "off", "option", "standard",
            "amazon", "google", "apple", "line", "rakuten", "yahoo", "premium", "store", "app",
            "service", "cloud", "music", "video", "news", "sample", "group", "billing"
        ]

        let foldedFull = TextFold.key(name)
        var out: [String] = []

        // Full base phrase before "(" is often a strong multi-word match (e.g. "jpnight", "amazonprime", "lineスタンダード").
        let base = name.split(separator: "(").first.map(String.init) ?? name
        let foldedBase = TextFold.key(base)
        if foldedBase.count >= 4, !stopWords.contains(foldedBase) {
            out.append(foldedBase)
        }
        // Keep combined phrase including short parentheticals like "with (dating)" -> "withdating".
        if foldedFull.count >= 6 && foldedFull.count <= 24, !stopWords.contains(foldedFull) {
            out.append(foldedFull)
        }

        // Tokenize BOTH outside and inside parentheses so "(Anthropic)" and "(billed by KDDI)" are captured.
        let separators = CharacterSet(charactersIn: " /・+()（）「」『』,、:：-–—·•")
        for rawPart in name.components(separatedBy: separators) {
            let token = TextFold.key(rawPart)
            if token.count >= 3, !stopWords.contains(token), !token.allSatisfy(\.isNumber) {
                out.append(token)
            }
        }

        // Standard global / Japanese payment-network descriptor aliases (no personal data).
        let aliases: [(needle: String, expansions: [String])] = [
            ("amazonprime", ["amazonp", "primeme", "アマゾンプライム"]),
            ("aws", ["amazonw", "amazonweb", "aws"]),
            ("rakutenmobile", ["ラクテンモバイル", "楽天モバイル"]),
            ("googleai", ["googleg", "googlep", "googleone"]),
            ("youtube", ["googlep", "googleg", "youtube"]),
            ("chatgpt", ["chatgpt", "openai"]),
            ("icloud", ["icloud"]),
            ("netflix", ["ネツトフリツクス"]),
            ("spotify", ["スポテイフアイ"]),
        ]
        let lowerFolded = foldedFull
        for (needle, expansions) in aliases where lowerFolded.contains(needle) || out.contains(needle) {
            out.append(contentsOf: expansions)
        }

        // Fallback if everything was filtered as stopwords (e.g., short single-word service).
        if out.isEmpty && foldedBase.count >= 3 {
            out.append(foldedBase)
        }
        return Array(Set(out))
    }
}

/// Real monthly repayment vs re-borrowing ledger flow for one debt account.
public struct DebtMonthlyFlow: Identifiable, Sendable, Equatable {
    public var id: String { month }
    public var month: String
    /// Total repaid toward this debt during `month` (positive yen).
    public var repaid: Int
    /// Total newly borrowed from this debt during `month` (positive yen).
    public var borrowed: Int
    /// `repaid - borrowed` (positive = net balance reduction).
    public var netProgress: Int

    public init(month: String, repaid: Int, borrowed: Int) {
        self.month = month
        self.repaid = repaid
        self.borrowed = borrowed
        self.netProgress = repaid - borrowed
    }
}

/// Complete debt inspector model combining static balance/limit with real ledger repayments and re-borrows.
public struct DebtHistory: Sendable, Equatable {
    public var debt: DebtEntry
    public var annualRatePercent: Double
    public var estimatedMonthlyInterest: Int
    public var estimatedAnnualInterest: Int
    public var monthlyFlows: [DebtMonthlyFlow]
    public var ytdRepaid: Int
    public var ytdBorrowed: Int
    public var ytdNetProgress: Int
    public var recentItems: [BudgetItem]

    public init(
        debt: DebtEntry,
        annualRatePercent: Double,
        estimatedMonthlyInterest: Int,
        estimatedAnnualInterest: Int,
        monthlyFlows: [DebtMonthlyFlow],
        ytdRepaid: Int,
        ytdBorrowed: Int,
        ytdNetProgress: Int,
        recentItems: [BudgetItem]
    ) {
        self.debt = debt
        self.annualRatePercent = annualRatePercent
        self.estimatedMonthlyInterest = estimatedMonthlyInterest
        self.estimatedAnnualInterest = estimatedAnnualInterest
        self.monthlyFlows = monthlyFlows
        self.ytdRepaid = ytdRepaid
        self.ytdBorrowed = ytdBorrowed
        self.ytdNetProgress = ytdNetProgress
        self.recentItems = recentItems
    }

    public static func compute(
        for debt: DebtEntry,
        allItems: [BudgetItem],
        config: LayerConfig,
        months: [String],
        today: String
    ) -> DebtHistory {
        let rate = SpendingInsights.extractAnnualRate(from: debt.lines) ?? 15.0
        let monthlyInt = Int((Double(debt.balance) * rate / 100.0 / 12.0).rounded())
        let annualInt = Int((Double(debt.balance) * rate / 100.0).rounded())

        let debtGroup = config.debtGroup ?? "Debt"
        let nameTokens = debtTokens(debt.name)
        let currentYear = String(today.prefix(4))

        // Match debt-group rows belonging to this lender (or all debt rows if only 1 debt matches loosely).
        let matched = allItems.filter { item in
            guard item.group == debtGroup else { return false }
            let hay = TextFold.key(item.merchant + " " + item.category + " " + item.source)
            return nameTokens.contains(where: { !$0.isEmpty && hay.contains($0) })
        }
        .sorted { ($0.date, abs($0.amount)) > ($1.date, abs($1.amount)) }

        var byMonth: [String: (repaid: Int, borrowed: Int)] = [:]
        var ytdRepaid = 0
        var ytdBorrowed = 0

        for item in matched {
            let m = String(item.date.prefix(7))
            var cur = byMonth[m, default: (0, 0)]
            if item.amount > 0 {
                cur.repaid += item.amount
                if item.date.hasPrefix(currentYear) { ytdRepaid += item.amount }
            } else if item.amount < 0 {
                cur.borrowed += -item.amount
                if item.date.hasPrefix(currentYear) { ytdBorrowed += -item.amount }
            }
            byMonth[m] = cur
        }

        let recentMonths = Array(months.suffix(6))
        let flows = recentMonths.map { m -> DebtMonthlyFlow in
            let stats = byMonth[m] ?? (0, 0)
            return DebtMonthlyFlow(month: m, repaid: stats.repaid, borrowed: stats.borrowed)
        }

        return DebtHistory(
            debt: debt,
            annualRatePercent: rate,
            estimatedMonthlyInterest: monthlyInt,
            estimatedAnnualInterest: annualInt,
            monthlyFlows: flows,
            ytdRepaid: ytdRepaid,
            ytdBorrowed: ytdBorrowed,
            ytdNetProgress: ytdRepaid - ytdBorrowed,
            recentItems: Array(matched.prefix(20))
        )
    }

    private static func debtTokens(_ name: String) -> [String] {
        var tokens: [String] = []
        let whole = TextFold.key(name)
        if whole.count >= 3 { tokens.append(whole) }
        for part in name.split(whereSeparator: { $0 == " " || $0 == "/" || $0 == "・" || $0 == "(" || $0 == ")" }) {
            let t = TextFold.key(String(part))
            if t.count >= 3 && !["card", "loan", "bank", "smart", "revolving", "balance", "sample"].contains(t) {
                tokens.append(t)
            }
        }
        if tokens.isEmpty && !whole.isEmpty { tokens.append(whole) }
        return Array(Set(tokens))
    }
}

/// Mini-dashboard model for a single spending category across up to 12 periods.
public struct CategoryHistory: Sendable, Equatable {
    public var category: String
    public var group: String
    public var layer: String?
    public var selectedPeriodTitle: String
    public var selectedPeriodTotal: Int
    public var averagePerPeriod: Int
    public var averageTransaction: Int
    public var transactionCount: Int
    public var currentTarget: Int?
    public var points: [PlanMonthPoint]
    public var periodItems: [BudgetItem]

    public static func compute(
        category: String,
        periods: [BudgetPeriod],
        totalsByPeriod: [String: MonthTotals],
        selectedPeriod: BudgetPeriod?,
        allItems: [BudgetItem],
        plan: [PlanEntry],
        config: LayerConfig,
        layers: [LayerDefinition]
    ) -> CategoryHistory {
        let recentPeriods = Array(periods.suffix(12))
        let selectedID = selectedPeriod?.id ?? recentPeriods.last?.id ?? ""

        let points = recentPeriods.map { p in
            PlanMonthPoint(
                month: p.shortLabel,
                spent: max(0, totalsByPeriod[p.id]?.categories[category]?.sum ?? 0),
                isSelected: p.id == selectedID,
                isInProgress: p.isInProgress
            )
        }

        let completedValues = recentPeriods
            .filter { !$0.isInProgress }
            .map { max(0, totalsByPeriod[$0.id]?.categories[category]?.sum ?? 0) }
        let nonZeroCompleted = completedValues.filter { $0 > 0 }
        let avgPeriod: Int = {
            let sample = nonZeroCompleted.isEmpty ? completedValues : nonZeroCompleted
            guard !sample.isEmpty else { return 0 }
            return Int((Double(sample.reduce(0, +)) / Double(sample.count)).rounded())
        }()

        let periodItems = allItems
            .filter { item in
                item.category == category && (selectedPeriod.map { $0.contains(item.date) } ?? true)
            }
            .sorted { ($0.date, $0.amount) > ($1.date, $1.amount) }

        let positive = periodItems.filter { $0.amount > 0 }
        let selectedTotal = periodItems.reduce(0) { $0 + $1.amount }
        let avgTx = positive.isEmpty
            ? 0
            : Int((Double(positive.reduce(0) { $0 + $1.amount }) / Double(positive.count)).rounded())

        let resolvedGroup = periodItems.first?.group
            ?? allItems.first(where: { $0.category == category })?.group
            ?? "Living"
        let resolvedLayer = config.layer(group: resolvedGroup, category: category, layers: layers)
        let target = plan.first(where: { $0.category == category })?.target

        return CategoryHistory(
            category: category,
            group: resolvedGroup,
            layer: resolvedLayer,
            selectedPeriodTitle: selectedPeriod?.title ?? "Selected period",
            selectedPeriodTotal: selectedTotal,
            averagePerPeriod: avgPeriod,
            averageTransaction: avgTx,
            transactionCount: positive.count,
            currentTarget: target,
            points: points,
            periodItems: periodItems
        )
    }
}

/// Mini-dashboard model for a single merchant across up to 12 periods.
public struct MerchantHistory: Sendable, Equatable {
    public var merchant: String
    public var foldedKey: String
    public var category: String
    public var selectedPeriodTitle: String
    public var selectedPeriodTotal: Int
    public var allTimeTotal: Int
    public var visitCount: Int
    public var averageVisit: Int
    public var sources: [String]
    public var points: [PlanMonthPoint]
    public var recentItems: [BudgetItem]

    public static func compute(
        merchant: String,
        periods: [BudgetPeriod],
        selectedPeriod: BudgetPeriod?,
        allItems: [BudgetItem]
    ) -> MerchantHistory {
        let key = TextFold.key(merchant)
        let allMatched = allItems
            .filter { TextFold.key($0.merchant) == key }
            .sorted { ($0.date, $0.amount) > ($1.date, $1.amount) }

        let recentPeriods = Array(periods.suffix(12))
        let selectedID = selectedPeriod?.id ?? recentPeriods.last?.id ?? ""
        let points = recentPeriods.map { period -> PlanMonthPoint in
            let sum = allMatched
                .filter { period.contains($0.date) }
                .reduce(0) { $0 + $1.amount }
            return PlanMonthPoint(
                month: period.shortLabel,
                spent: max(0, sum),
                isSelected: period.id == selectedID,
                isInProgress: period.isInProgress
            )
        }

        let periodItems = selectedPeriod.map { p in allMatched.filter { p.contains($0.date) } } ?? allMatched
        let selectedSum = periodItems.reduce(0) { $0 + $1.amount }
        let allSum = allMatched.reduce(0) { $0 + $1.amount }
        let positive = allMatched.filter { $0.amount > 0 }
        let avgVisit = positive.isEmpty
            ? 0
            : Int((Double(positive.reduce(0) { $0 + $1.amount }) / Double(positive.count)).rounded())

        return MerchantHistory(
            merchant: allMatched.first?.merchant ?? merchant,
            foldedKey: key,
            category: allMatched.first?.category ?? "Uncategorized",
            selectedPeriodTitle: selectedPeriod?.title ?? "All time",
            selectedPeriodTotal: selectedSum,
            allTimeTotal: allSum,
            visitCount: positive.count,
            averageVisit: avgVisit,
            sources: Array(Set(allMatched.map(\.source))).sorted(),
            points: points,
            recentItems: Array(allMatched.prefix(30))
        )
    }
}

/// One card in the 10-second daily Review inbox.
public struct ReviewQueueItem: Identifiable, Sendable, Equatable {
    public enum Reason: String, Sendable, Equatable {
        case declined = "Declined"
        case possibleDuplicate = "Check duplicate"
        case cancelledSub = "Stopped sub"
        case pendingEmail = "Pending email"
        case uncategorized = "Uncategorized"
    }

    public var id: String
    public var reason: Reason
    public var item: BudgetItem?
    public var alert: FinanceAlert?
    public var suggestions: [CategorySuggestion]

    public init(
        id: String,
        reason: Reason,
        item: BudgetItem? = nil,
        alert: FinanceAlert? = nil,
        suggestions: [CategorySuggestion] = []
    ) {
        self.id = id
        self.reason = reason
        self.item = item
        self.alert = alert
        self.suggestions = suggestions
    }
}

/// Builds the concise daily Review queue of unreviewed pending charges, uncategorized rows, and anomalies.
public enum ReviewInboxBuilder {
    public static func reviewKey(for item: BudgetItem) -> String {
        "tx:" + CategoryOverride.transactionFingerprint(for: item)
    }

    public static func build(
        allItems: [BudgetItem],
        alerts: [FinanceAlert],
        availableCategories: [(group: String, category: String)],
        reviewedKeys: Set<String>,
        today: String
    ) -> [ReviewQueueItem] {
        var queue: [ReviewQueueItem] = []
        var seenIDs = Set<String>()

        // 1. High-signal anomalies first (declines, duplicates, charges on stopped subscriptions).
        for alert in alerts {
            let reason: ReviewQueueItem.Reason?
            switch alert.kind {
            case .declinedPayment: reason = .declined
            case .possibleDuplicate: reason = .possibleDuplicate
            case .cancelledSubscriptionCharge: reason = .cancelledSub
            default: reason = nil
            }
            guard let reason else { continue }
            let key = "alert:\(alert.id)"
            guard !reviewedKeys.contains(key), seenIDs.insert(key).inserted else { continue }
            queue.append(ReviewQueueItem(id: key, reason: reason, alert: alert))
        }

        // Precompute top day-to-day spending categories for fallback suggestions (avoid suggesting
        // fixed bills like Rent/Utilities or non-spending groups for everyday card/cash purchases).
        let deprioritizedGroups: Set<String> = [
            "fixed bills", "bills", "housing", "income", "people", "debt", "transfers", "excluded", "work"
        ]
        let deprioritizedCategories: Set<String> = [
            "rent", "utilities", "electricity & gas", "resident tax (住民税)", "salary", "salary / bonus"
        ]
        var preferredCounts: [String: (group: String, count: Int)] = [:]
        var fallbackCounts: [String: (group: String, count: Int)] = [:]
        for item in allItems where item.amount > 0 && item.category.caseInsensitiveCompare("Uncategorized") != .orderedSame {
            let gLower = item.group.lowercased()
            let cLower = item.category.lowercased()
            let isFixedOrNonSpend = deprioritizedGroups.contains(gLower)
                || gLower.contains("work")
                || deprioritizedCategories.contains(cLower)
            if isFixedOrNonSpend {
                var cur = fallbackCounts[item.category] ?? (item.group, 0)
                cur.count += 1
                fallbackCounts[item.category] = cur
            } else {
                var cur = preferredCounts[item.category] ?? (item.group, 0)
                cur.count += 1
                preferredCounts[item.category] = cur
            }
        }
        let popularCategories = preferredCounts
            .sorted { $0.value.count > $1.value.count }
            .map { CategorySuggestion(group: $0.value.group, category: $0.key) }
            + fallbackCounts
            .sorted { $0.value.count > $1.value.count }
            .map { CategorySuggestion(group: $0.value.group, category: $0.key) }

        let uncatCutoff = JST.addingDays(-60, to: today) ?? "0000-00-00"
        let candidates = allItems
            .filter { item in
                item.isPending || (
                    item.date >= uncatCutoff
                        && item.category.caseInsensitiveCompare("Uncategorized") == .orderedSame
                )
            }
            .sorted { ($0.date, abs($0.amount)) > ($1.date, abs($1.amount)) }

        for item in candidates {
            let key = reviewKey(for: item)
            guard !reviewedKeys.contains(key), seenIDs.insert(key).inserted else { continue }
            let isUncat = item.category.caseInsensitiveCompare("Uncategorized") == .orderedSame
            let reason: ReviewQueueItem.Reason = item.isPending ? .pendingEmail : .uncategorized
            let suggestions = smartSuggestions(
                for: item,
                allItems: allItems,
                popular: popularCategories,
                available: availableCategories
            )
            queue.append(ReviewQueueItem(
                id: key,
                reason: isUncat && !item.isPending ? .uncategorized : reason,
                item: item,
                suggestions: suggestions
            ))
        }

        return Array(queue.prefix(30))
    }

    private static func smartSuggestions(
        for item: BudgetItem,
        allItems: [BudgetItem],
        popular: [CategorySuggestion],
        available: [(group: String, category: String)]
    ) -> [CategorySuggestion] {
        var result: [CategorySuggestion] = []
        var seen = Set<String>()

        func append(_ group: String, _ category: String) {
            guard !category.isEmpty,
                  category.caseInsensitiveCompare("Uncategorized") != .orderedSame,
                  seen.insert(category.lowercased()).inserted
            else { return }
            result.append(CategorySuggestion(group: group, category: category))
        }

        // First: existing category if already categorized.
        append(item.group, item.category)

        // Second: historical category for the same merchant or shared prefix.
        let targetKey = TextFold.key(item.merchant)
        if targetKey.count >= 3 {
            let prefix = String(targetKey.prefix(5))
            var histCounts: [String: (group: String, count: Int)] = [:]
            for other in allItems where other.category.caseInsensitiveCompare("Uncategorized") != .orderedSame {
                let otherKey = TextFold.key(other.merchant)
                if otherKey == targetKey || (prefix.count >= 4 && otherKey.hasPrefix(prefix)) {
                    var cur = histCounts[other.category] ?? (other.group, 0)
                    cur.count += 1
                    histCounts[other.category] = cur
                }
            }
            for (cat, meta) in histCounts.sorted(by: { $0.value.count > $1.value.count }) {
                append(meta.group, cat)
                if result.count >= 3 { return result }
            }
        }

        // Third: most frequent categories in the user's ledger.
        for pop in popular {
            append(pop.group, pop.category)
            if result.count >= 3 { return result }
        }

        for pair in available {
            append(pair.group, pair.category)
            if result.count >= 3 { return result }
        }
        return result
    }
}
