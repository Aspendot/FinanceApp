import FinanceCore
import SwiftUI

struct NowView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var session: AppSession
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var inspectedPayment: InspectedPayment?
    @State private var selectedBill: TimelineEntry?
    @State private var showStoppedSubs = false
    @State private var showGoodToKnow = false

    var body: some View {
        NavigationStack {
            ScrollViewReader { scrollProxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.cardSpacing) {
                        if let data = session.resolvedData(from: model) {
                            let screen = NowScreenModel(data: data, today: session.today)
                            if !screen.alerts.isEmpty {
                                alertsSection(screen: screen, scrollProxy: scrollProxy)
                            }
                            paydaySection(screen: screen)
                            if !screen.watchList.isEmpty {
                                watchListSection(screen: screen, data: data)
                            }
                            comingUpSection(screen: screen)
                                .id("comingUp")
                            if !screen.recentPending.isEmpty {
                                recentPendingSection(screen: screen, data: data)
                            }
                            if !screen.debts.isEmpty || !screen.notes.isEmpty {
                                debtsSection(screen: screen)
                            }
                            if !screen.subscriptionSummary.isEmpty {
                                subscriptionsSection(screen: screen)
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
            }
            .background(Theme.page)
            .navigationTitle("Now")
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
                    Button {
                        session.activeSheet = .quickAdd
                    } label: {
                        Image(systemName: "plus")
                            .font(.body.weight(.semibold))
                    }
                    .accessibilityLabel("Add payment")
                }
            }
            .refreshable {
                guard !session.isDemo else { return }
                await model.syncGmail()
            }
            .sheet(item: $inspectedPayment) { inspected in
                if let data = session.resolvedData(from: model) {
                    PaymentDetailSheet(item: inspected.item, data: data)
                }
            }
            .confirmationDialog(
                selectedBill?.item ?? "Scheduled item",
                isPresented: Binding(
                    get: { selectedBill != nil },
                    set: { if !$0 { selectedBill = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let bill = selectedBill {
                    let isPhoneChecked = session.resolvedData(from: model)?.phoneCheckedBillKeys
                        .contains(BillCheckoff.key(for: bill)) ?? false
                    if bill.done != true || isPhoneChecked {
                        Button(isPhoneChecked ? "Mark unpaid" : "Mark paid on phone") {
                            let target = bill
                            selectedBill = nil
                            guard !session.isDemo else { return }
                            Task { await model.toggleBillCheckoff(for: target) }
                        }
                    }
                    Button("Search past payments") {
                        let query = bill.item.split(separator: " ").first.map(String.init) ?? bill.item
                        selectedBill = nil
                        session.openPayments(month: nil, category: nil, query: query)
                    }
                    Button("Cancel", role: .cancel) {
                        selectedBill = nil
                    }
                }
            } message: {
                if let bill = selectedBill {
                    let amt = bill.amount == 0 ? "" : Money.payment(bill.amount) + " · "
                    Text(amt + DayText.long(bill.date) + (bill.note.map { "\n\($0)" } ?? ""))
                }
            }
        }
    }

    // MARK: - Smart alerts

    private func alertsSection(screen: NowScreenModel, scrollProxy: ScrollViewProxy) -> some View {
        FinanceCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 8) {
                    SectionLabel("Attention")
                    Spacer(minLength: 8)
                    QuietTag("\(screen.alerts.count)", tone: screen.alerts.contains { $0.severity == .urgent } ? .bad : .accent)
                }

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(screen.alerts.prefix(4).enumerated()), id: \.element.id) { idx, alert in
                        if idx > 0 {
                            HairlineDivider()
                                .padding(.vertical, 10)
                        }
                        alertRow(alert, scrollProxy: scrollProxy)
                    }
                }
            }
        }
    }

    private func alertRow(_ alert: FinanceAlert, scrollProxy: ScrollViewProxy) -> some View {
        let tone: QuietTag.Tone = {
            switch alert.severity {
            case .urgent: return .bad
            case .warning: return .accent
            case .info: return .neutral
            }
        }()

        return HStack(alignment: .top, spacing: 10) {
            Button {
                handleAlertAction(alert.action, scrollProxy: scrollProxy)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        QuietTag(alert.badge, tone: tone)
                        Text(alert.title)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Theme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(alert.detail)
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                guard !session.isDemo else { return }
                Task { await model.dismissAlert(id: alert.id) }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.muted)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss alert")
        }
    }

    private func handleAlertAction(_ action: FinanceAlert.Action, scrollProxy: ScrollViewProxy) {
        switch action {
        case .openPayments(let month, let category, let query, let onlyUncategorized):
            session.openPayments(
                month: month,
                category: category,
                query: query,
                onlyUncategorized: onlyUncategorized
            )
        case .openComingUp:
            withAnimation(.easeInOut(duration: 0.25)) {
                scrollProxy.scrollTo("comingUp", anchor: .top)
            }
        case .openTargets:
            session.activeSheet = .targets
        }
    }

    // MARK: - Until payday

    @ViewBuilder
    private func paydaySection(screen: NowScreenModel) -> some View {
        if let payday = screen.payday {
            PaydayHeroCard(
                payday: payday,
                breakdown: screen.paydayBreakdown,
                spent: screen.spentSincePayday,
                lastPayday: screen.lastPayday,
                pendingCount: screen.pendingSincePayday
            )
        } else {
            FinanceCard {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("Until payday")
                    Text("No upcoming payday in the data file.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Add a next payday entry to the timeline and re-export the data file.")
                        .font(.footnote)
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Active monthly cut targets

    private func watchListSection(screen: NowScreenModel, data: FinanceData) -> some View {
        let preview = Array(screen.watchList.prefix(4))
        return FinanceCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 8) {
                    SectionLabel("Monthly targets")
                    Spacer(minLength: 8)
                    Button {
                        session.activeSheet = .targets
                    } label: {
                        Text("Full plan")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                }

                VStack(alignment: .leading, spacing: 12) {
                    ForEach(preview) { row in
                        watchRow(row, currentMonth: data.planSummary.currentMonth)
                    }
                }
            }
        }
    }

    private func watchRow(_ row: PlanRow, currentMonth: String) -> some View {
        let target = row.entry.target ?? 0
        let ratio = row.currentMonthProgress ?? 0
        let tint: Color = row.isOverCapCurrentMonth
            ? Theme.bad
            : (row.isNearCapCurrentMonth ? Color("LayerDayToDay") : Theme.good)

        return Button {
            session.openPayments(month: currentMonth, category: row.entry.category)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.entry.category)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Theme.ink)
                        Text("\(Money.yen(row.currentMonthSpent)) / \(Money.yen(target))")
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(row.isOverCapCurrentMonth ? Theme.bad : Theme.ink2)
                    }
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(row.entry.category)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text("\(Money.yen(row.currentMonthSpent)) / \(Money.yen(target))")
                            .font(.caption.weight(.medium))
                            .monospacedDigit()
                            .foregroundStyle(row.isOverCapCurrentMonth ? Theme.bad : Theme.ink2)
                    }
                }
                ProgressMeter(ratio: ratio, tint: tint, height: 5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Coming up timeline

    private func comingUpSection(screen: NowScreenModel) -> some View {
        FinanceCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 8) {
                    SectionLabel("Coming up")
                    Spacer(minLength: 8)
                    Text("Tap a bill to update")
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                }

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(screen.timelineDays.enumerated()), id: \.element.id) { index, day in
                        if day.showsMonthHeader {
                            Text(DayText.monthUpper(day.monthKey))
                                .font(.caption2.weight(.semibold))
                                .tracking(0.8)
                                .foregroundStyle(Theme.muted)
                                .padding(.top, index > 0 ? 14 : 0)
                                .padding(.bottom, 6)
                        }
                        if day.isNextPayday {
                            paydayDivider(date: day.date)
                                .padding(.top, index > 0 && !day.showsMonthHeader ? 12 : 4)
                                .padding(.bottom, 8)
                        } else if index > 0 && !day.showsMonthHeader {
                            HairlineDivider()
                                .padding(.vertical, 10)
                        }
                        ComingUpDayRow(
                            day: day,
                            phoneCheckedBillKeys: screen.phoneCheckedBillKeys,
                            onSelectEntry: { entry in
                                if entry.event != true {
                                    selectedBill = entry
                                }
                            }
                        )
                    }
                }

                if let afterNote = screen.afterNote, !afterNote.isEmpty {
                    HairlineDivider()
                    Text(afterNote)
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func paydayDivider(date: String) -> some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 6) {
                    HairlineDivider(color: Theme.good.opacity(0.45))
                    Text("PAYDAY · \(FinanceFormat.dayHeader(date))")
                        .font(.caption2.weight(.semibold))
                        .tracking(0.8)
                        .foregroundStyle(Theme.good)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                HStack(spacing: 8) {
                    HairlineDivider(color: Theme.good.opacity(0.45))
                    Text("PAYDAY · \(FinanceFormat.dayHeader(date))")
                        .font(.caption2.weight(.semibold))
                        .tracking(0.8)
                        .foregroundStyle(Theme.good)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .layoutPriority(1)
                    HairlineDivider(color: Theme.good.opacity(0.45))
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Payday divider, \(DayText.long(date))")
    }

    // MARK: - Recent pending

    private func recentPendingSection(screen: NowScreenModel, data: FinanceData) -> some View {
        let previewRows = Array(screen.recentPending.prefix(5))
        let latestMonth = previewRows.first.map { String($0.value.date.prefix(7)) }

        return FinanceCard {
            VStack(alignment: .leading, spacing: 12) {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel("Recent pending")
                        QuietTag("\(screen.recentPending.count) pending", tone: .accent)
                    }
                } else {
                    HStack(alignment: .center, spacing: 8) {
                        SectionLabel("Recent pending")
                        Spacer(minLength: 8)
                        QuietTag("\(screen.recentPending.count) pending", tone: .accent)
                    }
                }

                Text("From bank emails, not on a statement yet. Tap any row for details.")
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(previewRows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 {
                            HairlineDivider()
                                .padding(.vertical, 10)
                        }
                        Button {
                            inspectedPayment = InspectedPayment(item: row.value)
                        } label: {
                            pendingPreviewRow(row.value, counted: data.layer(of: row.value) != nil)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }

                if screen.recentPending.count > 1 {
                    HairlineDivider()
                    LedgerRow(
                        title: "Pending spending",
                        detail: nil,
                        value: Money.yen(screen.pendingSpendingTotal),
                        accessibilityValue: FinanceFormat.yenAccessibility(screen.pendingSpendingTotal),
                        valueColor: Theme.ink,
                        emphasized: true
                    )
                }

                if let latestMonth {
                    Button {
                        session.openPayments(month: latestMonth, category: nil)
                    } label: {
                        HStack(spacing: 6) {
                            Text("Open in Payments")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.accent)
                                .multilineTextAlignment(.leading)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.accent)
                                .accessibilityHidden(true)
                        }
                        .frame(maxWidth: .infinity, minHeight: Theme.minTouchTarget, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func pendingPreviewRow(_ item: BudgetItem, counted: Bool) -> some View {
        let amountText = Money.payment(item.amount)
        let amountColor = item.amount < 0 ? Theme.good : Theme.ink

        return Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.merchant)
                        .font(.body.weight(.medium))
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(amountText)
                        .font(.body.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(amountColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .allowsTightening(true)
                    Text("\(DayText.short(item.date)) · \(item.category) · \(item.source)")
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    FlowLayout(horizontalSpacing: 6, verticalSpacing: 4) {
                        QuietTag("Pending", tone: .accent)
                        if !counted {
                            QuietTag("Not spending", tone: .neutral)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.merchant)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(amountText)
                            .font(.subheadline.weight(.medium))
                            .monospacedDigit()
                            .foregroundStyle(amountColor)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    HStack(alignment: .center, spacing: 6) {
                        Text("\(DayText.short(item.date)) · \(item.category) · \(item.source)")
                            .font(.caption)
                            .foregroundStyle(Theme.muted)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        QuietTag("Pending", tone: .accent)
                        if !counted {
                            QuietTag("Not spending", tone: .neutral)
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.merchant), \(FinanceFormat.paymentAccessibility(item.amount)), pending, \(DayText.short(item.date)), \(item.category), \(item.source)")
    }

    // MARK: - Debts & Good to know

    private func debtsSection(screen: NowScreenModel) -> some View {
        FinanceCard {
            VStack(alignment: .leading, spacing: 12) {
                if !screen.debts.isEmpty {
                    HStack(alignment: .center, spacing: 8) {
                        SectionLabel("Debts")
                        Spacer(minLength: 8)
                        Button {
                            session.activeSheet = .debtPayoff
                        } label: {
                            Text("Payoff calculator")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.accent)
                        }
                        .buttonStyle(.plain)
                    }

                    MetricMoneyText(amount: screen.totalDebt, color: Theme.bad)

                    HairlineDivider()

                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(screen.debts.enumerated()), id: \.offset) { index, debt in
                            if index > 0 {
                                HairlineDivider()
                                    .padding(.vertical, 10)
                            }
                            debtRow(debt)
                        }
                    }
                }

                if !screen.notes.isEmpty {
                    if !screen.debts.isEmpty {
                        HairlineDivider()
                    }
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showGoodToKnow.toggle()
                        }
                    } label: {
                        HStack {
                            SectionLabel("Good to know (\(screen.notes.count))")
                            Spacer()
                            Image(systemName: showGoodToKnow ? "chevron.up" : "chevron.down")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.muted)
                        }
                        .frame(minHeight: 32)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if showGoodToKnow {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(screen.notes.enumerated()), id: \.offset) { _, note in
                                HStack(alignment: .top, spacing: 8) {
                                    Circle()
                                        .fill(Theme.muted)
                                        .frame(width: 4, height: 4)
                                        .padding(.top, 7)
                                    Text(note)
                                        .font(.caption)
                                        .foregroundStyle(Theme.ink2)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func debtRow(_ debt: DebtEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    Text(debt.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(Money.yen(debt.balance))
                        .font(.body.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.bad)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .allowsTightening(true)
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(debt.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.ink)
                    Spacer(minLength: 8)
                    Text(Money.yen(debt.balance))
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.bad)
                }
            }

            if let limit = debt.limit, limit > 0 {
                let ratio = min(1.0, max(0.0, Double(debt.balance) / Double(limit)))
                let pct = Int((ratio * 100).rounded())
                ProgressMeter(ratio: ratio, tint: Theme.bad, height: 5)

                Text("\(pct)% of \(Money.yen(limit)) limit used")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let lines = debt.lines, !lines.isEmpty {
                Text(lines.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(debtAccessibilityLabel(debt))
    }

    private func debtAccessibilityLabel(_ debt: DebtEntry) -> String {
        var parts = [debt.name, FinanceFormat.yenAccessibility(debt.balance)]
        if let limit = debt.limit, limit > 0 {
            let pct = Int((Double(debt.balance) / Double(limit) * 100).rounded())
            parts.append("\(pct) percent of \(FinanceFormat.yenAccessibility(limit)) limit")
        }
        if let lines = debt.lines, !lines.isEmpty {
            parts.append(lines.joined(separator: ", "))
        }
        return parts.joined(separator: ", ")
    }

    // MARK: - Subscriptions summary (Running vs Stopped & Cancelled)

    private func subscriptionsSection(screen: NowScreenModel) -> some View {
        let summary = screen.subscriptionSummary
        return FinanceCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel("Subscriptions")
                Group {
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 2) {
                            MetricMoneyText(amount: summary.runningMonthlyTotal, color: Theme.ink)
                            Text("per month · \(summary.runningCount) running")
                                .font(.footnote)
                                .foregroundStyle(Theme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            MetricMoneyText(amount: summary.runningMonthlyTotal, color: Theme.ink)
                            Text("per month")
                                .font(.footnote)
                                .foregroundStyle(Theme.muted)
                        }
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(FinanceFormat.yenAccessibility(summary.runningMonthlyTotal)) per month, \(summary.runningCount) running")

                FlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                    Text("\(summary.runningCount) running · \(Money.yen(summary.runningAnnualTotal))/yr")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(Theme.muted)
                    if summary.monthlySavings > 0 {
                        QuietTag("Saves \(Money.yen(summary.monthlySavings))/mo", tone: .good)
                    }
                }

                if !summary.running.isEmpty {
                    HairlineDivider()

                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(summary.running.enumerated()), id: \.element.id) { index, item in
                            if index > 0 {
                                HairlineDivider()
                                    .padding(.vertical, 10)
                            }
                            subscriptionRow(item)
                        }
                    }
                }

                if !summary.stopped.isEmpty {
                    HairlineDivider()
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showStoppedSubs.toggle()
                        }
                    } label: {
                        HStack {
                            Text(showStoppedSubs
                                 ? "Hide stopped and cancelled"
                                 : "Show stopped and cancelled (\(summary.stoppedCount))")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Theme.accent)
                            Spacer()
                            Image(systemName: showStoppedSubs ? "chevron.up" : "chevron.down")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.accent)
                        }
                        .frame(minHeight: 36)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if showStoppedSubs {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(summary.stopped.enumerated()), id: \.element.id) { index, item in
                                if index > 0 {
                                    HairlineDivider()
                                        .padding(.vertical, 10)
                                }
                                subscriptionRow(item)
                                    .opacity(0.65)
                            }
                        }
                    }
                }
            }
        }
    }

    private func subscriptionRow(_ item: SubscriptionItem) -> some View {
        let sub = item.entry
        return Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    Text(sub.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(Money.yen(sub.monthly))
                        .font(.body.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .allowsTightening(true)
                    if let via = sub.via, !via.isEmpty {
                        Text(via)
                            .font(.caption)
                            .foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let status = item.displayStatus {
                        QuietTag(status, tone: QuietTag.Tone(statusTone: item.tone))
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(sub.name)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Theme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Text(Money.yen(sub.monthly))
                            .font(.subheadline.weight(.medium))
                            .monospacedDigit()
                            .foregroundStyle(Theme.ink)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    HStack(alignment: .center, spacing: 6) {
                        if let via = sub.via, !via.isEmpty {
                            Text(via)
                                .font(.caption)
                                .foregroundStyle(Theme.muted)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 6)
                        if let status = item.displayStatus {
                            QuietTag(status, tone: QuietTag.Tone(statusTone: item.tone))
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(sub.name), \(FinanceFormat.yenAccessibility(sub.monthly)) per month\(sub.via.map { ", via \($0)" } ?? "")\(item.displayStatus.map { ", \($0)" } ?? "")")
    }
}

// MARK: - Payday hero card

struct PaydayHeroCard: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let payday: PaydayView
    let breakdown: PaydayBreakdown?
    let spent: Int?
    let lastPayday: String?
    let pendingCount: Int

    var body: some View {
        FinanceCard {
            VStack(alignment: .leading, spacing: 14) {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel("Until payday")
                        QuietTag(FinanceFormat.daysLabel(payday.daysToPayday), tone: .accent)
                    }
                } else {
                    HStack(alignment: .center, spacing: 8) {
                        SectionLabel("Until payday")
                        Spacer(minLength: 8)
                        QuietTag(FinanceFormat.daysLabel(payday.daysToPayday), tone: .accent)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    HeroMoneyText(
                        amount: payday.left,
                        color: payday.left < 0 ? Theme.bad : Theme.ink
                    )
                    Text("To \(DayText.long(payday.next.date)) · left after scheduled bills")
                        .font(.footnote)
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                SplitBar(bills: payday.outSum, left: payday.left, borrowed: payday.borrowedSum)

                HairlineDivider()

                VStack(alignment: .leading, spacing: 10) {
                    LedgerRow(
                        title: "Money in",
                        detail: payday.ins.map { "\($0.item) \(Money.yen(-$0.amount))" }.joined(separator: " · "),
                        value: Money.signed(payday.inSum),
                        accessibilityValue: FinanceFormat.yenAccessibility(payday.inSum, signed: true),
                        valueColor: Theme.good
                    )

                    if let firstOut = payday.outs.first, let lastOut = payday.outs.last {
                        let billDetail: String = {
                            if let b = breakdown, b.paidBillsCount > 0 || b.remainingBillsCount > 0 {
                                var parts: [String] = []
                                if b.paidBillsCount > 0 {
                                    parts.append("\(b.paidBillsCount) paid \(Money.yen(b.paidBillsSum))")
                                }
                                if b.remainingBillsCount > 0 {
                                    parts.append("\(b.remainingBillsCount) left \(Money.yen(b.remainingBillsSum))")
                                }
                                return parts.joined(separator: " · ")
                            }
                            let billWord = payday.outs.count == 1 ? "payment" : "payments"
                            let span = firstOut.date == lastOut.date
                                ? DayText.short(firstOut.date)
                                : "\(DayText.short(firstOut.date)) to \(DayText.short(lastOut.date))"
                            return "\(payday.outs.count) \(billWord), \(span)"
                        }()
                        LedgerRow(
                            title: "Bills until payday",
                            detail: billDetail,
                            value: Money.signed(-payday.outSum),
                            accessibilityValue: FinanceFormat.yenAccessibility(-payday.outSum, signed: true),
                            valueColor: Theme.ink
                        )
                    }

                    HairlineDivider()

                    LedgerRow(
                        title: "Left for everything else",
                        detail: nil,
                        value: Money.yen(payday.left),
                        accessibilityValue: FinanceFormat.yenAccessibility(payday.left),
                        valueColor: payday.left < 0 ? Theme.bad : Theme.ink,
                        emphasized: true
                    )

                    if payday.borrowedSum > 0 {
                        LedgerRow(
                            title: "Borrowing planned",
                            detail: payday.borrowed.map {
                                "\(String($0.item.split(separator: ":").first ?? Substring($0.item))) \(Money.yen(-$0.amount))"
                            }.joined(separator: " · "),
                            value: Money.signed(payday.borrowedSum),
                            accessibilityValue: FinanceFormat.yenAccessibility(payday.borrowedSum, signed: true),
                            valueColor: Theme.bad
                        )
                        LedgerRow(
                            title: "Left if borrowed",
                            detail: nil,
                            value: Money.yen(payday.leftIfBorrowed),
                            accessibilityValue: FinanceFormat.yenAccessibility(payday.leftIfBorrowed),
                            valueColor: payday.leftIfBorrowed < 0 ? Theme.bad : Theme.ink,
                            emphasized: true
                        )
                    }

                    if let breakdown, let lastPayday {
                        HairlineDivider()
                        LedgerRow(
                            title: "Day-to-day since payday",
                            detail: "Since \(DayText.short(lastPayday)), excluding rent and fixed bills",
                            value: Money.yen(breakdown.dayToDaySpentSincePayday),
                            accessibilityValue: FinanceFormat.yenAccessibility(breakdown.dayToDaySpentSincePayday),
                            valueColor: Theme.ink,
                            tag: pendingCount > 0 ? ("\(pendingCount) pending", .accent) : nil
                        )
                        LedgerRow(
                            title: "Estimated remaining",
                            detail: "After day-to-day spending since \(DayText.short(lastPayday))",
                            value: Money.yen(breakdown.estimatedRemainingDiscretionary),
                            accessibilityValue: FinanceFormat.yenAccessibility(breakdown.estimatedRemainingDiscretionary),
                            valueColor: breakdown.estimatedRemainingDiscretionary < 0 ? Theme.bad : Theme.good,
                            emphasized: true,
                            tag: ("Estimate", .neutral)
                        )
                    } else if let spent, let lastPayday {
                        HairlineDivider()
                        LedgerRow(
                            title: "Spent since payday",
                            detail: "Since \(DayText.short(lastPayday)), statements and bank emails",
                            value: Money.yen(spent),
                            accessibilityValue: FinanceFormat.yenAccessibility(spent),
                            valueColor: Theme.ink,
                            tag: pendingCount > 0 ? ("\(pendingCount) pending", .accent) : nil
                        )
                    }
                }
            }
        }
    }
}

struct SplitBar: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let bills: Int
    let left: Int
    let borrowed: Int

    private struct Part: Identifiable {
        let id: String
        let amount: Int
        let color: Color
    }

    private var parts: [Part] {
        var result: [Part] = []
        if bills > 0 {
            result.append(Part(id: "Bills", amount: bills, color: Theme.ink2))
        }
        if left > 0 {
            result.append(Part(id: "Left", amount: left, color: Theme.good))
        } else if left < 0 {
            result.append(Part(id: "Short", amount: abs(left), color: Theme.bad))
        }
        if borrowed > 0 {
            result.append(Part(id: "Borrowed", amount: borrowed, color: Theme.bad))
        }
        return result
    }

    var body: some View {
        let activeParts = parts
        let total = max(1, activeParts.map(\.amount).reduce(0, +))

        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geo in
                let gap: CGFloat = activeParts.count > 1 ? 2 : 0
                let available = max(0, geo.size.width - gap * CGFloat(max(0, activeParts.count - 1)))
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.track)
                    if !activeParts.isEmpty {
                        HStack(spacing: gap) {
                            ForEach(activeParts) { part in
                                Capsule()
                                    .fill(part.color)
                                    .frame(width: max(6, available * CGFloat(part.amount) / CGFloat(total)))
                            }
                        }
                    }
                }
            }
            .frame(height: 10)
            .accessibilityHidden(true)

            FlowLayout(horizontalSpacing: 14, verticalSpacing: 6) {
                ForEach(activeParts) { part in
                    HStack(spacing: 5) {
                        Circle()
                            .fill(part.color)
                            .frame(width: 8, height: 8)
                            .accessibilityHidden(true)
                        Text("\(part.id) \(Money.yen(part.amount))")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(Theme.muted)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                            .fixedSize(horizontal: !dynamicTypeSize.isAccessibilitySize, vertical: true)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(part.id), \(FinanceFormat.yenAccessibility(part.amount))")
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct LedgerRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let title: String
    let detail: String?
    let value: String
    let accessibilityValue: String
    var valueColor: Color = Theme.ink
    var emphasized: Bool = false
    var tag: (String, QuietTag.Tone)? = nil

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(emphasized ? .body.weight(.semibold) : .body)
                        .foregroundStyle(emphasized ? Theme.ink : Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(value)
                        .font(emphasized ? .body.weight(.semibold) : .body.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(valueColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .allowsTightening(true)
                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let tag {
                        QuietTag(tag.0, tone: tag.1)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(title)
                            .font(emphasized ? .subheadline.weight(.semibold) : .subheadline)
                            .foregroundStyle(emphasized ? Theme.ink : Theme.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Text(value)
                            .font(emphasized ? .subheadline.weight(.semibold) : .subheadline.weight(.medium))
                            .monospacedDigit()
                            .foregroundStyle(valueColor)
                            .multilineTextAlignment(.trailing)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let tag {
                        QuietTag(tag.0, tone: tag.1)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(combinedAccessibilityLabel)
    }

    private var combinedAccessibilityLabel: String {
        var segments = [title, accessibilityValue]
        if let detail, !detail.isEmpty {
            segments.append(detail)
        }
        if let tag {
            segments.append(tag.0)
        }
        return segments.joined(separator: ", ")
    }
}

// MARK: - Coming up day row

struct ComingUpDayRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let day: NowScreenModel.TimelineDay
    let phoneCheckedBillKeys: Set<String>
    let onSelectEntry: (TimelineEntry) -> Void

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(day.label.map { "\($0.uppercased()) · \(DayText.shortMonth(day.date))" } ?? FinanceFormat.dayHeader(day.date))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(dateColor)
                            .fixedSize(horizontal: false, vertical: true)
                        if day.isToday {
                            QuietTag("Today", tone: .accent)
                        }
                    }
                    entriesContent
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .top, spacing: 14) {
                    VStack(spacing: 1) {
                        if let label = day.label {
                            Text(label.uppercased())
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Theme.muted)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                            Text(DayText.shortMonth(day.date))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(dateColor)
                        } else {
                            Text(DayText.weekday(day.date))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(day.isToday ? Theme.accent : Theme.muted)
                            Text(DayText.dayOfMonth(day.date))
                                .font(.title3.weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(dateColor)
                        }
                    }
                    .frame(width: 46)
                    .padding(.vertical, 2)
                    .background(day.isToday ? Theme.accentWash : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 8) {
                        if day.isToday {
                            HStack(spacing: 6) {
                                QuietTag("Today", tone: .accent)
                                Text(DayText.long(day.date))
                                    .font(.caption)
                                    .foregroundStyle(Theme.muted)
                                    .lineLimit(1)
                            }
                        }
                        entriesContent
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, day.isNextPayday ? 10 : 0)
        .padding(.vertical, day.isNextPayday ? 10 : 2)
        .background(
            day.isNextPayday ? Theme.goodWash : Color.clear,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .opacity(day.isPast && !day.isToday ? 0.55 : 1.0)
    }

    private var dateColor: Color {
        if day.isToday { return Theme.accent }
        if day.isNextPayday { return Theme.good }
        return Theme.ink
    }

    @ViewBuilder
    private var entriesContent: some View {
        if day.entries.isEmpty {
            Text("Nothing scheduled")
                .font(.subheadline)
                .foregroundStyle(Theme.muted)
                .accessibilityLabel("Today, \(DayText.long(day.date)), nothing scheduled")
        } else {
            ForEach(day.entries) { row in
                Button {
                    onSelectEntry(row.value)
                } label: {
                    timelineEntryRow(row.value)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func timelineEntryRow(_ entry: TimelineEntry) -> some View {
        let isEvent = entry.event == true
        let moneyIn = entry.amount < 0 && entry.borrowed != true
        let isBorrowed = entry.borrowed == true
        let amountText = (isEvent || entry.amount == 0) ? "" : Money.payment(entry.amount)
        let amountColor: Color = {
            if isBorrowed { return Theme.bad }
            if moneyIn { return Theme.good }
            return Theme.ink
        }()

        let isPhoneChecked = phoneCheckedBillKeys.contains(BillCheckoff.key(for: entry))
        let tags: [(String, QuietTag.Tone)] = {
            var list: [(String, QuietTag.Tone)] = []
            if isEvent { list.append(("Event", .accent)) }
            if entry.payday == true { list.append(("Payday", .good)) }
            if entry.done == true {
                if isPhoneChecked {
                    list.append(("Paid (phone)", .accent))
                } else {
                    let doneLabel = entry.amount < 0 ? "Received" : (entry.amount > 0 ? "Paid" : "Done")
                    list.append((doneLabel, .neutral))
                }
            }
            if entry.borrowed == true { list.append(("Borrowed", .bad)) }
            if entry.estimate == true { list.append(("Estimate", .neutral)) }
            return list
        }()

        return Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.item)
                        .font(.body.weight(.medium))
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    if !amountText.isEmpty {
                        Text(amountText)
                            .font(.body.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(amountColor)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                            .allowsTightening(true)
                    }
                    if let note = entry.note, !note.isEmpty {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !tags.isEmpty {
                        FlowLayout(horizontalSpacing: 6, verticalSpacing: 4) {
                            ForEach(Array(tags.enumerated()), id: \.offset) { _, tag in
                                QuietTag(tag.0, tone: tag.1)
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(entry.item)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Theme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        if !amountText.isEmpty {
                            Text(amountText)
                                .font(.subheadline.weight(.medium))
                                .monospacedDigit()
                                .foregroundStyle(amountColor)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                    if let note = entry.note, !note.isEmpty {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !tags.isEmpty {
                        FlowLayout(horizontalSpacing: 6, verticalSpacing: 4) {
                            ForEach(Array(tags.enumerated()), id: \.offset) { _, tag in
                                QuietTag(tag.0, tone: tag.1)
                            }
                        }
                        .padding(.top, 2)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entryAccessibilityLabel(entry, tags: tags.map(\.0)))
    }

    private func entryAccessibilityLabel(_ entry: TimelineEntry, tags: [String]) -> String {
        var parts = [DayText.long(day.date), entry.item]
        if entry.event != true && entry.amount != 0 {
            parts.append(FinanceFormat.paymentAccessibility(entry.amount))
        }
        parts.append(contentsOf: tags)
        if let note = entry.note, !note.isEmpty {
            parts.append(note)
        }
        return parts.joined(separator: ", ")
    }
}
