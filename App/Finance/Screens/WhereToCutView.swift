import FinanceCore
import SwiftUI

/// Full "Where to cut" plan view showing baseline vs targets, sparklines, and live monthly cap tracking.
struct WhereToCutView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var session: AppSession

    let plan: PlanSummary
    var isPresentedModally: Bool = false

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
        FinanceCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel("Monthly target")

                HeroMoneyText(amount: plan.projectedTotal, color: Theme.ink)

                Text("Down from \(Money.yen(plan.baselineTotal))/month baseline. Already cut about \(Money.yen(plan.alreadyCut))/month; active targets save another \(Money.yen(plan.potentialSavings))/month.")
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)

                HairlineDivider()

                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 8) {
                        statBlock(label: "Already cut", value: Money.yen(plan.alreadyCut), color: Theme.good)
                        statBlock(label: "Would save more", value: Money.yen(plan.potentialSavings), color: Theme.accent)
                    }
                } else {
                    HStack(alignment: .top, spacing: 16) {
                        statBlock(label: "Already cut", value: Money.yen(plan.alreadyCut), color: Theme.good)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        statBlock(label: "Would save more", value: Money.yen(plan.potentialSavings), color: Theme.accent)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private func statBlock(label: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(Theme.muted)
            Text(value + "/mo")
                .font(.headline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(color)
        }
    }

    private var activeTargetsCard: some View {
        FinanceCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionLabel("Active targets")
                    Spacer()
                    Text("Tap to open Payments")
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                }

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(plan.active.enumerated()), id: \.element.id) { idx, row in
                        if idx > 0 {
                            HairlineDivider()
                                .padding(.vertical, 12)
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
                        SectionLabel("Done or keeping (\(plan.settled.count))")
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
                                    .padding(.vertical, 12)
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
            session.openPayments(month: plan.selectedMonth, category: row.entry.category)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
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
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(row.entry.category)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        QuietTag(row.displayStatus, tone: QuietTag.Tone(statusTone: row.tone))
                        Spacer(minLength: 8)
                        savingText(row)
                    }
                }

                if let note = row.entry.note, !note.isEmpty {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !row.history.isEmpty {
                    PlanSparkline(points: Array(row.history.suffix(12)), target: row.entry.target)
                        .frame(height: 36)
                }

                if let target = row.entry.target {
                    let ratio = row.selectedMonthProgress ?? 0
                    let barColor: Color = row.selectedMonthSpent > target
                        ? Theme.bad
                        : (ratio >= 0.8 ? Color("LayerDayToDay") : Theme.good)
                    ProgressMeter(ratio: ratio, tint: barColor, height: 5)
                }

                FlowLayout(horizontalSpacing: 14, verticalSpacing: 4) {
                    metricPair(label: DayText.shortMonth(plan.selectedMonth + "-01"), value: Money.yen(row.selectedMonthSpent))
                    metricPair(label: "Avg", value: Money.yen(row.entry.now))
                    metricPair(label: "Target", value: row.entry.target.map { Money.yen($0) } ?? "—")
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
                Text("Saves \(Money.yen(saving))")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.good)
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
                .font(.caption2)
                .foregroundStyle(Theme.muted)
            Text(value)
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(Theme.ink2)
        }
    }
}

/// Compact multi-month bar sparkline with a dashed target line.
struct PlanSparkline: View {
    let points: [PlanMonthPoint]
    let target: Int?

    var body: some View {
        let maxSpent = points.map(\.spent).max() ?? 0
        let ceiling = max(1, max(maxSpent, target ?? 0))

        GeometryReader { geo in
            ZStack(alignment: .bottomLeading) {
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(points) { pt in
                        let frac = CGFloat(max(0, pt.spent)) / CGFloat(ceiling)
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(barColor(pt))
                            .opacity(pt.isInProgress ? 0.5 : (pt.isSelected ? 1.0 : 0.45))
                            .frame(height: max(pt.spent > 0 ? 3 : 1, geo.size.height * frac))
                            .frame(maxWidth: .infinity)
                    }
                }

                if let target, target > 0 {
                    let y = geo.size.height * (1.0 - CGFloat(target) / CGFloat(ceiling))
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: geo.size.width, y: y))
                    }
                    .stroke(Theme.accent.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func barColor(_ pt: PlanMonthPoint) -> Color {
        if let target, pt.spent > target, pt.isSelected {
            return Theme.bad
        }
        return pt.isSelected ? Theme.ink : Theme.muted
    }
}
