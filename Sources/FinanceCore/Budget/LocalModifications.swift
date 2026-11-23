import Foundation

/// A payment logged manually on the phone (e.g. cash) or imported on-device from a CSV export.
public struct ManualEntry: Codable, Sendable, Identifiable, Hashable {
    public enum Origin: String, Codable, Sendable, Hashable {
        case manual
        case csvImport = "csv_import"
    }

    public var id: UUID
    /// Transaction date in `"YYYY-MM-DD"` format.
    public var date: String
    /// Account, wallet or payment method label (e.g. `"Cash"`, `"PayPay"`).
    public var source: String
    public var merchant: String
    /// Signed whole yen; positive is money out, negative is money in.
    public var amount: Int
    public var group: String
    public var category: String
    public var note: String?
    public var origin: Origin
    /// Optional external transaction ID for idempotent CSV re-imports.
    public var externalID: String?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        date: String,
        source: String,
        merchant: String,
        amount: Int,
        group: String,
        category: String,
        note: String? = nil,
        origin: Origin = .manual,
        externalID: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.date = date
        self.source = source
        self.merchant = merchant
        self.amount = amount
        self.group = group
        self.category = category
        self.note = note
        self.origin = origin
        self.externalID = externalID
        self.createdAt = createdAt
    }

    public func asBudgetItem(config: LayerConfig, layers: [LayerDefinition]) -> BudgetItem {
        let displayMerchant: String
        if let note = note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            displayMerchant = "\(merchant) (\(note))"
        } else {
            displayMerchant = merchant
        }
        let layer = config.layer(group: group, category: category, layers: layers)
        return BudgetItem(
            date: date,
            source: source,
            merchant: displayMerchant,
            amount: amount,
            group: group,
            category: category,
            layer: layer,
            isPending: false
        )
    }
}

/// On-device category reassignment for either a single payment or every payment at one merchant.
public struct CategoryOverride: Codable, Sendable, Identifiable, Hashable {
    public enum Scope: Codable, Sendable, Hashable {
        /// Matches every transaction whose `TextFold.key(merchant)` equals `foldedKey`.
        case merchant(foldedKey: String, displayMerchant: String)
        /// Matches one specific transaction fingerprint (`date|source|amount|foldedMerchant`).
        case transaction(fingerprint: String, displayMerchant: String, date: String, amount: Int)
    }

    public var id: UUID
    public var scope: Scope
    public var group: String
    public var category: String
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        scope: Scope,
        group: String,
        category: String,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.scope = scope
        self.group = group
        self.category = category
        self.updatedAt = updatedAt
    }

    /// Stable fingerprint for single-transaction overrides.
    public static func transactionFingerprint(for item: BudgetItem) -> String {
        "\(item.date)|\(item.source)|\(item.amount)|\(TextFold.key(item.merchant))"
    }
}

/// Local bill checkoff recorded on the phone until a bank statement confirms it.
public struct BillCheckoff: Codable, Sendable, Hashable {
    public var key: String
    public var checkedAt: Date

    public init(key: String, checkedAt: Date = Date()) {
        self.key = key
        self.checkedAt = checkedAt
    }

    public static func key(for entry: TimelineEntry) -> String {
        "\(entry.date)|\(entry.item)|\(entry.amount)"
    }
}

/// All phone-local additions, overrides and dismissals kept separately from the PC bundle.
public struct LocalModifications: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    public var manualEntries: [ManualEntry]
    public var importedEntries: [ManualEntry]
    public var categoryOverrides: [CategoryOverride]
    public var billCheckoffs: [BillCheckoff]
    public var dismissedAlertIDs: Set<String>

    public init(
        version: Int = LocalModifications.currentVersion,
        manualEntries: [ManualEntry] = [],
        importedEntries: [ManualEntry] = [],
        categoryOverrides: [CategoryOverride] = [],
        billCheckoffs: [BillCheckoff] = [],
        dismissedAlertIDs: Set<String> = []
    ) {
        self.version = version
        self.manualEntries = manualEntries
        self.importedEntries = importedEntries
        self.categoryOverrides = categoryOverrides
        self.billCheckoffs = billCheckoffs
        self.dismissedAlertIDs = dismissedAlertIDs
    }

    public var isEmpty: Bool {
        manualEntries.isEmpty
            && importedEntries.isEmpty
            && categoryOverrides.isEmpty
            && billCheckoffs.isEmpty
            && dismissedAlertIDs.isEmpty
    }
}

/// Applies phone-local entries, category overrides and bill checkoffs without mutating the PC bundle.
public enum LocalDataApplier {
    public struct AppliedItems: Sendable, Equatable {
        /// All items (bundle + bank + pending + deduplicated local entries) with overrides applied.
        public var allItems: [BudgetItem]
        /// Set of `BudgetItem` values that originated from manual or CSV-imported local entries.
        public var localItemKeys: Set<String>
        /// Mapping from transaction fingerprint to local `ManualEntry.ID` for edit/delete lookup.
        public var localEntryByFingerprint: [String: UUID]
        /// Number of imported entries automatically suppressed because the bundle already contains them.
        public var supersededImportCount: Int
    }

    /// Merges manual and imported entries into the base item list and applies local category overrides.
    public static func apply(
        baseItems: [BudgetItem],
        modifications: LocalModifications,
        config: LayerConfig,
        layers: [LayerDefinition]
    ) -> AppliedItems {
        // Count base items by (date, source, amount, foldedMerchant) so overlapping CSV imports never double-count.
        var basePool: [String: Int] = [:]
        for item in baseItems {
            let fp = CategoryOverride.transactionFingerprint(for: item)
            basePool[fp, default: 0] += 1
        }

        var localItems: [BudgetItem] = []
        var localKeys = Set<String>()
        var entryByFP: [String: UUID] = [:]
        var superseded = 0

        for entry in modifications.manualEntries {
            let item = entry.asBudgetItem(config: config, layers: layers)
            let fp = CategoryOverride.transactionFingerprint(for: item)
            localItems.append(item)
            localKeys.insert(fp)
            entryByFP[fp] = entry.id
        }

        for entry in modifications.importedEntries {
            let item = entry.asBudgetItem(config: config, layers: layers)
            let fp = CategoryOverride.transactionFingerprint(for: item)
            if let remaining = basePool[fp], remaining > 0 {
                basePool[fp] = remaining - 1
                superseded += 1
                continue
            }
            localItems.append(item)
            localKeys.insert(fp)
            entryByFP[fp] = entry.id
        }

        let combined = baseItems + localItems
        guard !modifications.categoryOverrides.isEmpty else {
            return AppliedItems(
                allItems: combined,
                localItemKeys: localKeys,
                localEntryByFingerprint: entryByFP,
                supersededImportCount: superseded
            )
        }

        // Build lookup tables where newer overrides win.
        let sortedOverrides = modifications.categoryOverrides.sorted { $0.updatedAt < $1.updatedAt }
        var byMerchant: [String: (group: String, category: String)] = [:]
        var byTransaction: [String: (group: String, category: String)] = [:]
        for ov in sortedOverrides {
            switch ov.scope {
            case .merchant(let foldedKey, _):
                byMerchant[foldedKey] = (ov.group, ov.category)
            case .transaction(let fp, _, _, _):
                byTransaction[fp] = (ov.group, ov.category)
            }
        }

        let updated = combined.map { item -> BudgetItem in
            let fp = CategoryOverride.transactionFingerprint(for: item)
            let match = byTransaction[fp] ?? byMerchant[TextFold.key(item.merchant)]
            guard let match else { return item }
            var copy = item
            copy.group = match.group
            copy.category = match.category
            copy.layer = config.layer(group: match.group, category: match.category, layers: layers)
            return copy
        }

        return AppliedItems(
            allItems: updated,
            localItemKeys: localKeys,
            localEntryByFingerprint: entryByFP,
            supersededImportCount: superseded
        )
    }

    /// Marks open timeline entries checked off on the phone as `done`, returning the updated timeline
    /// and the set of keys that are phone-marked (rather than confirmed by bank data).
    public static func applyBillCheckoffs(
        timeline: [TimelineEntry],
        checkoffs: [BillCheckoff]
    ) -> (timeline: [TimelineEntry], phoneCheckedKeys: Set<String>) {
        guard !checkoffs.isEmpty else { return (timeline, []) }
        let checkKeys = Set(checkoffs.map(\.key))
        var phoneChecked = Set<String>()
        let updated = timeline.map { entry -> TimelineEntry in
            guard entry.done != true else { return entry }
            let key = BillCheckoff.key(for: entry)
            guard checkKeys.contains(key) else { return entry }
            phoneChecked.insert(key)
            var copy = entry
            copy.done = true
            return copy
        }
        return (updated, phoneChecked)
    }
}
