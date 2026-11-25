import Foundation

/// Errors thrown while decoding or validating a `DataBundle`.
public enum DataBundleError: Error, LocalizedError, Equatable, Sendable {
    /// The bundle declared a format version other than `DataBundle.supportedFormat`.
    case unsupportedFormat(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let format):
            return "Unsupported bundle format \"\(format)\"; expected \"\(DataBundle.supportedFormat)\"."
        }
    }
}

/// Inclusive "YYYY-MM-DD" coverage window for one statement source.
public struct CoverageRange: Codable, Sendable, Equatable {
    public var start: String
    public var end: String

    public init(start: String, end: String) {
        self.start = start
        self.end = end
    }
}

/// One spending, income or transfer line item in the budget.
///
/// Amounts are whole yen; positive is money out and negative is money in.
public struct BudgetItem: Codable, Sendable, Hashable {
    public var date: String
    public var source: String
    public var merchant: String
    public var amount: Int
    public var group: String
    public var category: String
    public var layer: String?
    /// True when built from a live notice rather than a statement bundle.
    public var isPending: Bool
    /// Optional underlying funding card/debit source key (e.g. `"mufg_debit"`) preserved when an
    /// aggregator receipt (such as Apple) supersedes a duplicate bank/debit notice.
    public var fundingSource: String?
    /// True when this item originated from a phone manual/CSV entry synced through the PC bundle,
    /// so live bank statement matching never mistakes it for a bank-balance row.
    public var isManual: Bool?
    /// Optional bank/card approval reference (e.g. 6-digit debit approval code) exported by the PC
    /// pipeline so snapshot and post-cutoff matching preserve debit identity even after merchant naming.
    public var reference: String?

    public init(
        date: String,
        source: String,
        merchant: String,
        amount: Int,
        group: String,
        category: String,
        layer: String? = nil,
        isPending: Bool = false,
        fundingSource: String? = nil,
        isManual: Bool? = nil,
        reference: String? = nil
    ) {
        self.date = date
        self.source = source
        self.merchant = merchant
        self.amount = amount
        self.group = group
        self.category = category
        self.layer = layer
        self.isPending = isPending
        self.fundingSource = fundingSource
        self.isManual = isManual
        self.reference = reference
    }

    private enum CodingKeys: String, CodingKey {
        case date, source, merchant, amount, group, category, layer, isPending, fundingSource, isManual, reference
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decode(String.self, forKey: .date)
        source = try c.decode(String.self, forKey: .source)
        merchant = try c.decode(String.self, forKey: .merchant)
        amount = try c.decode(Int.self, forKey: .amount)
        group = try c.decode(String.self, forKey: .group)
        category = try c.decode(String.self, forKey: .category)
        layer = try c.decodeIfPresent(String.self, forKey: .layer)
        isPending = try c.decodeIfPresent(Bool.self, forKey: .isPending) ?? false
        fundingSource = try c.decodeIfPresent(String.self, forKey: .fundingSource)
        isManual = try c.decodeIfPresent(Bool.self, forKey: .isManual)
        reference = try c.decodeIfPresent(String.self, forKey: .reference)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(date, forKey: .date)
        try c.encode(source, forKey: .source)
        try c.encode(merchant, forKey: .merchant)
        try c.encode(amount, forKey: .amount)
        try c.encode(group, forKey: .group)
        try c.encode(category, forKey: .category)
        try c.encodeIfPresent(layer, forKey: .layer)
        if isPending {
            try c.encode(true, forKey: .isPending)
        }
        try c.encodeIfPresent(fundingSource, forKey: .fundingSource)
        try c.encodeIfPresent(isManual, forKey: .isManual)
        try c.encodeIfPresent(reference, forKey: .reference)
    }
}

/// Rule exported by the PC pipeline to match an open timeline entry against confirmed bank rows
/// or unsettled card/debit notices.
public struct TimelineMatch: Codable, Sendable, Hashable {
    /// Bundle source label (value from `sourceLabels`, e.g. `"MUFG"`).
    public var source: String
    /// Regular expression matched against the bank's own line description.
    public var pattern: String
    /// Cashflow direction: `"in"` (negative amount) or `"out"` (positive amount).
    public var dir: String
    /// Inclusive day-offset window `[start, end]` around the entry's scheduled date.
    public var window: [Int]
    /// Optional inclusive lower bound on `abs(amount)` to disambiguate shared billing descriptors.
    public var minAmount: Int?
    /// Optional inclusive upper bound on `abs(amount)` to disambiguate shared billing descriptors.
    public var maxAmount: Int?

    public init(
        source: String,
        pattern: String,
        dir: String,
        window: [Int],
        minAmount: Int? = nil,
        maxAmount: Int? = nil
    ) {
        self.source = source
        self.pattern = pattern
        self.dir = dir
        self.window = window
        self.minAmount = minAmount
        self.maxAmount = maxAmount
    }
}

/// One scheduled or past event on the cashflow timeline.
///
/// Negative amounts are money in; positive amounts are money out.
public struct TimelineEntry: Codable, Sendable, Hashable {
    /// Optional stable identifier exported by the PC pipeline so phone checkoffs survive re-estimates.
    public var id: String?
    public var date: String
    public var item: String
    public var amount: Int
    public var note: String?
    public var payday: Bool?
    public var done: Bool?
    /// True when marked paid only on the phone (awaiting bank confirmation), so cash remains held
    /// and the user can still undo the checkoff after a PC bundle round-trip.
    public var phoneChecked: Bool?
    public var next: Bool?
    public var borrowed: Bool?
    public var estimate: Bool?
    public var event: Bool?
    public var label: String?
    public var match: TimelineMatch?
    /// True when this entry represents a regular monthly recurring flow (salary or recurring bill),
    /// false for one-off items, nil for legacy bundles that omit the field.
    public var recurring: Bool?
    /// True when this charge bills onto a deferred credit card whose lump-sum bill is already on the
    /// timeline, so it is shown for visibility without being subtracted from cash a second time.
    public var cardBilled: Bool?
    /// Display yen amount for a `cardBilled` entry when `amount` is kept at 0 for backwards compatibility.
    public var billedAmount: Int?
    /// True when bank holidays/weekends shift this entry's projection to a bank business day;
    /// false for fixed-calendar-day card/debit subscriptions; nil for legacy bundles.
    public var rollBusinessDay: Bool?
    /// Optional nominal day-of-month (1...31) for recurring entries before holiday/weekend rolling,
    /// so future forecast months anchor on the true billing/payday day rather than a shifted date.
    public var nominalDay: Int?

    public init(
        id: String? = nil,
        date: String,
        item: String,
        amount: Int,
        note: String? = nil,
        payday: Bool? = nil,
        done: Bool? = nil,
        phoneChecked: Bool? = nil,
        next: Bool? = nil,
        borrowed: Bool? = nil,
        estimate: Bool? = nil,
        event: Bool? = nil,
        label: String? = nil,
        match: TimelineMatch? = nil,
        recurring: Bool? = nil,
        cardBilled: Bool? = nil,
        billedAmount: Int? = nil,
        rollBusinessDay: Bool? = nil,
        nominalDay: Int? = nil
    ) {
        self.id = id
        self.date = date
        self.item = item
        self.amount = amount
        self.note = note
        self.payday = payday
        self.done = done
        self.phoneChecked = phoneChecked
        self.next = next
        self.borrowed = borrowed
        self.estimate = estimate
        self.event = event
        self.label = label
        self.match = match
        self.recurring = recurring
        self.cardBilled = cardBilled
        self.billedAmount = billedAmount
        self.rollBusinessDay = rollBusinessDay
        self.nominalDay = nominalDay
    }

    private enum CodingKeys: String, CodingKey {
        case id, date, item, amount, note, payday, done, phoneChecked, next, borrowed, estimate, event, label, match, recurring
        case cardBilled, billedAmount, rollBusinessDay, nominalDay
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        date = try c.decode(String.self, forKey: .date)
        item = try c.decode(String.self, forKey: .item)
        amount = try c.decodeIfPresent(Int.self, forKey: .amount) ?? 0
        note = try c.decodeIfPresent(String.self, forKey: .note)
        payday = try c.decodeIfPresent(Bool.self, forKey: .payday)
        done = try c.decodeIfPresent(Bool.self, forKey: .done)
        phoneChecked = try c.decodeIfPresent(Bool.self, forKey: .phoneChecked)
        next = try c.decodeIfPresent(Bool.self, forKey: .next)
        borrowed = try c.decodeIfPresent(Bool.self, forKey: .borrowed)
        estimate = try c.decodeIfPresent(Bool.self, forKey: .estimate)
        event = try c.decodeIfPresent(Bool.self, forKey: .event)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        match = try c.decodeIfPresent(TimelineMatch.self, forKey: .match)
        recurring = try c.decodeIfPresent(Bool.self, forKey: .recurring)
        cardBilled = try c.decodeIfPresent(Bool.self, forKey: .cardBilled)
        billedAmount = try c.decodeIfPresent(Int.self, forKey: .billedAmount)
        rollBusinessDay = try c.decodeIfPresent(Bool.self, forKey: .rollBusinessDay)
        nominalDay = try c.decodeIfPresent(Int.self, forKey: .nominalDay)
    }
}

/// One debt balance tracked in the bundle.
public struct DebtEntry: Codable, Sendable, Equatable {
    public var name: String
    public var balance: Int
    public var limit: Int?
    public var lines: [String]?

    public init(name: String, balance: Int, limit: Int? = nil, lines: [String]? = nil) {
        self.name = name
        self.balance = balance
        self.limit = limit
        self.lines = lines
    }
}

/// Confirmed bank account balance snapshot from the PC pipeline, updated live on the phone.
public struct AccountBalance: Codable, Sendable, Equatable, Hashable {
    /// Bundle source key for this bank account (e.g. `"mufg_bank"`).
    public var source: String
    /// Display name shown in the UI.
    public var label: String
    /// Confirmed closing balance in yen inclusive of all transactions on or before `asOf`.
    public var balance: Int
    /// Last statement date (`"YYYY-MM-DD"`) reflected in `balance`.
    public var asOf: String
    /// Debit card source keys whose unsettled notices immediately draw down this bank account.
    /// Deferred credit cards billed monthly are omitted so they aren't subtracted twice.
    public var debitNoticeSources: [String]?
    /// Signed yen amounts (`+out`, `-in`) of bank rows dated on `asOf` that are already included
    /// in `balance`, allowing later intraday rows on `asOf` to be detected without double-counting.
    public var asOfRowAmounts: [Int]?

    public init(
        source: String,
        label: String,
        balance: Int,
        asOf: String,
        debitNoticeSources: [String]? = nil,
        asOfRowAmounts: [Int]? = nil
    ) {
        self.source = source
        self.label = label
        self.balance = balance
        self.asOf = asOf
        self.debitNoticeSources = debitNoticeSources
        self.asOfRowAmounts = asOfRowAmounts
    }
}

/// Standing usable credit room (e.g. remaining limit on a credit card) available right now
/// without belonging to a specific calendar date on the timeline.
public struct CreditRoom: Codable, Sendable, Equatable, Hashable {
    /// Short display label shown alongside cash totals (e.g. `"Card A"`).
    public var label: String
    /// Confirmed usable credit room in yen as of `asOf`.
    public var available: Int
    /// Optional total credit limit in yen used as an upper cap when refunds arrive.
    public var limit: Int?
    /// Optional date (`"YYYY-MM-DD"`) when `available` was verified.
    public var asOf: String?
    /// Optional card source keys whose charges strictly after `asOf` draw down `available` live.
    public var sourceKeys: [String]?
    /// Optional short context note.
    public var note: String?
    /// Signed yen amounts (`+out`, `-in`) of card charges dated on `asOf` that are already reflected
    /// in `available`, enabling same-day post-snapshot charges to draw down room without double-counting.
    public var asOfRowAmounts: [Int]?
    /// Optional ISO-8601 timestamp when a manual phone balance override was recorded, so same-day
    /// charges received strictly after the override still draw down live credit room.
    public var asOfTimestamp: String?

    public init(
        label: String,
        available: Int,
        limit: Int? = nil,
        asOf: String? = nil,
        sourceKeys: [String]? = nil,
        note: String? = nil,
        asOfRowAmounts: [Int]? = nil,
        asOfTimestamp: String? = nil
    ) {
        self.label = label
        self.available = available
        self.limit = limit
        self.asOf = asOf
        self.sourceKeys = sourceKeys
        self.note = note
        self.asOfRowAmounts = asOfRowAmounts
        self.asOfTimestamp = asOfTimestamp
    }
}

/// One recurring subscription entry in the bundle.
public struct SubscriptionEntry: Codable, Sendable, Equatable {
    public var name: String
    public var monthly: Int
    public var via: String?
    public var status: String?
    /// Optional date (`"YYYY-MM-DD"`) when a cancelled/stopped subscription was turned off,
    /// so charges on or before that date don't raise false resurrected-charge alerts.
    public var stoppedDate: String?

    public init(
        name: String,
        monthly: Int,
        via: String? = nil,
        status: String? = nil,
        stoppedDate: String? = nil
    ) {
        self.name = name
        self.monthly = monthly
        self.via = via
        self.status = status
        self.stoppedDate = stoppedDate
    }
}

/// One category target in the monthly spending plan.
public struct PlanEntry: Codable, Sendable, Equatable {
    public var category: String
    public var now: Int
    public var target: Int?
    public var status: String
    public var note: String?

    public init(category: String, now: Int, target: Int? = nil, status: String, note: String? = nil) {
        self.category = category
        self.now = now
        self.target = target
        self.status = status
        self.note = note
    }
}

/// Display key and color for one spending layer.
public struct LayerDefinition: Codable, Sendable, Equatable {
    public var key: String
    public var color: String

    public init(key: String, color: String) {
        self.key = key
        self.color = color
    }
}

/// Rules that map an item's group and category to a spending layer or a non-spending bucket.
///
/// The four spending layer keys correspond in order to `layers` from the bundle:
/// rent, bills, subscriptions and day-to-day. When fewer than four layer definitions
/// are supplied, `defaultLayerKeys` ("Rent", "Bills & taxes", "Subscriptions", "Day-to-day")
/// is used.
public struct LayerConfig: Codable, Sendable, Equatable {
    public static let defaultLayerKeys = ["Rent", "Bills & taxes", "Subscriptions", "Day-to-day"]

    public var notSpendingGroups: [String]
    public var rentCategories: [String]
    public var billGroups: [String]
    public var subscriptionGroups: [String]
    public var subscriptionCategories: [String]
    /// Group name used for income in `MonthTotals`. Falls back to the first of `notSpendingGroups`.
    public var incomeGroup: String?
    /// Group name used for people transfers in `MonthTotals`.
    public var peopleGroup: String?
    /// Group name used for debt payments in `MonthTotals`.
    public var debtGroup: String?

    public init(
        notSpendingGroups: [String] = [],
        rentCategories: [String] = [],
        billGroups: [String] = [],
        subscriptionGroups: [String] = [],
        subscriptionCategories: [String] = [],
        incomeGroup: String? = nil,
        peopleGroup: String? = nil,
        debtGroup: String? = nil
    ) {
        self.notSpendingGroups = notSpendingGroups
        self.rentCategories = rentCategories
        self.billGroups = billGroups
        self.subscriptionGroups = subscriptionGroups
        self.subscriptionCategories = subscriptionCategories
        self.incomeGroup = incomeGroup
        self.peopleGroup = peopleGroup
        self.debtGroup = debtGroup
    }

    private enum CodingKeys: String, CodingKey {
        case notSpendingGroups, rentCategories, billGroups, subscriptionGroups, subscriptionCategories
        case incomeGroup, peopleGroup, debtGroup
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        notSpendingGroups = try c.decodeIfPresent([String].self, forKey: .notSpendingGroups) ?? []
        rentCategories = try c.decodeIfPresent([String].self, forKey: .rentCategories) ?? []
        billGroups = try c.decodeIfPresent([String].self, forKey: .billGroups) ?? []
        subscriptionGroups = try c.decodeIfPresent([String].self, forKey: .subscriptionGroups) ?? []
        subscriptionCategories = try c.decodeIfPresent([String].self, forKey: .subscriptionCategories) ?? []
        incomeGroup = try c.decodeIfPresent(String.self, forKey: .incomeGroup)
        peopleGroup = try c.decodeIfPresent(String.self, forKey: .peopleGroup)
        debtGroup = try c.decodeIfPresent(String.self, forKey: .debtGroup)
    }

    /// Returns the spending layer key for an item, or nil when it is not spending.
    ///
    /// Pass `layers` from `DataBundle.layers` to read the four layer keys in order
    /// (rent, bills, subscriptions, day-to-day) instead of using `defaultLayerKeys`.
    public func layer(for item: BudgetItem, layers: [LayerDefinition] = []) -> String? {
        layer(group: item.group, category: item.category, layers: layers)
    }

    /// Returns the spending layer key for a group and category, or nil when not spending.
    public func layer(group: String, category: String, layers: [LayerDefinition] = []) -> String? {
        if isNotSpending(group: group) {
            return nil
        }
        let keys = layers.count >= 4 ? layers.prefix(4).map(\.key) : Self.defaultLayerKeys
        if rentCategories.contains(category) {
            return keys[0]
        }
        if billGroups.contains(group) {
            return keys[1]
        }
        if subscriptionGroups.contains(group) || subscriptionCategories.contains(category) {
            return keys[2]
        }
        return keys[3]
    }

    func isNotSpending(group: String) -> Bool {
        let lower = group.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return notSpendingGroups.contains(group)
            || group == incomeGroup
            || group == peopleGroup
            || group == debtGroup
            || lower == "excluded"
            || lower == "transfers"
            || lower == "hidden"
            || lower == "pass-through"
            || lower == "self"
            || lower == "work"
    }

    /// Non-spending group used when the user excludes a personal item (never lands in a Work group).
    public var resolvedExcludedGroup: String {
        if let explicit = notSpendingGroups.first(where: {
            let l = $0.lowercased()
            return l == "excluded" || l.contains("transfer")
        }) {
            return explicit
        }
        return "Excluded"
    }

    /// Non-spending group used when the user tags a reimbursable work expense.
    public var resolvedWorkGroup: String {
        if let explicit = notSpendingGroups.first(where: { $0.lowercased().contains("work") }) {
            return explicit
        }
        return "Work"
    }

    public var resolvedIncomeGroup: String? {
        incomeGroup ?? notSpendingGroups.first
    }

    public func resolvedLayer(for item: BudgetItem, layers: [LayerDefinition] = []) -> String? {
        if isNotSpending(group: item.group) {
            return nil
        }
        if let explicit = item.layer, !explicit.isEmpty {
            return explicit
        }
        return layer(group: item.group, category: item.category, layers: layers)
    }
}

/// A regex rule that maps a merchant name to a group and category.
public struct CategoryRule: Codable, Sendable, Equatable {
    public var pattern: String
    public var group: String
    public var category: String

    public init(pattern: String, group: String, category: String) {
        self.pattern = pattern
        self.group = group
        self.category = category
    }
}

/// An override rule that refines a base category by amount, merchant pattern or date.
public struct AmountRule: Codable, Sendable, Equatable {
    public var whenCategory: String?
    public var merchantPattern: String?
    public var minAmount: Int?
    public var maxAmount: Int?
    public var fromDate: String?
    public var group: String
    public var category: String

    public init(
        whenCategory: String? = nil,
        merchantPattern: String? = nil,
        minAmount: Int? = nil,
        maxAmount: Int? = nil,
        fromDate: String? = nil,
        group: String,
        category: String
    ) {
        self.whenCategory = whenCategory
        self.merchantPattern = merchantPattern
        self.minAmount = minAmount
        self.maxAmount = maxAmount
        self.fromDate = fromDate
        self.group = group
        self.category = category
    }
}

/// A group and category pair assigned to a merchant.
public struct CategoryPair: Codable, Sendable, Equatable {
    public var group: String
    public var category: String

    public init(group: String, category: String) {
        self.group = group
        self.category = category
    }
}

/// Categorization rules carried inside a `DataBundle`.
public struct RuleSet: Codable, Sendable, Equatable {
    public var rules: [CategoryRule]
    public var amountRules: [AmountRule]
    /// Keyed by `TextFold.key(merchant)`.
    public var learned: [String: CategoryPair]

    public init(
        rules: [CategoryRule] = [],
        amountRules: [AmountRule] = [],
        learned: [String: CategoryPair] = [:]
    ) {
        self.rules = rules
        self.amountRules = amountRules
        self.learned = learned
    }

    private enum CodingKeys: String, CodingKey {
        case rules, amountRules, learned
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rules = try c.decodeIfPresent([CategoryRule].self, forKey: .rules) ?? []
        amountRules = try c.decodeIfPresent([AmountRule].self, forKey: .amountRules) ?? []
        learned = try c.decodeIfPresent([String: CategoryPair].self, forKey: .learned) ?? [:]
    }
}

/// Data-driven rule for extracting an optional approval/reference number and/or merchant
/// prefix from a bank statement description during notice matching.
///
/// Display text always keeps the statement description verbatim; these capture groups are
/// used only for matching card/debit notices to bank rows.
public struct StatementLineRule: Codable, Sendable, Equatable {
    /// Regular expression matched against the bank transaction description.
    public var pattern: String
    /// 1-based capture group index for an approval or reference number, if present.
    public var referenceGroup: Int?
    /// 1-based capture group index for a merchant name or prefix, if present.
    public var merchantGroup: Int?
    /// Optional `BudgetItem.source` label override for rows matching this rule (e.g. a debit sub-channel)
    /// so phone-confirmed items share the same source label as PC-exported items.
    public var itemSource: String?

    public init(
        pattern: String,
        referenceGroup: Int? = nil,
        merchantGroup: Int? = nil,
        itemSource: String? = nil
    ) {
        self.pattern = pattern
        self.referenceGroup = referenceGroup
        self.merchantGroup = merchantGroup
        self.itemSource = itemSource
    }
}

/// Private budget snapshot exported by the PC pipeline and imported on the phone.
public struct DataBundle: Codable, Sendable, Equatable {
    public static let supportedFormat = "finance-bundle/1"

    public var format: String
    public var generatedAt: String
    public var asOf: String
    public var coverage: [String: CoverageRange]
    public var sourceLabels: [String: String]
    public var items: [BudgetItem]
    public var timeline: [TimelineEntry]
    public var debts: [DebtEntry]
    public var subs: [SubscriptionEntry]
    public var plan: [PlanEntry]
    public var notes: [String]?
    public var afterNote: String?
    public var planWindow: [String]?
    public var layers: [LayerDefinition]
    public var layerConfig: LayerConfig
    public var rules: RuleSet
    /// Categories whose payment notifications omit the shop name.
    public var discreetCategories: [String]?
    /// Maps a notice source key to additional confirmed statement/bank source keys
    /// whose rows can settle its notices (e.g. a card notice source -> bank source).
    public var noticeSourceMatches: [String: [String]]?
    /// Optional per-source regex rules for extracting reference numbers and merchant
    /// prefixes from bank statement descriptions when matching notices.
    public var statementLineRules: [String: [StatementLineRule]]?
    /// Optional confirmed bank account balance snapshots used to compute live cash until payday.
    public var accountBalances: [AccountBalance]?
    /// Optional standing usable credit room snapshots (not tied to a calendar date in Coming up).
    public var creditRooms: [CreditRoom]?
    /// Per-fingerprint counts of phone deletions already applied when the PC built this bundle,
    /// so the phone never subtracts the same tombstone a second time against surviving duplicates.
    public var appliedPhoneDeletions: [String: Int]?

    public init(
        format: String = DataBundle.supportedFormat,
        generatedAt: String,
        asOf: String,
        coverage: [String: CoverageRange] = [:],
        sourceLabels: [String: String] = [:],
        items: [BudgetItem] = [],
        timeline: [TimelineEntry] = [],
        debts: [DebtEntry] = [],
        subs: [SubscriptionEntry] = [],
        plan: [PlanEntry] = [],
        notes: [String]? = nil,
        afterNote: String? = nil,
        planWindow: [String]? = nil,
        layers: [LayerDefinition] = [],
        layerConfig: LayerConfig = LayerConfig(),
        rules: RuleSet = RuleSet(),
        discreetCategories: [String]? = nil,
        noticeSourceMatches: [String: [String]]? = nil,
        statementLineRules: [String: [StatementLineRule]]? = nil,
        accountBalances: [AccountBalance]? = nil,
        creditRooms: [CreditRoom]? = nil,
        appliedPhoneDeletions: [String: Int]? = nil
    ) {
        self.format = format
        self.generatedAt = generatedAt
        self.asOf = asOf
        self.coverage = coverage
        self.sourceLabels = sourceLabels
        self.items = items
        self.timeline = timeline
        self.debts = debts
        self.subs = subs
        self.plan = plan
        self.notes = notes
        self.afterNote = afterNote
        self.planWindow = planWindow
        self.layers = layers
        self.layerConfig = layerConfig
        self.rules = rules
        self.discreetCategories = discreetCategories
        self.noticeSourceMatches = noticeSourceMatches
        self.statementLineRules = statementLineRules
        self.accountBalances = accountBalances
        self.creditRooms = creditRooms
        self.appliedPhoneDeletions = appliedPhoneDeletions
    }

    private enum CodingKeys: String, CodingKey {
        case format, generatedAt, asOf, coverage, sourceLabels, items, timeline
        case debts, subs, plan, notes, afterNote, planWindow, layers, layerConfig, rules
        case discreetCategories, noticeSourceMatches, statementLineRules, accountBalances, creditRooms
        case appliedPhoneDeletions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let format = try c.decode(String.self, forKey: .format)
        guard format == Self.supportedFormat else {
            throw DataBundleError.unsupportedFormat(format)
        }
        self.format = format
        generatedAt = try c.decode(String.self, forKey: .generatedAt)
        asOf = try c.decode(String.self, forKey: .asOf)
        coverage = try c.decodeIfPresent([String: CoverageRange].self, forKey: .coverage) ?? [:]
        sourceLabels = try c.decodeIfPresent([String: String].self, forKey: .sourceLabels) ?? [:]
        items = try c.decodeIfPresent([BudgetItem].self, forKey: .items) ?? []
        timeline = try c.decodeIfPresent([TimelineEntry].self, forKey: .timeline) ?? []
        debts = try c.decodeIfPresent([DebtEntry].self, forKey: .debts) ?? []
        subs = try c.decodeIfPresent([SubscriptionEntry].self, forKey: .subs) ?? []
        plan = try c.decodeIfPresent([PlanEntry].self, forKey: .plan) ?? []
        notes = try c.decodeIfPresent([String].self, forKey: .notes)
        afterNote = try c.decodeIfPresent(String.self, forKey: .afterNote)
        planWindow = try c.decodeIfPresent([String].self, forKey: .planWindow)
        layers = try c.decodeIfPresent([LayerDefinition].self, forKey: .layers) ?? []
        layerConfig = try c.decodeIfPresent(LayerConfig.self, forKey: .layerConfig) ?? LayerConfig()
        rules = try c.decodeIfPresent(RuleSet.self, forKey: .rules) ?? RuleSet()
        discreetCategories = try c.decodeIfPresent([String].self, forKey: .discreetCategories)
        noticeSourceMatches = try c.decodeIfPresent([String: [String]].self, forKey: .noticeSourceMatches)
        statementLineRules = try c.decodeIfPresent([String: [StatementLineRule]].self, forKey: .statementLineRules)
        accountBalances = try c.decodeIfPresent([AccountBalance].self, forKey: .accountBalances)
        creditRooms = try c.decodeIfPresent([CreditRoom].self, forKey: .creditRooms)
        appliedPhoneDeletions = try c.decodeIfPresent([String: Int].self, forKey: .appliedPhoneDeletions)
    }

    /// Decodes a `DataBundle` from UTF-8 JSON bytes and validates its format.
    public static func decode(from data: Data) throws -> DataBundle {
        try JSONDecoder().decode(DataBundle.self, from: data)
    }

    /// Computes the spending layer for an item using this bundle's `layerConfig` and `layers`.
    public func layer(for item: BudgetItem) -> String? {
        layerConfig.layer(for: item, layers: layers)
    }
}
