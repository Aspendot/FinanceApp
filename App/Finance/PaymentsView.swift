import FinanceCore
import SwiftUI

struct PaymentsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var session: AppSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var query = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.cardSpacing) {
                    if let data = session.resolvedData(from: model) {
                        let screen = PaymentsScreenModel(
                            data: data,
                            selectedMonth: session.paymentsMonth,
                            category: session.paymentsCategory,
                            query: query
                        )
                        if screen.months.isEmpty {
                            StateCard(
                                kind: .empty,
                                title: "No payments yet",
                                message: "Turn on Google Drive sync in More → Connections."
                            )
                        } else {
                            monthPicker(screen: screen)
                            if !screen.categories.isEmpty {
                                categoryPicker(screen: screen)
                            }
                            summaryCard(screen: screen)
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
            .searchable(text: $query, prompt: "Merchant, category or card")
            .navigationTitle("Payments")
            .refreshable {
                guard !session.isDemo else { return }
                await model.syncGmail()
            }
        }
    }

    // MARK: - Month picker (oldest left, newest right)

    private func monthPicker(screen: PaymentsScreenModel) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(screen.months, id: \.self) { month in
                        FilterChip(
                            title: FinanceFormat.monthChip(month, includeYear: screen.spansMultipleYears),
                            isSelected: month == screen.selectedMonth
                        ) {
                            selectMonth(month)
                        }
                        .id(month)
                    }
                }
            }
            .onAppear {
                proxy.scrollTo(screen.selectedMonth, anchor: .trailing)
            }
            .onChange(of: screen.selectedMonth) { _, target in
                if reduceMotion {
                    proxy.scrollTo(target, anchor: .center)
                } else {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(target, anchor: .center)
                    }
                }
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
            }
            .onAppear {
                if let activeCategory {
                    proxy.scrollTo(activeCategory, anchor: .center)
                }
            }
            .onChange(of: session.paymentsCategory) { _, target in
                let scrollTarget = target ?? "ALL"
                if reduceMotion {
                    proxy.scrollTo(scrollTarget, anchor: .center)
                } else {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(scrollTarget, anchor: .center)
                    }
                }
            }
        }
    }

    // MARK: - Month summary card

    private func summaryCard(screen: PaymentsScreenModel) -> some View {
        let paymentWord = screen.totalRows == 1 ? "payment" : "payments"

        return FinanceCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 8) {
                    SectionLabel(DayText.month(screen.selectedMonth))
                    Spacer(minLength: 8)
                    if let activeCategory = session.paymentsCategory {
                        QuietTag(activeCategory, tone: .accent)
                    }
                }

                MetricMoneyText(amount: screen.countedSpending, color: Theme.ink)

                FlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                    Text("\(screen.totalRows) \(paymentWord) counted as spending")
                        .font(.footnote)
                        .foregroundStyle(Theme.muted)
                    if screen.pendingCount > 0 {
                        QuietTag("\(screen.pendingCount) pending", tone: .accent)
                    }
                }
            }
        }
    }

    // MARK: - Day section

    private func daySectionView(section: PaymentsScreenModel.DaySection, data: FinanceData) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                SectionLabel(FinanceFormat.dayHeader(section.date))
                Spacer(minLength: 8)
                if section.countedSubtotal != 0 {
                    Text(Money.payment(section.countedSubtotal))
                        .font(.caption.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(Theme.muted)
                        .accessibilityLabel("Day total \(FinanceFormat.paymentAccessibility(section.countedSubtotal))")
                }
            }
            .padding(.horizontal, 2)

            FinanceCard(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(section.rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 {
                            HairlineDivider()
                                .padding(.leading, Theme.cardPadding)
                        }
                        PaymentRow(item: row.value, counted: data.layer(of: row.value) != nil)
                            .padding(.horizontal, Theme.cardPadding)
                            .padding(.vertical, 12)
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
            message: "Try a different search term or clear the active category filter.",
            actionTitle: "Clear filters"
        ) {
            query = ""
            selectCategory(nil)
        }
    }

    private func selectMonth(_ month: String) {
        if reduceMotion {
            session.paymentsMonth = month
            session.paymentsCategory = nil
        } else {
            withAnimation(.easeInOut(duration: 0.18)) {
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
}

struct PaymentRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let item: BudgetItem
    let counted: Bool

    var body: some View {
        let amountText = Money.payment(item.amount)
        let amountColor = item.amount < 0 ? Theme.good : Theme.ink
        // Rows sit under a day header, so the date isn't repeated here.
        let subtitle = "\(item.category) · \(item.source)"

        return Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.merchant)
                        .font(.body.weight(.medium))
                        .foregroundStyle(Theme.ink)
                    Text(amountText)
                        .font(.body.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(amountColor)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                    if item.isPending || !counted {
                        FlowLayout(horizontalSpacing: 6, verticalSpacing: 4) {
                            if item.isPending {
                                QuietTag("Pending", tone: .accent)
                            }
                            if !counted {
                                QuietTag("Not spending", tone: .neutral)
                            }
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
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
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(Theme.muted)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        if item.isPending {
                            QuietTag("Pending", tone: .accent)
                        }
                        if !counted {
                            QuietTag("Not spending", tone: .neutral)
                        }
                    }
                }
            }
        }
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
        if !counted {
            parts.append("Not counted as spending")
        }
        return parts.joined(separator: ", ")
    }
}
