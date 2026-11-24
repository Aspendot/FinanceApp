import Charts
import FinanceCore
import SwiftUI

/// Interactive 90-day cash-flow runway curve with haptic scrubbing and What-If toggles.
struct CashFlowRunwayView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.privacyMasked) private var privacyMasked
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var session: AppSession

    @State private var cancelledSubIDs: Set<String> = []
    @State private var extraDebtPayment: Double = 0
    @State private var monthlyTrim: Double = 0
    @State private var scrubbedDayIndex: Int? = nil
    @State private var startingCashOverride: Int? = nil
    @State private var editingStartingCash = false
    @State private var startingCashInput = ""
    @State private var forecastCache = ScreenModelCache<String, CashFlowSummary>()

    private var activeData: FinanceData? {
        session.resolvedData(from: model)
    }

    private var resolvedStartingOverride: Int? {
        session.isDemo ? nil : startingCashOverride
    }

    private var scenario: WhatIfScenario {
        WhatIfScenario(
            cancelledSubscriptionIDs: cancelledSubIDs,
            extraMonthlyDebtPayment: Int(extraDebtPayment.rounded()),
            monthlyDayToDaySavings: Int(monthlyTrim.rounded())
        )
    }

    private var forecastCacheKey: String {
        guard let data = activeData else { return "" }
        let subsKey = cancelledSubIDs.sorted().joined(separator: ",")
        return "\(data.id.uuidString)|\(session.today)|\(resolvedStartingOverride.map(String.init) ?? "auto")|\(subsKey)|\(Int(extraDebtPayment.rounded()))|\(Int(monthlyTrim.rounded()))"
    }

    private func resolvedForecast(for data: FinanceData) -> CashFlowSummary {
        forecastCache.get(for: forecastCacheKey) {
            CashFlowForecast.project(
                today: session.today,
                days: 90,
                payday: data.payday,
                paydayBreakdown: data.paydayBreakdown,
                timeline: data.timeline,
                allItems: data.allItems,
                subscriptionSummary: data.subscriptionSummary,
                config: data.bundle.layerConfig,
                layers: data.bundle.layers,
                scenario: scenario,
                startingCashOverride: resolvedStartingOverride,
                liveCash: data.liveCash
            )
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: Theme.cardSpacing) {
                    if let data = activeData {
                        let forecast = resolvedForecast(for: data)
                        heroSummaryCard(forecast: forecast)
                        runwayChartCard(forecast: forecast)
                        whatIfControlsCard(data: data, forecast: forecast)
                        keyMilestonesCard(forecast: forecast)
                    } else {
                        NoDataView()
                    }
                }
                .verticalScrollPage()
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.page)
            .navigationTitle("90-day runway")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !scenario.isBaseline {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Reset") {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                cancelledSubIDs.removeAll()
                                extraDebtPayment = 0
                                monthlyTrim = 0
                            }
                        }
                        .font(.subheadline.weight(.medium))
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    // MARK: - Midnight Forest Hero

    private func heroSummaryCard(forecast: CashFlowSummary) -> some View {
        let activePoint: CashFlowDayPoint? = scrubbedDayIndex.flatMap { idx in
            forecast.points.indices.contains(idx) ? forecast.points[idx] : nil
        }
        let displayAmount = activePoint?.scenarioBalance ?? forecast.scenarioEndBalance
        let lowest = forecast.scenarioLowest
        let hasDip = (lowest?.scenarioBalance ?? 0) < 20_000

        return HeroVaultCard(accentTint: hasDip ? Theme.heroCoral : Theme.heroGlow) {
            VStack(alignment: .leading, spacing: 14) {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionLabel(
                            activePoint.map { DayText.short($0.date) } ?? "Projected in 90 days",
                            symbol: "chart.xyaxis.line",
                            color: Theme.heroInkMuted
                        )
                        QuietTag("Estimate", tone: .hero)
                    }
                } else {
                    HStack {
                        SectionLabel(
                            activePoint.map { DayText.short($0.date) } ?? "Projected in 90 days",
                            symbol: "chart.xyaxis.line",
                            color: Theme.heroInkMuted
                        )
                        Spacer()
                        QuietTag("Estimate", tone: .hero)
                    }
                }

                HeroMoneyText(
                    amount: displayAmount,
                    color: displayAmount < 0 ? Theme.heroCoral : Theme.heroInk
                )

                if let activePoint {
                    if !activePoint.events.isEmpty {
                        let summary = activePoint.events
                            .map { "\($0.title) \(MaskedMoney.payment($0.amount, masked: privacyMasked))" }
                            .joined(separator: " · ")
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(Theme.heroAccent)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Day \(activePoint.dayIndex + 1) of 90 · drag along the chart to inspect any day.")
                            .font(.caption)
                            .foregroundStyle(Theme.heroInkMuted)
                    }
                } else if !scenario.isBaseline {
                    let delta = forecast.scenarioDelta
                    Text("What-If change: \(MaskedMoney.signed(delta, masked: privacyMasked)) vs current pace over 90 days.")
                        .font(.footnote)
                        .foregroundStyle(delta >= 0 ? Theme.heroAccent : Theme.heroCoral)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    let deferredNote = forecast.excludedDeferredCardSources.isEmpty
                        ? ""
                        : " (\(forecast.excludedDeferredCardSources.joined(separator: ", ")) counted via monthly bills)"
                    Text("Projects recurring bills, paydays, and your recent cash/debit pace (\(MaskedMoney.yen(forecast.baselineDailyBurn, masked: privacyMasked))/day)\(deferredNote).")
                        .font(.footnote)
                        .foregroundStyle(Theme.heroInkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if editingStartingCash {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            TextField("Current bank cash (yen)", text: $startingCashInput)
                                .keyboardType(.numberPad)
                                .font(.subheadline.weight(.semibold))
                                .monospacedDigit()
                                .padding(.horizontal, 11)
                                .padding(.vertical, 8)
                                .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .foregroundStyle(Theme.heroInk)
                            Button("Set") {
                                let clean = startingCashInput.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                                if let val = Int(clean) {
                                    startingCashOverride = val
                                }
                                editingStartingCash = false
                            }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.heroTop)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Theme.heroAccent, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .buttonStyle(.plain)
                        }
                        HStack(spacing: 14) {
                            if resolvedStartingOverride != nil {
                                Button("Reset to estimate") {
                                    startingCashOverride = nil
                                    editingStartingCash = false
                                }
                                .font(.caption.weight(.medium))
                                .foregroundStyle(Theme.heroCoral)
                                .buttonStyle(.plain)
                            }
                            Button("Cancel") {
                                editingStartingCash = false
                            }
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Theme.heroInkMuted)
                            .buttonStyle(.plain)
                        }
                    }
                }

                if dynamicTypeSize.isAccessibilitySize {
                    VStack(spacing: 8) {
                        startingTile(forecast: forecast, fillHeight: false)
                        lowestTile(lowest: lowest, fillHeight: false)
                    }
                } else {
                    Grid(alignment: .topLeading, horizontalSpacing: 10, verticalSpacing: 8) {
                        GridRow {
                            startingTile(forecast: forecast, fillHeight: true)
                            lowestTile(lowest: lowest, fillHeight: true)
                        }
                    }
                }
            }
        }
    }

    private func startingTile(forecast: CashFlowSummary, fillHeight: Bool) -> some View {
        Button {
            guard !session.isDemo else { return }
            startingCashInput = String(max(0, forecast.startingCashEstimate))
            withAnimation(.easeInOut(duration: 0.16)) {
                editingStartingCash.toggle()
            }
        } label: {
            FrostedMetricTile(fillHeight: fillHeight) {
                HStack(spacing: 4) {
                    Text(resolvedStartingOverride != nil ? "Bank cash set" : "Est. cash today")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Theme.heroInkMuted)
                    if !session.isDemo {
                        Image(systemName: "pencil")
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(Theme.heroAccent)
                    }
                }
                Text(MaskedMoney.yen(forecast.startingCashEstimate, masked: privacyMasked))
                    .font(.subheadline.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.heroInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(DayText.short(forecast.startDate))
                    .font(.caption2)
                    .foregroundStyle(Theme.heroInkMuted.opacity(0.85))
            }
        }
        .buttonStyle(TactileCardButtonStyle())
    }

    private func lowestTile(lowest: CashFlowDayPoint?, fillHeight: Bool) -> some View {
        let lowVal = lowest?.scenarioBalance ?? 0
        let isLow = lowVal < 20_000
        return FrostedMetricTile(fillHeight: fillHeight) {
            Text("Lowest point")
                .font(.caption2.weight(.medium))
                .foregroundStyle(Theme.heroInkMuted)
            Text(MaskedMoney.yen(lowVal, masked: privacyMasked))
                .font(.subheadline.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(isLow ? Theme.heroCoral : Theme.heroAccent)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(lowest.map { DayText.short($0.date) } ?? "—")
                .font(.caption2)
                .foregroundStyle(Theme.heroInkMuted.opacity(0.85))
        }
    }

    // MARK: - Interactive Scrubbing Curve

    private func runwayChartCard(forecast: CashFlowSummary) -> some View {
        let allValues = forecast.points.flatMap { [$0.baselineBalance, $0.scenarioBalance] }
        let minVal = min(0, allValues.min() ?? 0)
        let maxVal = max(50_000, allValues.max() ?? 100_000)
        let pad = max(15_000, Int(Double(maxVal - minVal) * 0.12))
        let yLow = minVal < 0 ? minVal - pad : 0
        let yHigh = maxVal + pad

        return FinanceCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionLabel("Balance curve", symbol: "waveform.path.ecg")
                    Spacer()
                    Text("Drag to scrub")
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                }

                Chart {
                    if yLow < 0 {
                        RuleMark(y: .value("Zero", 0))
                            .foregroundStyle(Theme.bad.opacity(0.55))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    }

                    if !scenario.isBaseline {
                        ForEach(forecast.points) { pt in
                            LineMark(
                                x: .value("Day", pt.dayIndex),
                                y: .value("Baseline", pt.baselineBalance),
                                series: .value("Series", "Current pace")
                            )
                            .foregroundStyle(Theme.muted.opacity(0.55))
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                        }
                    }

                    ForEach(forecast.points) { pt in
                        AreaMark(
                            x: .value("Day", pt.dayIndex),
                            yStart: .value("Floor", max(0, yLow)),
                            yEnd: .value("Balance", pt.scenarioBalance)
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Theme.accent.opacity(0.24), Theme.accent.opacity(0.02)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                        LineMark(
                            x: .value("Day", pt.dayIndex),
                            y: .value("Balance", pt.scenarioBalance),
                            series: .value("Series", "Scenario")
                        )
                        .foregroundStyle(Theme.accent)
                        .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                    }

                    if let low = forecast.scenarioLowest, low.scenarioBalance < 20_000 {
                        PointMark(
                            x: .value("Day", low.dayIndex),
                            y: .value("Low", low.scenarioBalance)
                        )
                        .foregroundStyle(Theme.bad)
                        .symbolSize(52)
                    }

                    if let idx = scrubbedDayIndex, forecast.points.indices.contains(idx) {
                        let pt = forecast.points[idx]
                        RuleMark(x: .value("Scrub", idx))
                            .foregroundStyle(Theme.ink.opacity(0.35))
                            .lineStyle(StrokeStyle(lineWidth: 1))
                        PointMark(
                            x: .value("Scrub", idx),
                            y: .value("Balance", pt.scenarioBalance)
                        )
                        .foregroundStyle(Theme.surface)
                        .symbolSize(70)
                        PointMark(
                            x: .value("Scrub", idx),
                            y: .value("Balance", pt.scenarioBalance)
                        )
                        .foregroundStyle(pt.scenarioBalance < 0 ? Theme.bad : Theme.accent)
                        .symbolSize(38)
                    }
                }
                .chartLegend(.hidden)
                .chartYScale(domain: yLow...yHigh)
                .chartXScale(domain: 0...max(1, forecast.points.count - 1))
                .chartXAxis {
                    AxisMarks(values: [0, 30, 60, max(1, forecast.points.count - 1)]) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                            .foregroundStyle(Theme.grid)
                        AxisValueLabel(
                            anchor: value.as(Int.self) == max(1, forecast.points.count - 1) ? .topTrailing : (value.as(Int.self) == 0 ? .topLeading : .top)
                        ) {
                            if let idx = value.as(Int.self), forecast.points.indices.contains(idx) {
                                Text(DayText.format(forecast.points[idx].date, template: "MMMd"))
                                    .font(.caption2)
                                    .foregroundStyle(Theme.muted)
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                            .foregroundStyle(Theme.grid)
                        AxisValueLabel {
                            if let val = value.as(Int.self) {
                                Text(privacyMasked ? "¥••" : FinanceFormat.compactYen(val))
                                    .font(.caption2)
                                    .monospacedDigit()
                                    .foregroundStyle(Theme.muted)
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
                                guard let frame = proxy.plotFrame else { return }
                                let x = location.x - geo[frame].origin.x
                                if let idx: Int = proxy.value(atX: x) {
                                    let clamped = min(max(0, idx), max(0, forecast.points.count - 1))
                                    scrubbedDayIndex = (scrubbedDayIndex == clamped) ? nil : clamped
                                }
                            }
                            .simultaneousGesture(
                                DragGesture(minimumDistance: 14)
                                    .onChanged { value in
                                        // Only scrub on horizontal drags so vertical scrolling over the chart stays effortless.
                                        guard abs(value.translation.width) > abs(value.translation.height) else { return }
                                        guard let frame = proxy.plotFrame else { return }
                                        let x = value.location.x - geo[frame].origin.x
                                        if let idx: Int = proxy.value(atX: x) {
                                            let clamped = min(max(0, idx), max(0, forecast.points.count - 1))
                                            if scrubbedDayIndex != clamped {
                                                scrubbedDayIndex = clamped
                                            }
                                        }
                                    }
                                    .onEnded { _ in
                                        scrubbedDayIndex = nil
                                    }
                            )
                    }
                }
                .sensoryFeedback(.selection, trigger: scrubbedDayIndex)
                .frame(height: 210)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(runwayChartAccessibility(forecast: forecast))
            }
        }
    }

    private func runwayChartAccessibility(forecast: CashFlowSummary) -> String {
        let start = MaskedMoney.accessibility(forecast.startingCashEstimate, masked: privacyMasked)
        let end = MaskedMoney.accessibility(
            scenario.isBaseline ? forecast.baselineEndBalance : forecast.scenarioEndBalance,
            masked: privacyMasked
        )
        let low = forecast.baselineLowest.map {
            ", lowest point \(MaskedMoney.accessibility($0.baselineBalance, masked: privacyMasked)) on \(DayText.short($0.date))"
        } ?? ""
        return "90-day cash flow runway chart. Starting from \(start), projected to \(end)\(low)."
    }

    // MARK: - Interactive What-If Controls

    private func whatIfControlsCard(data: FinanceData, forecast: CashFlowSummary) -> some View {
        FinanceCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    SectionLabel("What-if levers", symbol: "slider.horizontal.3")
                    Spacer()
                    if !scenario.isBaseline {
                        let d = forecast.scenarioDelta
                        QuietTag(
                            "\(d >= 0 ? "+" : "")\(MaskedMoney.yen(d, masked: privacyMasked)) / 90d",
                            tone: d >= 0 ? .good : .bad
                        )
                    }
                }

                if !data.subscriptionSummary.running.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Tap a subscription to simulate cancelling it")
                            .font(.caption)
                            .foregroundStyle(Theme.muted)
                        FlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                            ForEach(data.subscriptionSummary.running) { sub in
                                let isOff = cancelledSubIDs.contains(sub.id)
                                Button {
                                    withAnimation(.easeInOut(duration: 0.16)) {
                                        if isOff {
                                            cancelledSubIDs.remove(sub.id)
                                        } else {
                                            cancelledSubIDs.insert(sub.id)
                                        }
                                    }
                                } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: isOff ? "checkmark.circle.fill" : "circle")
                                            .font(.caption2)
                                        Text("\(sub.entry.name) · \(MaskedMoney.yen(sub.entry.monthly, masked: privacyMasked))")
                                            .font(.caption.weight(.medium))
                                            .strikethrough(isOff)
                                    }
                                    .foregroundStyle(isOff ? Theme.good : Theme.ink2)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(isOff ? Theme.goodWash : Theme.well, in: Capsule())
                                    .overlay(
                                        Capsule().strokeBorder(
                                            isOff ? Theme.good.opacity(0.3) : Theme.line.opacity(0.6),
                                            lineWidth: 0.6
                                        )
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                HairlineDivider()

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Trim day-to-day / month")
                            .font(.subheadline)
                            .foregroundStyle(Theme.ink2)
                        Spacer()
                        Text("+\(MaskedMoney.yen(Int(monthlyTrim.rounded()), masked: privacyMasked))")
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(Theme.good)
                    }
                    Slider(value: $monthlyTrim, in: 0...60_000, step: 2_000)
                        .tint(Theme.good)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Extra debt payment / month")
                            .font(.subheadline)
                            .foregroundStyle(Theme.ink2)
                        Spacer()
                        Text("−\(MaskedMoney.yen(Int(extraDebtPayment.rounded()), masked: privacyMasked))")
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(extraDebtPayment > 0 ? Theme.warn : Theme.muted)
                    }
                    Slider(value: $extraDebtPayment, in: 0...60_000, step: 2_000)
                        .tint(Theme.warn)
                }

                Text("Estimate only. Assumes regular paydays and recurring bills repeat monthly alongside your 60-day average day-to-day pace.")
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Key Scheduled Inflections

    private func keyMilestonesCard(forecast: CashFlowSummary) -> some View {
        let majorEvents = forecast.points
            .flatMap(\.events)
            .filter { abs($0.amount) >= 10_000 }
            .prefix(10)

        return FinanceCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel("Key bills & paydays ahead", symbol: "calendar.badge.clock")

                if majorEvents.isEmpty {
                    Text("No scheduled items above ¥10,000 in the next 90 days.")
                        .font(.footnote)
                        .foregroundStyle(Theme.muted)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(majorEvents.enumerated()), id: \.element.id) { idx, ev in
                            if idx > 0 {
                                HairlineDivider().padding(.vertical, 9)
                            }
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(ev.title)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(Theme.ink)
                                    HStack(spacing: 6) {
                                        Text(DayText.short(ev.date))
                                            .font(.caption)
                                            .foregroundStyle(Theme.muted)
                                        if ev.isProjectedRepeat {
                                            QuietTag("Projected", tone: .neutral)
                                        } else if ev.isEstimate {
                                            QuietTag("Estimate", tone: .neutral)
                                        }
                                    }
                                }
                                Spacer(minLength: 8)
                                Text(MaskedMoney.payment(ev.amount, masked: privacyMasked))
                                    .font(.subheadline.weight(.semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(ev.amount < 0 ? Theme.good : Theme.ink)
                            }
                        }
                    }
                }
            }
        }
    }
}
