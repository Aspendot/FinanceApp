import FinanceCore
import SwiftUI

struct NowView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var session: AppSession
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.privacyMasked) private var privacyMasked

    @State private var inspectedPayment: InspectedPayment?
    @State private var selectedBill: TimelineEntry?
    @State private var showingCashBreakdown = false
    @State private var showAfterPayday = false
    @State private var showStoppedSubs = false
    @State private var showGoodToKnow = false
    @State private var screenCache = ScreenModelCache<String, NowScreenModel>()

    private var activeData: FinanceData? {
        session.resolvedData(from: model)
    }

    private var screenCacheKey: String {
        guard let data = activeData else { return "" }
        return "\(data.id.uuidString)|\(session.today)"
    }

    private func resolvedScreen(for data: FinanceData) -> NowScreenModel {
        screenCache.get(for: screenCacheKey) {
            NowScreenModel(data: data, today: session.today)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { scrollProxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: Theme.cardSpacing) {
                        if let data = activeData {
                            let screen = resolvedScreen(for: data)
                            paydaySection(screen: screen, scrollProxy: scrollProxy)
                            if screen.reviewQueueCount > 0 {
                                reviewInboxBanner(count: screen.reviewQueueCount)
                            }
                            if !screen.alerts.isEmpty {
                                alertsSection(screen: screen, scrollProxy: scrollProxy)
                            }
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
                    .verticalScrollPage()
                }
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            }
            .background(Theme.page)
            .navigationTitle("Now")
            .sensoryFeedback(.selection, trigger: session.privacyMasked)
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

                        Menu {
                            Button {
                                session.activeSheet = .quickAdd
                            } label: {
                                Label("Add payment", systemImage: "plus.circle")
                            }
                            Button {
                                session.activeSheet = .scanReceipt
                            } label: {
                                Label("Scan receipt or slip", systemImage: "doc.text.viewfinder")
                            }
                            Button {
                                session.activeSheet = .addReminder(defaultTitle: nil, defaultDate: nil, defaultNote: nil)
                            } label: {
                                Label("Add bill or reminder", systemImage: "calendar.badge.plus")
                            }
                        } label: {
                            Image(systemName: "plus")
                                .font(.body.weight(.semibold))
                        }
                        .accessibilityLabel("Add payment, receipt, or reminder")
                    }
                }
            }
            .refreshable {
                guard !session.isDemo else { return }
                await model.syncGmail()
            }
            .sheet(item: $inspectedPayment) { inspected in
                if let data = activeData {
                    PaymentDetailSheet(item: inspected.item, data: data)
                }
            }
            .sheet(isPresented: $showingCashBreakdown) {
                if let data = activeData, let liveCash = data.liveCash {
                    BankCashBreakdownSheet(
                        liveCash: liveCash,
                        payday: data.payday,
                        onOpenRunway: {
                            showingCashBreakdown = false
                            session.activeSheet = .runway
                        }
                    )
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
                    let matchingReminder = model.localModifications.customReminders.first {
                        BillCheckoff.key(for: $0.asTimelineEntry()) == BillCheckoff.key(for: bill)
                    }
                    if bill.event != true && bill.cardBilled != true && bill.amount > 0 && (bill.done != true || isPhoneChecked) {
                        Button(isPhoneChecked ? "Mark unpaid" : "Mark paid on phone") {
                            let target = bill
                            selectedBill = nil
                            guard !session.isDemo else { return }
                            Task { await model.toggleBillCheckoff(for: target) }
                        }
                    }
                    if bill.event != true {
                        Button("Search past payments") {
                            let query = bill.item.split(separator: " ").first.map(String.init) ?? bill.item
                            selectedBill = nil
                            session.openPayments(month: nil, category: nil, query: query)
                        }
                    }
                    if let reminder = matchingReminder {
                        Button("Delete reminder", role: .destructive) {
                            selectedBill = nil
                            guard !session.isDemo else { return }
                            Task { try? await model.removeCustomReminder(id: reminder.id) }
                        }
                    }
                    Button("Cancel", role: .cancel) {
                        selectedBill = nil
                    }
                }
            } message: {
                if let bill = selectedBill {
                    let shownAmount = bill.cardBilled == true ? (bill.billedAmount ?? bill.amount) : bill.amount
                    let amt = shownAmount == 0 ? "" : MaskedMoney.payment(shownAmount, masked: privacyMasked) + " · "
                    let noteText = bill.note.map { "\n\(MaskedMoney.redactText($0, masked: privacyMasked))" } ?? ""
                    Text(amt + DayText.long(bill.date) + noteText)
                }
            }
        }
    }

    // MARK: - Smart alerts

    private func alertsSection(screen: NowScreenModel, scrollProxy: ScrollViewProxy) -> some View {
        let hasUrgent = screen.alerts.contains { $0.severity == .urgent }
        return FinanceCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 8) {
                    SectionLabel(
                        "Attention",
                        symbol: hasUrgent ? "exclamationmark.circle.fill" : "bell.badge.fill",
                        color: hasUrgent ? Theme.bad : Theme.warnText
                    )
                    Spacer(minLength: 8)
                    QuietTag("\(screen.alerts.count)", tone: hasUrgent ? .bad : .warn)
                }

                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(screen.alerts.prefix(4))) { alert in
                        alertRow(alert, scrollProxy: scrollProxy)
                    }
                }
            }
        }
    }

    private func alertRow(_ alert: FinanceAlert, scrollProxy: ScrollViewProxy) -> some View {
        let accentColor: Color = {
            switch alert.severity {
            case .urgent: return Theme.bad
            case .warning: return Theme.warn
            case .info: return Color("LayerRent")
            }
        }()
        let tone: QuietTag.Tone = {
            switch alert.severity {
            case .urgent: return .bad
            case .warning: return .warn
            case .info: return .info
            }
        }()

        return HStack(alignment: .top, spacing: 10) {
            Capsule()
                .fill(accentColor)
                .frame(width: 3)
                .padding(.vertical, 2)
                .accessibilityHidden(true)

            Button {
                handleAlertAction(alert.action, scrollProxy: scrollProxy)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    if dynamicTypeSize.isAccessibilitySize {
                        QuietTag(alert.badge, tone: tone)
                        Text(MaskedMoney.redactText(alert.title, masked: privacyMasked))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            QuietTag(alert.badge, tone: tone)
                            Text(MaskedMoney.redactText(alert.title, masked: privacyMasked))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.ink)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Text(MaskedMoney.redactText(alert.detail, masked: privacyMasked))
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
                    .frame(width: Theme.minTouchTarget, height: Theme.minTouchTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss alert")
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            accentColor.opacity(0.06),
            in: RoundedRectangle(cornerRadius: Theme.innerRadius, style: .continuous)
        )
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

    // MARK: - Daily Review Inbox banner

    private func reviewInboxBanner(count: Int) -> some View {
        Button {
            session.activeSheet = .reviewInbox
        } label: {
            FinanceCard(padding: 14) {
                HStack(alignment: .center, spacing: 12) {
                    if !dynamicTypeSize.isAccessibilitySize {
                        IconMedallion(symbol: "tray.and.arrow.down.fill", tint: Theme.accent, size: 36)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("Review")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.ink)
                            QuietTag("\(count)", tone: .accent)
                        }
                        Text("Confirm pending notices and uncategorized items in 10 seconds")
                            .font(.caption)
                            .foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 6)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(TactileCardButtonStyle())
    }

    // MARK: - Until payday

    @ViewBuilder
    private func paydaySection(screen: NowScreenModel, scrollProxy: ScrollViewProxy) -> some View {
        if let payday = screen.payday {
            PaydayHeroCard(
                payday: payday,
                breakdown: screen.paydayBreakdown,
                liveCash: screen.liveCash,
                spent: screen.spentSincePayday,
                lastPayday: screen.lastPayday,
                pendingCount: screen.pendingSincePayday,
                onTapBankCash: {
                    if screen.liveCash != nil {
                        showingCashBreakdown = true
                    }
                },
                onTapBills: {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        scrollProxy.scrollTo("comingUp", anchor: .top)
                    }
                },
                onTapDayToDay: {
                    if let start = screen.lastPayday {
                        let cycleEnd = JST.addingDays(-1, to: payday.next.date) ?? session.today
                        let upperBound = max(start, cycleEnd)
                        session.openPayments(
                            layer: .dayToDay,
                            dateRange: start...upperBound,
                            dateRangeLabel: "Since \(DayText.short(start))"
                        )
                    } else {
                        session.openPayments(month: String(session.today.prefix(7)), layer: .dayToDay)
                    }
                },
                onTapRunway: {
                    session.activeSheet = .runway
                },
                onTogglePrivacy: {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        session.privacyMasked.toggle()
                    }
                }
            )
        } else {
            FinanceCard {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("Until payday", symbol: "calendar")
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
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 8) {
                    SectionLabel("Monthly targets", symbol: "target")
                    Spacer(minLength: 8)
                    Button {
                        session.activeSheet = .targets
                    } label: {
                        HStack(spacing: 4) {
                            Text("Full plan")
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

                VStack(alignment: .leading, spacing: 12) {
                    ForEach(preview) { row in
                        watchRow(
                            row,
                            currentMonth: data.planSummary.currentMonth,
                            pace: screen.activePeriodPace
                        )
                    }
                }
            }
        }
    }

    private func watchRow(_ row: PlanRow, currentMonth: String, pace: Double?) -> some View {
        let target = row.entry.target ?? 0
        let ratio = row.currentMonthProgress ?? 0
        let pct = Int((ratio * 100).rounded())
        let tint: Color = row.isOverCapCurrentMonth
            ? Theme.bad
            : (row.isNearCapCurrentMonth ? Theme.warn : Theme.good)

        return Button {
            session.activeSheet = .categoryDetail(name: row.entry.category, periodID: currentMonth)
        } label: {
            HStack(alignment: .center, spacing: 12) {
                if !dynamicTypeSize.isAccessibilitySize {
                    CategoryBadge(category: row.entry.category, size: 34)
                }

                VStack(alignment: .leading, spacing: 6) {
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.entry.category)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.ink)
                            Text("\(MaskedMoney.yen(row.currentMonthSpent, masked: privacyMasked)) / \(MaskedMoney.yen(target, masked: privacyMasked)) · \(pct)%")
                                .font(.caption.weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(row.isOverCapCurrentMonth ? Theme.bad : Theme.ink2)
                        }
                    } else {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(row.entry.category)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.ink)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            HStack(alignment: .firstTextBaseline, spacing: 3) {
                                Text(MaskedMoney.yen(row.currentMonthSpent, masked: privacyMasked))
                                    .font(.subheadline.weight(.semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(row.isOverCapCurrentMonth ? Theme.bad : Theme.ink)
                                Text("/ \(MaskedMoney.yen(target, masked: privacyMasked))")
                                    .font(.caption)
                                    .monospacedDigit()
                                    .foregroundStyle(Theme.muted)
                            }
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                    ProgressMeter(ratio: ratio, tint: tint, height: 6, paceRatio: pace)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Coming up timeline

    private func comingUpSection(screen: NowScreenModel) -> some View {
        let nextPaydayDate = screen.payday?.next.date
        let primaryDays: [NowScreenModel.TimelineDay]
        let afterPaydayDays: [NowScreenModel.TimelineDay]
        if let cutoff = nextPaydayDate {
            primaryDays = screen.timelineDays.filter { $0.date <= cutoff }
            afterPaydayDays = screen.timelineDays.filter { $0.date > cutoff }
        } else {
            primaryDays = screen.timelineDays
            afterPaydayDays = []
        }
        let visibleDays = showAfterPayday ? screen.timelineDays : primaryDays

        return FinanceCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 8) {
                    SectionLabel("Coming up", symbol: "calendar.badge.clock")
                    Spacer(minLength: 8)
                    Text("Tap a bill to update")
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                }

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(visibleDays.enumerated()), id: \.element.id) { index, day in
                        if day.showsMonthHeader {
                            HStack(spacing: 8) {
                                Text(DayText.monthUpper(day.monthKey))
                                    .font(.caption2.weight(.bold))
                                    .tracking(0.9)
                                    .foregroundStyle(Theme.muted)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Theme.well, in: Capsule())
                                HairlineDivider()
                            }
                            .padding(.top, index > 0 ? 16 : 0)
                            .padding(.bottom, 8)
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
                            todayCashBalance: day.isToday ? screen.todayCashBalance : nil,
                            onTapCashNow: {
                                if screen.liveCash != nil {
                                    showingCashBreakdown = true
                                }
                            },
                            onSelectEntry: { entry in
                                let isCustomReminder = model.localModifications.customReminders.contains {
                                    BillCheckoff.key(for: $0.asTimelineEntry()) == BillCheckoff.key(for: entry)
                                }
                                if entry.event != true || isCustomReminder {
                                    selectedBill = entry
                                }
                            }
                        )
                    }
                }

                if !afterPaydayDays.isEmpty, let cutoff = nextPaydayDate {
                    let afterItemsCount = afterPaydayDays.reduce(0) { $0 + $1.entries.count }
                    HairlineDivider()
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showAfterPayday.toggle()
                        }
                    } label: {
                        HStack {
                            Text(showAfterPayday
                                 ? "Hide after \(DayText.short(cutoff))"
                                 : "Show after \(DayText.short(cutoff)) (\(afterItemsCount) items)")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Theme.accent)
                            Spacer()
                            Image(systemName: showAfterPayday ? "chevron.up" : "chevron.down")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.accent)
                        }
                        .frame(minHeight: 36)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                if showAfterPayday, let afterNote = screen.afterNote, !afterNote.isEmpty {
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
                        .font(.caption2.weight(.bold))
                        .tracking(0.8)
                        .foregroundStyle(Theme.good)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                HStack(spacing: 8) {
                    HairlineDivider(color: Theme.good.opacity(0.45))
                    HStack(spacing: 4) {
                        Image(systemName: "sparkle")
                            .font(.system(size: 9, weight: .bold))
                        Text("PAYDAY · \(FinanceFormat.dayHeader(date))")
                            .font(.caption2.weight(.bold))
                            .tracking(0.8)
                    }
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
                        SectionLabel("Recent pending", symbol: "envelope.badge")
                        QuietTag("\(screen.recentPending.count) pending", tone: .accent)
                    }
                } else {
                    HStack(alignment: .center, spacing: 8) {
                        SectionLabel("Recent pending", symbol: "envelope.badge")
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
                        value: MaskedMoney.yen(screen.pendingSpendingTotal, masked: privacyMasked),
                        accessibilityValue: MaskedMoney.accessibility(screen.pendingSpendingTotal, masked: privacyMasked),
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
                            Spacer()
                            Image(systemName: "arrow.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.accent)
                                .accessibilityHidden(true)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Theme.accentWash, in: RoundedRectangle(cornerRadius: Theme.innerRadius, style: .continuous))
                        .frame(maxWidth: .infinity, minHeight: Theme.minTouchTarget, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func pendingPreviewRow(_ item: BudgetItem, counted: Bool) -> some View {
        let amountText = MaskedMoney.payment(item.amount, masked: privacyMasked)
        let amountColor = item.amount < 0 ? Theme.good : Theme.ink

        return Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.merchant)
                        .font(.body.weight(.semibold))
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
                HStack(alignment: .center, spacing: 12) {
                    CategoryBadge(category: item.category, size: 36)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(item.merchant)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.ink)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(amountText)
                                .font(.subheadline.weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(amountColor)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        HStack(alignment: .center, spacing: 6) {
                            Text("\(DayText.short(item.date)) · \(item.category)")
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
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.merchant), \(MaskedMoney.paymentAccessibility(item.amount, masked: privacyMasked)), pending, \(DayText.short(item.date)), \(item.category), \(item.source)")
    }

    // MARK: - Debts & Good to know

    private func debtsSection(screen: NowScreenModel) -> some View {
        FinanceCard {
            VStack(alignment: .leading, spacing: 14) {
                if !screen.debts.isEmpty {
                    HStack(alignment: .center, spacing: 8) {
                        SectionLabel("Debts", symbol: "percent", color: Theme.bad)
                        Spacer(minLength: 8)
                        Button {
                            session.activeSheet = .debtPayoff
                        } label: {
                            HStack(spacing: 4) {
                                Text("Payoff")
                                    .font(.caption.weight(.semibold))
                                Image(systemName: "slider.horizontal.3")
                                    .font(.caption2.weight(.semibold))
                            }
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Theme.accentWash, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }

                    MetricMoneyText(amount: screen.totalDebt, color: Theme.bad)

                    HairlineDivider()

                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(screen.debts.enumerated()), id: \.offset) { index, debt in
                            if index > 0 {
                                HairlineDivider()
                                    .padding(.vertical, 12)
                            }
                            Button {
                                session.activeSheet = .debtDetail(debt)
                            } label: {
                                debtRow(debt)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
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
                            SectionLabel("Good to know (\(screen.notes.count))", symbol: "note.text")
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
                                        .fill(Theme.accent)
                                        .frame(width: 5, height: 5)
                                        .padding(.top, 6)
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
        VStack(alignment: .leading, spacing: 7) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    Text(debt.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(MaskedMoney.yen(debt.balance, masked: privacyMasked))
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
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.ink)
                    Spacer(minLength: 8)
                    Text(MaskedMoney.yen(debt.balance, masked: privacyMasked))
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.bad)
                }
            }

            if let limit = debt.limit, limit > 0 {
                let ratio = min(1.0, max(0.0, Double(debt.balance) / Double(limit)))
                let pct = Int((ratio * 100).rounded())
                ProgressMeter(ratio: ratio, tint: Theme.bad, height: 6)

                HStack {
                    Text("\(pct)% of \(MaskedMoney.yen(limit, masked: privacyMasked)) limit used")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
            }

            if let lines = debt.lines, !lines.isEmpty {
                Text(MaskedMoney.redactText(lines.joined(separator: " · "), masked: privacyMasked))
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(debtAccessibilityLabel(debt))
    }

    private func debtAccessibilityLabel(_ debt: DebtEntry) -> String {
        var parts = [debt.name, MaskedMoney.accessibility(debt.balance, masked: privacyMasked)]
        if let limit = debt.limit, limit > 0 {
            let pct = Int((Double(debt.balance) / Double(limit) * 100).rounded())
            parts.append("\(pct) percent of \(MaskedMoney.accessibility(limit, masked: privacyMasked)) limit")
        }
        if let lines = debt.lines, !lines.isEmpty {
            parts.append(MaskedMoney.redactText(lines.joined(separator: ", "), masked: privacyMasked))
        }
        return parts.joined(separator: ", ")
    }

    // MARK: - Subscriptions summary (Running vs Stopped & Cancelled)

    private func subscriptionsSection(screen: NowScreenModel) -> some View {
        let summary = screen.subscriptionSummary
        return FinanceCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 8) {
                    SectionLabel("Subscriptions", symbol: "repeat")
                    Spacer(minLength: 8)
                    if summary.monthlySavings > 0 {
                        QuietTag("Saves \(MaskedMoney.yen(summary.monthlySavings, masked: privacyMasked))/mo", tone: .good)
                    }
                }

                Group {
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 2) {
                            MetricMoneyText(amount: summary.runningMonthlyTotal, color: Theme.ink)
                            Text("per month · \(summary.runningCount) running · \(MaskedMoney.yen(summary.runningAnnualTotal, masked: privacyMasked))/yr")
                                .font(.footnote)
                                .foregroundStyle(Theme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            MetricMoneyText(amount: summary.runningMonthlyTotal, color: Theme.ink)
                            Text("/mo")
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(Theme.muted)
                            Spacer(minLength: 8)
                            Text("\(summary.runningCount) active · \(MaskedMoney.yen(summary.runningAnnualTotal, masked: privacyMasked))/yr")
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(Theme.muted)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                        }
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(MaskedMoney.accessibility(summary.runningMonthlyTotal, masked: privacyMasked)) per month, \(summary.runningCount) running")

                if !summary.running.isEmpty {
                    HairlineDivider()

                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(summary.running.enumerated()), id: \.element.id) { index, item in
                            if index > 0 {
                                HairlineDivider()
                                    .padding(.vertical, 10)
                            }
                            Button {
                                session.activeSheet = .subscriptionDetail(item)
                            } label: {
                                subscriptionRow(item)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
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
                                Button {
                                    session.activeSheet = .subscriptionDetail(item)
                                } label: {
                                    subscriptionRow(item)
                                        .opacity(0.62)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
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
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(MaskedMoney.yen(sub.monthly, masked: privacyMasked))
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
                HStack(alignment: .center, spacing: 11) {
                    MonogramBadge(
                        text: sub.name,
                        tint: !item.isOff ? Color("LayerSubscriptions") : Theme.muted,
                        size: 32
                    )
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(sub.name)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Theme.ink)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            Text(MaskedMoney.yen(sub.monthly, masked: privacyMasked))
                                .font(.subheadline.weight(.semibold))
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
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(sub.name), \(MaskedMoney.accessibility(sub.monthly, masked: privacyMasked)) per month\(sub.via.map { ", via \($0)" } ?? "")\(item.displayStatus.map { ", \($0)" } ?? "")")
    }
}

// MARK: - Signature Midnight Forest Payday Hero Card

struct PaydayHeroCard: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.privacyMasked) private var privacyMasked

    let payday: PaydayView
    let breakdown: PaydayBreakdown?
    let liveCash: LiveCashSummary?
    let spent: Int?
    let lastPayday: String?
    let pendingCount: Int
    var onTapBankCash: () -> Void = {}
    var onTapBills: () -> Void = {}
    var onTapDayToDay: () -> Void = {}
    var onTapRunway: () -> Void = {}
    var onTogglePrivacy: () -> Void = {}

    private var heroLeft: Int {
        liveCash?.cashLeftUntilPayday ?? breakdown?.estimatedRemainingDiscretionary ?? payday.left
    }

    private var isHeroEstimate: Bool {
        liveCash?.isEstimate ?? true
    }

    private var heroSubtitle: String {
        let base = "To \(DayText.long(payday.next.date))"
        if let live = liveCash {
            if live.remainingInflowsSum > 0 {
                return "\(base) · bank cash + inflows − unpaid bills"
            }
            return "\(base) · bank cash after unpaid bills"
        }
        return "\(base) · est. after bills & spending"
    }

    private var cycleProgress: Double {
        let totalDays: Int = {
            if let last = lastPayday,
               let start = DayText.date(last),
               let end = DayText.date(payday.next.date),
               let span = Calendar(identifier: .gregorian).dateComponents([.day], from: start, to: end).day,
               span > 0
            {
                return span
            }
            return 30
        }()
        let elapsed = max(0, totalDays - payday.daysToPayday)
        return min(1.0, max(0.06, Double(elapsed) / Double(totalDays)))
    }

    private var billSummaryNote: String {
        if let live = liveCash {
            var parts: [String] = []
            parts.append("\(live.remainingBillsCount) left")
            if let b = breakdown, b.paidBillsCount > 0 {
                parts.append("\(b.paidBillsCount) paid")
            }
            if live.phoneCheckedBillsSum > 0 {
                parts.append("incl. phone-checked")
            }
            return parts.joined(separator: " · ")
        }
        if let b = breakdown, b.paidBillsCount > 0 || b.remainingBillsCount > 0 {
            var parts: [String] = []
            if b.paidBillsCount > 0 { parts.append("\(b.paidBillsCount) paid") }
            if b.remainingBillsCount > 0 { parts.append("\(b.remainingBillsCount) left · \(MaskedMoney.yen(b.remainingBillsSum, masked: privacyMasked))") }
            return parts.joined(separator: " · ")
        }
        let count = payday.outs.count
        return "\(count) \(count == 1 ? "bill" : "bills")"
    }

    private var openCreditSources: [ComingUpCreditSource] {
        if let live = liveCash, !live.creditSources.isEmpty {
            return live.creditSources
        }
        return payday.borrowed
            .filter { $0.done != true && $0.amount < 0 }
            .map { ComingUpCreditSource(item: $0.item, amount: -$0.amount) }
    }

    private var openBorrowedTotal: Int {
        liveCash?.openBorrowedSum ?? payday.borrowedSum
    }

    private var totalWithCredit: Int {
        liveCash?.cashLeftIfBorrowed ?? (heroLeft + openBorrowedTotal)
    }

    var body: some View {
        HeroVaultCard(accentTint: heroLeft < 0 ? Theme.heroCoral : Theme.heroGlow) {
            VStack(alignment: .leading, spacing: 16) {
                // Header + Sculpted Cycle Ring (long-press hero balance toggles train privacy mask)
                Group {
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionLabel("Until payday", symbol: "calendar", color: Theme.heroInkMuted)
                            HeroMoneyText(
                                amount: heroLeft,
                                color: heroLeft < 0 ? Theme.heroCoral : Theme.heroInk
                            )
                            if openBorrowedTotal > 0 {
                                Text("With credit: \(MaskedMoney.yen(totalWithCredit, masked: privacyMasked))")
                                    .font(.footnote.weight(.semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(Theme.heroAccent)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            FlowLayout(horizontalSpacing: 6, verticalSpacing: 4) {
                                QuietTag(FinanceFormat.daysLabel(payday.daysToPayday), tone: .hero)
                                if isHeroEstimate {
                                    QuietTag("Estimate", tone: .hero)
                                }
                            }
                            Text(heroSubtitle)
                                .font(.footnote)
                                .foregroundStyle(Theme.heroInkMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 8) {
                                    SectionLabel("Until payday", symbol: "calendar", color: Theme.heroInkMuted)
                                    if isHeroEstimate {
                                        QuietTag("Estimate", tone: .hero)
                                    }
                                }
                                HeroMoneyText(
                                    amount: heroLeft,
                                    color: heroLeft < 0 ? Theme.heroCoral : Theme.heroInk
                                )
                                if openBorrowedTotal > 0 {
                                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                                        Text("With credit:")
                                            .font(.footnote)
                                            .foregroundStyle(Theme.heroInkMuted)
                                        Text(MaskedMoney.yen(totalWithCredit, masked: privacyMasked))
                                            .font(.footnote.weight(.bold))
                                            .monospacedDigit()
                                            .foregroundStyle(Theme.heroAccent)
                                    }
                                    .fixedSize(horizontal: false, vertical: true)
                                }
                                Text(heroSubtitle)
                                    .font(.footnote)
                                    .foregroundStyle(Theme.heroInkMuted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 8)
                            CycleRingView(
                                progress: cycleProgress,
                                valueText: payday.daysToPayday == 0 ? "0" : "\(payday.daysToPayday)",
                                unitText: payday.daysToPayday == 1 ? "day" : "days",
                                fillColor: heroLeft < 0 ? Theme.heroCoral : Theme.heroAccent,
                                size: 62,
                                lineWidth: 4.5
                            )
                        }
                    }
                }
                .contentShape(Rectangle())
                .onLongPressGesture {
                    onTogglePrivacy()
                }

                // Sculpted translucent allocation bar
                SplitBar(
                    bills: liveCash?.unsettledBillsSum ?? payday.outSum,
                    left: heroLeft,
                    borrowed: liveCash != nil ? 0 : payday.borrowedSum,
                    onHeroSurface: true
                )

                // Frosted 2-up key tiles: Cash in banks (tappable breakdown) & Bills left (jumps to Coming up)
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(spacing: 8) {
                        Button(action: onTapBankCash) { cashOrMoneyInTile(fillHeight: false) }
                            .buttonStyle(TactileCardButtonStyle())
                            .disabled(liveCash == nil)
                        Button(action: onTapBills) { billsTile(fillHeight: false) }
                            .buttonStyle(TactileCardButtonStyle())
                    }
                } else {
                    Grid(alignment: .topLeading, horizontalSpacing: 10, verticalSpacing: 8) {
                        GridRow {
                            Button(action: onTapBankCash) { cashOrMoneyInTile(fillHeight: true) }
                                .buttonStyle(TactileCardButtonStyle())
                                .disabled(liveCash == nil)
                            Button(action: onTapBills) { billsTile(fillHeight: true) }
                                .buttonStyle(TactileCardButtonStyle())
                        }
                    }
                }

                if openBorrowedTotal > 0 {
                    let creditBreakdown: String = {
                        if openCreditSources.isEmpty {
                            return "If used: \(MaskedMoney.yen(totalWithCredit, masked: privacyMasked))"
                        }
                        return openCreditSources
                            .map { "\($0.shortLabel) \(MaskedMoney.yen($0.amount, masked: privacyMasked))" }
                            .joined(separator: " + ")
                    }()
                    FrostedMetricTile {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Optional credit room")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(Theme.heroInkMuted)
                                Text(creditBreakdown)
                                    .font(.caption2)
                                    .monospacedDigit()
                                    .foregroundStyle(Theme.heroInkMuted.opacity(0.85))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 8)
                            Text(MaskedMoney.signed(openBorrowedTotal, masked: privacyMasked))
                                .font(.subheadline.weight(.bold))
                                .monospacedDigit()
                                .foregroundStyle(Theme.heroCoral)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                }

                // Tappable Day-to-day since payday strip -> jumps directly into filtered Payments
                if let breakdown, let lastPayday {
                    Button(action: onTapDayToDay) {
                        FrostedMetricTile {
                            if dynamicTypeSize.isAccessibilitySize {
                                VStack(alignment: .leading, spacing: 8) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Day-to-day since \(DayText.short(lastPayday))")
                                            .font(.caption)
                                            .foregroundStyle(Theme.heroInkMuted)
                                        Text(MaskedMoney.yen(breakdown.dayToDaySpentSincePayday, masked: privacyMasked))
                                            .font(.subheadline.weight(.bold))
                                            .monospacedDigit()
                                            .foregroundStyle(Theme.heroInk)
                                    }
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Cycle budget after bills")
                                            .font(.caption)
                                            .foregroundStyle(Theme.heroInkMuted)
                                        Text(MaskedMoney.yen(payday.left, masked: privacyMasked))
                                            .font(.subheadline.weight(.bold))
                                            .monospacedDigit()
                                            .foregroundStyle(payday.left < 0 ? Theme.heroCoral : Theme.heroAccent)
                                    }
                                    if pendingCount > 0 {
                                        QuietTag("\(pendingCount) pending", tone: .hero)
                                    }
                                }
                            } else {
                                HStack(alignment: .center, spacing: 10) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 4) {
                                            Text("Day-to-day since \(DayText.short(lastPayday))")
                                                .font(.caption2.weight(.medium))
                                                .foregroundStyle(Theme.heroInkMuted)
                                            Image(systemName: "chevron.right")
                                                .font(.system(size: 8.5, weight: .bold))
                                                .foregroundStyle(Theme.heroInkMuted.opacity(0.75))
                                        }
                                        HStack(spacing: 6) {
                                            Text(MaskedMoney.yen(breakdown.dayToDaySpentSincePayday, masked: privacyMasked))
                                                .font(.subheadline.weight(.bold))
                                                .monospacedDigit()
                                                .foregroundStyle(Theme.heroInk)
                                            if pendingCount > 0 {
                                                Text("· \(pendingCount) pending")
                                                    .font(.caption2)
                                                    .foregroundStyle(Theme.heroAccent)
                                            }
                                        }
                                    }
                                    Spacer(minLength: 8)
                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text("Cycle budget")
                                            .font(.caption2.weight(.medium))
                                            .foregroundStyle(Theme.heroInkMuted)
                                        Text(MaskedMoney.yen(payday.left, masked: privacyMasked))
                                            .font(.subheadline.weight(.bold))
                                            .monospacedDigit()
                                            .foregroundStyle(payday.left < 0 ? Theme.heroCoral : Theme.heroAccent)
                                    }
                                }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                } else if let spent, let lastPayday {
                    Button(action: onTapDayToDay) {
                        FrostedMetricTile {
                            HStack(alignment: .firstTextBaseline) {
                                Text("Spent since \(DayText.short(lastPayday))")
                                    .font(.caption)
                                    .foregroundStyle(Theme.heroInkMuted)
                                Spacer()
                                Text(MaskedMoney.yen(spent, masked: privacyMasked))
                                    .font(.subheadline.weight(.bold))
                                    .monospacedDigit()
                                    .foregroundStyle(Theme.heroInk)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }

                // 90-Day Cash-Flow Runway & What-If Simulator entry pill
                Button(action: onTapRunway) {
                    HStack(spacing: 8) {
                        Image(systemName: "chart.xyaxis.line")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.heroAccent)
                        Text("90-day runway & What-If simulator")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.heroInk)
                        Spacer()
                        Image(systemName: "arrow.right")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Theme.heroAccent)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Theme.heroAccent.opacity(0.14), in: RoundedRectangle(cornerRadius: Theme.innerRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.innerRadius, style: .continuous)
                            .strokeBorder(Theme.heroAccent.opacity(0.26), lineWidth: 0.6)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func cashOrMoneyInTile(fillHeight: Bool) -> some View {
        if let live = liveCash {
            FrostedMetricTile(fillHeight: fillHeight) {
                HStack(spacing: 4) {
                    Text("Cash in banks")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Theme.heroInkMuted)
                    Spacer(minLength: 2)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(Theme.heroInkMuted.opacity(0.75))
                }
                Text(MaskedMoney.yen(live.estimatedBankCash, masked: privacyMasked))
                    .font(.subheadline.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(live.estimatedBankCash < 0 ? Theme.heroCoral : Theme.heroAccent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(bankAccountsFootnote(live))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(Theme.heroInkMuted.opacity(0.85))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            FrostedMetricTile(fillHeight: fillHeight) {
                Text("Money in")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Theme.heroInkMuted)
                Text(MaskedMoney.signed(payday.inSum, masked: privacyMasked))
                    .font(.subheadline.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.heroAccent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let firstIn = payday.ins.first {
                    Text(payday.ins.count == 1 ? firstIn.item : "\(payday.ins.count) inflows")
                        .font(.caption2)
                        .foregroundStyle(Theme.heroInkMuted.opacity(0.85))
                        .lineLimit(1)
                }
            }
        }
    }

    private func bankAccountsFootnote(_ live: LiveCashSummary) -> String {
        var parts: [String]
        if live.accounts.count == 1, let only = live.accounts.first {
            parts = [only.label]
        } else {
            parts = live.accounts.map { acc in
                "\(acc.label) \(MaskedMoney.yen(acc.estimatedBalance, masked: privacyMasked))"
            }
        }
        if live.pendingDebitOutflow > 0 {
            parts.append("after −\(MaskedMoney.yen(live.pendingDebitOutflow, masked: privacyMasked)) pending")
        } else if live.pendingDebitOutflow < 0 {
            parts.append("incl. +\(MaskedMoney.yen(-live.pendingDebitOutflow, masked: privacyMasked)) refund")
        }
        return parts.joined(separator: " · ")
    }

    private func billsTile(fillHeight: Bool) -> some View {
        let displayBills = liveCash?.unsettledBillsSum ?? payday.outSum
        let title = liveCash != nil ? "Bills left" : "Bills until payday"
        return FrostedMetricTile(fillHeight: fillHeight) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Theme.heroInkMuted)
                Spacer(minLength: 2)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(Theme.heroInkMuted.opacity(0.75))
            }
            Text(MaskedMoney.signed(-displayBills, masked: privacyMasked))
                .font(.subheadline.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(Theme.heroInk)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(billSummaryNote)
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(Theme.heroInkMuted.opacity(0.85))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct SplitBar: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.privacyMasked) private var privacyMasked

    let bills: Int
    let left: Int
    let borrowed: Int
    var onHeroSurface: Bool = false

    private struct Part: Identifiable {
        let id: String
        let amount: Int
        let color: Color
    }

    private var parts: [Part] {
        var result: [Part] = []
        if bills > 0 {
            result.append(Part(
                id: "Bills",
                amount: bills,
                color: onHeroSurface ? Color.white.opacity(0.45) : Theme.ink2
            ))
        }
        if left > 0 {
            result.append(Part(
                id: "Left",
                amount: left,
                color: onHeroSurface ? Theme.heroAccent : Theme.good
            ))
        } else if left < 0 {
            result.append(Part(
                id: "Short",
                amount: abs(left),
                color: onHeroSurface ? Theme.heroCoral : Theme.bad
            ))
        }
        if borrowed > 0 {
            result.append(Part(
                id: "Borrowed",
                amount: borrowed,
                color: onHeroSurface ? Theme.heroCoral : Theme.bad
            ))
        }
        return result
    }

    var body: some View {
        let activeParts = parts
        let total = max(1, activeParts.map(\.amount).reduce(0, +))

        VStack(alignment: .leading, spacing: 9) {
            GeometryReader { geo in
                let gap: CGFloat = activeParts.count > 1 ? 3 : 0
                let available = max(0, geo.size.width - gap * CGFloat(max(0, activeParts.count - 1)))
                let rawWidths = activeParts.map { max(8, available * CGFloat($0.amount) / CGFloat(total)) }
                let sumWidths = max(1, rawWidths.reduce(0, +))
                let scale = sumWidths > available ? (available / sumWidths) : 1.0
                ZStack(alignment: .leading) {
                    Capsule().fill(onHeroSurface ? Color.white.opacity(0.12) : Theme.track)
                    if !activeParts.isEmpty {
                        HStack(spacing: gap) {
                            ForEach(Array(activeParts.enumerated()), id: \.element.id) { idx, part in
                                Capsule()
                                    .fill(part.color)
                                    .frame(width: max(0, rawWidths[idx] * scale))
                            }
                        }
                    }
                }
                .clipped()
            }
            .frame(height: 9)
            .accessibilityHidden(true)

            FlowLayout(horizontalSpacing: 14, verticalSpacing: 6) {
                ForEach(activeParts) { part in
                    HStack(spacing: 5) {
                        Circle()
                            .fill(part.color)
                            .frame(width: 7, height: 7)
                            .accessibilityHidden(true)
                        Text("\(part.id) \(MaskedMoney.yen(part.amount, masked: privacyMasked))")
                            .font(.caption.weight(.medium))
                            .monospacedDigit()
                            .foregroundStyle(onHeroSurface ? Theme.heroInkMuted : Theme.muted)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                            .fixedSize(horizontal: !dynamicTypeSize.isAccessibilitySize, vertical: true)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(part.id), \(MaskedMoney.accessibility(part.amount, masked: privacyMasked))")
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
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.privacyMasked) private var privacyMasked
    let day: NowScreenModel.TimelineDay
    let phoneCheckedBillKeys: Set<String>
    var todayCashBalance: ComingUpRunningBalance? = nil
    var onTapCashNow: () -> Void = {}
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
                            .opacity(isDayHeaderDimmed ? 0.62 : 1.0)
                        if day.isToday {
                            QuietTag("Today", tone: .accent)
                        }
                    }
                    if let todayCash = todayCashBalance {
                        todayCashBar(todayCash)
                    }
                    entriesContent
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .top, spacing: 14) {
                    calendarTile
                        .opacity(isDayHeaderDimmed ? 0.62 : 1.0)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 10) {
                        if day.isToday {
                            HStack(spacing: 6) {
                                QuietTag("Today", tone: .accent)
                                Text(DayText.long(day.date))
                                    .font(.caption)
                                    .foregroundStyle(Theme.muted)
                                    .lineLimit(1)
                            }
                        }
                        if let todayCash = todayCashBalance {
                            todayCashBar(todayCash)
                        }
                        entriesContent
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, day.isNextPayday ? 12 : 0)
        .padding(.vertical, day.isNextPayday ? 11 : 2)
        .background(
            Group {
                if day.isNextPayday {
                    RoundedRectangle(cornerRadius: Theme.innerRadius, style: .continuous)
                        .fill(Theme.goodWash)
                } else {
                    Color.clear
                }
            }
        )
        .overlay(
            Group {
                if day.isNextPayday {
                    RoundedRectangle(cornerRadius: Theme.innerRadius, style: .continuous)
                        .strokeBorder(Theme.good.opacity(0.28), lineWidth: 0.75)
                }
            }
        )
    }

    /// Dim a past day's date tile only when every entry on that day is settled (nothing overdue or open).
    private var isDayHeaderDimmed: Bool {
        guard day.isPast && !day.isToday else { return false }
        return !day.entries.contains { row in
            !isEntryDimmed(row.value)
        }
    }

    private func isEntryDimmed(_ entry: TimelineEntry) -> Bool {
        if entry.done == true { return true }
        if entry.event == true && day.isPast && !day.isToday { return true }
        return false
    }

    private var calendarTile: some View {
        let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
        let fill: Color = {
            if day.isToday { return Theme.accent }
            if day.isNextPayday { return Theme.good.opacity(colorScheme == .dark ? 0.25 : 0.16) }
            return Theme.well.opacity(colorScheme == .dark ? 0.9 : 0.75)
        }()
        let topTextColor: Color = {
            if day.isToday { return colorScheme == .dark ? Theme.page.opacity(0.8) : Color.white.opacity(0.82) }
            if day.isNextPayday { return Theme.good }
            return Theme.muted
        }()
        let mainTextColor: Color = {
            if day.isToday { return colorScheme == .dark ? Theme.page : Color.white }
            if day.isNextPayday { return Theme.good }
            return Theme.ink
        }()

        return VStack(spacing: 1) {
            if let label = day.label {
                Text(label.uppercased())
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(topTextColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(DayText.shortMonth(day.date))
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(mainTextColor)
            } else {
                Text(DayText.weekday(day.date).uppercased())
                    .font(.system(size: 9.5, weight: .bold))
                    .tracking(0.4)
                    .foregroundStyle(topTextColor)
                Text(DayText.dayOfMonth(day.date))
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(mainTextColor)
            }
        }
        .frame(width: 48, height: 48)
        .background(fill, in: shape)
        .overlay(
            shape.strokeBorder(
                day.isToday ? Color.clear : Theme.line.opacity(0.5),
                lineWidth: 0.5
            )
        )
    }

    private var dateColor: Color {
        if day.isToday { return Theme.accent }
        if day.isNextPayday { return Theme.good }
        return Theme.ink
    }

    private func todayCashBar(_ cash: ComingUpRunningBalance) -> some View {
        let nowTint: Color = cash.cashNow < 0 ? Theme.bad : Theme.good
        let holdLabel: String? = {
            if cash.overdueUnpaidSum > 0 && cash.pastPhoneHeldSum > 0 {
                return "After \(MaskedMoney.yen(cash.priorHeldSum, masked: privacyMasked)) overdue & pending"
            }
            if cash.overdueUnpaidSum > 0 {
                return "After \(MaskedMoney.yen(cash.overdueUnpaidSum, masked: privacyMasked)) overdue"
            }
            if cash.pastPhoneHeldSum > 0 {
                return "After \(MaskedMoney.yen(cash.pastPhoneHeldSum, masked: privacyMasked)) pending debit"
            }
            return nil
        }()
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

        return Button(action: onTapCashNow) {
            VStack(alignment: .leading, spacing: 4) {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Cash now")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.ink2)
                        Text(MaskedMoney.yen(cash.cashNow, masked: privacyMasked))
                            .font(.subheadline.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(nowTint)
                    }
                    if let holdLabel {
                        Text("\(holdLabel): \(MaskedMoney.yen(cash.startingTodayCash, masked: privacyMasked))")
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(cash.startingTodayCash < 0 ? Theme.bad : Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    HStack(alignment: .center, spacing: 6) {
                        Circle()
                            .fill(nowTint)
                            .frame(width: 6, height: 6)
                            .accessibilityHidden(true)
                        Text("Cash now")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.ink2)
                        Spacer(minLength: 8)
                        Text(MaskedMoney.yen(cash.cashNow, masked: privacyMasked))
                            .font(.subheadline.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(nowTint)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(Theme.muted.opacity(0.65))
                            .accessibilityHidden(true)
                    }
                    if let holdLabel {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(holdLabel)
                                .font(.caption2)
                                .foregroundStyle(Theme.muted)
                                .lineLimit(1)
                            Spacer(minLength: 6)
                            Text(MaskedMoney.yen(cash.startingTodayCash, masked: privacyMasked))
                                .font(.caption2.weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(cash.startingTodayCash < 0 ? Theme.bad : Theme.muted)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                (cash.cashNow < 0 ? Theme.badWash : Theme.goodWash),
                in: shape
            )
            .overlay(
                shape.strokeBorder(
                    (cash.cashNow < 0 ? Theme.bad : Theme.good).opacity(colorScheme == .dark ? 0.28 : 0.22),
                    lineWidth: 0.6
                )
            )
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Cash now, \(MaskedMoney.accessibility(cash.cashNow, masked: privacyMasked))"
            + (holdLabel != nil ? ", after prior unpaid bills \(MaskedMoney.accessibility(cash.startingTodayCash, masked: privacyMasked))" : "")
        )
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
                    timelineEntryRow(row.value, remainingBalance: row.remainingBalance)
                        .opacity(isEntryDimmed(row.value) ? 0.56 : 1.0)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func timelineEntryRow(_ entry: TimelineEntry, remainingBalance: Int?) -> some View {
        let isEvent = entry.event == true
        let isCardBilled = entry.cardBilled == true
        let moneyIn = entry.amount < 0 && entry.borrowed != true
        let isBorrowed = entry.borrowed == true
        let displayAmount = isCardBilled ? (entry.billedAmount ?? entry.amount) : entry.amount
        let amountText = (isEvent || displayAmount == 0) ? "" : MaskedMoney.payment(displayAmount, masked: privacyMasked)
        let amountColor: Color = {
            if isCardBilled { return Theme.muted }
            if isBorrowed { return Theme.bad }
            if moneyIn { return Theme.good }
            return Theme.ink
        }()

        let isPhoneChecked = phoneCheckedBillKeys.contains(BillCheckoff.key(for: entry))
        let isOverdue = day.isPast && !day.isToday && entry.done != true && !isEvent && !isBorrowed && !isCardBilled && entry.amount > 0
        let tags: [(String, QuietTag.Tone)] = {
            var list: [(String, QuietTag.Tone)] = []
            if isOverdue { list.append(("Overdue", .bad)) }
            if isEvent { list.append(("Event", .accent)) }
            if isCardBilled { list.append(("On card bill", .neutral)) }
            if entry.payday == true { list.append(("Payday", .good)) }
            if entry.done == true {
                if isPhoneChecked {
                    list.append(("Paid (phone)", .accent))
                } else if isCardBilled {
                    list.append(("Charged", .good))
                } else {
                    let doneLabel = entry.amount < 0 ? "Received" : (entry.amount > 0 ? "Paid" : "Done")
                    list.append((doneLabel, .neutral))
                }
            }
            if entry.borrowed == true { list.append(("Borrowed", .bad)) }
            if entry.estimate == true { list.append(("Estimate", .neutral)) }
            return list
        }()

        let balanceColor: Color = {
            guard let balance = remainingBalance else { return Theme.muted }
            if balance < 0 { return Theme.bad }
            if balance < 20_000 { return Theme.warnText }
            if moneyIn { return Theme.good }
            return Theme.ink2.opacity(0.82)
        }()

        return Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.item)
                        .font(.body.weight(.semibold))
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
                        Text(MaskedMoney.redactText(note, masked: privacyMasked))
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
                    if let balance = remainingBalance {
                        Text("Left after · \(MaskedMoney.yen(balance, masked: privacyMasked))")
                            .font(.caption2.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(balanceColor)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(entry.item)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        if !amountText.isEmpty {
                            Text(amountText)
                                .font(.subheadline.weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(amountColor)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                    if let note = entry.note, !note.isEmpty {
                        Text(MaskedMoney.redactText(note, masked: privacyMasked))
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
                    if let balance = remainingBalance {
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Image(systemName: "arrow.turn.down.right")
                                .font(.system(size: 8.5, weight: .semibold))
                                .foregroundStyle(Theme.muted.opacity(0.6))
                                .accessibilityHidden(true)
                            Text("Left after")
                                .font(.caption2)
                                .foregroundStyle(Theme.muted)
                            Spacer(minLength: 8)
                            Text(MaskedMoney.yen(balance, masked: privacyMasked))
                                .font(.caption2.weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(balanceColor)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .padding(.top, 2)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entryAccessibilityLabel(entry, tags: tags.map(\.0), remainingBalance: remainingBalance))
    }

    private func entryAccessibilityLabel(_ entry: TimelineEntry, tags: [String], remainingBalance: Int?) -> String {
        var parts = [DayText.long(day.date), entry.item]
        let displayAmount = entry.cardBilled == true ? (entry.billedAmount ?? entry.amount) : entry.amount
        if entry.event != true && displayAmount != 0 {
            parts.append(MaskedMoney.paymentAccessibility(displayAmount, masked: privacyMasked))
        }
        parts.append(contentsOf: tags)
        if let note = entry.note, !note.isEmpty {
            parts.append(MaskedMoney.redactText(note, masked: privacyMasked))
        }
        if let balance = remainingBalance {
            parts.append("left after \(MaskedMoney.accessibility(balance, masked: privacyMasked))")
        }
        return parts.joined(separator: ", ")
    }
}
