import FinanceCore
import SwiftUI

struct PaymentsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var session: AppSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.privacyMasked) private var privacyMasked
    @Environment(\.colorScheme) private var colorScheme

    @State private var statusFilter: PaymentStatusFilter = .all
    @State private var typeFilter: PaymentTypeFilter = .payments
    @State private var sortOrder: PaymentSortOrder = .newest
    @State private var inspectedPayment: InspectedPayment?
    @State private var quickRecategorizeItem: BudgetItem?

    private var activeSelectedID: String? {
        session.periodMode == .payCycle ? session.paymentsCycleID : session.paymentsMonth
    }

    private var hasExtraFilters: Bool {
        statusFilter != .all
            || typeFilter != .payments
            || sortOrder != .newest
            || session.paymentsSource != nil
            || session.paymentsLayer != nil
            || session.paymentsDateRange != nil
    }

    var body: some View {
        NavigationStack {
            Group {
                if let data = session.resolvedData(from: model) {
                    let effectiveStatus: PaymentStatusFilter = session.paymentsOnlyUncategorized
                        ? .uncategorized
                        : statusFilter
                    let screen = PaymentsScreenModel(
                        data: data,
                        periodMode: session.periodMode,
                        selectedPeriodID: activeSelectedID,
                        allPeriods: session.paymentsAllMonths,
                        category: session.paymentsCategory,
                        source: session.paymentsSource,
                        layerFilter: session.paymentsLayer,
                        dateRange: session.paymentsDateRange,
                        statusFilter: effectiveStatus,
                        typeFilter: typeFilter,
                        sortOrder: sortOrder,
                        query: session.paymentsQuery
                    )
                    if screen.periods.isEmpty {
                        ScrollView {
                            StateCard(
                                kind: .empty,
                                title: "No payments yet",
                                message: "Turn on Google Drive sync in More → Connections."
                            )
                            .padding(.horizontal, Theme.screenPadding)
                            .padding(.vertical, 12)
                        }
                        .background(Theme.page)
                    } else {
                        paymentsList(screen: screen, data: data, effectiveStatus: effectiveStatus)
                    }
                } else if !session.hasCompletedInitialLoad {
                    ScrollView {
                        StateCard(
                            kind: .loading,
                            title: "Loading data",
                            message: "Checking stored statements and recent bank emails."
                        )
                        .padding(.horizontal, Theme.screenPadding)
                        .padding(.vertical, 12)
                    }
                    .background(Theme.page)
                } else if let error = model.importMessage, error.hasPrefix("Not imported:") {
                    ScrollView {
                        StateCard(
                            kind: .error,
                            title: "Could not read data file",
                            message: error,
                            actionTitle: "Check again"
                        ) {
                            Task { await model.checkInbox() }
                        }
                        .padding(.horizontal, Theme.screenPadding)
                        .padding(.vertical, 12)
                    }
                    .background(Theme.page)
                } else {
                    ScrollView {
                        NoDataView()
                            .padding(.horizontal, Theme.screenPadding)
                            .padding(.vertical, 12)
                    }
                    .background(Theme.page)
                }
            }
            .searchable(text: $session.paymentsQuery, prompt: "Merchant, category or card")
            .navigationTitle("Payments")
            .toolbar {
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

                        filterMenu

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
                        } label: {
                            Image(systemName: "plus")
                                .font(.body.weight(.semibold))
                        }
                        .accessibilityLabel("Add payment or scan receipt")
                    }
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
                quickRecategorizeItem?.merchant ?? "Change category",
                isPresented: Binding(
                    get: { quickRecategorizeItem != nil },
                    set: { if !$0 { quickRecategorizeItem = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let target = quickRecategorizeItem, let data = session.resolvedData(from: model) {
                    ForEach(data.availableCategories.prefix(12), id: \.category) { pair in
                        Button(pair.category) {
                            let item = target
                            quickRecategorizeItem = nil
                            guard !session.isDemo else { return }
                            Task {
                                try? await model.setCategoryOverride(
                                    for: item,
                                    group: pair.group,
                                    category: pair.category,
                                    applyToAllFromMerchant: false
                                )
                            }
                        }
                    }
                    Button("More options…") {
                        let item = target
                        quickRecategorizeItem = nil
                        inspectedPayment = InspectedPayment(item: item)
                    }
                    Button("Cancel", role: .cancel) { quickRecategorizeItem = nil }
                }
            } message: {
                if let target = quickRecategorizeItem {
                    Text("\(Money.payment(target.amount)) · Swipe triage updates this payment immediately.")
                }
            }
        }
    }

    // MARK: - Native List enabling silky .swipeActions triage while preserving porcelain card design

    private func paymentsList(
        screen: PaymentsScreenModel,
        data: FinanceData,
        effectiveStatus: PaymentStatusFilter
    ) -> some View {
        List {
            // Controls + Summary header block
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    PeriodModeSwitch(mode: $session.periodMode)
                    scopeAndPeriodControls(screen: screen)
                    if !screen.categories.isEmpty {
                        categoryPicker(screen: screen)
                    }
                    if hasExtraFilters || session.paymentsOnlyUncategorized {
                        activeFiltersBanner(effectiveStatus: effectiveStatus, bundleLayers: data.bundle.layers)
                    }
                    summaryCard(screen: screen, data: data)
                }
                .listRowInsets(EdgeInsets(top: 8, leading: Theme.screenPadding, bottom: 8, trailing: Theme.screenPadding))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }

            if screen.sections.isEmpty {
                Section {
                    emptyFilterCard
                        .listRowInsets(EdgeInsets(top: 6, leading: Theme.screenPadding, bottom: 12, trailing: Theme.screenPadding))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
            } else {
                ForEach(screen.sections) { section in
                    Section {
                        ForEach(Array(section.rows.enumerated()), id: \.element.id) { index, row in
                            let isFirst = index == 0
                            let isLast = index == section.rows.count - 1
                            swipeablePaymentRow(
                                item: row.value,
                                data: data,
                                isFirst: isFirst,
                                isLast: isLast,
                                showDateInSubtitle: section.date == "LARGEST"
                            )
                            .listRowInsets(EdgeInsets(
                                top: isFirst ? 2 : 0,
                                leading: Theme.screenPadding,
                                bottom: isLast ? 8 : 0,
                                trailing: Theme.screenPadding
                            ))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                Button {
                                    quickRecategorizeItem = row.value
                                } label: {
                                    Label("Category", systemImage: "tag.fill")
                                }
                                .tint(Theme.accent)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button {
                                    guard !session.isDemo else { return }
                                    Task { try? await model.excludeAsNonSpending(item: row.value, categoryLabel: "Excluded") }
                                } label: {
                                    Label("Exclude", systemImage: "eye.slash")
                                }
                                .tint(Theme.muted)

                                Button {
                                    guard !session.isDemo else { return }
                                    Task { try? await model.excludeAsNonSpending(item: row.value, categoryLabel: "Work expense") }
                                } label: {
                                    Label("Work", systemImage: "briefcase.fill")
                                }
                                .tint(Color("LayerRent"))
                            }
                        }
                    } header: {
                        daySectionHeader(section: section)
                            .textCase(nil)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.page)
    }

    private func daySectionHeader(section: PaymentsScreenModel.DaySection) -> some View {
        let headerTitle = section.date == "LARGEST" ? "Largest first" : FinanceFormat.dayHeader(section.date)
        return Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 2) {
                    SectionLabel(headerTitle)
                    if section.countedSubtotal != 0 && section.date != "LARGEST" {
                        Text(MaskedMoney.payment(section.countedSubtotal, masked: privacyMasked))
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(Theme.ink2)
                    }
                }
            } else {
                HStack(alignment: .center, spacing: 8) {
                    SectionLabel(headerTitle)
                    Spacer(minLength: 8)
                    if section.countedSubtotal != 0 && section.date != "LARGEST" {
                        Text(MaskedMoney.payment(section.countedSubtotal, masked: privacyMasked))
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(Theme.ink2)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Theme.well.opacity(0.8), in: Capsule())
                    }
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
    }

    private func swipeablePaymentRow(
        item: BudgetItem,
        data: FinanceData,
        isFirst: Bool,
        isLast: Bool,
        showDateInSubtitle: Bool
    ) -> some View {
        let topR: CGFloat = isFirst ? Theme.cardRadius : 0
        let botR: CGFloat = isLast ? Theme.cardRadius : 0
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: topR,
            bottomLeadingRadius: botR,
            bottomTrailingRadius: botR,
            topTrailingRadius: topR,
            style: .continuous
        )

        return Button {
            inspectedPayment = InspectedPayment(item: item)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                PaymentRow(
                    item: item,
                    counted: data.layer(of: item) != nil,
                    isLocal: data.isLocalItem(item),
                    showDateInSubtitle: showDateInSubtitle
                )
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                if !isLast {
                    HairlineDivider()
                        .padding(.leading, dynamicTypeSize.isAccessibilitySize ? Theme.cardPadding : 64)
                }
            }
            .background(Theme.surface, in: shape)
            .overlay(
                shape.strokeBorder(
                    colorScheme == .dark ? Color.white.opacity(0.06) : Theme.line.opacity(0.55),
                    lineWidth: 0.5
                )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Filter & Sort menu

    private var filterMenu: some View {
        let data = session.resolvedData(from: model)
        let sources = data?.availableSources ?? []
        let bundleLayers = data?.bundle.layers ?? []
        return Menu {
            Section("Scope") {
                Button {
                    session.paymentsDateRange = nil
                    session.paymentsDateRangeLabel = nil
                    session.paymentsAllMonths = false
                } label: {
                    let selected = !session.paymentsAllMonths && session.paymentsDateRange == nil
                    if selected {
                        Label(session.periodMode == .payCycle ? "Single pay cycle" : "Single month", systemImage: "checkmark")
                    } else {
                        Text(session.periodMode == .payCycle ? "Single pay cycle" : "Single month")
                    }
                }
                Button {
                    session.paymentsDateRange = nil
                    session.paymentsDateRangeLabel = nil
                    session.paymentsAllMonths = true
                } label: {
                    if session.paymentsAllMonths && session.paymentsDateRange == nil {
                        Label("All time", systemImage: "checkmark")
                    } else {
                        Text("All time")
                    }
                }
            }

            Section("Spending Layer") {
                Button {
                    session.paymentsLayer = nil
                } label: {
                    if session.paymentsLayer == nil {
                        Label("All layers", systemImage: "checkmark")
                    } else {
                        Text("All layers")
                    }
                }
                ForEach(SpendingLayer.allCases) { layer in
                    Button {
                        session.paymentsLayer = layer
                    } label: {
                        let title = layer.title(in: bundleLayers)
                        if session.paymentsLayer == layer {
                            Label(title, systemImage: "checkmark")
                        } else {
                            Text(title)
                        }
                    }
                }
            }

            Section("Status") {
                ForEach(PaymentStatusFilter.allCases) { option in
                    Button {
                        session.paymentsOnlyUncategorized = false
                        statusFilter = option
                    } label: {
                        let selected = (session.paymentsOnlyUncategorized ? .uncategorized : statusFilter) == option
                        if selected {
                            Label(option.rawValue, systemImage: "checkmark")
                        } else {
                            Text(option.rawValue)
                        }
                    }
                }
            }

            Section("Type") {
                ForEach(PaymentTypeFilter.allCases) { option in
                    Button {
                        typeFilter = option
                    } label: {
                        if typeFilter == option {
                            Label(option.rawValue, systemImage: "checkmark")
                        } else {
                            Text(option.rawValue)
                        }
                    }
                }
            }

            if !sources.isEmpty {
                Section("Card / Source") {
                    Button {
                        session.paymentsSource = nil
                    } label: {
                        if session.paymentsSource == nil {
                            Label("All sources", systemImage: "checkmark")
                        } else {
                            Text("All sources")
                        }
                    }
                    ForEach(sources, id: \.self) { src in
                        Button {
                            session.paymentsSource = src
                        } label: {
                            if session.paymentsSource == src {
                                Label(src, systemImage: "checkmark")
                            } else {
                                Text(src)
                            }
                        }
                    }
                }
            }

            Section("Sort") {
                ForEach(PaymentSortOrder.allCases) { order in
                    Button {
                        sortOrder = order
                    } label: {
                        if sortOrder == order {
                            Label(order.rawValue, systemImage: "checkmark")
                        } else {
                            Text(order.rawValue)
                        }
                    }
                }
            }

            if hasExtraFilters || session.paymentsOnlyUncategorized {
                Button("Reset filters", role: .destructive) {
                    resetAllFilters()
                }
            }
        } label: {
            Image(systemName: (hasExtraFilters || session.paymentsOnlyUncategorized)
                  ? "line.3.horizontal.decrease.circle.fill"
                  : "line.3.horizontal.decrease.circle")
                .font(.body)
        }
        .accessibilityLabel("Filter and sort payments")
    }

    // MARK: - Scope & period picker

    private func scopeAndPeriodControls(screen: PaymentsScreenModel) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    FilterChip(
                        title: screen.periodMode == .payCycle ? "All cycles" : "All months",
                        isSelected: screen.allPeriods && session.paymentsDateRange == nil
                    ) {
                        toggleAllPeriods(true)
                    }
                    .id("ALL_PERIODS")

                    ForEach(screen.periods) { period in
                        FilterChip(
                            title: period.shortLabel,
                            isSelected: !screen.allPeriods && period.id == screen.selectedPeriodID
                        ) {
                            selectPeriod(period.id)
                        }
                        .id(period.id)
                    }
                }
                .padding(.vertical, 2)
            }
            .onAppear {
                proxy.scrollTo(screen.allPeriods ? "ALL_PERIODS" : screen.selectedPeriodID, anchor: .trailing)
            }
            .onChange(of: screen.selectedPeriodID) { _, target in
                guard !screen.allPeriods else { return }
                scrollTo(proxy: proxy, target: target)
            }
        }
    }

    private func scrollTo(proxy: ScrollViewProxy, target: String) {
        if reduceMotion {
            proxy.scrollTo(target, anchor: .center)
        } else {
            withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo(target, anchor: .center)
            }
        }
    }

    // MARK: - Category filter strip

    private func categoryPicker(screen: PaymentsScreenModel) -> some View {
        let activeCategory = session.paymentsCategory
        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    FilterChip(
                        title: "All",
                        isSelected: activeCategory == nil
                    ) {
                        selectCategory(nil)
                    }
                    .id("ALL")

                    ForEach(screen.categories) { option in
                        let isSelected = activeCategory == option.name
                        FilterChip(
                            title: option.name,
                            isSelected: isSelected
                        ) {
                            selectCategory(isSelected ? nil : option.name)
                        }
                        .id(option.name)
                    }
                }
                .padding(.vertical, 2)
            }
            .onAppear {
                if let activeCategory {
                    proxy.scrollTo(activeCategory, anchor: .center)
                }
            }
            .onChange(of: session.paymentsCategory) { _, target in
                scrollTo(proxy: proxy, target: target ?? "ALL")
            }
        }
    }

    private func activeFiltersBanner(effectiveStatus: PaymentStatusFilter, bundleLayers: [LayerDefinition]) -> some View {
        FlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
            if let rangeLabel = session.paymentsDateRangeLabel {
                QuietTag(rangeLabel, tone: .accent)
            } else if let range = session.paymentsDateRange {
                QuietTag("\(DayText.short(range.lowerBound)) – \(DayText.short(range.upperBound))", tone: .accent)
            }
            if let layer = session.paymentsLayer {
                QuietTag(layer.title(in: bundleLayers), tone: .accent)
            }
            if effectiveStatus != .all {
                QuietTag(effectiveStatus.rawValue, tone: .accent)
            }
            if typeFilter != .payments {
                QuietTag(typeFilter.rawValue, tone: .accent)
            }
            if let source = session.paymentsSource {
                QuietTag(source, tone: .accent)
            }
            if sortOrder != .newest {
                QuietTag("Largest first", tone: .neutral)
            }
            Button("Clear") {
                resetAllFilters()
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 6)
            .buttonStyle(.plain)
        }
    }

    // MARK: - Summary card with 4-layer proportion ribbon

    private func summaryCard(screen: PaymentsScreenModel, data: FinanceData) -> some View {
        let headerLabel: String = {
            if let rangeLabel = session.paymentsDateRangeLabel { return rangeLabel }
            if screen.allPeriods {
                return screen.periodMode == .payCycle
                    ? "All \(screen.periods.count) pay cycles"
                    : "All \(screen.periods.count) months"
            }
            return screen.selectedPeriod?.title ?? screen.selectedPeriodID
        }()

        let displayAmount = typeFilter == .income ? screen.incomeTotal : screen.countedSpending
        let amountColor = typeFilter == .income ? Theme.good : Theme.ink

        let countLine: String = {
            if typeFilter == .income {
                let w = screen.totalRows == 1 ? "deposit" : "deposits"
                return "\(screen.totalRows) \(w)"
            }
            var parts: [String] = []
            let w = screen.spendingRowCount == 1 ? "spending payment" : "spending payments"
            parts.append("\(screen.spendingRowCount) \(w)")
            if screen.excludedRowCount > 0 {
                parts.append("\(screen.excludedRowCount) excluded")
            }
            if screen.spendingRowCount > 1 && (!session.paymentsQuery.isEmpty || screen.allPeriods) {
                let avg = Int((Double(screen.countedSpending) / Double(screen.spendingRowCount)).rounded())
                parts.append("avg \(MaskedMoney.yen(avg, masked: privacyMasked))")
            }
            return parts.joined(separator: " · ")
        }()

        let layerSlices: [(layer: SpendingLayer, sum: Int)] = {
            guard typeFilter != .income else { return [] }
            var totals: [SpendingLayer: Int] = [:]
            for sec in screen.sections {
                for row in sec.rows {
                    let item = row.value
                    guard item.amount > 0, let layerKey = data.layer(of: item) else { continue }
                    let layer = SpendingLayer.resolve(key: layerKey, bundleLayers: data.bundle.layers)
                    totals[layer, default: 0] += item.amount
                }
            }
            return SpendingLayer.allCases.compactMap { layer in
                let val = totals[layer, default: 0]
                return val > 0 ? (layer, val) : nil
            }
        }()

        return FinanceCard {
            VStack(alignment: .leading, spacing: 10) {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel(headerLabel, symbol: "creditcard")
                        if let activeCategory = session.paymentsCategory {
                            QuietTag(activeCategory, tone: .accent)
                        }
                    }
                } else {
                    HStack(alignment: .center, spacing: 8) {
                        SectionLabel(headerLabel, symbol: "creditcard")
                        Spacer(minLength: 8)
                        if let activeCategory = session.paymentsCategory {
                            QuietTag(activeCategory, tone: .accent)
                        }
                    }
                }

                HeroMoneyText(amount: displayAmount, color: amountColor)

                FlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                    Text(countLine)
                        .font(.footnote)
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    if screen.pendingCount > 0 {
                        QuietTag("\(screen.pendingCount) pending", tone: .accent)
                    }
                    if screen.manualCount > 0 {
                        QuietTag("\(screen.manualCount) local", tone: .neutral)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)

                if !layerSlices.isEmpty {
                    let total = max(1, layerSlices.reduce(0) { $0 + $1.sum })
                    GeometryReader { geo in
                        let gap: CGFloat = layerSlices.count > 1 ? 2.5 : 0
                        let usable = max(0, geo.size.width - gap * CGFloat(max(0, layerSlices.count - 1)))
                        HStack(spacing: gap) {
                            ForEach(layerSlices, id: \.layer) { slice in
                                Capsule()
                                    .fill(slice.layer.color)
                                    .frame(width: max(6, usable * CGFloat(slice.sum) / CGFloat(total)))
                            }
                        }
                    }
                    .frame(height: 5.5)
                    .padding(.top, 2)
                    .accessibilityHidden(true)
                }
            }
        }
    }

    // MARK: - Empty filter state

    private var emptyFilterCard: some View {
        StateCard(
            kind: .empty,
            title: "No matching payments",
            message: session.paymentsAllMonths
                ? "Try a different search term or clear active filters."
                : "No matches in this period. Try switching to All or clearing filters.",
            actionTitle: session.paymentsAllMonths ? "Clear filters" : "Search all periods"
        ) {
            if session.paymentsAllMonths {
                resetAllFilters()
                session.paymentsQuery = ""
                selectCategory(nil)
            } else {
                session.paymentsDateRange = nil
                session.paymentsDateRangeLabel = nil
                session.paymentsAllMonths = true
            }
        }
    }

    private func toggleAllPeriods(_ all: Bool) {
        let update = {
            session.paymentsDateRange = nil
            session.paymentsDateRangeLabel = nil
            session.paymentsAllMonths = all
        }
        if reduceMotion { update() } else { withAnimation(.easeInOut(duration: 0.18), update) }
    }

    private func selectPeriod(_ id: String) {
        let update = {
            session.paymentsDateRange = nil
            session.paymentsDateRangeLabel = nil
            session.paymentsAllMonths = false
            if session.periodMode == .payCycle {
                session.paymentsCycleID = id
            } else {
                session.paymentsMonth = id
            }
            session.paymentsCategory = nil
        }
        if reduceMotion { update() } else { withAnimation(.easeInOut(duration: 0.18), update) }
    }

    private func selectCategory(_ category: String?) {
        if reduceMotion {
            session.paymentsCategory = category
        } else {
            withAnimation(.easeInOut(duration: 0.18)) {
                session.paymentsCategory = category
            }
        }
    }

    private func resetAllFilters() {
        statusFilter = .all
        typeFilter = .payments
        sortOrder = .newest
        session.paymentsSource = nil
        session.paymentsLayer = nil
        session.paymentsDateRange = nil
        session.paymentsDateRangeLabel = nil
        session.paymentsOnlyUncategorized = false
    }
}

struct PaymentRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.privacyMasked) private var privacyMasked
    let item: BudgetItem
    let counted: Bool
    var isLocal: Bool = false
    var showDateInSubtitle: Bool = false

    var body: some View {
        let amountText = MaskedMoney.payment(item.amount, masked: privacyMasked)
        let amountColor = item.amount < 0 ? Theme.good : Theme.ink
        let subtitle = showDateInSubtitle
            ? "\(DayText.short(item.date)) · \(item.category) · \(item.source)"
            : "\(item.category) · \(item.source)"

        return Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 5) {
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
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    if item.isPending || isLocal || !counted {
                        FlowLayout(horizontalSpacing: 6, verticalSpacing: 4) {
                            if item.isPending {
                                QuietTag("Pending", tone: .accent)
                            }
                            if isLocal {
                                QuietTag("Local", tone: .accent)
                            }
                            if !counted {
                                QuietTag("Not spending", tone: .neutral)
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .center, spacing: 12) {
                    CategoryBadge(category: item.amount < 0 ? "Salary" : item.category, size: 36)

                    VStack(alignment: .leading, spacing: 3.5) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
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
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(Theme.muted)
                                .lineLimit(1)
                            Spacer(minLength: 6)
                            if item.isPending {
                                QuietTag("Pending", tone: .accent)
                            }
                            if isLocal {
                                QuietTag("Local", tone: .accent)
                            }
                            if !counted {
                                QuietTag("Not spending", tone: .neutral)
                            }
                        }
                    }
                }
            }
        }
        .opacity(counted ? 1.0 : 0.72)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var parts = [
            item.merchant,
            privacyMasked ? "Hidden amount" : FinanceFormat.paymentAccessibility(item.amount),
            DayText.short(item.date),
            item.category,
            item.source
        ]
        if item.isPending {
            parts.append("Pending")
        }
        if isLocal {
            parts.append("Saved locally on phone")
        }
        if !counted {
            parts.append("Not counted as spending")
        }
        return parts.joined(separator: ", ")
    }
}
