import Foundation

/// Timeline entries grouped under a single "YYYY-MM-DD" date.
public struct ComingUpGroup: Codable, Sendable, Equatable {
    public var date: String
    public var entries: [TimelineEntry]
    public var isPast: Bool
    public var isToday: Bool
    public var hasPayday: Bool

    public init(
        date: String,
        entries: [TimelineEntry],
        isPast: Bool,
        isToday: Bool,
        hasPayday: Bool
    ) {
        self.date = date
        self.entries = entries
        self.isPast = isPast
        self.isToday = isToday
        self.hasPayday = hasPayday
    }
}

/// Groups timeline entries by day in ascending chronological order.
public enum ComingUp {
    /// Groups `timeline` by date ascending, preserving entry order within each day.
    public static func groups(timeline: [TimelineEntry], today: String) -> [ComingUpGroup] {
        var byDate: [String: [TimelineEntry]] = [:]
        for entry in timeline {
            byDate[entry.date, default: []].append(entry)
        }
        return byDate.keys.sorted().map { date in
            let entries = byDate[date] ?? []
            return ComingUpGroup(
                date: date,
                entries: entries,
                isPast: date < today,
                isToday: date == today,
                hasPayday: entries.contains { $0.payday == true }
            )
        }
    }

    /// Convenience overload converting a `Date` to a Japan-time "YYYY-MM-DD" day.
    public static func groups(timeline: [TimelineEntry], today: Date) -> [ComingUpGroup] {
        groups(timeline: timeline, today: JST.day(today))
    }
}
