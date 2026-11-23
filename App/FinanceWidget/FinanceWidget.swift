import SwiftUI
import UIKit
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

private enum WidgetPalette {
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x15181C)
    static let ink = dynamic(light: 0x111318, dark: 0xECEEF2)
    static let ink2 = dynamic(light: 0x414752, dark: 0xB4BAC4)
    static let muted = dynamic(light: 0x6B7280, dark: 0x868D98)
    static let line = dynamic(light: 0xDDE0E6, dark: 0x272B32)
    static let bad = dynamic(light: 0xB8322A, dark: 0xF2766B)

    private static func dynamic(light: Int, dark: Int) -> Color {
        Color(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255.0,
                green: CGFloat((hex >> 8) & 0xFF) / 255.0,
                blue: CGFloat(hex & 0xFF) / 255.0,
                alpha: 1.0
            )
        })
    }
}

struct FinanceWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotEntry

    var body: some View {
        switch family {
        case .accessoryRectangular:
            accessoryRectangularBody
                .containerBackground(Color.clear, for: .widget)
        default:
            systemSmallBody
                .containerBackground(WidgetPalette.surface, for: .widget)
        }
    }

    private var systemSmallBody: some View {
        let isNegative = entry.snapshot.value.hasPrefix("−") || entry.snapshot.value.hasPrefix("-")
        let detailText = entry.hasGroup ? entry.snapshot.detail : "No shared data (App Group missing)"

        return VStack(alignment: .leading, spacing: 6) {
            Text(entry.snapshot.title.uppercased())
                .font(.system(size: 11, weight: .semibold, design: .default))
                .tracking(0.6)
                .foregroundStyle(WidgetPalette.muted)
                .lineLimit(1)
                .privacySensitive()

            Text(entry.snapshot.value)
                .font(.system(size: 28, weight: .semibold, design: .default))
                .tracking(-0.6)
                .monospacedDigit()
                .foregroundStyle(isNegative ? WidgetPalette.bad : WidgetPalette.ink)
                .minimumScaleFactor(0.55)
                .lineLimit(1)
                .privacySensitive()
                .accessibilityLabel(Self.yenSpeech(entry.snapshot.value))

            Text(detailText)
                .font(.caption)
                .foregroundStyle(WidgetPalette.ink2)
                .lineLimit(2)
                .privacySensitive()

            Spacer(minLength: 4)

            if entry.hasGroup, let updated = Self.updatedLabel(entry.snapshot.updatedAt) {
                Rectangle()
                    .fill(WidgetPalette.line)
                    .frame(height: 0.5)
                Text(updated)
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(WidgetPalette.muted)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var accessoryRectangularBody: some View {
        let updated = entry.hasGroup ? Self.updatedLabel(entry.snapshot.updatedAt) : nil
        let detail = entry.hasGroup ? entry.snapshot.detail : "App Group missing"

        return VStack(alignment: .leading, spacing: 2) {
            Text(entry.snapshot.title.uppercased())
                .font(.system(size: 10, weight: .semibold, design: .default))
                .tracking(0.5)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .privacySensitive()

            Text(entry.snapshot.value)
                .font(.system(size: 22, weight: .semibold, design: .default))
                .tracking(-0.4)
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .privacySensitive()
                .accessibilityLabel(Self.yenSpeech(entry.snapshot.value))

            Text(updated ?? detail)
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .privacySensitive()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func updatedLabel(_ date: Date) -> String? {
        guard date != .distantPast else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "MMM d, HH:mm"
        return "Updated " + formatter.string(from: date)
    }

    private static func yenSpeech(_ value: String) -> String {
        if value.hasPrefix("−¥") || value.hasPrefix("-¥") {
            return "minus \(value.dropFirst(2)) yen"
        }
        if value.hasPrefix("+¥") {
            return "plus \(value.dropFirst(2)) yen"
        }
        if value.hasPrefix("¥") {
            return "\(value.dropFirst(1)) yen"
        }
        return value
    }
}

@main
struct FinanceWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "FinanceWidget", provider: SnapshotProvider()) { entry in
            FinanceWidgetView(entry: entry)
        }
        .configurationDisplayName("Finance")
        .description("Until payday balance shared by the Finance app.")
        .supportedFamilies([.systemSmall, .accessoryRectangular])
    }
}
