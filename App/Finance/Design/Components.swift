import FinanceCore
import SwiftUI

private struct PrivacyMaskedKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

extension EnvironmentValues {
    /// When true (train/commute privacy mode), yen figures render masked as `¥•••,•••`.
    var privacyMasked: Bool {
        get { self[PrivacyMaskedKey.self] }
        set { self[PrivacyMaskedKey.self] = newValue }
    }
}

/// Formats yen figures cleanly while respecting the 1-tap Train Privacy Mask.
enum MaskedMoney {
    static func yen(_ value: Int, masked: Bool) -> String {
        masked ? "¥•••,•••" : Money.yen(value)
    }

    static func payment(_ value: Int, masked: Bool) -> String {
        guard masked else { return Money.payment(value) }
        return value < 0 ? "+¥•••,•••" : "¥•••,•••"
    }

    static func signed(_ value: Int, masked: Bool) -> String {
        guard masked else { return Money.signed(value) }
        return value < 0 ? "−¥•••,•••" : "+¥•••,•••"
    }

    private static let yenPattern = try? NSRegularExpression(pattern: #"[+−\-]?[¥￥]\s*[0-9][0-9,]*"#)

    /// Redacts any inline yen figures inside alert or Q&A strings when privacy mode is active.
    static func redactText(_ text: String, masked: Bool) -> String {
        guard masked, let regex = yenPattern else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "¥•••,•••")
    }
}

/// Elevated porcelain (light) or satin obsidian (dark) card with continuous 20 pt curvature,
/// fine hairline border, specular dark-mode rim, and whisper-soft ambient depth.
struct FinanceCard<Content: View>: View {
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var colorScheme
    private let padding: CGFloat
    private let content: Content

    init(padding: CGFloat = Theme.cardPadding, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
        let hairline = 1.0 / max(displayScale, 1)

        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: shape)
        .overlay(
            Group {
                if colorScheme == .dark {
                    shape.strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.11),
                                Color.white.opacity(0.035),
                                Color.white.opacity(0.02)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.75
                    )
                } else {
                    shape.strokeBorder(Theme.line.opacity(0.75), lineWidth: hairline)
                }
            }
        )
        .shadow(
            color: colorScheme == .dark
                ? Color.black.opacity(0.32)
                : Color(red: 0.06, green: 0.11, blue: 0.09).opacity(0.055),
            radius: colorScheme == .dark ? 12 : 16,
            x: 0,
            y: colorScheme == .dark ? 6 : 6
        )
        .shadow(
            color: colorScheme == .dark
                ? Color.clear
                : Color(red: 0.06, green: 0.11, blue: 0.09).opacity(0.03),
            radius: 2,
            x: 0,
            y: 1
        )
    }
}

/// Signature Midnight Forest Obsidian centerpiece card with subtle ambient jade sheen
/// and fine luminous rim — anchored at the top of Now and Where to Cut.
struct HeroVaultCard<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    private let padding: CGFloat
    private let accentTint: Color
    private let content: Content

    init(
        padding: CGFloat = 20,
        accentTint: Color = Theme.heroGlow,
        @ViewBuilder content: () -> Content
    ) {
        self.padding = padding
        self.accentTint = accentTint
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)

        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                LinearGradient(
                    colors: [Theme.heroTop, Theme.heroMid, Theme.heroBottom],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                RadialGradient(
                    colors: [accentTint.opacity(0.22), Color.clear],
                    center: .topTrailing,
                    startRadius: 8,
                    endRadius: 240
                )
                RadialGradient(
                    colors: [Color.white.opacity(0.05), Color.clear],
                    center: .topLeading,
                    startRadius: 2,
                    endRadius: 160
                )
            }
            .clipShape(shape)
        )
        .overlay(
            shape.strokeBorder(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.20),
                        accentTint.opacity(0.16),
                        Color.white.opacity(0.05)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 0.9
            )
        )
        .shadow(
            color: colorScheme == .dark
                ? Color.black.opacity(0.50)
                : Color(red: 0.03, green: 0.13, blue: 0.09).opacity(0.24),
            radius: 22,
            x: 0,
            y: 12
        )
        .shadow(
            color: colorScheme == .dark
                ? Color.clear
                : Color(red: 0.03, green: 0.13, blue: 0.09).opacity(0.08),
            radius: 4,
            x: 0,
            y: 2
        )
    }
}

/// Frosted translucent inset well designed for key figures inside `HeroVaultCard`.
struct FrostedMetricTile<Content: View>: View {
    private let fillHeight: Bool
    private let content: Content

    init(fillHeight: Bool = false, @ViewBuilder content: () -> Content) {
        self.fillHeight = fillHeight
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.innerRadius, style: .continuous)
        VStack(alignment: .leading, spacing: 4) {
            content
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: fillHeight ? .infinity : nil, alignment: .topLeading)
        .background(Color.white.opacity(0.075), in: shape)
        .overlay(
            shape.strokeBorder(Color.white.opacity(0.10), lineWidth: 0.6)
        )
    }
}

/// Soft recessed well for side-by-side summary stats inside standard `FinanceCard`s.
struct MetricWell<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    private let tint: Color?
    private let content: Content

    init(tint: Color? = nil, @ViewBuilder content: () -> Content) {
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.innerRadius, style: .continuous)
        let fill: Color = {
            if let tint {
                return tint.opacity(colorScheme == .dark ? 0.14 : 0.08)
            }
            return Theme.well.opacity(colorScheme == .dark ? 0.85 : 0.65)
        }()
        VStack(alignment: .leading, spacing: 4) {
            content
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(fill, in: shape)
        .overlay(
            shape.strokeBorder(
                (tint ?? Theme.line).opacity(colorScheme == .dark ? 0.22 : 0.25),
                lineWidth: 0.5
            )
        )
    }
}

/// Sculpted circular progress ring for payday countdown and savings rate gauges.
struct CycleRingView: View {
    let progress: Double
    let valueText: String
    let unitText: String
    var trackColor: Color = Color.white.opacity(0.14)
    var fillColor: Color = Theme.heroAccent
    var textColor: Color = Theme.heroInk
    var unitColor: Color = Theme.heroInkMuted
    var size: CGFloat = 58
    var lineWidth: CGFloat = 4.5

    var body: some View {
        let clamped = min(1.0, max(0.04, progress))
        ZStack {
            Circle()
                .stroke(trackColor, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: clamped)
                .stroke(
                    AngularGradient(
                        colors: [fillColor.opacity(0.55), fillColor],
                        center: .center,
                        startAngle: .degrees(-90),
                        endAngle: .degrees(270)
                    ),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            VStack(spacing: -1) {
                Text(valueText)
                    .font(.system(size: size * 0.31, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(textColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(unitText.uppercased())
                    .font(.system(size: max(8, size * 0.14), weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(unitColor)
                    .lineLimit(1)
            }
            .padding(6)
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(valueText) \(unitText)")
    }
}

/// 11.5 pt semibold uppercase section eyebrow with deliberate tracking and optional tiny symbol.
struct SectionLabel: View {
    let text: String
    var symbol: String? = nil
    var color: Color = Theme.muted
    @ScaledMetric(relativeTo: .caption2) private var size: CGFloat = 11.5

    init(_ text: String, symbol: String? = nil, color: Color = Theme.muted) {
        self.text = text
        self.symbol = symbol
        self.color = color
    }

    var body: some View {
        let clamped = min(size, 21)
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: clamped, weight: .semibold))
                    .foregroundStyle(color)
                    .accessibilityHidden(true)
            }
            Text(text.uppercased())
                .font(.system(size: clamped, weight: .semibold, design: .default))
                .tracking(clamped * 0.09)
                .foregroundStyle(color)
        }
        .accessibilityAddTraits(.isHeader)
    }
}

/// Editorial hero yen value with subtly lighter, refined ¥ currency prefix and crisp bold monospaced digits.
struct HeroMoneyText: View {
    @Environment(\.privacyMasked) private var privacyMasked
    let amount: Int
    var color: Color = Theme.ink
    var signed: Bool = false
    @ScaledMetric(relativeTo: .largeTitle) private var size: CGFloat = 42

    var body: some View {
        let scaled = min(size, 60)
        let prefix: String = {
            if amount < 0 { return "−¥" }
            if signed && amount > 0 { return "+¥" }
            return "¥"
        }()
        let digits = privacyMasked ? "•••,•••" : amount.magnitude.formatted()

        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(prefix)
                .font(.system(size: scaled * 0.62, weight: .medium, design: .rounded))
                .foregroundStyle(color.opacity(0.72))
            Text(digits)
                .font(.system(size: scaled, weight: .bold, design: .rounded))
                .tracking(-scaled * 0.024)
                .monospacedDigit()
                .foregroundStyle(color)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.45)
        .allowsTightening(true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(privacyMasked ? "Hidden amount" : FinanceFormat.yenAccessibility(amount, signed: signed))
    }
}

/// Editorial 24 pt bold metric yen value with refined ¥ prefix and monospaced digits.
struct MetricMoneyText: View {
    @Environment(\.privacyMasked) private var privacyMasked
    let amount: Int
    var color: Color = Theme.ink
    var signed: Bool = false
    @ScaledMetric(relativeTo: .title2) private var size: CGFloat = 24

    var body: some View {
        let scaled = min(size, 38)
        let prefix: String = {
            if amount < 0 { return "−¥" }
            if signed && amount > 0 { return "+¥" }
            return "¥"
        }()
        let digits = privacyMasked ? "•••,•••" : amount.magnitude.formatted()

        HStack(alignment: .firstTextBaseline, spacing: 1.5) {
            Text(prefix)
                .font(.system(size: scaled * 0.68, weight: .medium, design: .rounded))
                .foregroundStyle(color.opacity(0.72))
            Text(digits)
                .font(.system(size: scaled, weight: .bold, design: .rounded))
                .tracking(-scaled * 0.018)
                .monospacedDigit()
                .foregroundStyle(color)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        .allowsTightening(true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(privacyMasked ? "Hidden amount" : FinanceFormat.yenAccessibility(amount, signed: signed))
    }
}

/// Single-pixel hairline divider in `Theme.line`.
struct HairlineDivider: View {
    @Environment(\.displayScale) private var displayScale
    var color: Color = Theme.line

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(height: 1.0 / max(displayScale, 1))
    }
}

/// Sculpted capsule progress meter with subtle tonal sheen, guaranteed visibility for non-zero ratios,
/// and an optional quiet "Pace Notch" vertical marker showing where today sits in the active period.
struct ProgressMeter: View {
    let ratio: Double
    var tint: Color = Theme.accent
    var track: Color = Theme.track
    var height: CGFloat = 6.5
    /// Optional 0...1 fraction showing today's position in the current month or pay cycle.
    var paceRatio: Double? = nil

    var body: some View {
        let clamped = min(1.0, max(0.0, ratio))
        let hasNotch = paceRatio != nil
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(track)
                    .frame(height: height)
                if clamped > 0 {
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [tint.opacity(0.84), tint],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(height, geo.size.width * clamped), height: height)
                }
                if let pace = paceRatio {
                    let clampedPace = min(0.98, max(0.02, pace))
                    let xPos = geo.size.width * clampedPace
                    ZStack {
                        Capsule()
                            .fill(Theme.surface.opacity(0.92))
                            .frame(width: 4, height: height + 6)
                        Capsule()
                            .fill(Theme.ink.opacity(0.78))
                            .frame(width: 1.75, height: height + 5)
                    }
                    .offset(x: xPos - 2)
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(height: hasNotch ? height + 6 : height)
        .accessibilityHidden(true)
    }
}

/// Refined segmented pill switch for global `Calendar | Pay Cycle` period mode.
struct PeriodModeSwitch: View {
    @Binding var mode: BudgetPeriodMode

    var body: some View {
        Picker("Period mode", selection: $mode) {
            ForEach(BudgetPeriodMode.allCases) { option in
                Text(option.rawValue).tag(option)
            }
        }
        .pickerStyle(.segmented)
    }
}

/// Refined full-pill tag with subtle tonal border for Pending, Estimate, Payday, Borrowed, or status states.
struct QuietTag: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme

    enum Tone {
        case neutral
        case accent
        case good
        case bad
        case warn
        case info
        case hero

        init(statusTone: StatusTone) {
            switch statusTone {
            case .good: self = .good
            case .bad: self = .bad
            case .accent: self = .accent
            case .neutral: self = .neutral
            }
        }
    }

    let text: String
    var tone: Tone = .neutral

    init(_ text: String, tone: Tone = .neutral) {
        self.text = text
        self.tone = tone
    }

    var body: some View {
        let isAccessibility = dynamicTypeSize.isAccessibilitySize
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .minimumScaleFactor(isAccessibility ? 0.5 : 1.0)
            .allowsTightening(isAccessibility)
            .padding(.horizontal, isAccessibility ? 12 : 9)
            .padding(.vertical, isAccessibility ? 4 : 3.5)
            .background(background, in: Capsule())
            .overlay(
                Capsule().strokeBorder(borderColor, lineWidth: 0.6)
            )
            .fixedSize(horizontal: !isAccessibility, vertical: false)
    }

    private var foreground: Color {
        switch tone {
        case .neutral: return Theme.muted
        case .accent: return Theme.accent
        case .good: return Theme.good
        case .bad: return Theme.bad
        case .warn: return Theme.warn
        case .info: return Color("LayerRent")
        case .hero: return Theme.heroAccent
        }
    }

    private var background: Color {
        switch tone {
        case .neutral: return Theme.track.opacity(colorScheme == .dark ? 0.9 : 0.8)
        case .accent: return Theme.accentWash
        case .good: return Theme.goodWash
        case .bad: return Theme.badWash
        case .warn: return Theme.warn.opacity(colorScheme == .dark ? 0.16 : 0.12)
        case .info: return Color("LayerRent").opacity(colorScheme == .dark ? 0.18 : 0.11)
        case .hero: return Theme.heroAccent.opacity(0.16)
        }
    }

    private var borderColor: Color {
        switch tone {
        case .neutral: return Theme.line.opacity(0.6)
        case .accent: return Theme.accent.opacity(colorScheme == .dark ? 0.28 : 0.18)
        case .good: return Theme.good.opacity(colorScheme == .dark ? 0.28 : 0.18)
        case .bad: return Theme.bad.opacity(colorScheme == .dark ? 0.28 : 0.18)
        case .warn: return Theme.warn.opacity(colorScheme == .dark ? 0.30 : 0.22)
        case .info: return Color("LayerRent").opacity(colorScheme == .dark ? 0.30 : 0.20)
        case .hero: return Theme.heroAccent.opacity(0.32)
        }
    }
}

/// Tactile pill filter or month chip with emerald glow when selected and crisp elevation when unselected.
struct FilterChip: View {
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(isSelected ? .semibold : .medium))
                .foregroundStyle(selectedForeground)
                .padding(.horizontal, 15)
                .padding(.vertical, 8.5)
                .background(
                    Group {
                        if isSelected {
                            Capsule().fill(Theme.accent)
                        } else {
                            Capsule().fill(Theme.surface)
                        }
                    }
                )
                .overlay(
                    Capsule().strokeBorder(
                        isSelected
                            ? Color.white.opacity(colorScheme == .dark ? 0.16 : 0.20)
                            : Theme.line.opacity(colorScheme == .dark ? 0.9 : 0.8),
                        lineWidth: isSelected ? 0.6 : (1.0 / max(displayScale, 1))
                    )
                )
                .shadow(
                    color: isSelected
                        ? Theme.accent.opacity(colorScheme == .dark ? 0.28 : 0.24)
                        : Color.black.opacity(colorScheme == .dark ? 0.16 : 0.03),
                    radius: isSelected ? 7 : 4,
                    x: 0,
                    y: isSelected ? 3 : 1
                )
                .frame(minHeight: Theme.minTouchTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var selectedForeground: Color {
        guard isSelected else { return Theme.ink2 }
        return colorScheme == .dark ? Color("Page") : Color.white
    }
}

/// Wrapping horizontal layout for tags, legends, and compact metadata so narrow widths
/// and accessibility text sizes never clip or collide.
struct FlowLayout: Layout {
    var horizontalSpacing: CGFloat = 8
    var verticalSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let proposedWidth = proposal.width
        let maxWidth = proposedWidth ?? .infinity
        let layout = arrange(maxWidth: maxWidth, subviews: subviews)
        let width: CGFloat
        if let proposedWidth, proposedWidth.isFinite, proposedWidth > 0 {
            width = proposedWidth
        } else {
            width = ceil(layout.widestRow)
        }
        return CGSize(width: width, height: ceil(layout.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = arrange(maxWidth: bounds.width, subviews: subviews)
        for placement in layout.placements {
            subviews[placement.index].place(
                at: CGPoint(x: bounds.minX + placement.x, y: bounds.minY + placement.y),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: placement.width, height: placement.height)
            )
        }
    }

    private struct Placement {
        let index: Int
        let x: CGFloat
        let y: CGFloat
        let width: CGFloat
        let height: CGFloat
    }

    private struct Arrangement {
        let placements: [Placement]
        let widestRow: CGFloat
        let height: CGFloat
    }

    private func arrange(maxWidth: CGFloat, subviews: Subviews) -> Arrangement {
        let limit = maxWidth.isFinite ? max(0, maxWidth) : CGFloat.infinity
        let tolerance: CGFloat = 0.5
        var placements: [Placement] = []
        placements.reserveCapacity(subviews.count)

        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widestRow: CGFloat = 0

        for (index, subview) in subviews.enumerated() {
            let subviewProposal = limit.isFinite ? ProposedViewSize(width: limit, height: nil) : .unspecified
            let size = subview.sizeThatFits(subviewProposal)
            let clampedWidth = limit.isFinite ? min(size.width, limit) : size.width

            if x > 0 && x + clampedWidth > limit + tolerance {
                widestRow = max(widestRow, x - horizontalSpacing)
                x = 0
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }

            placements.append(
                Placement(
                    index: index,
                    x: x,
                    y: y,
                    width: clampedWidth,
                    height: size.height
                )
            )
            x += clampedWidth + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }

        if x > 0 {
            widestRow = max(widestRow, x - horizontalSpacing)
        }

        let totalHeight = placements.isEmpty ? 0 : y + rowHeight
        return Arrangement(placements: placements, widestRow: widestRow, height: totalHeight)
    }
}

/// Tactile emerald primary action button with guaranteed contrast in both light and dark modes.
struct PrimaryActionButton: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    let title: String
    let action: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(foreground)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, minHeight: Theme.minTouchTarget)
                .background(background, in: shape)
                .overlay(
                    shape.strokeBorder(
                        isEnabled ? Color.white.opacity(0.16) : Color.clear,
                        lineWidth: 0.6
                    )
                )
                .shadow(
                    color: isEnabled ? Theme.accent.opacity(colorScheme == .dark ? 0.24 : 0.22) : .clear,
                    radius: 8,
                    x: 0,
                    y: 4
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var foreground: Color {
        guard isEnabled else { return Theme.muted }
        return colorScheme == .dark ? Theme.page : Color.white
    }

    private var background: Color {
        isEnabled ? Theme.accent : Theme.track
    }
}

/// Consistent key-value status row for settings and About lists.
struct SettingsValueRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let label: String
    let value: String
    var valueColor: Color = Theme.ink2
    var monospaced: Bool = false
    var selectable: Bool = false

    var body: some View {
        LabeledContent {
            valueText
                .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
        } label: {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(Theme.ink)
        }
    }

    @ViewBuilder
    private var valueText: some View {
        let base = Text(value)
            .font(monospaced ? Font.footnote.monospaced() : Font.subheadline)
            .monospacedDigit()
            .foregroundStyle(valueColor)
        if selectable {
            base.textSelection(.enabled)
        } else {
            base
        }
    }
}

/// Calm empty, loading, and error presentation cards with plain short English.
struct StateCard: View {
    enum Kind {
        case loading
        case empty
        case error
    }

    let kind: Kind
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        FinanceCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    if kind == .loading {
                        ProgressView()
                            .tint(Theme.accent)
                    } else if kind == .error {
                        IconMedallion(symbol: "exclamationmark.triangle.fill", tint: Theme.bad, size: 30)
                    } else {
                        IconMedallion(symbol: "tray", tint: Theme.accent, size: 30)
                    }
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(kind == .error ? Theme.bad : Theme.ink)
                }
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if let actionTitle, let action {
                    Button(action: action) {
                        HStack(spacing: 4) {
                            Text(actionTitle)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.accent)
                            Image(systemName: "arrow.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.accent)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Theme.accentWash, in: Capsule())
                        .frame(minHeight: Theme.minTouchTarget, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                }
            }
        }
    }
}
