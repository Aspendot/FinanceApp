import SwiftUI

/// White/elevated surface card with 14 pt continuous corners and a 1 px hairline border.
/// No gradients and no shadows.
struct FinanceCard<Content: View>: View {
    @Environment(\.displayScale) private var displayScale
    private let padding: CGFloat
    private let content: Content

    init(padding: CGFloat = Theme.cardPadding, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: shape)
        .overlay(
            shape.strokeBorder(Theme.line, lineWidth: 1.0 / max(displayScale, 1))
        )
    }
}

/// 12 pt semibold uppercase section label with 0.08 em tracking in muted ink.
struct SectionLabel: View {
    let text: String
    @ScaledMetric(relativeTo: .caption2) private var size: CGFloat = 12

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: min(size, 22), weight: .semibold, design: .default))
            .tracking(min(size, 22) * 0.08)
            .foregroundStyle(Theme.muted)
            .accessibilityAddTraits(.isHeader)
    }
}

/// 44 pt semibold SF Pro hero yen value with tight tracking and monospaced digits.
struct HeroMoneyText: View {
    let amount: Int
    var color: Color = Theme.ink
    var signed: Bool = false
    @ScaledMetric(relativeTo: .largeTitle) private var size: CGFloat = 44

    var body: some View {
        let scaled = min(size, 64)
        Text(signed ? Money.signed(amount) : Money.yen(amount))
            .font(.system(size: scaled, weight: .semibold, design: .default))
            .tracking(-scaled * 0.028)
            .monospacedDigit()
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.45)
            .allowsTightening(true)
            .accessibilityLabel(FinanceFormat.yenAccessibility(amount, signed: signed))
    }
}

/// 25 pt semibold SF Pro metric yen value with tight tracking and monospaced digits.
struct MetricMoneyText: View {
    let amount: Int
    var color: Color = Theme.ink
    var signed: Bool = false
    @ScaledMetric(relativeTo: .title2) private var size: CGFloat = 25

    var body: some View {
        let scaled = min(size, 40)
        Text(signed ? Money.signed(amount) : Money.yen(amount))
            .font(.system(size: scaled, weight: .semibold, design: .default))
            .tracking(-scaled * 0.018)
            .monospacedDigit()
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.55)
            .allowsTightening(true)
            .accessibilityLabel(FinanceFormat.yenAccessibility(amount, signed: signed))
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

/// Calm full-pill tag for Pending, Estimate, Payday, Borrowed, or Not spending states.
struct QuietTag: View {
    enum Tone {
        case neutral
        case accent
        case good
        case bad
    }

    let text: String
    var tone: Tone = .neutral

    init(_ text: String, tone: Tone = .neutral) {
        self.text = text
        self.tone = tone
    }

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(background, in: Capsule())
            .fixedSize(horizontal: true, vertical: false)
    }

    private var foreground: Color {
        switch tone {
        case .neutral: return Theme.muted
        case .accent: return Theme.accent
        case .good: return Theme.good
        case .bad: return Theme.bad
        }
    }

    private var background: Color {
        switch tone {
        case .neutral: return Theme.track
        case .accent: return Theme.accentWash
        case .good: return Theme.goodWash
        case .bad: return Theme.badWash
        }
    }
}

/// Full-pill interactive filter or month chip with a guaranteed 44 pt touch target.
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
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(isSelected ? Theme.accent : Theme.surface, in: Capsule())
                .overlay(
                    Capsule().strokeBorder(
                        isSelected ? Color.clear : Theme.line,
                        lineWidth: 1.0 / max(displayScale, 1)
                    )
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
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widestRow: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
            if x > 0 && x + size.width > maxWidth {
                widestRow = max(widestRow, x - horizontalSpacing)
                x = 0
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }
            x += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }
        if x > 0 {
            widestRow = max(widestRow, x - horizontalSpacing)
        }
        return CGSize(width: min(widestRow, maxWidth), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }
            subview.place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: min(size.width, maxWidth), height: size.height)
            )
            x += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
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
                        Circle()
                            .fill(Theme.bad)
                            .frame(width: 8, height: 8)
                            .accessibilityHidden(true)
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
                        Text(actionTitle)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                            .frame(minHeight: Theme.minTouchTarget)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                }
            }
        }
    }
}
