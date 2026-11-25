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
            isPending: false,
            isManual: true
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

    /// Stable key for a timeline entry: prefers its bundle `id` (surviving amount/date re-estimates),
    /// falling back to `date|item|amount` for legacy entries and custom reminders.
    public static func key(for entry: TimelineEntry) -> String {
        if let id = entry.id?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
            return "id:\(id)"
        }
        return legacyKey(for: entry)
    }

    public static func legacyKey(for entry: TimelineEntry) -> String {
        "\(entry.date)|\(entry.item)|\(entry.amount)"
    }

    public static func matches(_ entry: TimelineEntry, in keys: Set<String>) -> Bool {
        keys.contains(key(for: entry)) || keys.contains(legacyKey(for: entry))
    }
}

/// Custom bill, subscription cancellation reminder, or timeline event added on the phone.
public struct CustomReminder: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    /// Scheduled date in `"YYYY-MM-DD"` format.
    public var date: String
    public var title: String
    /// Whole yen; 0 for non-cash events, positive for outflow, negative for inflow.
    public var amount: Int
    public var note: String?
    public var isEvent: Bool
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        date: String,
        title: String,
        amount: Int = 0,
        note: String? = nil,
        isEvent: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.date = date
        self.title = title
        self.amount = amount
        self.note = note
        self.isEvent = isEvent
        self.createdAt = createdAt
    }

    public func asTimelineEntry() -> TimelineEntry {
        TimelineEntry(
            id: "rem:\(id.uuidString)",
            date: date,
            item: title,
            amount: isEvent ? 0 : amount,
            note: note,
            event: isEvent ? true : nil,
            recurring: false
        )
    }
}

/// All phone-local additions, overrides and dismissals kept separately from the PC bundle.
public struct LocalModifications: Codable, Sendable, Equatable {
    public static let currentVersion = 2

    public var version: Int
    public var manualEntries: [ManualEntry]
    public var importedEntries: [ManualEntry]
    public var categoryOverrides: [CategoryOverride]
    public var billCheckoffs: [BillCheckoff]
    public var dismissedAlertIDs: Set<String>
    /// Category name -> edited monthly yen cap synced back to PC.
    public var targetOverrides: [String: Int]
    /// Debt name -> updated balance yen synced back to PC.
    public var debtBalanceOverrides: [String: Int]
    /// Debt name -> JST `"YYYY-MM-DD"` date when that debt balance override was entered,
    /// keeping CreditRoom `asOf` anchored to the edit date instead of drifting with later unrelated edits.
    public var debtBalanceOverrideDates: [String: String]
    /// Debt name -> ISO-8601 JST timestamp when that debt balance override was entered,
    /// allowing same-day charges received strictly after the override to draw down credit room live.
    public var debtBalanceOverrideTimestamps: [String: String]
    /// User-added bills and cancellation/review reminders merged into Coming up.
    public var customReminders: [CustomReminder]
    /// Stable timeline IDs (`"rem:<UUID>"`) of custom reminders deleted on the phone, so PC-round-tripped
    /// copies disappear immediately before the next PC rebuild completes.
    public var deletedCustomReminderIDs: Set<String>
    /// Item or alert keys confirmed in the daily Review inbox.
    public var reviewedItemKeys: Set<String>
    /// Fingerprints (`date|source|amount|foldedMerchant`) of previously-synced local entries deleted on the phone.
    public var deletedEntryFingerprints: Set<String>
    /// Exact deletion counts per fingerprint so deleting one of two identical same-day entries only hides one.
    public var deletedEntryFingerprintCounts: [String: Int]
    /// Last modification timestamp for two-way Drive sync.
    public var updatedAt: Date?

    public init(
        version: Int = LocalModifications.currentVersion,
        manualEntries: [ManualEntry] = [],
        importedEntries: [ManualEntry] = [],
        categoryOverrides: [CategoryOverride] = [],
        billCheckoffs: [BillCheckoff] = [],
        dismissedAlertIDs: Set<String> = [],
        targetOverrides: [String: Int] = [:],
        debtBalanceOverrides: [String: Int] = [:],
        debtBalanceOverrideDates: [String: String] = [:],
        debtBalanceOverrideTimestamps: [String: String] = [:],
        customReminders: [CustomReminder] = [],
        deletedCustomReminderIDs: Set<String> = [],
        reviewedItemKeys: Set<String> = [],
        deletedEntryFingerprints: Set<String> = [],
        deletedEntryFingerprintCounts: [String: Int] = [:],
        updatedAt: Date? = nil
    ) {
        self.version = version
        self.manualEntries = manualEntries
        self.importedEntries = importedEntries
        self.categoryOverrides = categoryOverrides
        self.billCheckoffs = billCheckoffs
        self.dismissedAlertIDs = dismissedAlertIDs
        self.targetOverrides = targetOverrides
        self.debtBalanceOverrides = debtBalanceOverrides
        self.debtBalanceOverrideDates = debtBalanceOverrideDates
        self.debtBalanceOverrideTimestamps = debtBalanceOverrideTimestamps
        self.customReminders = customReminders
        self.deletedCustomReminderIDs = deletedCustomReminderIDs
        self.reviewedItemKeys = reviewedItemKeys
        self.deletedEntryFingerprints = deletedEntryFingerprints
        self.deletedEntryFingerprintCounts = deletedEntryFingerprintCounts
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case version, manualEntries, importedEntries, categoryOverrides, billCheckoffs, dismissedAlertIDs
        case targetOverrides, debtBalanceOverrides, debtBalanceOverrideDates, debtBalanceOverrideTimestamps
        case customReminders, deletedCustomReminderIDs, reviewedItemKeys
        case deletedEntryFingerprints, deletedEntryFingerprintCounts, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        manualEntries = try c.decodeIfPresent([ManualEntry].self, forKey: .manualEntries) ?? []
        importedEntries = try c.decodeIfPresent([ManualEntry].self, forKey: .importedEntries) ?? []
        categoryOverrides = try c.decodeIfPresent([CategoryOverride].self, forKey: .categoryOverrides) ?? []
        billCheckoffs = try c.decodeIfPresent([BillCheckoff].self, forKey: .billCheckoffs) ?? []
        dismissedAlertIDs = try c.decodeIfPresent(Set<String>.self, forKey: .dismissedAlertIDs) ?? []
        targetOverrides = try c.decodeIfPresent([String: Int].self, forKey: .targetOverrides) ?? [:]
        debtBalanceOverrides = try c.decodeIfPresent([String: Int].self, forKey: .debtBalanceOverrides) ?? [:]
        debtBalanceOverrideDates = try c.decodeIfPresent([String: String].self, forKey: .debtBalanceOverrideDates) ?? [:]
        debtBalanceOverrideTimestamps = try c.decodeIfPresent([String: String].self, forKey: .debtBalanceOverrideTimestamps) ?? [:]
        customReminders = try c.decodeIfPresent([CustomReminder].self, forKey: .customReminders) ?? []
        deletedCustomReminderIDs = try c.decodeIfPresent(Set<String>.self, forKey: .deletedCustomReminderIDs) ?? []
        reviewedItemKeys = try c.decodeIfPresent(Set<String>.self, forKey: .reviewedItemKeys) ?? []
        deletedEntryFingerprints = try c.decodeIfPresent(Set<String>.self, forKey: .deletedEntryFingerprints) ?? []
        deletedEntryFingerprintCounts = try c.decodeIfPresent([String: Int].self, forKey: .deletedEntryFingerprintCounts) ?? [:]
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
    }

    /// Freezes any legacy debt overrides lacking a per-debt date onto the prior `updatedAt` day
    /// before a new edit updates `updatedAt`.
    public mutating func stampLegacyDebtOverrideDates() {
        guard !debtBalanceOverrides.isEmpty, let previous = updatedAt else { return }
        let prevDay = JST.day(previous)
        for name in debtBalanceOverrides.keys where debtBalanceOverrideDates[name] == nil {
            debtBalanceOverrideDates[name] = prevDay
        }
    }

    public var isEmpty: Bool {
        manualEntries.isEmpty
            && importedEntries.isEmpty
            && categoryOverrides.isEmpty
            && billCheckoffs.isEmpty
            && dismissedAlertIDs.isEmpty
            && targetOverrides.isEmpty
            && debtBalanceOverrides.isEmpty
            && debtBalanceOverrideDates.isEmpty
            && debtBalanceOverrideTimestamps.isEmpty
            && customReminders.isEmpty
            && deletedCustomReminderIDs.isEmpty
            && reviewedItemKeys.isEmpty
            && deletedEntryFingerprints.isEmpty
            && deletedEntryFingerprintCounts.isEmpty
    }
}

/// Applies phone-local entries, category overrides and bill checkoffs without mutating the PC bundle.
public enum LocalDataApplier {
    public struct AppliedItems: Sendable, Equatable {
        /// All items (bundle + bank + pending + deduplicated local entries) with overrides applied.
        public var allItems: [BudgetItem]
        /// Set of transaction fingerprints that originated from manual or CSV-imported local entries.
        public var localItemKeys: Set<String>
        /// Mapping from transaction fingerprint to local `ManualEntry.ID` for edit/delete lookup.
        public var localEntryByFingerprint: [String: UUID]
        /// Number of manual/imported entries automatically suppressed because the bundle already contains them.
        public var supersededImportCount: Int
    }

    /// Merges manual and imported entries into the base item list and applies local category overrides.
    ///
    /// Deduplicates BOTH `manualEntries` and `importedEntries` against `baseItems` so two-way Drive sync
    /// round-trips never double-count cash entries or scanned receipts once the PC bundle absorbs them,
    /// while preserving `localItemKeys` and `localEntryByFingerprint` so the user can still delete them.
    public static func apply(
        baseItems: [BudgetItem],
        modifications: LocalModifications,
        config: LayerConfig,
        layers: [LayerDefinition],
        appliedBundleDeletions: [String: Int] = [:]
    ) -> AppliedItems {
        // Build per-fingerprint deletion counts so deleting 1 of 2 identical same-day local entries
        // never hides the second copy, never filters out live pending email notices, and subtracts
        // deletions the PC bundle already applied so a synced tombstone never deletes a second copy.
        var deleteBudget: [String: Int] = modifications.deletedEntryFingerprintCounts.filter { $0.value > 0 }
        for fp in modifications.deletedEntryFingerprints where deleteBudget[fp] == nil {
            deleteBudget[fp] = 1
        }
        if !appliedBundleDeletions.isEmpty {
            for (fp, pcApplied) in appliedBundleDeletions where pcApplied > 0 {
                if let current = deleteBudget[fp] {
                    let remaining = current - pcApplied
                    if remaining > 0 {
                        deleteBudget[fp] = remaining
                    } else {
                        deleteBudget.removeValue(forKey: fp)
                    }
                }
            }
        }

        let filteredBase: [BudgetItem]
        if deleteBudget.isEmpty {
            filteredBase = baseItems
        } else {
            var remainingDeletes = deleteBudget
            filteredBase = baseItems.filter { item in
                guard !item.isPending else { return true }
                let fp = CategoryOverride.transactionFingerprint(for: item)
                if let count = remainingDeletes[fp], count > 0 {
                    remainingDeletes[fp] = count - 1
                    return false
                }
                return true
            }
        }

        // Count confirmed base items by (date, source, amount, foldedMerchant) so round-tripped entries never double-count.
        var basePool: [String: Int] = [:]
        for item in filteredBase where !item.isPending {
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
            if let remaining = basePool[fp], remaining > 0 {
                basePool[fp] = remaining - 1
                superseded += 1
                // Keep manual cash/receipt entries deletable even after PC bundle absorption,
                // without marking live bank or pending rows from other sources as phone-local.
                if entry.source.caseInsensitiveCompare("Cash") == .orderedSame {
                    localKeys.insert(fp)
                    if entryByFP[fp] == nil { entryByFP[fp] = entry.id }
                }
                continue
            }
            localItems.append(item)
            localKeys.insert(fp)
            if entryByFP[fp] == nil { entryByFP[fp] = entry.id }
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
            if entryByFP[fp] == nil { entryByFP[fp] = entry.id }
        }

        let combined = filteredBase + localItems
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

    /// Marks open timeline entries checked off on the phone as `done` + `phoneChecked`, preserving
    /// PC round-tripped `phoneChecked` entries so cash holds remain intact and undoable until a bank row confirms them.
    public static func applyBillCheckoffs(
        timeline: [TimelineEntry],
        checkoffs: [BillCheckoff]
    ) -> (timeline: [TimelineEntry], phoneCheckedKeys: Set<String>) {
        let checkKeys = Set(checkoffs.map(\.key))
        var phoneChecked = Set<String>()
        let updated = timeline.map { entry -> TimelineEntry in
            let stableKey = BillCheckoff.key(for: entry)
            let isCheckedOnPhone = BillCheckoff.matches(entry, in: checkKeys)

            // Entry round-tripped from the PC as phone-checked (not bank-confirmed):
            if entry.phoneChecked == true {
                var copy = entry
                if isCheckedOnPhone {
                    copy.done = true
                    copy.phoneChecked = true
                    phoneChecked.insert(stableKey)
                } else {
                    // User unchecked it on the phone (or it is no longer checked locally).
                    copy.done = nil
                    copy.phoneChecked = nil
                }
                return copy
            }

            // Already confirmed by bank/statement: leave untouched.
            guard entry.done != true else { return entry }
            guard isCheckedOnPhone else { return entry }
            phoneChecked.insert(stableKey)
            var copy = entry
            copy.done = true
            copy.phoneChecked = true
            return copy
        }
        return (updated, phoneChecked)
    }

    /// Applies on-device monthly cap edits to the bundle's plan rows.
    /// Categories not yet in `plan` are appended as active `"Cut"` rows using `recentAverage` when supplied.
    public static func applyPlanOverrides(
        plan: [PlanEntry],
        overrides: [String: Int],
        recentAverageByCategory: [String: Int] = [:]
    ) -> [PlanEntry] {
        guard !overrides.isEmpty else { return plan }
        var seen = Set<String>()
        var updated = plan.map { entry -> PlanEntry in
            seen.insert(entry.category)
            guard let customTarget = overrides[entry.category] else { return entry }
            var copy = entry
            copy.target = max(0, customTarget)
            return copy
        }
        for (category, target) in overrides.sorted(by: { $0.key < $1.key }) where !seen.contains(category) {
            let baseline = recentAverageByCategory[category] ?? target
            updated.append(PlanEntry(
                category: category,
                now: max(0, baseline),
                target: max(0, target),
                status: "Cut",
                note: "Target set on phone"
            ))
        }
        return updated
    }

    /// Applies on-device balance updates to tracked debts.
    public static func applyDebtOverrides(
        debts: [DebtEntry],
        overrides: [String: Int]
    ) -> [DebtEntry] {
        guard !overrides.isEmpty else { return debts }
        return debts.map { debt in
            guard let updatedBalance = overrides[debt.name] else { return debt }
            var copy = debt
            copy.balance = max(0, updatedBalance)
            return copy
        }
    }

    /// Merges phone-created reminders and custom bills into the timeline, deduplicating PC-round-tripped
    /// reminders by stable `rem:<UUID>` ID and hiding any reminders deleted on the phone.
    public static func mergeCustomReminders(
        timeline: [TimelineEntry],
        reminders: [CustomReminder],
        deletedIDs: Set<String> = []
    ) -> [TimelineEntry] {
        var combined = deletedIDs.isEmpty ? timeline : timeline.filter { entry in
            if let id = entry.id {
                return !deletedIDs.contains(id)
            }
            return !deletedIDs.contains("legacy:\(BillCheckoff.legacyKey(for: entry))")
        }
        guard !reminders.isEmpty else { return combined }

        var existingIDs = Set(combined.compactMap(\.id))
        // Seed legacy key counts ONLY from bundle timeline entries lacking an `id` (1-to-1 multiset),
        // never inserting newly merged phone reminders so two identical local reminders with distinct
        // UUIDs both stay visible before and after PC round-trip.
        var existingLegacyCounts: [String: Int] = [:]
        for entry in combined where entry.id == nil {
            existingLegacyCounts[BillCheckoff.legacyKey(for: entry), default: 0] += 1
        }
        for reminder in reminders {
            let entry = reminder.asTimelineEntry()
            let remID = entry.id ?? "rem:\(reminder.id.uuidString)"
            if deletedIDs.contains(remID) || existingIDs.contains(remID) {
                continue
            }
            let legacyKey = BillCheckoff.legacyKey(for: entry)
            if let remCount = existingLegacyCounts[legacyKey], remCount > 0 {
                existingLegacyCounts[legacyKey] = remCount - 1
                continue
            }
            combined.append(entry)
            existingIDs.insert(remID)
        }
        return combined.sorted {
            if $0.date != $1.date { return $0.date < $1.date }
            if $0.item != $1.item { return $0.item < $1.item }
            return ($0.id ?? "") < ($1.id ?? "")
        }
    }
}
