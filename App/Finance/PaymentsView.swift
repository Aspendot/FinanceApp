import FinanceCore
import SwiftUI

struct PaymentsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var session: AppSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var statusFilter: PaymentStatusFilter = .all
    @State private var typeFilter: PaymentTypeFilter = .payments
    @State private var sortOrder: PaymentSortOrder = .newest
    @State private var inspectedPayment: InspectedPayment?

    private var hasExtraFilters: Bool {
        statusFilter != .all || typeFilter != .payments || sortOrder != .newest || session.paymentsSource != nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.cardSpacing) {
                    if let data = session.resolvedData(from: model) {
                        let effectiveStatus: PaymentStatusFilter = session.paymentsOnlyUncategorized
                            ? .uncategorized
                            : statusFilter
                        let screen = PaymentsScreenModel(
                            data: data,
                            selectedMonth: session.paymentsMonth,
                            allMonths: session.paymentsAllMonths,
                            category: session.paymentsCategory,
                            source: session.paymentsSource,
                            statusFilter: effectiveStatus,
                            typeFilter: typeFilter,
                            sortOrder: sortOrder,
                            query: session.paymentsQuery
                        )
                        if screen.months.isEmpty {
                            StateCard(
                                kind: .empty,
                                title: "No payments yet",
                                message: "Turn on Google Drive sync in More → Connections."
                            )
                        } else {
                            scopeAndMonthControls(screen: screen)
                            if !screen.categories.isEmpty {
                                categoryPicker(screen: screen)
                            }
                            if hasExtraFilters || session.paymentsOnlyUncategorized {
                                activeFiltersBanner(effectiveStatus: effectiveStatus)
                            }
                            summaryCard(screen: screen, data: data)
                            if screen.sections.isEmpty {
                                emptyFilterCard
                            } else {
                                ForEach(screen.sections) { section in
                                    daySectionView(section: section, data: data)
                                }
                            }
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
            .searchable(text: $session.paymentsQuery, prompt: "Merchant, category or card")
            .navigationTitle("Payments")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        filterMenu
                        Button {
                            session.activeSheet = .quickAdd
                        } label: {
                            Image(systemName: "plus")
                                .font(.body.weight(.semibold))
                        }
                        .accessibilityLabel("Add payment")
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
        }
    }

    // MARK: - Filter & Sort menu

    private var filterMenu: some View {
        let sources = session.resolvedData(from: model)?.availableSources ?? []
        return Menu {
            Section("Scope") {
                Button {
                    session.paymentsAllMonths = false
                } label: {
                    if !session.paymentsAllMonths {
                        Label("Single month", systemImage: "checkmark")
                    } else {
                        Text("Single month")
                    }
                }
                Button {
                    session.paymentsAllMonths = true
                } label: {
                    if session.paymentsAllMonths {
                        Label("All months", systemImage: "checkmark")
                    } else {
                        Text("All months")
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

    // MARK: - Scope & month picker

    private func scopeAndMonthControls(screen: PaymentsScreenModel) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    FilterChip(
                        title: "All months",
                        isSelected: screen.allMonths
                    ) {
                        toggleAllMonths(true)
                    }
                    .id("ALL_MONTHS")

                    ForEach(screen.months, id: \.self) { month in
                        FilterChip(
                            title: FinanceFormat.monthChip(month, includeYear: screen.spansMultipleYears),
                            isSelected: !screen.allMonths && month == screen.selectedMonth
                        ) {
                            selectMonth(month)
                        }
                        .id(month)
                    }
                }
                .padding(.vertical, 2)
            }
            .onAppear {
                proxy.scrollTo(screen.allMonths ? "ALL_MONTHS" : screen.selectedMonth, anchor: .trailing)
            }
            .onChange(of: screen.selectedMonth) { _, target in
                guard !screen.allMonths else { return }
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

    private func activeFiltersBanner(effectiveStatus: PaymentStatusFilter) -> some View {
        FlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
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

    // MARK: - Month summary card with 4-layer proportion ribbon

    private func summaryCard(screen: PaymentsScreenModel, data: FinanceData) -> some View {
        let headerLabel = screen.allMonths
            ? "All \(screen.months.count) months"
            : DayText.month(screen.selectedMonth)

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
            if screen.spendingRowCount > 1 && (!session.paymentsQuery.isEmpty || screen.allMonths) {
                let avg = Int((Double(screen.countedSpending) / Double(screen.spendingRowCount)).rounded())
                parts.append("avg \(Money.yen(avg))")
            }
            return parts.joined(separator: " · ")
        }()

        // Compute the 4-layer spending mix for the sleek ribbon bar
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

    // MARK: - Day section

    private func daySectionView(section: PaymentsScreenModel.DaySection, data: FinanceData) -> some View {
        let headerTitle = section.date == "LARGEST" ? "Largest first" : FinanceFormat.dayHeader(section.date)
        return VStack(alignment: .leading, spacing: 8) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 2) {
                        SectionLabel(headerTitle)
                        if section.countedSubtotal != 0 && section.date != "LARGEST" {
                            Text(Money.payment(section.countedSubtotal))
                                .font(.caption.weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(Theme.ink2)
                                .lineLimit(1)
                                .minimumScaleFactor(0.5)
                                .allowsTightening(true)
                                .accessibilityLabel("Day total \(FinanceFormat.paymentAccessibility(section.countedSubtotal))")
                        }
                    }
                } else {
                    HStack(alignment: .center, spacing: 8) {
                        SectionLabel(headerTitle)
                        Spacer(minLength: 8)
                        if section.countedSubtotal != 0 && section.date != "LARGEST" {
                            Text(Money.payment(section.countedSubtotal))
                                .font(.caption.weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(Theme.ink2)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Theme.well.opacity(0.8), in: Capsule())
                                .accessibilityLabel("Day total \(FinanceFormat.paymentAccessibility(section.countedSubtotal))")
                        }
                    }
                }
            }
            .padding(.horizontal, 4)

            FinanceCard(padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(section.rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 {
                            HairlineDivider()
                                .padding(.leading, dynamicTypeSize.isAccessibilitySize ? Theme.cardPadding : 64)
                        }
                        Button {
                            inspectedPayment = InspectedPayment(item: row.value)
                        } label: {
                            PaymentRow(
                                item: row.value,
                                counted: data.layer(of: row.value) != nil,
                                isLocal: data.isLocalItem(row.value),
                                showDateInSubtitle: section.date == "LARGEST"
                            )
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
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
                : "No matches in this month. Try switching to All months or clearing filters.",
            actionTitle: session.paymentsAllMonths ? "Clear filters" : "Search all months"
        ) {
            if session.paymentsAllMonths {
                resetAllFilters()
                session.paymentsQuery = ""
                selectCategory(nil)
            } else {
                session.paymentsAllMonths = true
            }
        }
    }

    private func toggleAllMonths(_ all: Bool) {
        if reduceMotion {
            session.paymentsAllMonths = all
        } else {
            withAnimation(.easeInOut(duration: 0.18)) {
                session.paymentsAllMonths = all
            }
        }
    }

    private func selectMonth(_ month: String) {
        if reduceMotion {
            session.paymentsAllMonths = false
            session.paymentsMonth = month
            session.paymentsCategory = nil
        } else {
            withAnimation(.easeInOut(duration: 0.18)) {
                session.paymentsAllMonths = false
                session.paymentsMonth = month
                session.paymentsCategory = nil
            }
        }
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
        session.paymentsOnlyUncategorized = false
    }
}

struct PaymentRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let item: BudgetItem
    let counted: Bool
    var isLocal: Bool = false
    var showDateInSubtitle: Bool = false

    var body: some View {
        let amountText = Money.payment(item.amount)
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
            FinanceFormat.paymentAccessibility(item.amount),
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
