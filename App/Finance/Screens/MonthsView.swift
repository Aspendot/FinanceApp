import Charts
import FinanceCore
import SwiftUI

struct MonthsView: View {
    private enum BreakdownTab: String, CaseIterable, Identifiable {
        case categories = "Categories"
        case merchants = "Merchants"
        case cards = "Cards"

        var id: String { rawValue }
    }

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var session: AppSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .caption2) private var chartAxisFontSize: CGFloat = 11

    @State private var breakdownTab: BreakdownTab = .categories
    @State private var showAllCategories = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.cardSpacing) {
                    if let data = session.resolvedData(from: model) {
                        let screen = MonthsScreenModel(
                            data: data,
                            selectedMonth: session.monthsSelectedMonth,
                            today: session.today
                        )
                        if screen.months.isEmpty {
                            StateCard(
                                kind: .empty,
                                title: "No monthly totals yet",
                                message: "Turn on Google Drive sync in More → Connections."
                            )
                        } else {
                            stackedChartCard(screen: screen, asOf: data.bundle.asOf)
                            spentVsIncomeCard(screen: screen)
                            if !screen.planSummary.isEmpty {
                                whereToCutSummaryCard(screen: screen)
                            }
                            breakdownCard(screen: screen)
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
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        session.activeSheet = .ask
                    } label: {
                        Label("Ask", systemImage: "text.magnifyingglass")
                            .labelStyle(.titleAndIcon)
                            .font(.subheadline.weight(.medium))
                    }
                    .accessibilityLabel("Ask Finance")
                }
                if let data = session.resolvedData(from: model), !data.planSummary.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Targets") {
                            session.activeSheet = .targets
                        }
                        .font(.subheadline.weight(.medium))
                    }
                }
            }
            .refreshable {
                guard !session.isDemo else { return }
                await model.syncGmail()
            }
        }
    }

    // MARK: - Editorial Stacked Bar Chart Card

    private func stackedChartCard(screen: MonthsScreenModel, asOf: String) -> some View {
        let comp = screen.comparison
        return FinanceCard {
            VStack(alignment: .leading, spacing: 14) {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel(comp.isInProgress ? "Spent so far" : "Monthly spending", symbol: "chart.bar.fill")
                        monthMenuButton(screen: screen)
                    }
                } else {
                    HStack(alignment: .center, spacing: 8) {
                        SectionLabel(comp.isInProgress ? "Spent so far" : "Monthly spending", symbol: "chart.bar.fill")
                        Spacer(minLength: 8)
                        monthMenuButton(screen: screen)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    HeroMoneyText(amount: screen.selectedTotals.total, color: Theme.ink)

                    FlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                        if let delta = comp.deltaFromPrevious, let prev = comp.previousMonth {
                            let isUp = delta > 0
                            let arrow = isUp ? "▲" : "▼"
                            let verb = isUp ? "vs" : "under"
                            QuietTag(
                                "\(arrow) \(Money.yen(abs(delta))) \(verb) \(DayText.shortMonth(prev + "-01"))",
                                tone: isUp ? .bad : .good
                            )
                        } else if comp.isInProgress {
                            QuietTag("So far · \(DayText.short(asOf))", tone: .accent)
                        }
                        if let avg = comp.baselineAverage {
                            QuietTag("Avg \(Money.yen(avg))/mo", tone: .neutral)
                        }
                    }
                }

                stackedChart(screen: screen)
                    .frame(height: dynamicTypeSize.isAccessibilitySize ? 245 : 220)
                    .padding(.top, 2)
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
                    let suffix = month == screen.inProgressMonth ? " (so far)" : ""
                    if month == screen.selectedMonth {
                        Label(DayText.month(month) + suffix, systemImage: "checkmark")
                    } else {
                        Text(DayText.month(month) + suffix)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(DayText.month(screen.selectedMonth))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .allowsTightening(true)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.accent)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(Theme.accentWash, in: Capsule())
            .overlay(
                Capsule().strokeBorder(Theme.accent.opacity(0.22), lineWidth: 0.6)
            )
            .frame(minHeight: 32)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Selected month, \(DayText.month(screen.selectedMonth))")
        .accessibilityHint("Choose another month")
    }

    private func stackedChart(screen: MonthsScreenModel) -> some View {
        let axisSize = min(chartAxisFontSize, 15)
        let topLayerByMonth: [String: SpendingLayer] = Dictionary(
            grouping: screen.segments,
            by: \.month
        ).compactMapValues { segs in
            segs.max(by: { $0.yEnd < $1.yEnd })?.layer
        }

        let baseChart = Chart {
            // Subtle vertical spotlight behind the selected month
            RectangleMark(
                x: .value("Month", screen.selectedMonth),
                yStart: .value("Start", 0),
                yEnd: .value("End", screen.maxChartTotal),
                width: .ratio(0.84)
            )
            .foregroundStyle(Theme.accent.opacity(0.07))

            ForEach(screen.segments) { segment in
                let isSelected = segment.month == screen.selectedMonth
                let isTop = topLayerByMonth[segment.month] == segment.layer
                let opacity: Double = {
                    if segment.isInProgress { return isSelected ? 0.86 : 0.36 }
                    return isSelected ? 1.0 : 0.42
                }()
                BarMark(
                    x: .value("Month", segment.month),
                    yStart: .value("Start", segment.yStart),
                    yEnd: .value("End", segment.yEnd),
                    width: .ratio(0.56)
                )
                .foregroundStyle(segment.layer.color)
                .opacity(opacity)
                .cornerRadius(isTop ? 3 : 0)
            }

            if screen.incomePoints.count >= 2 {
                ForEach(screen.incomePoints) { pt in
                    LineMark(
                        x: .value("Month", pt.month),
                        y: .value("Income", pt.income)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(Theme.good)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

                    PointMark(
                        x: .value("Month", pt.month),
                        y: .value("Income", pt.income)
                    )
                    .foregroundStyle(Theme.surface)
                    .symbolSize(46)

                    PointMark(
                        x: .value("Month", pt.month),
                        y: .value("Income", pt.income)
                    )
                    .foregroundStyle(Theme.good)
                    .symbol(.circle)
                    .symbolSize(24)
                }
            }
        }
        .chartLegend(.hidden)
        .chartXScale(domain: screen.months)
        .chartYScale(domain: 0...screen.maxChartTotal)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.6, dash: [3, 3]))
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
                        let label = FinanceFormat.chartMonth(month) + (month == screen.inProgressMonth ? "*" : "")
                        Text(label)
                            .font(.system(size: axisSize, weight: isSelected ? .bold : .medium))
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
        VStack(alignment: .leading, spacing: 9) {
            ForEach(screen.selectedLayerAmounts) { item in
                let pct = Int((item.share * 100).rounded())
                Group {
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .center, spacing: 8) {
                                Capsule()
                                    .fill(item.layer.color)
                                    .frame(width: 12, height: 6)
                                    .accessibilityHidden(true)
                                Text(item.title)
                                    .font(.subheadline)
                                    .foregroundStyle(Theme.ink2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Text("\(Money.yen(item.amount)) · \(pct)%")
                                .font(.subheadline.weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(item.amount > 0 ? Theme.ink : Theme.muted)
                                .lineLimit(1)
                                .minimumScaleFactor(0.5)
                                .allowsTightening(true)
                                .padding(.leading, 20)
                                .accessibilityLabel("\(FinanceFormat.yenAccessibility(item.amount)), \(pct) percent")
                        }
                    } else {
                        HStack(alignment: .center, spacing: 10) {
                            Capsule()
                                .fill(item.layer.color)
                                .frame(width: 14, height: 6)
                                .accessibilityHidden(true)
                            Text(item.title)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Theme.ink2)
                            Spacer(minLength: 8)
                            Text(Money.yen(item.amount))
                                .font(.subheadline.weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(item.amount > 0 ? Theme.ink : Theme.muted)
                                .accessibilityLabel(FinanceFormat.yenAccessibility(item.amount))
                            Text("\(pct)%")
                                .font(.caption.weight(.medium))
                                .monospacedDigit()
                                .foregroundStyle(Theme.muted)
                                .frame(minWidth: 34, alignment: .trailing)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
            }
            if screen.incomePoints.count >= 2 {
                HStack(spacing: 8) {
                    HStack(spacing: 0) {
                        Capsule()
                            .fill(Theme.good)
                            .frame(width: 14, height: 2.5)
                    }
                    .accessibilityHidden(true)
                    Text("Green line shows completed months' income")
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                }
                .padding(.top, 2)
            }
        }
    }

    // MARK: - Spent vs income summary card

    private func spentVsIncomeCard(screen: MonthsScreenModel) -> some View {
        let totals = screen.selectedTotals
        let comp = screen.comparison
        let hasIncome = totals.income > 0
        let overspent = hasIncome && totals.total > totals.income
        let ratio = hasIncome ? min(1.0, Double(max(0, totals.total)) / Double(totals.income)) : 0

        return FinanceCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    SectionLabel("Spent vs income", symbol: "scale.3d")
                    Spacer()
                    if let rate = comp.savingsRate, !comp.isInProgress {
                        let pct = Int((rate * 100).rounded())
                        QuietTag(
                            pct >= 0 ? "Saved \(pct)%" : "Over by \(-pct)%",
                            tone: pct >= 0 ? .good : .bad
                        )
                    }
                }

                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 10) {
                        MetricWell {
                            summaryMetric(title: "Spent", amount: totals.total, color: overspent ? Theme.bad : Theme.ink)
                        }
                        MetricWell(tint: hasIncome ? Theme.good : nil) {
                            summaryMetric(title: "Income", amount: totals.income, color: hasIncome ? Theme.good : Theme.muted)
                        }
                    }
                } else {
                    HStack(alignment: .top, spacing: 10) {
                        MetricWell {
                            summaryMetric(title: "Spent", amount: totals.total, color: overspent ? Theme.bad : Theme.ink)
                        }
                        MetricWell(tint: hasIncome ? Theme.good : nil) {
                            summaryMetric(title: "Income", amount: totals.income, color: hasIncome ? Theme.good : Theme.muted)
                        }
                    }
                }

                if hasIncome {
                    ProgressMeter(ratio: ratio, tint: overspent ? Theme.bad : Theme.accent, height: 8)
                }

                VStack(alignment: .leading, spacing: 9) {
                    summaryDetailRow(
                        title: "Fixed (rent, bills, subs)",
                        value: Money.yen(comp.fixedCosts),
                        accessibilityValue: FinanceFormat.yenAccessibility(comp.fixedCosts),
                        color: Theme.ink2
                    )
                    summaryDetailRow(
                        title: "Day-to-day",
                        value: Money.yen(comp.dayToDayCosts),
                        accessibilityValue: FinanceFormat.yenAccessibility(comp.dayToDayCosts),
                        color: Theme.ink
                    )
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
                        MetricWell(tint: leftPositive ? Theme.good : Theme.bad) {
                            summaryDetailRow(
                                title: leftPositive ? "Left after spending" : "Short by",
                                value: Money.signed(totals.left),
                                accessibilityValue: FinanceFormat.yenAccessibility(totals.left, signed: true),
                                color: leftPositive ? Theme.good : Theme.bad,
                                emphasized: true
                            )
                        }
                        .padding(.top, 2)
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
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption.weight(.medium))
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
                        .font(emphasized ? .subheadline.weight(.semibold) : .subheadline.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(color)
                        .accessibilityLabel(accessibilityValue)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Where to cut summary card

    private func whereToCutSummaryCard(screen: MonthsScreenModel) -> some View {
        let plan = screen.planSummary
        return FinanceCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 8) {
                    SectionLabel("Where to cut", symbol: "scissors")
                    Spacer(minLength: 8)
                    NavigationLink {
                        WhereToCutView(plan: plan)
                    } label: {
                        HStack(spacing: 4) {
                            Text("All \(plan.active.count + plan.settled.count)")
                                .font(.caption.weight(.semibold))
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                        }
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Theme.accentWash, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }

                if dynamicTypeSize.isAccessibilitySize {
                    VStack(spacing: 8) {
                        MetricWell(tint: Theme.good) {
                            Text("Already cut")
                                .font(.caption)
                                .foregroundStyle(Theme.muted)
                            Text("\(Money.yen(plan.alreadyCut))/mo")
                                .font(.subheadline.weight(.bold))
                                .monospacedDigit()
                                .foregroundStyle(Theme.good)
                        }
                        MetricWell(tint: Theme.accent) {
                            Text("Targets save more")
                                .font(.caption)
                                .foregroundStyle(Theme.muted)
                            Text("\(Money.yen(plan.potentialSavings))/mo")
                                .font(.subheadline.weight(.bold))
                                .monospacedDigit()
                                .foregroundStyle(Theme.accent)
                        }
                    }
                } else {
                    HStack(spacing: 10) {
                        MetricWell(tint: Theme.good) {
                            Text("Already cut")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(Theme.muted)
                            Text("\(Money.yen(plan.alreadyCut))/mo")
                                .font(.subheadline.weight(.bold))
                                .monospacedDigit()
                                .foregroundStyle(Theme.good)
                        }
                        MetricWell(tint: Theme.accent) {
                            Text("Targets save more")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(Theme.muted)
                            Text("\(Money.yen(plan.potentialSavings))/mo")
                                .font(.subheadline.weight(.bold))
                                .monospacedDigit()
                                .foregroundStyle(Theme.accent)
                        }
                    }
                }

                if !plan.watchList.isEmpty {
                    VStack(alignment: .leading, spacing: 11) {
                        ForEach(plan.watchList.prefix(3)) { row in
                            let target = row.entry.target ?? 0
                            let ratio = row.selectedMonthProgress ?? 0
                            let tint: Color = row.selectedMonthSpent > target
                                ? Theme.bad
                                : (ratio >= 0.8 ? Theme.warn : Theme.good)
                            Button {
                                session.openPayments(month: screen.selectedMonth, category: row.entry.category)
                            } label: {
                                HStack(alignment: .center, spacing: 11) {
                                    if !dynamicTypeSize.isAccessibilitySize {
                                        CategoryBadge(category: row.entry.category, size: 32)
                                    }
                                    VStack(alignment: .leading, spacing: 5) {
                                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                                            Text(row.entry.category)
                                                .font(.subheadline.weight(.semibold))
                                                .foregroundStyle(Theme.ink)
                                                .lineLimit(1)
                                            Spacer(minLength: 8)
                                            Text("\(Money.yen(row.selectedMonthSpent)) / \(Money.yen(target))")
                                                .font(.caption.weight(.semibold))
                                                .monospacedDigit()
                                                .foregroundStyle(row.selectedMonthSpent > target ? Theme.bad : Theme.ink2)
                                        }
                                        ProgressMeter(ratio: ratio, tint: tint, height: 5.5)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Where it went (Categories | Merchants | Cards)

    private func breakdownCard(screen: MonthsScreenModel) -> some View {
        FinanceCard {
            VStack(alignment: .leading, spacing: 14) {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 4) {
                        SectionLabel("Where it went", symbol: "square.grid.2x2")
                        Text("Tap to filter Payments")
                            .font(.caption)
                            .foregroundStyle(Theme.muted)
                    }
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        SectionLabel("Where it went", symbol: "square.grid.2x2")
                        Spacer(minLength: 8)
                        Text("Tap to filter")
                            .font(.caption)
                            .foregroundStyle(Theme.muted)
                    }
                }

                Picker("Breakdown", selection: $breakdownTab) {
                    ForEach(BreakdownTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)

                switch breakdownTab {
                case .categories:
                    categoriesList(screen: screen)
                case .merchants:
                    merchantsList(screen: screen)
                case .cards:
                    sourcesList(screen: screen)
                }
            }
        }
    }

    @ViewBuilder
    private func categoriesList(screen: MonthsScreenModel) -> some View {
        if screen.categoryBars.isEmpty {
            Text("No categorized spending in \(DayText.month(screen.selectedMonth)).")
                .font(.subheadline)
                .foregroundStyle(Theme.muted)
        } else {
            let visible = showAllCategories ? screen.categoryBars : Array(screen.categoryBars.prefix(12))
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(visible.enumerated()), id: \.element.id) { index, bar in
                    if index > 0 {
                        HairlineDivider()
                            .padding(.vertical, 4)
                    }
                    categoryRow(bar: bar, month: screen.selectedMonth)
                }
            }
            if screen.categoryBars.count > 12 {
                HairlineDivider()
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showAllCategories.toggle()
                    }
                } label: {
                    Text(showAllCategories ? "Show top 12" : "Show all \(screen.categoryBars.count) categories")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func merchantsList(screen: MonthsScreenModel) -> some View {
        if screen.topMerchants.isEmpty {
            Text("No merchants in \(DayText.month(screen.selectedMonth)).")
                .font(.subheadline)
                .foregroundStyle(Theme.muted)
        } else {
            let maxSum = max(1, screen.topMerchants.first?.total ?? 1)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(screen.topMerchants.prefix(15).enumerated()), id: \.element.id) { idx, shop in
                    if idx > 0 {
                        HairlineDivider()
                            .padding(.vertical, 4)
                    }
                    Button {
                        session.openPayments(month: screen.selectedMonth, category: nil, query: shop.merchant)
                    } label: {
                        HStack(alignment: .center, spacing: 11) {
                            if !dynamicTypeSize.isAccessibilitySize {
                                CategoryBadge(category: shop.category, size: 34)
                            }
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(shop.merchant)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(Theme.ink)
                                        .lineLimit(1)
                                    Spacer(minLength: 8)
                                    Text(Money.yen(shop.total))
                                        .font(.subheadline.weight(.semibold))
                                        .monospacedDigit()
                                        .foregroundStyle(Theme.ink)
                                }
                                Text("\(shop.count) \(shop.count == 1 ? "visit" : "visits") · avg \(Money.yen(shop.average)) · \(shop.category)")
                                    .font(.caption)
                                    .foregroundStyle(Theme.muted)
                                    .lineLimit(1)
                                ProgressMeter(ratio: Double(shop.total) / Double(maxSum), tint: Theme.accent, height: 5.5)
                            }
                        }
                        .padding(.vertical, 8)
                        .frame(minHeight: Theme.minTouchTarget)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private func sourcesList(screen: MonthsScreenModel) -> some View {
        if screen.sourceSummaries.isEmpty {
            Text("No card or account spending in \(DayText.month(screen.selectedMonth)).")
                .font(.subheadline)
                .foregroundStyle(Theme.muted)
        } else {
            let maxSum = max(1, screen.sourceSummaries.first?.total ?? 1)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(screen.sourceSummaries.enumerated()), id: \.element.id) { idx, src in
                    if idx > 0 {
                        HairlineDivider()
                            .padding(.vertical, 4)
                    }
                    let pct = Int((src.share * 100).rounded())
                    let spec = CategoryStyle.forSource(src.source)
                    Button {
                        session.openPayments(month: screen.selectedMonth, category: nil, source: src.source)
                    } label: {
                        HStack(alignment: .center, spacing: 11) {
                            if !dynamicTypeSize.isAccessibilitySize {
                                IconMedallion(symbol: spec.symbol, tint: spec.tint, size: 34)
                            }
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(src.source)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(Theme.ink)
                                    Text("\(src.count)")
                                        .font(.caption)
                                        .foregroundStyle(Theme.muted)
                                    Spacer(minLength: 8)
                                    Text(Money.yen(src.total))
                                        .font(.subheadline.weight(.semibold))
                                        .monospacedDigit()
                                        .foregroundStyle(Theme.ink)
                                    Text("\(pct)%")
                                        .font(.caption.weight(.medium))
                                        .monospacedDigit()
                                        .foregroundStyle(Theme.muted)
                                        .frame(minWidth: 32, alignment: .trailing)
                                }
                                ProgressMeter(ratio: Double(src.total) / Double(maxSum), tint: spec.tint, height: 6)
                            }
                        }
                        .padding(.vertical, 8)
                        .frame(minHeight: Theme.minTouchTarget)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
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
            HStack(alignment: .center, spacing: 11) {
                if !dynamicTypeSize.isAccessibilitySize {
                    CategoryBadge(category: bar.name, size: 34)
                }

                VStack(alignment: .leading, spacing: 7) {
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(bar.name)
                                    .font(.body.weight(.semibold))
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
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.ink)
                                .lineLimit(1)
                            Text("\(bar.count)")
                                .font(.caption)
                                .foregroundStyle(Theme.muted)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(Money.yen(bar.sum))
                                .font(.subheadline.weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(Theme.ink)
                            Text("\(percent)%")
                                .font(.caption.weight(.medium))
                                .monospacedDigit()
                                .foregroundStyle(Theme.muted)
                                .frame(minWidth: 32, alignment: .trailing)
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Theme.muted)
                                .accessibilityHidden(true)
                        }
                    }

                    ProgressMeter(ratio: bar.barFraction, tint: bar.layer.color, height: 6)
                }
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
            session.monthsSelectedMonth = month
        } else {
            withAnimation(.easeInOut(duration: 0.18)) {
                session.monthsSelectedMonth = month
            }
        }
    }

    private func chartAccessibilitySummary(screen: MonthsScreenModel) -> String {
        let monthName = DayText.month(screen.selectedMonth)
        let total = FinanceFormat.yenAccessibility(screen.selectedTotals.total)
        return "Monthly spending stacked chart. Selected month \(monthName), total spending \(total)."
    }
}
