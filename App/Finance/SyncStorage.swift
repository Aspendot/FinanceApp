import FinanceCore
import FinanceSync
import Foundation

/// One pending payment alert persisted until `UNUserNotificationCenter.add` succeeds.
struct PendingPaymentAlert: Codable, Equatable, Sendable {
    var messageID: String
    var amount: Int
    var merchant: String
    var sourceLabel: String
    var isDiscreet: Bool
}

struct PendingPaymentSummary: Codable, Equatable, Sendable {
    var id = UUID()
    var count: Int
}

/// Persisted atomically in one file so seen IDs, notices and the payment alert queue
/// are always committed together.
struct SyncStoreState: Codable, Equatable, Sendable {
    var syncState: SyncState
    var notices: [Notice]
    var alertQueue: [PendingPaymentAlert]
    var pendingSummary: PendingPaymentSummary? = nil
    var overflowAlertCount: Int? = nil
    var lastShortcutAttempt: Date? = nil

    init(
        syncState: SyncState = SyncState(),
        notices: [Notice] = [],
        alertQueue: [PendingPaymentAlert] = []
    ) {
        self.syncState = syncState
        self.notices = notices
        self.alertQueue = alertQueue
    }
}

/// Which entry point triggered a sync run.
enum SyncTrigger: String, Codable, Sendable {
    case app
    case background
    case shortcut
}

/// Result status of a single sync run.
enum SyncOutcome: String, Codable, Sendable {
    case updated
    case skipped
    case busy
    case notSignedIn
    case signInRequired
    case timedOut
    case cancelled
    case failed

    var label: String {
        switch self {
        case .updated: return "Updated"
        case .skipped: return "Skipped"
        case .busy: return "Busy"
        case .notSignedIn: return "Not signed in"
        case .signInRequired: return "Sign in to Gmail again"
        case .timedOut: return "Timed out"
        case .cancelled: return "Cancelled"
        case .failed: return "Failed"
        }
    }
}

/// One persisted entry in the sync run log.
struct SyncRunRecord: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    var trigger: SyncTrigger
    var startedAt: Date
    var durationSeconds: Double
    var outcome: SyncOutcome
    var newNotices: Int
    var newPayments: Int
    var notifiedCount: Int
    var errorMessage: String?

    init(
        id: UUID = UUID(),
        trigger: SyncTrigger,
        startedAt: Date,
        durationSeconds: Double,
        outcome: SyncOutcome,
        newNotices: Int = 0,
        newPayments: Int = 0,
        notifiedCount: Int = 0,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.trigger = trigger
        self.startedAt = startedAt
        self.durationSeconds = durationSeconds
        self.outcome = outcome
        self.newNotices = newNotices
        self.newPayments = newPayments
        self.notifiedCount = notifiedCount
        self.errorMessage = errorMessage
    }
}

/// Return value from `SyncEngine.run`.
struct SyncReport: Equatable, Sendable {
    var trigger: SyncTrigger
    var startedAt: Date
    var durationSeconds: Double
    var outcome: SyncOutcome
    var newNotices: Int
    var newPayments: Int
    var notifiedCount: Int
    var errorMessage: String?

    var record: SyncRunRecord {
        SyncRunRecord(
            trigger: trigger,
            startedAt: startedAt,
            durationSeconds: durationSeconds,
            outcome: outcome,
            newNotices: newNotices,
            newPayments: newPayments,
            notifiedCount: notifiedCount,
            errorMessage: errorMessage
        )
    }
}

/// App-local atomic file storage for Gmail sync state, the payment alert queue and the run log.
enum SyncStorage {
    private static let legacyCacheKey = "gmailSyncCache"
    private static let legacyStateKey = "gmailSyncState"
    private static let legacyNoticesKey = "recentNotices"
    private static let maxRunLogEntries = 100

    private struct LegacyCache: Codable {
        var state: SyncState
        var notices: [Notice]
    }

    private static var dataDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FinanceData", isDirectory: true)
    }

    private static var stateURL: URL {
        dataDirectory.appendingPathComponent("gmail-sync-state.json")
    }

    private static var runLogURL: URL {
        dataDirectory.appendingPathComponent("sync-runs.json")
    }

    @discardableResult
    private static func ensureDataDirectory() throws -> URL {
        var folder = dataDirectory
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        return folder
    }

    private static func writeProtected(_ data: Data, to url: URL) throws {
        _ = try ensureDataDirectory()
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Loads the persisted sync state, falling back to earlier `UserDefaults.standard` keys.
    static func loadState() throws -> SyncStoreState {
        let decoder = JSONDecoder()
        do {
            return try decoder.decode(SyncStoreState.self, from: Data(contentsOf: stateURL))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // Try legacy storage only when there is no current file.
        }
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: legacyCacheKey) {
            let legacy = try decoder.decode(LegacyCache.self, from: data)
            return SyncStoreState(syncState: legacy.state, notices: legacy.notices, alertQueue: [])
        }
        let state = try defaults.data(forKey: legacyStateKey).map { try decoder.decode(SyncState.self, from: $0) }
        let notices = try defaults.data(forKey: legacyNoticesKey).map { try decoder.decode([Notice].self, from: $0) }
        return SyncStoreState(syncState: state ?? SyncState(), notices: notices ?? [], alertQueue: [])
    }

    /// Atomically commits seen IDs, notices and the payment alert queue together.
    static func saveState(_ state: SyncStoreState) throws {
        let data = try JSONEncoder().encode(state)
        try writeProtected(data, to: stateURL)
        removeLegacyDefaults()
    }

    static func clearState() throws {
        do {
            try FileManager.default.removeItem(at: stateURL)
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            // The sync state has not been created.
        }
        removeLegacyDefaults()
    }

    private static func removeLegacyDefaults() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: legacyCacheKey)
        defaults.removeObject(forKey: legacyStateKey)
        defaults.removeObject(forKey: legacyNoticesKey)
    }

    static func loadRunLog() -> [SyncRunRecord] {
        guard let data = try? Data(contentsOf: runLogURL),
              let records = try? JSONDecoder().decode([SyncRunRecord].self, from: data)
        else {
            return []
        }
        return records
    }

    static func appendRunRecord(_ record: SyncRunRecord) {
        var records = loadRunLog()
        records.insert(record, at: 0)
        if records.count > maxRunLogEntries {
            records = Array(records.prefix(maxRunLogEntries))
        }
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? writeProtected(data, to: runLogURL)
    }

    /// Formats a check timestamp as "10:42" today, or "Nov 22, 10:42" on an earlier day.
    static func formatCheckTime(_ date: Date, now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = JST.timeZone
        formatter.dateFormat = JST.day(date) == JST.day(now) ? "HH:mm" : "MMM d, HH:mm"
        return formatter.string(from: date)
    }
}
