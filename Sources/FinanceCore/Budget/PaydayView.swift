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

    /// Computes the payday view for the active pay cycle leading up to the first entry marked `next == true`.
    /// Starts at the latest `payday == true` entry before `next` when one exists, otherwise from the start of the timeline.
    /// Returns nil when no entry is marked `next == true` or either date is invalid.
    public static func compute(timeline: [TimelineEntry], today: String) -> PaydayView? {
        guard let next = timeline.first(where: { $0.next == true }),
              let nextDay = JST.dayNumber(next.date),
              let todayDay = JST.dayNumber(today)
        else {
            return nil
        }

        let prior = timeline.filter { $0.next != true && $0.date < next.date }
        let cycleStart = prior.filter { $0.payday == true }.map(\.date).max()
        let period = cycleStart.map { start in prior.filter { $0.date >= start } } ?? prior
        let ins = period.filter { $0.amount < 0 && $0.borrowed != true }
        let outs = period.filter { $0.amount > 0 }
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
