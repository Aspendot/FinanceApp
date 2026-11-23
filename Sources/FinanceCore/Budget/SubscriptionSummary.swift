import Foundation

/// Visual tone for a subscription or budget plan status badge.
public enum StatusTone: String, Codable, Sendable, Equatable {
    case good
    case bad
    case accent
    case neutral
}

/// One subscription enriched with active/off classification and badge styling.
public struct SubscriptionItem: Sendable, Equatable, Identifiable {
    public var id: String { "\(entry.name)|\(entry.via ?? "")|\(entry.monthly)|\(entry.status ?? "")" }
    public var entry: SubscriptionEntry
    /// True when the subscription is stopped, ended, repaid, cancelled or not subscribed.
    public var isOff: Bool
    /// True when an off subscription counts toward monthly savings (excludes repaid and not subscribed).
    public var countsAsSaving: Bool
    /// Human-readable status text (maps "OK" to "On target").
    public var displayStatus: String?
    public var tone: StatusTone

    public init(
        entry: SubscriptionEntry,
        isOff: Bool,
        countsAsSaving: Bool,
        displayStatus: String?,
        tone: StatusTone
    ) {
        self.entry = entry
        self.isOff = isOff
        self.countsAsSaving = countsAsSaving
        self.displayStatus = displayStatus
        self.tone = tone
    }
}

/// Separated summary of running vs stopped/cancelled subscriptions and monthly savings.
public struct SubscriptionSummary: Sendable, Equatable {
    public var running: [SubscriptionItem]
    public var stopped: [SubscriptionItem]
    public var runningMonthlyTotal: Int
    public var runningAnnualTotal: Int
    public var monthlySavings: Int
    public var annualSavings: Int

    public var runningCount: Int { running.count }
    public var stoppedCount: Int { stopped.count }
    public var isEmpty: Bool { running.isEmpty && stopped.isEmpty }

    public init(
        running: [SubscriptionItem] = [],
        stopped: [SubscriptionItem] = [],
        runningMonthlyTotal: Int = 0,
        runningAnnualTotal: Int = 0,
        monthlySavings: Int = 0,
        annualSavings: Int = 0
    ) {
        self.running = running
        self.stopped = stopped
        self.runningMonthlyTotal = runningMonthlyTotal
        self.runningAnnualTotal = runningAnnualTotal
        self.monthlySavings = monthlySavings
        self.annualSavings = annualSavings
    }

    private static let offPrefixes = [
        "stopped", "ends", "repaid", "cancelled", "canceled", "not subscribed"
    ]

    private static let nonSavingOffPrefixes = [
        "repaid", "not subscribed"
    ]

    public static func isOffStatus(_ status: String?) -> Bool {
        guard let raw = status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty
        else { return false }
        return offPrefixes.contains { raw.hasPrefix($0) }
    }

    public static func countsAsSavingStatus(_ status: String?) -> Bool {
        guard isOffStatus(status),
              let raw = status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        else { return false }
        return !nonSavingOffPrefixes.contains { raw.hasPrefix($0) }
    }

    public static func statusTone(_ status: String?) -> StatusTone {
        guard let raw = status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty
        else { return .neutral }
        if raw.hasPrefix("cut") { return .bad }
        if raw.hasPrefix("check") || raw.hasPrefix("review") || raw.hasPrefix("your call")
            || raw.hasPrefix("raise") || raw == "keep?"
        {
            return .accent
        }
        if raw.hasPrefix("done") || raw.hasPrefix("stopped") || raw.hasPrefix("ends")
            || raw == "ok" || raw.hasPrefix("ok ") || raw.hasPrefix("cancelled")
            || raw.hasPrefix("canceled")
        {
            return .good
        }
        return .neutral
    }

    public static func displayStatus(_ status: String?) -> String? {
        guard let trimmed = status?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        let lower = trimmed.lowercased()
        if lower == "active" { return nil }
        if lower == "ok" { return "On target" }
        return trimmed
    }

    /// Computes separated running and off subscription totals, sorted highest monthly cost first.
    public static func compute(from subs: [SubscriptionEntry]) -> SubscriptionSummary {
        var running: [SubscriptionItem] = []
        var stopped: [SubscriptionItem] = []

        for entry in subs {
            let off = isOffStatus(entry.status)
            let saving = countsAsSavingStatus(entry.status)
            let item = SubscriptionItem(
                entry: entry,
                isOff: off,
                countsAsSaving: saving,
                displayStatus: displayStatus(entry.status),
                tone: statusTone(entry.status)
            )
            if off {
                stopped.append(item)
            } else {
                running.append(item)
            }
        }

        let sortOrder: (SubscriptionItem, SubscriptionItem) -> Bool = { a, b in
            if a.entry.monthly != b.entry.monthly {
                return a.entry.monthly > b.entry.monthly
            }
            return a.entry.name.localizedCaseInsensitiveCompare(b.entry.name) == .orderedAscending
        }
        running.sort(by: sortOrder)
        stopped.sort(by: sortOrder)

        let runningMonthly = running.reduce(0) { $0 + $1.entry.monthly }
        let savings = stopped.filter(\.countsAsSaving).reduce(0) { $0 + $1.entry.monthly }

        return SubscriptionSummary(
            running: running,
            stopped: stopped,
            runningMonthlyTotal: runningMonthly,
            runningAnnualTotal: runningMonthly * 12,
            monthlySavings: savings,
            annualSavings: savings * 12
        )
    }
}
