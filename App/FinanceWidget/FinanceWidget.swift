import AppIntents
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
        let now = Date()
        let base = SharedStore.read() ?? .placeholder
        let hasGroup = SharedStore.groupID != nil
        var entries = [SnapshotEntry(date: now, snapshot: Self.adjustedSnapshot(base, on: now), hasGroup: hasGroup)]

        // Schedule an automatic JST midnight rollover entry so `daysToPayday` advances overnight without opening the app.
        let jst = TimeZone(secondsFromGMT: 9 * 3600)!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = jst
        if let tomorrowStart = cal.nextDate(
            after: now,
            matching: DateComponents(hour: 0, minute: 0, second: 5),
            matchingPolicy: .nextTime
        ) {
            entries.append(SnapshotEntry(
                date: tomorrowStart,
                snapshot: Self.adjustedSnapshot(base, on: tomorrowStart),
                hasGroup: hasGroup
            ))
        }
        let nextRefresh = min(
            now.addingTimeInterval(30 * 60),
            entries.count > 1 ? entries[1].date.addingTimeInterval(60) : now.addingTimeInterval(30 * 60)
        )
        completion(Timeline(entries: entries, policy: .after(nextRefresh)))
    }

    private func current() -> SnapshotEntry {
        let now = Date()
        let snap = Self.adjustedSnapshot(SharedStore.read() ?? .placeholder, on: now)
        return SnapshotEntry(date: now, snapshot: snap, hasGroup: SharedStore.groupID != nil)
    }

    /// Applies live Privacy Mode masking, recomputes `daysToPayday` from `paydayDate` in JST so countdowns
    /// never freeze overnight, and blanks expired figures once the target payday has passed.
    private static func adjustedSnapshot(_ raw: WidgetSnapshot, on date: Date) -> WidgetSnapshot {
        var copy = raw
        let shouldMask = SharedStore.privacyMasked
        if shouldMask {
            copy.value = "¥•••,•••"
            copy.compactValue = "¥•••"
            copy.billsSum = nil
            copy.leftSum = nil
            copy.borrowedSum = nil
            if let spentRange = copy.detail.range(of: " · spent ") {
                copy.detail = String(copy.detail[..<spentRange.lowerBound])
            }
            copy.detail = redactYen(copy.detail)
            copy.upcomingBills = copy.upcomingBills?.enumerated().map { idx, bill in
                WidgetBill(
                    id: "masked-\(idx)",
                    title: redactYen(bill.title),
                    date: bill.date,
                    dateLabel: bill.dateLabel,
                    amount: 0,
                    isEstimate: bill.isEstimate
                )
            }
            copy.isPrivacyMasked = true
        }
        guard let paydayDate = copy.paydayDate,
              let targetDay = dayNumber(paydayDate)
        else { return copy }
        let jst = TimeZone(secondsFromGMT: 9 * 3600)!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = jst
        let c = cal.dateComponents([.year, .month, .day], from: date)
        guard let y = c.year, let m = c.month, let d = c.day,
              let todayNum = dayNumber(String(format: "%04d-%02d-%02d", y, m, d))
        else { return copy }
        if todayNum > targetDay {
            copy.title = "Payday passed"
            copy.value = "–"
            copy.compactValue = "–"
            copy.detail = "Open Finance to refresh"
            copy.daysToPayday = nil
            copy.cycleProgress = 1.0
            copy.billsSum = nil
            copy.leftSum = nil
            copy.borrowedSum = nil
            copy.upcomingBills = []
            return copy
        }
        let remaining = max(0, targetDay - todayNum)
        copy.daysToPayday = remaining
        if copy.title.hasPrefix("Until payday") {
            let word = remaining == 1 ? "day" : "days"
            copy.title = "Until payday · \(remaining) \(word)"
        }
        return copy
    }

    private static func redactYen(_ text: String) -> String {
        SharedMoneyRedactor.redact(text)
    }

    private static func dayNumber(_ text: String) -> Int? {
        let p = text.split(separator: "-", omittingEmptySubsequences: false)
        guard p.count == 3, p[0].count == 4, p[1].count == 2, p[2].count == 2,
              let y = Int(p[0]), let m = Int(p[1]), let d = Int(p[2]),
              (1...12).contains(m)
        else { return nil }
        let maxDay: Int = {
            switch m {
            case 1, 3, 5, 7, 8, 10, 12: return 31
            case 4, 6, 9, 11: return 30
            case 2: return ((y % 4 == 0 && y % 100 != 0) || (y % 400 == 0)) ? 29 : 28
            default: return 0
            }
        }()
        guard (1...maxDay).contains(d) else { return nil }
        let yy = m <= 2 ? y - 1 : y
        let era = (yy >= 0 ? yy : yy - 399) / 400
        let yoe = yy - era * 400
        let doy = (153 * ((m + 9) % 12) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }
}

private enum WidgetPalette {
    static let bgTop = Color(red: 0.055, green: 0.205, blue: 0.155)
    static let bgMid = Color(red: 0.043, green: 0.130, blue: 0.108)
    static let bgBottom = Color(red: 0.043, green: 0.078, blue: 0.074)
    static let glow = Color(red: 0.200, green: 0.780, blue: 0.560)
    static let ink = Color(red: 0.976, green: 0.984, blue: 0.980)
    static let ink2 = Color(red: 0.800, green: 0.875, blue: 0.840)
    static let muted = Color(red: 0.650, green: 0.755, blue: 0.710)
    static let line = Color.white.opacity(0.12)
    static let good = Color(red: 0.360, green: 0.890, blue: 0.660)
    static let bad = Color(red: 0.970, green: 0.520, blue: 0.470)
}

struct FinanceWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotEntry

    var body: some View {
        switch family {
        case .systemMedium:
            systemMediumBody
                .containerBackground(for: .widget) { heroWidgetBackground }
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
                .containerBackground(for: .widget) { heroWidgetBackground }
        }
    }

    private var heroWidgetBackground: some View {
        ZStack {
            LinearGradient(
                colors: [WidgetPalette.bgTop, WidgetPalette.bgMid, WidgetPalette.bgBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [(isNegative ? WidgetPalette.bad : WidgetPalette.glow).opacity(0.24), Color.clear],
                center: .topTrailing,
                startRadius: 4,
                endRadius: 180
            )
        }
    }

    private var isNegative: Bool {
        entry.snapshot.value.hasPrefix("−") || entry.snapshot.value.hasPrefix("-")
    }

    // MARK: - Small Home Screen

    private var systemSmallBody: some View {
        let detailText = entry.hasGroup ? entry.snapshot.detail : "No shared data (App Group missing)"

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(entry.snapshot.title.uppercased())
                    .font(.system(size: 10.5, weight: .semibold, design: .default))
                    .tracking(0.6)
                    .foregroundStyle(WidgetPalette.muted)
                    .lineLimit(1)
                    .privacySensitive()
                Spacer(minLength: 2)
                if let days = entry.snapshot.daysToPayday {
                    Text("\(days)d")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(WidgetPalette.good)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(WidgetPalette.good.opacity(0.18), in: Capsule())
                }
            }

            Text(entry.snapshot.value)
                .font(.system(size: 27, weight: .bold, design: .rounded))
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
                HStack(spacing: 4) {
                    Text(entry.snapshot.title.uppercased())
                        .font(.system(size: 10.5, weight: .semibold, design: .default))
                        .tracking(0.5)
                        .foregroundStyle(WidgetPalette.muted)
                        .lineLimit(1)
                        .privacySensitive()
                    Spacer(minLength: 2)
                    if let days = entry.snapshot.daysToPayday {
                        Text("\(days)d")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(WidgetPalette.good)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(WidgetPalette.good.opacity(0.18), in: Capsule())
                    }
                }

                Text(entry.snapshot.value)
                    .font(.system(size: 27, weight: .bold, design: .rounded))
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
                .frame(width: 0.75)
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
                        let masked = entry.snapshot.isPrivacyMasked == true
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text(bill.title)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(WidgetPalette.ink)
                                    .lineLimit(2)
                                    .minimumScaleFactor(0.85)
                                Spacer(minLength: 4)
                                Text(masked ? "¥•••,•••" : "¥" + bill.amount.formatted())
                                    .font(.caption.weight(.bold))
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
        let masked = entry.snapshot.isPrivacyMasked == true
        let footer: String
        if let nextBill, entry.hasGroup {
            let billAmt = masked ? "¥•••,•••" : "¥\(nextBill.amount.formatted())"
            footer = "Next: \(nextBill.title) \(billAmt)"
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
                .font(.system(size: 22, weight: .bold, design: .rounded))
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
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text(valueText)
                    .font(.system(size: 8.5, weight: .semibold, design: .rounded))
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
            HStack(spacing: 2.5) {
                if b > 0 {
                    Capsule()
                        .fill(Color.white.opacity(0.40))
                        .frame(width: max(5, (w - 2.5) * CGFloat(b) / CGFloat(total)))
                }
                if l > 0 {
                    Capsule()
                        .fill(left < 0 ? WidgetPalette.bad : WidgetPalette.good)
                        .frame(width: max(5, (w - 2.5) * CGFloat(l) / CGFloat(total)))
                }
            }
        }
        .frame(height: 6)
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
        if value.contains("•") {
            return "Hidden amount"
        }
        if value == "–" || value == "-" {
            return "unavailable"
        }
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

/// Control Center and Lock Screen 1-tap button that opens Quick Add directly.
struct QuickAddControlWidget: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "QuickAddControlWidget") {
            ControlWidgetButton(action: OpenQuickAddIntent()) {
                Label("Add payment", systemImage: "yensign.circle.fill")
            }
        }
        .displayName("Add payment")
        .description("Log a cash or card payment in Finance.")
    }
}

/// Control Center and Lock Screen 1-tap button that opens the AI/OCR Receipt Scanner directly.
struct ScanReceiptControlWidget: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "ScanReceiptControlWidget") {
            ControlWidgetButton(action: OpenScanReceiptIntent()) {
                Label("Scan receipt", systemImage: "doc.text.viewfinder")
            }
        }
        .displayName("Scan receipt")
        .description("Scan a paper receipt, payment slip, or screenshot in Finance.")
    }
}

@main
struct FinanceWidgetBundle: WidgetBundle {
    var body: some Widget {
        FinanceWidget()
        QuickAddControlWidget()
        ScanReceiptControlWidget()
    }
}
