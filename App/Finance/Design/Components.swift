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

/// Calm primary action button with guaranteed contrast in both light and dark modes.
struct PrimaryActionButton: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(foreground)
                .frame(maxWidth: .infinity, minHeight: Theme.minTouchTarget)
                .background(background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
    let label: String
    let value: String
    var valueColor: Color = Theme.ink2
    var monospaced: Bool = false
    var selectable: Bool = false

    var body: some View {
        LabeledContent {
            valueText
                .multilineTextAlignment(.trailing)
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
