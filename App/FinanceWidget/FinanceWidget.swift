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
    static let track = dynamic(light: 0xE7E9ED, dark: 0x262A31)
    static let good = dynamic(light: 0x0F7140, dark: 0x45C985)
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
        case .systemMedium:
            systemMediumBody
                .containerBackground(WidgetPalette.surface, for: .widget)
        case .accessoryRectangular:
            accessoryRectangularBody
                .containerBackground(Color.clear, for: .widget)
        case .accessoryCircular:
            accessoryCircularBody
                .containerBackground(Color.clear, for: .widget)
        case .accessoryInline:
            accessoryInlineBody
                .containerBackground(Color.clear, for: .widget)
        default:
            systemSmallBody
                .containerBackground(WidgetPalette.surface, for: .widget)
        }
    }

    private var isNegative: Bool {
        entry.snapshot.value.hasPrefix("−") || entry.snapshot.value.hasPrefix("-")
    }

    // MARK: - Small Home Screen

    private var systemSmallBody: some View {
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

            if let bills = entry.snapshot.billsSum, let left = entry.snapshot.leftSum, bills + abs(left) > 0 {
                miniSplitBar(bills: bills, left: left)
            }

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

    // MARK: - Medium Home Screen (Payday + Next Bills)

    private var systemMediumBody: some View {
        let bills = entry.snapshot.upcomingBills ?? []
        return HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.snapshot.title.uppercased())
                    .font(.system(size: 10.5, weight: .semibold, design: .default))
                    .tracking(0.5)
                    .foregroundStyle(WidgetPalette.muted)
                    .lineLimit(1)
                    .privacySensitive()

                Text(entry.snapshot.value)
                    .font(.system(size: 27, weight: .semibold, design: .default))
                    .tracking(-0.6)
                    .monospacedDigit()
                    .foregroundStyle(isNegative ? WidgetPalette.bad : WidgetPalette.ink)
                    .minimumScaleFactor(0.55)
                    .lineLimit(1)
                    .privacySensitive()
                    .accessibilityLabel(Self.yenSpeech(entry.snapshot.value))

                if let bSum = entry.snapshot.billsSum, let lSum = entry.snapshot.leftSum, bSum + abs(lSum) > 0 {
                    miniSplitBar(bills: bSum, left: lSum)
                }

                Text(entry.hasGroup ? entry.snapshot.detail : "App Group missing")
                    .font(.caption)
                    .foregroundStyle(WidgetPalette.ink2)
                    .lineLimit(2)
                    .privacySensitive()

                Spacer(minLength: 2)

                if entry.hasGroup, let updated = Self.updatedLabel(entry.snapshot.updatedAt) {
                    Text(updated)
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(WidgetPalette.muted)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Rectangle()
                .fill(WidgetPalette.line)
                .frame(width: 0.5)
                .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 6) {
                Text("NEXT BILLS")
                    .font(.system(size: 10.5, weight: .semibold, design: .default))
                    .tracking(0.5)
                    .foregroundStyle(WidgetPalette.muted)
                    .lineLimit(1)

                if bills.isEmpty {
                    Text("No unpaid bills before payday.")
                        .font(.caption)
                        .foregroundStyle(WidgetPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                } else {
                    ForEach(bills.prefix(3)) { bill in
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text(bill.title)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(WidgetPalette.ink)
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                Text("¥" + bill.amount.formatted())
                                    .font(.caption.weight(.semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(WidgetPalette.ink)
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                            Text(bill.isEstimate ? "\(bill.dateLabel) · est." : bill.dateLabel)
                                .font(.caption2)
                                .foregroundStyle(WidgetPalette.muted)
                                .lineLimit(1)
                        }
                        .privacySensitive()
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    // MARK: - Lock Screen Accessories

    private var accessoryRectangularBody: some View {
        let updated = entry.hasGroup ? Self.updatedLabel(entry.snapshot.updatedAt) : nil
        let nextBill = entry.snapshot.upcomingBills?.first
        let footer: String
        if let nextBill, entry.hasGroup {
            footer = "Next: \(nextBill.title) ¥\(nextBill.amount.formatted())"
        } else {
            footer = updated ?? (entry.hasGroup ? entry.snapshot.detail : "App Group missing")
        }

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

            Text(footer)
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .privacySensitive()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var accessoryCircularBody: some View {
        let progress = min(1.0, max(0.0, entry.snapshot.cycleProgress ?? 0))
        let daysText = entry.snapshot.daysToPayday.map { "\($0)d" } ?? "–"
        let valueText = entry.snapshot.compactValue ?? entry.snapshot.value

        return Gauge(value: progress) {
            Text("Payday")
        } currentValueLabel: {
            VStack(spacing: 0) {
                Text(daysText)
                    .font(.system(size: 14, weight: .semibold))
                    .monospacedDigit()
                Text(valueText)
                    .font(.system(size: 8.5, weight: .medium))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .privacySensitive()
            }
        }
        .gaugeStyle(.accessoryCircularCapacity)
    }

    private var accessoryInlineBody: some View {
        let compact = entry.snapshot.compactValue ?? entry.snapshot.value
        let text = entry.snapshot.daysToPayday.map { "\(compact) left · \($0)d" } ?? "\(compact) · Finance"
        return Text(text)
            .privacySensitive()
    }

    // MARK: - Helpers

    private func miniSplitBar(bills: Int, left: Int) -> some View {
        let b = max(0, bills)
        let l = abs(left)
        let total = max(1, b + l)
        return GeometryReader { geo in
            let w = geo.size.width
            HStack(spacing: 2) {
                if b > 0 {
                    Capsule()
                        .fill(WidgetPalette.ink2)
                        .frame(width: max(4, (w - 2) * CGFloat(b) / CGFloat(total)))
                }
                if l > 0 {
                    Capsule()
                        .fill(left < 0 ? WidgetPalette.bad : WidgetPalette.good)
                        .frame(width: max(4, (w - 2) * CGFloat(l) / CGFloat(total)))
                }
            }
        }
        .frame(height: 5)
        .accessibilityHidden(true)
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
        .description("Until payday balance and upcoming bills shared by the Finance app.")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .accessoryRectangular,
            .accessoryCircular,
            .accessoryInline
        ])
    }
}
