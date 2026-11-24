import FinanceCore
import SwiftUI

/// Full "Where to cut" plan view showing baseline vs targets, sparklines, and live monthly cap tracking.
struct WhereToCutView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.privacyMasked) private var privacyMasked
    @EnvironmentObject private var session: AppSession

    let plan: PlanSummary
    var isPresentedModally: Bool = false
    var activePace: Double? = nil

    @State private var showSettled = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.cardSpacing) {
                summaryCard
                if !plan.active.isEmpty {
                    activeTargetsCard
                }
                if !plan.settled.isEmpty {
                    settledTargetsCard
                }
            }
            .padding(.horizontal, Theme.screenPadding)
            .padding(.vertical, 12)
        }
        .background(Theme.page)
        .navigationTitle("Where to cut")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isPresentedModally {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var summaryCard: some View {
        HeroVaultCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionLabel("Monthly target", symbol: "scissors", color: Theme.heroInkMuted)

                HeroMoneyText(amount: plan.projectedTotal, color: Theme.heroInk)

                Text("Down from \(Money.yen(plan.baselineTotal))/month baseline across active and completed cuts.")
                    .font(.footnote)
                    .foregroundStyle(Theme.heroInkMuted)
                    .fixedSize(horizontal: false, vertical: true)

                if dynamicTypeSize.isAccessibilitySize {
                    VStack(spacing: 8) {
                        heroStatTile(label: "Already cut", value: "\(Money.yen(plan.alreadyCut))/mo", color: Theme.heroAccent)
                        heroStatTile(label: "Would save more", value: "\(Money.yen(plan.potentialSavings))/mo", color: Theme.heroInk)
                    }
                } else {
                    HStack(spacing: 10) {
                        heroStatTile(label: "Already cut", value: "\(Money.yen(plan.alreadyCut))/mo", color: Theme.heroAccent)
                        heroStatTile(label: "Would save more", value: "\(Money.yen(plan.potentialSavings))/mo", color: Theme.heroInk)
                    }
                }
            }
        }
    }

    private func heroStatTile(label: String, value: String, color: Color) -> some View {
        FrostedMetricTile {
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(Theme.heroInkMuted)
            Text(value)
                .font(.headline.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    private var activeTargetsCard: some View {
        FinanceCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    SectionLabel("Active targets", symbol: "target")
                    Spacer()
                    Text("Tap to edit cap")
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                }

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(plan.active.enumerated()), id: \.element.id) { idx, row in
                        if idx > 0 {
                            HairlineDivider()
                                .padding(.vertical, 14)
                        }
                        planRowView(row)
                    }
                }
            }
        }
    }

    private var settledTargetsCard: some View {
        FinanceCard {
            VStack(alignment: .leading, spacing: 12) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showSettled.toggle()
                    }
                } label: {
                    HStack {
                        SectionLabel("Done or keeping (\(plan.settled.count))", symbol: "checkmark.circle")
                        Spacer()
                        Image(systemName: showSettled ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.muted)
                    }
                    .frame(minHeight: 32)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if showSettled {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(plan.settled.enumerated()), id: \.element.id) { idx, row in
                            if idx > 0 {
                                HairlineDivider()
                                    .padding(.vertical, 14)
                            }
                            planRowView(row)
                        }
                    }
                }
            }
        }
    }

    private func planRowView(_ row: PlanRow) -> some View {
        Button {
            if isPresentedModally { dismiss() }
            session.activeSheet = .categoryDetail(name: row.entry.category, periodID: plan.selectedMonth)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.entry.category)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Theme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        QuietTag(row.displayStatus, tone: QuietTag.Tone(statusTone: row.tone))
                        savingText(row)
                    }
                } else {
                    HStack(alignment: .center, spacing: 11) {
                        CategoryBadge(category: row.entry.category, size: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(row.entry.category)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Theme.ink)
                                    .lineLimit(1)
                                QuietTag(row.displayStatus, tone: QuietTag.Tone(statusTone: row.tone))
                            }
                            if let note = row.entry.note, !note.isEmpty {
                                Text(note)
                                    .font(.caption)
                                    .foregroundStyle(Theme.muted)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 6)
                        savingText(row)
                    }
                }

                if dynamicTypeSize.isAccessibilitySize, let note = row.entry.note, !note.isEmpty {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !row.history.isEmpty {
                    PlanSparkline(points: Array(row.history.suffix(12)), target: row.entry.target)
                        .frame(height: 40)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 6)
                        .background(Theme.well.opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                if let target = row.entry.target {
                    let ratio = row.selectedMonthProgress ?? 0
                    let barColor: Color = row.selectedMonthSpent > target
                        ? Theme.bad
                        : (ratio >= 0.8 ? Theme.warn : Theme.good)
                    ProgressMeter(ratio: ratio, tint: barColor, height: 6, paceRatio: activePace)
                }

                FlowLayout(horizontalSpacing: 16, verticalSpacing: 4) {
                    metricPair(label: "Period", value: MaskedMoney.yen(row.selectedMonthSpent, masked: privacyMasked))
                    metricPair(label: "Avg", value: MaskedMoney.yen(row.entry.now, masked: privacyMasked))
                    metricPair(label: "Target", value: row.entry.target.map { MaskedMoney.yen($0, masked: privacyMasked) } ?? "—")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func savingText(_ row: PlanRow) -> some View {
        if let saving = row.monthlySaving {
            if saving > 0 {
                QuietTag("Saves \(Money.yen(saving))", tone: .good)
            } else if saving < 0 {
                Text("+\(Money.yen(-saving))")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(Theme.muted)
            } else {
                Text("¥0")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(Theme.muted)
            }
        }
    }

    private func metricPair(label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(Theme.muted)
            Text(value)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.ink2)
        }
    }
}

/// Compact multi-month bar sparkline with rounded bar caps and a dashed emerald target line.
struct PlanSparkline: View {
    let points: [PlanMonthPoint]
    let target: Int?

    var body: some View {
        let maxSpent = points.map(\.spent).max() ?? 0
        let ceiling = max(1, max(maxSpent, target ?? 0))

        GeometryReader { geo in
            ZStack(alignment: .bottomLeading) {
                HStack(alignment: .bottom, spacing: 4) {
                    ForEach(points) { pt in
                        let frac = CGFloat(max(0, pt.spent)) / CGFloat(ceiling)
                        RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                            .fill(barColor(pt))
                            .opacity(pt.isInProgress ? 0.65 : (pt.isSelected ? 1.0 : 0.48))
                            .frame(height: max(pt.spent > 0 ? 4 : 1.5, geo.size.height * frac))
                            .frame(maxWidth: .infinity)
                    }
                }

                if let target, target > 0 {
                    let y = geo.size.height * (1.0 - CGFloat(target) / CGFloat(ceiling))
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: geo.size.width, y: y))
                    }
                    .stroke(Theme.accent.opacity(0.85), style: StrokeStyle(lineWidth: 1.25, dash: [4, 3]))
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func barColor(_ pt: PlanMonthPoint) -> Color {
        if let target, pt.spent > target {
            return pt.isSelected ? Theme.bad : Theme.bad.opacity(0.65)
        }
        return pt.isSelected ? Theme.accent : Theme.muted
    }
}
