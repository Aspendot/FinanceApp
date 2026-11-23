import SwiftUI
import WidgetKit

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
    let hasGroup: Bool
}

struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: Date(), snapshot: .placeholder, hasGroup: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : current())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        completion(Timeline(entries: [current()], policy: .after(Date(timeIntervalSinceNow: 30 * 60))))
    }

    private func current() -> SnapshotEntry {
        SnapshotEntry(date: Date(), snapshot: SharedStore.read() ?? .placeholder, hasGroup: SharedStore.groupID != nil)
    }
}

struct FinanceWidgetView: View {
    let entry: SnapshotEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.snapshot.title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .privacySensitive()
            Text(entry.snapshot.value)
                .font(.title2.weight(.semibold))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .privacySensitive()
            Text(entry.hasGroup ? entry.snapshot.detail : "No shared data (App Group missing)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .privacySensitive()
            if entry.hasGroup, let updated = Self.updatedLabel(entry.snapshot.updatedAt) {
                Text(updated)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private static func updatedLabel(_ date: Date) -> String? {
        guard date != .distantPast else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "MMM d, HH:mm"
        return "Updated " + formatter.string(from: date)
    }
}

@main
struct FinanceWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "FinanceWidget", provider: SnapshotProvider()) { entry in
            FinanceWidgetView(entry: entry)
        }
        .configurationDisplayName("Finance")
        .description("A value shared by the Finance app.")
        .supportedFamilies([.systemSmall, .accessoryRectangular])
    }
}
