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
    @Environment(\.privacyMasked) private var privacyMasked
    @ScaledMetric(relativeTo: .caption2) private var chartAxisFontSize: CGFloat = 11

    @State private var breakdownTab: BreakdownTab = .categories
    @State private var showAllCategories = false
    @State private var isScrubbingChart = false
    @State private var screenCache = ScreenModelCache<String, MonthsScreenModel>()

    private var activeData: FinanceData? {
        session.resolvedData(from: model)
    }

    private var activeSelectedID: String? {
        session.periodMode == .payCycle ? session.monthsSelectedCycleID : session.monthsSelectedMonth
    }

    private var screenCacheKey: String {
        guard let data = activeData else { return "" }
        return "\(data.id.uuidString)|\(session.periodMode.rawValue)|\(activeSelectedID ?? "")|\(session.today)"
    }

    private func resolvedScreen(for data: FinanceData) -> MonthsScreenModel {
        screenCache.get(for: screenCacheKey) {
            MonthsScreenModel(
                data: data,
                periodMode: session.periodMode,
                selectedPeriodID: activeSelectedID,
                today: session.today
            )
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: Theme.cardSpacing) {
                    if let data = activeData {
                        let screen = resolvedScreen(for: data)
                        if screen.periods.isEmpty {
                            StateCard(
                                kind: .empty,
                                title: "No monthly totals yet",
                                message: "Turn on Google Drive sync in More → Connections."
                            )
                        } else {
                            PeriodModeSwitch(mode: $session.periodMode)
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
                .verticalScrollPage()
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .background(Theme.page)
            .navigationTitle(session.periodMode == .payCycle ? "Pay Cycles" : "Months")
            .sensoryFeedback(.selection, trigger: session.periodMode)
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
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.16)) {
                                session.privacyMasked.toggle()
                            }
                        } label: {
                            Image(systemName: session.privacyMasked ? "eye.slash.fill" : "eye")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(session.privacyMasked ? Theme.accent : Theme.ink2)
                        }
                        .accessibilityLabel(session.privacyMasked ? "Show amounts" : "Hide amounts")

                        if let data = session.resolvedData(from: model), !data.planSummary.isEmpty {
                            Button("Targets") {
                                session.activeSheet = .targets
                            }
                            .font(.subheadline.weight(.medium))
                        }
                    }
                }
            }
            .refreshable {
                guard !session.isDemo else { return }
                await model.syncGmail()
            }
        }
    }

    // MARK: - Editorial Stacked Bar Chart Card with Haptic Scrubbing & Tappable Layer Legend

    private func stackedChartCard(screen: MonthsScreenModel, asOf: String) -> some View {
        let comp = screen.comparison
        let headerTitle = comp.isInProgress
            ? (screen.periodMode == .payCycle ? "Spent this cycle" : "Spent so far")
            : (screen.periodMode == .payCycle ? "Cycle spending" : "Monthly spending")

        return FinanceCard {
            VStack(alignment: .leading, spacing: 14) {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel(headerTitle, symbol: "chart.bar.fill")
                        periodMenuButton(screen: screen)
                    }
                } else {
                    HStack(alignment: .center, spacing: 8) {
                        SectionLabel(headerTitle, symbol: "chart.bar.fill")
                        Spacer(minLength: 8)
                        periodMenuButton(screen: screen)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        HeroMoneyText(amount: screen.selectedTotals.total, color: Theme.ink)
                        if isScrubbingChart, let period = screen.selectedPeriod {
                            QuietTag(period.shortLabel, tone: .accent)
                        }
                    }

                    FlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                        if !privacyMasked, let delta = comp.deltaFromPrevious, let prev = comp.previousMonth {
                            let isUp = delta > 0
                            let arrow = isUp ? "▲" : "▼"
                            let verb = isUp ? "vs" : "under"
                            let prevLabel = screen.periodMode == .calendarMonth
                                ? DayText.shortMonth(prev + "-01")
                                : prev
                            QuietTag(
                                "\(arrow) \(MaskedMoney.yen(abs(delta), masked: false)) \(verb) \(prevLabel)",
                                tone: isUp ? .bad : .good
                            )
                        } else if comp.isInProgress {
                            QuietTag("So far · \(DayText.short(asOf))", tone: .accent)
                        }
                        if let avg = comp.baselineAverage {
                            QuietTag("Avg \(MaskedMoney.yen(avg, masked: privacyMasked))", tone: .neutral)
                        }
                    }
                }

                if privacyMasked {
                    stackedChart(screen: screen)
                        .frame(height: dynamicTypeSize.isAccessibilitySize ? 245 : 220)
                        .padding(.top, 2)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Spending chart hidden in Privacy Mode.")
                } else {
                    stackedChart(screen: screen)
                        .frame(height: dynamicTypeSize.isAccessibilitySize ? 245 : 220)
                        .padding(.top, 2)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(chartAccessibilitySummary(screen: screen))
                        .accessibilityAdjustableAction { direction in
                            stepPeriod(screen: screen, forward: direction == .increment)
                        }
                }

                HairlineDivider()

                layerLegend(screen: screen)
            }
        }
    }

    private func periodMenuButton(screen: MonthsScreenModel) -> some View {
        let title = screen.selectedPeriod?.title ?? screen.selectedPeriodID
        return Menu {
            ForEach(screen.periods.reversed()) { period in
                Button {
                    selectPeriod(period.id)
                } label: {
                    let suffix = period.isInProgress ? " (active)" : ""
                    if period.id == screen.selectedPeriodID {
                        Label(period.title + suffix, systemImage: "checkmark")
                    } else {
                        Text(period.title + suffix)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(title)
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
        .accessibilityLabel("Selected period, \(title)")
        .accessibilityHint("Choose another period")
    }

    private func stackedChart(screen: MonthsScreenModel) -> some View {
        let axisSize = min(chartAxisFontSize, 15)
        let topLayerByPeriod: [String: SpendingLayer] = Dictionary(
            grouping: screen.segments,
            by: \.periodID
        ).compactMapValues { segs in
            segs.max(by: { $0.yEnd < $1.yEnd })?.layer
        }

        let baseChart = Chart {
            RectangleMark(
                x: .value("Period", screen.selectedPeriodID),
                yStart: .value("Start", 0),
                yEnd: .value("End", screen.maxChartTotal),
                width: .ratio(0.84)
            )
            .foregroundStyle(Theme.accent.opacity(isScrubbingChart ? 0.13 : 0.07))

            ForEach(screen.segments) { segment in
                let isSelected = segment.periodID == screen.selectedPeriodID
                let isTop = topLayerByPeriod[segment.periodID] == segment.layer
                let opacity: Double = {
                    if segment.isInProgress { return isSelected ? 0.86 : 0.36 }
                    return isSelected ? 1.0 : 0.42
                }()
                BarMark(
                    x: .value("Period", segment.periodID),
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
                        x: .value("Period", pt.periodID),
                        y: .value("Income", pt.income)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(Theme.good)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

                    PointMark(
                        x: .value("Period", pt.periodID),
                        y: .value("Income", pt.income)
                    )
                    .foregroundStyle(Theme.surface)
                    .symbolSize(46)

                    PointMark(
                        x: .value("Period", pt.periodID),
                        y: .value("Income", pt.income)
                    )
                    .foregroundStyle(Theme.good)
                    .symbol(.circle)
                    .symbolSize(24)
                }
            }
        }
        .chartLegend(.hidden)
        .chartXScale(domain: screen.periodIDs)
        .chartYScale(domain: 0...screen.maxChartTotal)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.6, dash: [3, 3]))
                    .foregroundStyle(Theme.grid)
                AxisValueLabel {
                    if let amount = value.as(Int.self) {
                        Text(privacyMasked ? "¥••" : FinanceFormat.compactYen(amount))
                            .font(.system(size: axisSize))
                            .monospacedDigit()
                            .foregroundStyle(Theme.muted)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: screen.periodIDs) { value in
                AxisValueLabel {
                    if let id = value.as(String.self) {
                        let isSelected = id == screen.selectedPeriodID
                        Text(screen.axisLabel(for: id))
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
                        let plotX = location.x - geo[plotFrame].origin.x
                        if let hit = proxy.value(atX: plotX, as: String.self),
                           screen.periodIDs.contains(hit),
                           hit != screen.selectedPeriodID {
                            selectPeriod(hit)
                        }
                    }
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 14)
                            .onChanged { value in
                                // Only horizontal-scrub when all periods fit without native horizontal chart scrolling.
                                guard screen.periodIDs.count <= 6,
                                      abs(value.translation.width) > abs(value.translation.height)
                                else { return }
                                isScrubbingChart = true
                                guard let plotFrame = proxy.plotFrame else { return }
                                let plotX = value.location.x - geo[plotFrame].origin.x
                                if let hit = proxy.value(atX: plotX, as: String.self),
                                   screen.periodIDs.contains(hit),
                                   hit != screen.selectedPeriodID {
                                    selectPeriod(hit)
                                }
                            }
                            .onEnded { _ in
                                isScrubbingChart = false
                            }
                    )
            }
        }
        .sensoryFeedback(.selection, trigger: screen.selectedPeriodID)

        return Group {
            if privacyMasked {
                VStack(spacing: 8) {
                    Image(systemName: "eye.slash")
                        .font(.title3)
                        .foregroundStyle(Theme.muted)
                    Text("Chart hidden in Privacy Mode")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.muted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.well.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else if screen.periodIDs.count > 6 {
                baseChart
                    .chartScrollableAxes(.horizontal)
                    .chartXVisibleDomain(length: 6)
                    .chartScrollPosition(initialX: screen.selectedPeriodID)
            } else {
                baseChart
            }
        }
    }

    private func stepPeriod(screen: MonthsScreenModel, forward: Bool) {
        guard let currentIndex = screen.periodIDs.firstIndex(of: screen.selectedPeriodID) else { return }
        let nextIndex = forward ? currentIndex + 1 : currentIndex - 1
        guard screen.periodIDs.indices.contains(nextIndex) else { return }
        selectPeriod(screen.periodIDs[nextIndex])
    }

    private func layerLegend(screen: MonthsScreenModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(screen.selectedLayerAmounts) { item in
                let pct = Int((item.share * 100).rounded())
                Button {
                    openPaymentsForLayer(item.layer, period: screen.selectedPeriod)
                } label: {
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
                                Text(privacyMasked ? MaskedMoney.yen(item.amount, masked: true) : "\(MaskedMoney.yen(item.amount, masked: false)) · \(pct)%")
                                    .font(.subheadline.weight(.semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(item.amount > 0 ? Theme.ink : Theme.muted)
                                    .padding(.leading, 20)
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
                                Text(MaskedMoney.yen(item.amount, masked: privacyMasked))
                                    .font(.subheadline.weight(.semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(item.amount > 0 ? Theme.ink : Theme.muted)
                                Text(privacyMasked ? "••%" : "\(pct)%")
                                    .font(.caption.weight(.medium))
                                    .monospacedDigit()
                                    .foregroundStyle(Theme.muted)
                                    .frame(minWidth: 34, alignment: .trailing)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Theme.muted.opacity(0.65))
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if screen.incomePoints.count >= 2 {
                HStack(spacing: 8) {
                    Capsule()
                        .fill(Theme.good)
                        .frame(width: 14, height: 2.5)
                        .accessibilityHidden(true)
                    Text(screen.periodMode == .payCycle
                         ? "Green line shows salary & income each pay cycle"
                         : "Green line shows completed months' income")
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                }
                .padding(.top, 2)
            }
        }
    }

    // MARK: - Spent vs income summary card (with Pace Notch)

    private func spentVsIncomeCard(screen: MonthsScreenModel) -> some View {
        let totals = screen.selectedTotals
        let comp = screen.comparison
        let hasIncome = totals.income > 0
        let overspent = hasIncome && totals.total > totals.income
        let ratio = hasIncome ? min(1.0, Double(max(0, totals.total)) / Double(totals.income)) : 0
        let periodLabel = screen.selectedPeriod?.title ?? screen.selectedPeriodID

        return FinanceCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    SectionLabel("Spent vs income", symbol: "scale.3d")
                    Spacer()
                    if !privacyMasked, let rate = comp.savingsRate, (!comp.isInProgress || screen.periodMode == .payCycle) {
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
                            summaryMetric(title: "Spent", amount: totals.total, color: (!privacyMasked && overspent) ? Theme.bad : Theme.ink)
                        }
                        MetricWell(tint: hasIncome ? Theme.good : nil) {
                            summaryMetric(title: "Income", amount: totals.income, color: hasIncome ? Theme.good : Theme.muted)
                        }
                    }
                } else {
                    HStack(alignment: .top, spacing: 10) {
                        MetricWell {
                            summaryMetric(title: "Spent", amount: totals.total, color: (!privacyMasked && overspent) ? Theme.bad : Theme.ink)
                        }
                        MetricWell(tint: hasIncome ? Theme.good : nil) {
                            summaryMetric(title: "Income", amount: totals.income, color: hasIncome ? Theme.good : Theme.muted)
                        }
                    }
                }

                if hasIncome {
                    ProgressMeter(
                        ratio: privacyMasked ? 0 : ratio,
                        tint: (!privacyMasked && overspent) ? Theme.bad : Theme.accent,
                        height: 8,
                        paceRatio: screen.activePeriodPace
                    )
                }

                VStack(alignment: .leading, spacing: 9) {
                    summaryDetailRow(
                        title: "Fixed (rent, bills, subs)",
                        value: MaskedMoney.yen(comp.fixedCosts, masked: privacyMasked),
                        accessibilityValue: MaskedMoney.accessibility(comp.fixedCosts, masked: privacyMasked),
                        color: Theme.ink2
                    )
                    summaryDetailRow(
                        title: "Day-to-day",
                        value: MaskedMoney.yen(comp.dayToDayCosts, masked: privacyMasked),
                        accessibilityValue: MaskedMoney.accessibility(comp.dayToDayCosts, masked: privacyMasked),
                        color: Theme.ink
                    )
                    if totals.debt != 0 {
                        summaryDetailRow(
                            title: "Debt payments",
                            value: MaskedMoney.yen(totals.debt, masked: privacyMasked),
                            accessibilityValue: MaskedMoney.accessibility(totals.debt, masked: privacyMasked),
                            color: Theme.bad
                        )
                    }
                    if totals.people != 0 {
                        summaryDetailRow(
                            title: "Transfers to people",
                            value: MaskedMoney.yen(totals.people, masked: privacyMasked),
                            accessibilityValue: MaskedMoney.accessibility(totals.people, masked: privacyMasked),
                            color: Theme.ink2
                        )
                    }
                    if hasIncome {
                        let leftPositive = totals.left >= 0
                        let hasExtraOutflows = totals.debt != 0 || totals.people != 0
                        let leftLabel: String = {
                            if privacyMasked {
                                return hasExtraOutflows ? "Net left" : "Left after spending"
                            }
                            return leftPositive
                                ? (hasExtraOutflows ? "Net left" : "Left after spending")
                                : "Short by"
                        }()
                        let wellTint: Color = privacyMasked ? Theme.accent : (leftPositive ? Theme.good : Theme.bad)
                        let valueColor: Color = privacyMasked ? Theme.ink : (leftPositive ? Theme.good : Theme.bad)
                        MetricWell(tint: wellTint) {
                            summaryDetailRow(
                                title: leftLabel,
                                value: MaskedMoney.signed(totals.left, masked: privacyMasked),
                                accessibilityValue: MaskedMoney.accessibility(totals.left, signed: true, masked: privacyMasked),
                                color: valueColor,
                                emphasized: true
                            )
                        }
                        .padding(.top, 2)
                    } else {
                        Text("No income recorded in \(periodLabel) yet.")
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

    // MARK: - Where to cut summary card (with Pace Notch + Category Inspector)

    private func whereToCutSummaryCard(screen: MonthsScreenModel) -> some View {
        let plan = screen.planSummary
        return FinanceCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 8) {
                    SectionLabel("Where to cut", symbol: "scissors")
                    Spacer(minLength: 8)
                    NavigationLink {
                        WhereToCutView(plan: plan, activePace: screen.activePeriodPace)
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
                            Text("\(MaskedMoney.yen(plan.alreadyCut, masked: privacyMasked))/mo")
                                .font(.subheadline.weight(.bold))
                                .monospacedDigit()
                                .foregroundStyle(Theme.good)
                        }
                        MetricWell(tint: Theme.accent) {
                            Text("Targets save more")
                                .font(.caption)
                                .foregroundStyle(Theme.muted)
                            Text("\(MaskedMoney.yen(plan.potentialSavings, masked: privacyMasked))/mo")
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
                            Text("\(MaskedMoney.yen(plan.alreadyCut, masked: privacyMasked))/mo")
                                .font(.subheadline.weight(.bold))
                                .monospacedDigit()
                                .foregroundStyle(Theme.good)
                        }
                        MetricWell(tint: Theme.accent) {
                            Text("Targets save more")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(Theme.muted)
                            Text("\(MaskedMoney.yen(plan.potentialSavings, masked: privacyMasked))/mo")
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
                            let tint: Color = privacyMasked
                                ? Theme.accent
                                : (row.selectedMonthSpent > target
                                    ? Theme.bad
                                    : (ratio >= 0.8 ? Theme.warn : Theme.good))
                            Button {
                                session.activeSheet = .categoryDetail(name: row.entry.category, periodID: screen.selectedPeriodID)
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
                                            Text("\(MaskedMoney.yen(row.selectedMonthSpent, masked: privacyMasked)) / \(MaskedMoney.yen(target, masked: privacyMasked))")
                                                .font(.caption.weight(.semibold))
                                                .monospacedDigit()
                                                .foregroundStyle((!privacyMasked && row.selectedMonthSpent > target) ? Theme.bad : Theme.ink2)
                                        }
                                        ProgressMeter(ratio: privacyMasked ? 0 : ratio, tint: tint, height: 5.5, paceRatio: screen.activePeriodPace)
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

    // MARK: - Where it went (Categories | Merchants | Cards — with Deep Inspector Mini-Dashboards)

    private func breakdownCard(screen: MonthsScreenModel) -> some View {
        FinanceCard {
            VStack(alignment: .leading, spacing: 14) {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 4) {
                        SectionLabel("Where it went", symbol: "square.grid.2x2")
                        Text("Tap to inspect")
                            .font(.caption)
                            .foregroundStyle(Theme.muted)
                    }
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        SectionLabel("Where it went", symbol: "square.grid.2x2")
                        Spacer(minLength: 8)
                        Text("Tap to inspect")
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
            Text("No categorized spending in \(screen.selectedPeriod?.title ?? "this period").")
                .font(.subheadline)
                .foregroundStyle(Theme.muted)
        } else {
            let visible = showAllCategories ? screen.categoryBars : Array(screen.categoryBars.prefix(12))
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(visible.enumerated()), id: \.element.id) { index, bar in
                    if index > 0 {
                        HairlineDivider().padding(.vertical, 4)
                    }
                    categoryRow(bar: bar, periodID: screen.selectedPeriodID)
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
            Text("No merchants in \(screen.selectedPeriod?.title ?? "this period").")
                .font(.subheadline)
                .foregroundStyle(Theme.muted)
        } else {
            let maxSum = max(1, screen.topMerchants.first?.total ?? 1)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(screen.topMerchants.prefix(15).enumerated()), id: \.element.id) { idx, shop in
                    if idx > 0 {
                        HairlineDivider().padding(.vertical, 4)
                    }
                    Button {
                        session.activeSheet = .merchantDetail(name: shop.merchant, periodID: screen.selectedPeriodID)
                    } label: {
                        HStack(alignment: .center, spacing: 11) {
                            if !dynamicTypeSize.isAccessibilitySize {
                                CategoryBadge(category: shop.category, size: 34)
                            }
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(MaskedMoney.redactText(shop.merchant, masked: privacyMasked))
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(Theme.ink)
                                        .lineLimit(1)
                                    Spacer(minLength: 8)
                                    Text(MaskedMoney.yen(shop.total, masked: privacyMasked))
                                        .font(.subheadline.weight(.semibold))
                                        .monospacedDigit()
                                        .foregroundStyle(Theme.ink)
                                    Image(systemName: "chevron.right")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(Theme.muted)
                                }
                                Text("\(shop.count) \(shop.count == 1 ? "visit" : "visits") · avg \(MaskedMoney.yen(shop.average, masked: privacyMasked)) · \(shop.category)")
                                    .font(.caption)
                                    .foregroundStyle(Theme.muted)
                                    .lineLimit(1)
                                ProgressMeter(ratio: privacyMasked ? 0 : Double(shop.total) / Double(maxSum), tint: Theme.accent, height: 5.5)
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
            Text("No card or account spending in \(screen.selectedPeriod?.title ?? "this period").")
                .font(.subheadline)
                .foregroundStyle(Theme.muted)
        } else {
            let maxSum = max(1, screen.sourceSummaries.first?.total ?? 1)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(screen.sourceSummaries.enumerated()), id: \.element.id) { idx, src in
                    if idx > 0 {
                        HairlineDivider().padding(.vertical, 4)
                    }
                    let pct = Int((src.share * 100).rounded())
                    let spec = CategoryStyle.forSource(src.source)
                    Button {
                        if let period = screen.selectedPeriod, period.mode == .payCycle {
                            session.openPayments(cycleID: period.id, source: src.source)
                        } else {
                            session.openPayments(month: screen.selectedPeriodID, source: src.source)
                        }
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
                                    Text(MaskedMoney.yen(src.total, masked: privacyMasked))
                                        .font(.subheadline.weight(.semibold))
                                        .monospacedDigit()
                                        .foregroundStyle(Theme.ink)
                                    Text(privacyMasked ? "••%" : "\(pct)%")
                                        .font(.caption.weight(.medium))
                                        .monospacedDigit()
                                        .foregroundStyle(Theme.muted)
                                        .frame(minWidth: 32, alignment: .trailing)
                                }
                                ProgressMeter(ratio: privacyMasked ? 0 : Double(src.total) / Double(maxSum), tint: spec.tint, height: 6)
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

    private func categoryRow(bar: MonthsScreenModel.CategoryBar, periodID: String) -> some View {
        let percent = Int((bar.share * 100).rounded())
        let paymentWord = bar.count == 1 ? "payment" : "payments"

        return Button {
            session.activeSheet = .categoryDetail(name: bar.name, periodID: periodID)
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
                            Text(MaskedMoney.yen(bar.sum, masked: privacyMasked))
                                .font(.body.weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(Theme.ink)
                            Text(privacyMasked ? "\(bar.count) \(paymentWord)" : "\(bar.count) \(paymentWord) · \(percent)%")
                                .font(.caption)
                                .foregroundStyle(Theme.muted)
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
                            Text(MaskedMoney.yen(bar.sum, masked: privacyMasked))
                                .font(.subheadline.weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(Theme.ink)
                            Text(privacyMasked ? "••%" : "\(percent)%")
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

                    ProgressMeter(ratio: privacyMasked ? 0 : bar.barFraction, tint: bar.layer.color, height: 6)
                }
            }
            .padding(.vertical, 8)
            .frame(minHeight: Theme.minTouchTarget, alignment: .center)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            privacyMasked
                ? "\(bar.name), \(MaskedMoney.accessibility(bar.sum, masked: true)), \(bar.count) \(paymentWord)"
                : "\(bar.name), \(MaskedMoney.accessibility(bar.sum, masked: false)), \(percent) percent, \(bar.count) \(paymentWord)"
        )
    }

    private func openPaymentsForLayer(_ layer: SpendingLayer, period: BudgetPeriod?) {
        if let period {
            if period.mode == .payCycle {
                session.openPayments(cycleID: period.id, layer: layer)
            } else {
                session.openPayments(month: period.id, layer: layer)
            }
        } else {
            session.openPayments(month: nil, layer: layer)
        }
    }

    private func selectPeriod(_ id: String) {
        let update = {
            if session.periodMode == .payCycle {
                session.monthsSelectedCycleID = id
            } else {
                session.monthsSelectedMonth = id
            }
        }
        if reduceMotion {
            update()
        } else {
            withAnimation(.easeInOut(duration: 0.16), update)
        }
    }

    private func chartAccessibilitySummary(screen: MonthsScreenModel) -> String {
        let title = screen.selectedPeriod?.title ?? screen.selectedPeriodID
        let total = MaskedMoney.accessibility(screen.selectedTotals.total, masked: privacyMasked)
        return "Spending stacked chart. Selected period \(title), total spending \(total)."
    }
}
