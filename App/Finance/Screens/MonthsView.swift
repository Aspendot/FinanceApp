import Charts
import FinanceCore
import SwiftUI

struct MonthsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var session: AppSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .caption2) private var chartAxisFontSize: CGFloat = 11
    @State private var selectedMonth: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.cardSpacing) {
                    if let data = session.resolvedData(from: model) {
                        let screen = MonthsScreenModel(data: data, selectedMonth: selectedMonth)
                        if screen.months.isEmpty {
                            StateCard(
                                kind: .empty,
                                title: "No monthly totals yet",
                                message: "Turn on Google Drive sync in More → Connections."
                            )
                        } else {
                            stackedChartCard(screen: screen)
                            spentVsIncomeCard(screen: screen)
                            whereItWentCard(screen: screen)
                        }
                    } else if !session.hasCompletedInitialLoad {
                        StateCard(
                            kind: .loading,
                            title: "Loading data",
                            message: "Checking stored statements and recent bank emails."
                        )
                    } else if let error = model.importMessage, error.hasPrefix("Not imported:") {
                        StateCard(
                            kind: .error,
                            title: "Could not read data file",
                            message: error,
                            actionTitle: "Check again"
                        ) {
                            Task { await model.checkInbox() }
                        }
                    } else {
                        NoDataView()
                    }
                }
                .padding(.horizontal, Theme.screenPadding)
                .padding(.vertical, 12)
            }
            .background(Theme.page)
            .navigationTitle("Months")
            .refreshable {
                guard !session.isDemo else { return }
                await model.syncGmail()
            }
        }
    }

    // MARK: - Stacked bar chart card

    private func stackedChartCard(screen: MonthsScreenModel) -> some View {
        FinanceCard {
            VStack(alignment: .leading, spacing: 14) {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionLabel("Monthly spending")
                        monthMenuButton(screen: screen)
                    }
                } else {
                    HStack(alignment: .center, spacing: 8) {
                        SectionLabel("Monthly spending")
                        Spacer(minLength: 8)
                        monthMenuButton(screen: screen)
                    }
                }

                stackedChart(screen: screen)
                    .frame(height: dynamicTypeSize.isAccessibilitySize ? 240 : 210)
                    .accessibilityLabel(chartAccessibilitySummary(screen: screen))
                    .accessibilityAdjustableAction { direction in
                        stepMonth(screen: screen, forward: direction == .increment)
                    }

                HairlineDivider()

                layerLegend(screen: screen)
            }
        }
    }

    private func monthMenuButton(screen: MonthsScreenModel) -> some View {
        Menu {
            ForEach(screen.months.reversed(), id: \.self) { month in
                Button {
                    selectMonth(month)
                } label: {
                    if month == screen.selectedMonth {
                        Label(DayText.month(month), systemImage: "checkmark")
                    } else {
                        Text(DayText.month(month))
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(DayText.month(screen.selectedMonth))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .allowsTightening(true)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 32)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Selected month, \(DayText.month(screen.selectedMonth))")
        .accessibilityHint("Choose another month")
    }

    private func stackedChart(screen: MonthsScreenModel) -> some View {
        let axisSize = min(chartAxisFontSize, 15)
        let baseChart = Chart {
            ForEach(screen.segments) { segment in
                BarMark(
                    x: .value("Month", segment.month),
                    yStart: .value("Start", segment.yStart),
                    yEnd: .value("End", segment.yEnd),
                    width: .ratio(0.56)
                )
                .foregroundStyle(segment.layer.color)
                .opacity(segment.month == screen.selectedMonth ? 1.0 : 0.42)
            }
        }
        .chartLegend(.hidden)
        .chartYScale(domain: 0...screen.maxChartTotal)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(Theme.grid)
                AxisValueLabel {
                    if let amount = value.as(Int.self) {
                        Text(FinanceFormat.compactYen(amount))
                            .font(.system(size: axisSize))
                            .monospacedDigit()
                            .foregroundStyle(Theme.muted)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: screen.months) { value in
                AxisValueLabel {
                    if let month = value.as(String.self) {
                        let isSelected = month == screen.selectedMonth
                        Text(FinanceFormat.chartMonth(month))
                            .font(.system(size: axisSize, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(isSelected ? Theme.accent : Theme.muted)
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        guard let plotFrame = proxy.plotFrame else { return }
                        let origin = geo[plotFrame].origin
                        let plotX = location.x - origin.x
                        if let tappedMonth = proxy.value(atX: plotX, as: String.self),
                           screen.months.contains(tappedMonth) {
                            selectMonth(tappedMonth)
                        }
                    }
            }
        }

        return Group {
            if screen.months.count > 6 {
                baseChart
                    .chartScrollableAxes(.horizontal)
                    .chartXVisibleDomain(length: 6)
                    .chartScrollPosition(initialX: screen.selectedMonth)
            } else {
                baseChart
            }
        }
    }

    private func stepMonth(screen: MonthsScreenModel, forward: Bool) {
        guard let currentIndex = screen.months.firstIndex(of: screen.selectedMonth) else { return }
        let nextIndex = forward ? currentIndex + 1 : currentIndex - 1
        guard screen.months.indices.contains(nextIndex) else { return }
        selectMonth(screen.months[nextIndex])
    }

    private func layerLegend(screen: MonthsScreenModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(screen.selectedLayerAmounts) { item in
                Group {
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .center, spacing: 8) {
                                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                    .fill(item.layer.color)
                                    .frame(width: 12, height: 12)
                                    .accessibilityHidden(true)
                                Text(item.title)
                                    .font(.subheadline)
                                    .foregroundStyle(Theme.ink2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Text(Money.yen(item.amount))
                                .font(.subheadline.weight(.medium))
                                .monospacedDigit()
                                .foregroundStyle(item.amount > 0 ? Theme.ink : Theme.muted)
                                .lineLimit(1)
                                .minimumScaleFactor(0.5)
                                .allowsTightening(true)
                                .padding(.leading, 20)
                                .accessibilityLabel(FinanceFormat.yenAccessibility(item.amount))
                        }
                    } else {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                .fill(item.layer.color)
                                .frame(width: 10, height: 10)
                                .accessibilityHidden(true)
                            Text(item.title)
                                .font(.subheadline)
                                .foregroundStyle(Theme.ink2)
                            Spacer(minLength: 8)
                            Text(Money.yen(item.amount))
                                .font(.subheadline.weight(.medium))
                                .monospacedDigit()
                                .foregroundStyle(item.amount > 0 ? Theme.ink : Theme.muted)
                                .accessibilityLabel(FinanceFormat.yenAccessibility(item.amount))
                        }
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    // MARK: - Spent vs income summary card

    private func spentVsIncomeCard(screen: MonthsScreenModel) -> some View {
        let totals = screen.selectedTotals
        let hasIncome = totals.income > 0
        let overspent = hasIncome && totals.total > totals.income
        let ratio = hasIncome ? min(1.0, Double(max(0, totals.total)) / Double(totals.income)) : 0

        return FinanceCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionLabel("Spent vs income")

                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 12) {
                        summaryMetric(title: "Spent", amount: totals.total, color: overspent ? Theme.bad : Theme.ink)
                        summaryMetric(title: "Income", amount: totals.income, color: hasIncome ? Theme.good : Theme.muted)
                    }
                } else {
                    HStack(alignment: .top, spacing: 16) {
                        summaryMetric(title: "Spent", amount: totals.total, color: overspent ? Theme.bad : Theme.ink)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        summaryMetric(title: "Income", amount: totals.income, color: hasIncome ? Theme.good : Theme.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if hasIncome {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Theme.track)
                            Capsule()
                                .fill(overspent ? Theme.bad : Theme.accent)
                                .frame(width: max(ratio > 0 ? 6 : 0, geo.size.width * ratio))
                        }
                    }
                    .frame(height: 8)
                    .accessibilityHidden(true)
                }

                HairlineDivider()

                VStack(alignment: .leading, spacing: 8) {
                    if totals.debt != 0 {
                        summaryDetailRow(
                            title: "Debt payments",
                            value: Money.yen(totals.debt),
                            accessibilityValue: FinanceFormat.yenAccessibility(totals.debt),
                            color: Theme.bad
                        )
                    }
                    if totals.people != 0 {
                        summaryDetailRow(
                            title: "Transfers to people",
                            value: Money.yen(totals.people),
                            accessibilityValue: FinanceFormat.yenAccessibility(totals.people),
                            color: Theme.ink2
                        )
                    }
                    if hasIncome {
                        let leftPositive = totals.left >= 0
                        summaryDetailRow(
                            title: leftPositive ? "Left after spending" : "Over income",
                            value: Money.signed(totals.left),
                            accessibilityValue: FinanceFormat.yenAccessibility(totals.left, signed: true),
                            color: leftPositive ? Theme.good : Theme.bad,
                            emphasized: true
                        )
                    } else {
                        Text("No income recorded in \(DayText.month(screen.selectedMonth)) yet.")
                            .font(.footnote)
                            .foregroundStyle(Theme.muted)
                    }
                }
            }
        }
    }

    private func summaryMetric(title: String, amount: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.footnote)
                .foregroundStyle(Theme.muted)
            MetricMoneyText(amount: amount, color: color)
        }
        .accessibilityElement(children: .combine)
    }

    private func summaryDetailRow(
        title: String,
        value: String,
        accessibilityValue: String,
        color: Color,
        emphasized: Bool = false
    ) -> some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(emphasized ? .subheadline.weight(.semibold) : .subheadline)
                        .foregroundStyle(emphasized ? Theme.ink : Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(value)
                        .font(emphasized ? .subheadline.weight(.semibold) : .subheadline)
                        .monospacedDigit()
                        .foregroundStyle(color)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .allowsTightening(true)
                        .accessibilityLabel(accessibilityValue)
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title)
                        .font(emphasized ? .subheadline.weight(.semibold) : .subheadline)
                        .foregroundStyle(emphasized ? Theme.ink : Theme.ink2)
                    Spacer(minLength: 8)
                    Text(value)
                        .font(emphasized ? .subheadline.weight(.semibold) : .subheadline)
                        .monospacedDigit()
                        .foregroundStyle(color)
                        .accessibilityLabel(accessibilityValue)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Where it went card

    private func whereItWentCard(screen: MonthsScreenModel) -> some View {
        FinanceCard {
            VStack(alignment: .leading, spacing: 14) {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 4) {
                        SectionLabel("Where it went")
                        Text("Tap to filter")
                            .font(.caption)
                            .foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        SectionLabel("Where it went")
                        Spacer(minLength: 8)
                        Text("Tap to filter")
                            .font(.caption)
                            .foregroundStyle(Theme.muted)
                    }
                }

                if screen.categoryBars.isEmpty {
                    Text("No categorized spending in \(DayText.month(screen.selectedMonth)).")
                        .font(.subheadline)
                        .foregroundStyle(Theme.muted)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(screen.categoryBars.enumerated()), id: \.element.id) { index, bar in
                            if index > 0 {
                                HairlineDivider()
                                    .padding(.vertical, 4)
                            }
                            categoryRow(bar: bar, month: screen.selectedMonth)
                        }
                    }
                }
            }
        }
    }

    private func categoryRow(bar: MonthsScreenModel.CategoryBar, month: String) -> some View {
        let percent = Int((bar.share * 100).rounded())
        let paymentWord = bar.count == 1 ? "payment" : "payments"

        return Button {
            session.openPayments(month: month, category: bar.name)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(bar.name)
                                .font(.body.weight(.medium))
                                .foregroundStyle(Theme.ink)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.muted)
                                .accessibilityHidden(true)
                        }
                        Text(Money.yen(bar.sum))
                            .font(.body.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                            .allowsTightening(true)
                        Text("\(bar.count) \(paymentWord) · \(percent)%")
                            .font(.caption)
                            .foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(bar.name)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                        Text("\(bar.count) \(paymentWord)")
                            .font(.caption)
                            .foregroundStyle(Theme.muted)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(Money.yen(bar.sum))
                            .font(.subheadline.weight(.medium))
                            .monospacedDigit()
                            .foregroundStyle(Theme.ink)
                        Text("\(percent)%")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(Theme.muted)
                            .frame(minWidth: 32, alignment: .trailing)
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Theme.muted)
                            .accessibilityHidden(true)
                    }
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Theme.track)
                        Capsule()
                            .fill(bar.layer.color)
                            .frame(width: max(6, geo.size.width * bar.barFraction))
                    }
                }
                .frame(height: 6)
                .accessibilityHidden(true)
            }
            .padding(.vertical, 8)
            .frame(minHeight: Theme.minTouchTarget, alignment: .center)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(bar.name), \(FinanceFormat.yenAccessibility(bar.sum)), \(percent) percent, \(bar.count) \(paymentWord)")
        .accessibilityHint("Filters Payments to \(bar.name) in \(DayText.month(month))")
    }

    private func selectMonth(_ month: String) {
        if reduceMotion {
            selectedMonth = month
        } else {
            withAnimation(.easeInOut(duration: 0.18)) {
                selectedMonth = month
            }
        }
    }

    private func chartAccessibilitySummary(screen: MonthsScreenModel) -> String {
        let monthName = DayText.month(screen.selectedMonth)
        let total = FinanceFormat.yenAccessibility(screen.selectedTotals.total)
        return "Monthly spending stacked chart. Selected month \(monthName), total spending \(total)."
    }
}
