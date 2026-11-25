import FinanceCore
import SwiftUI

// MARK: - 1. Subscription Inspector

struct SubscriptionDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.privacyMasked) private var privacyMasked
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var session: AppSession

    let subscription: SubscriptionItem
    @State private var inspectedPayment: InspectedPayment?
    @State private var showingAddReminder = false

    private var activeData: FinanceData? {
        session.resolvedData(from: model)
    }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: Theme.cardSpacing) {
                    if let data = activeData {
                        let history = SubscriptionHistory.compute(
                            for: subscription,
                            allItems: data.allItems,
                            months: data.months,
                            today: session.today,
                            config: data.bundle.layerConfig,
                            layers: data.bundle.layers
                        )
                        heroCard(history: history)
                        historySparklineCard(history: history)
                        actionsCard(history: history)
                        recentChargesCard(history: history)
                    } else {
                        NoDataView()
                    }
                }
                .verticalScrollPage()
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .background(Theme.page)
            .navigationTitle(MaskedMoney.redactText(subscription.entry.name, masked: privacyMasked))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $inspectedPayment) { inspected in
                if let data = activeData {
                    PaymentDetailSheet(item: inspected.item, data: data)
                }
            }
            .sheet(isPresented: $showingAddReminder) {
                let nextDate = JST.addingDays(14, to: session.today) ?? session.today
                let viaText = MaskedMoney.redactText(subscription.entry.via ?? "card", masked: privacyMasked)
                AddReminderSheet(
                    defaultTitle: "Review or cancel \(MaskedMoney.redactText(subscription.entry.name, masked: privacyMasked))",
                    defaultDate: nextDate,
                    defaultNote: privacyMasked ? "via \(viaText)" : "\(Money.yen(subscription.entry.monthly))/mo via \(viaText)"
                )
            }
        }
    }

    private func heroCard(history: SubscriptionHistory) -> some View {
        let sub = subscription.entry
        return HeroVaultCard(accentTint: subscription.isOff ? Theme.heroGlow : Theme.heroAccent) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionLabel(MaskedMoney.redactText(sub.via ?? "Subscription", masked: privacyMasked), symbol: "repeat", color: Theme.heroInkMuted)
                    Spacer()
                    if let status = subscription.displayStatus {
                        QuietTag(status, tone: .hero)
                    }
                }

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    HeroMoneyText(amount: sub.monthly, color: Theme.heroInk)
                    Text("/mo")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.heroInkMuted)
                }

                if let delta = history.priceChangeDelta {
                    let up = delta > 0
                    QuietTag(
                        up ? "Price rose \(MaskedMoney.yen(delta, masked: privacyMasked))" : "Price dropped \(MaskedMoney.yen(abs(delta), masked: privacyMasked))",
                        tone: up ? .bad : .good
                    )
                }

                HStack(spacing: 10) {
                    FrostedMetricTile {
                        Text("Annual burn")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(Theme.heroInkMuted)
                        Text(MaskedMoney.yen(history.annualRunRate, masked: privacyMasked))
                            .font(.subheadline.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(Theme.heroInk)
                    }
                    FrostedMetricTile {
                        Text("Last 12 mo actual")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(Theme.heroInkMuted)
                        Text(MaskedMoney.yen(history.last12MonthsSpend, masked: privacyMasked))
                            .font(.subheadline.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(Theme.heroAccent)
                    }
                }
            }
        }
    }

    private func historySparklineCard(history: SubscriptionHistory) -> some View {
        FinanceCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionLabel("12-month history", symbol: "chart.bar.fill")
                    Spacer()
                    Text("\(history.matchedItems.count) charges")
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                }
                if history.monthlyPoints.isEmpty {
                    Text("No matching charges found in statement history yet.")
                        .font(.footnote)
                        .foregroundStyle(Theme.muted)
                } else {
                    PlanSparkline(points: history.monthlyPoints, target: subscription.entry.monthly)
                        .frame(height: 56)
                        .padding(8)
                        .background(Theme.well.opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    if let last = history.lastChargeDate {
                        Text("Last charged \(DayText.long(last))")
                            .font(.caption)
                            .foregroundStyle(Theme.muted)
                    }
                }
            }
        }
    }

    private func actionsCard(history: SubscriptionHistory) -> some View {
        FinanceCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("Actions", symbol: "bolt.fill")
                PrimaryActionButton(title: "Set cancel / review reminder") {
                    showingAddReminder = true
                }
                Button {
                    let token = subscription.entry.name.split(separator: " ").first.map(String.init) ?? subscription.entry.name
                    dismiss()
                    session.openPayments(month: nil, category: nil, query: token)
                } label: {
                    HStack {
                        Text("Show all charges in Payments")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                        Spacer()
                        Image(systemName: "arrow.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(Theme.accentWash, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func recentChargesCard(history: SubscriptionHistory) -> some View {
        FinanceCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel("Matched payments", symbol: "list.bullet")
                if history.matchedItems.isEmpty {
                    Text("No matched ledger entries yet.")
                        .font(.footnote)
                        .foregroundStyle(Theme.muted)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(history.matchedItems.prefix(12).enumerated()), id: \.offset) { idx, item in
                            if idx > 0 {
                                HairlineDivider().padding(.vertical, 9)
                            }
                            Button {
                                inspectedPayment = InspectedPayment(item: item)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(MaskedMoney.redactText(item.merchant, masked: privacyMasked))
                                            .font(.subheadline.weight(.medium))
                                            .foregroundStyle(Theme.ink)
                                            .lineLimit(1)
                                        Text("\(DayText.short(item.date)) · \(item.source)")
                                            .font(.caption)
                                            .foregroundStyle(Theme.muted)
                                    }
                                    Spacer()
                                    Text(MaskedMoney.payment(item.amount, masked: privacyMasked))
                                        .font(.subheadline.weight(.semibold))
                                        .monospacedDigit()
                                        .foregroundStyle(Theme.ink)
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
}

// MARK: - 2. Debt Inspector (Real Ledger Repaid vs Re-Borrowed + Live Balance Editor)

struct DebtDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.privacyMasked) private var privacyMasked
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var session: AppSession

    let debt: DebtEntry

    @State private var editingBalance = false
    @State private var balanceInput = ""
    @State private var inspectedPayment: InspectedPayment?
    @State private var showingPayoffCalculator = false

    private var activeData: FinanceData? {
        session.resolvedData(from: model)
    }

    private var resolvedDebt: DebtEntry {
        activeData?.effectiveDebts.first(where: { $0.name == debt.name }) ?? debt
    }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: Theme.cardSpacing) {
                    if let data = activeData {
                        let current = resolvedDebt
                        let history = DebtHistory.compute(
                            for: current,
                            allItems: data.allItems,
                            config: data.bundle.layerConfig,
                            months: data.months,
                            today: session.today
                        )
                        heroCard(debt: current, history: history)
                        ledgerFlowCard(history: history)
                        actionsCard(debt: current)
                        if !history.recentItems.isEmpty {
                            recentRowsCard(items: history.recentItems)
                        }
                    } else {
                        NoDataView()
                    }
                }
                .verticalScrollPage()
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.page)
            .navigationTitle(debt.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $inspectedPayment) { inspected in
                if let data = activeData {
                    PaymentDetailSheet(item: inspected.item, data: data)
                }
            }
            .sheet(isPresented: $showingPayoffCalculator) {
                DebtPayoffSheet()
            }
            .onChange(of: privacyMasked) { _, masked in
                if masked {
                    editingBalance = false
                    balanceInput = ""
                }
            }
        }
    }

    private func heroCard(debt: DebtEntry, history: DebtHistory) -> some View {
        HeroVaultCard(accentTint: Theme.heroCoral) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionLabel("Current balance", symbol: "percent", color: Theme.heroInkMuted)
                    Spacer()
                    Button(editingBalance ? "Cancel" : "Update balance") {
                        editingBalance.toggle()
                        balanceInput = (editingBalance && !privacyMasked) ? String(debt.balance) : ""
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.heroAccent)
                    .buttonStyle(.plain)
                }

                if editingBalance {
                    HStack(spacing: 10) {
                        TextField("Balance yen", text: $balanceInput)
                            .keyboardType(.numberPad)
                            .font(.title3.weight(.bold))
                            .monospacedDigit()
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .foregroundStyle(Theme.heroInk)
                        Button("Save") {
                            saveBalance(for: debt)
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.heroTop)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Theme.heroAccent, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .buttonStyle(.plain)
                    }
                } else {
                    HeroMoneyText(amount: debt.balance, color: Theme.heroInk)
                }

                if let limit = debt.limit, limit > 0 {
                    let ratio = min(1.0, max(0.0, Double(debt.balance) / Double(limit)))
                    let pct = Int((ratio * 100).rounded())
                    ProgressMeter(
                        ratio: privacyMasked ? 0 : ratio,
                        tint: privacyMasked ? Theme.heroAccent : Theme.heroCoral,
                        track: Color.white.opacity(0.15),
                        height: 6
                    )
                    Text(
                        privacyMasked
                            ? "Limit \(MaskedMoney.yen(limit, masked: true))"
                            : "\(pct)% of \(MaskedMoney.yen(limit, masked: false)) limit used"
                    )
                        .font(.caption)
                        .foregroundStyle(Theme.heroInkMuted)
                }

                HStack(spacing: 10) {
                    FrostedMetricTile {
                        Text("Est. monthly interest")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(Theme.heroInkMuted)
                        Text(MaskedMoney.yen(history.estimatedMonthlyInterest, masked: privacyMasked))
                            .font(.subheadline.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(privacyMasked ? Theme.heroInk : Theme.heroCoral)
                        Text(
                            history.hasExplicitRate
                                ? String(format: "%.1f%% APR · estimate", history.annualRatePercent)
                                : String(format: "Assumed %.0f%% APR (rate not set)", history.annualRatePercent)
                        )
                            .font(.caption2)
                            .foregroundStyle(Theme.heroInkMuted.opacity(0.85))
                    }
                    FrostedMetricTile {
                        Text("YTD net progress")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(Theme.heroInkMuted)
                        Text(MaskedMoney.signed(history.ytdNetProgress, masked: privacyMasked))
                            .font(.subheadline.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(privacyMasked ? Theme.heroInk : (history.ytdNetProgress >= 0 ? Theme.heroAccent : Theme.heroCoral))
                        Text("Repaid minus borrowed")
                            .font(.caption2)
                            .foregroundStyle(Theme.heroInkMuted.opacity(0.85))
                    }
                }
            }
        }
    }

    private func ledgerFlowCard(history: DebtHistory) -> some View {
        FinanceCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel("Monthly repayments vs re-borrows", symbol: "arrow.left.arrow.right")

                HStack(spacing: 10) {
                    MetricWell(tint: Theme.good) {
                        Text("YTD repaid")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(Theme.muted)
                        Text(MaskedMoney.yen(history.ytdRepaid, masked: privacyMasked))
                            .font(.subheadline.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(Theme.good)
                    }
                    MetricWell(tint: Theme.bad) {
                        Text("YTD borrowed")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(Theme.muted)
                        Text(MaskedMoney.yen(history.ytdBorrowed, masked: privacyMasked))
                            .font(.subheadline.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(Theme.bad)
                    }
                }

                let nonZero = history.monthlyFlows.filter { $0.repaid > 0 || $0.borrowed > 0 }
                if nonZero.isEmpty {
                    Text("No matched repayment rows recorded in recent months yet.")
                        .font(.footnote)
                        .foregroundStyle(Theme.muted)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(nonZero.reversed().enumerated()), id: \.element.id) { idx, flow in
                            if idx > 0 {
                                HairlineDivider().padding(.vertical, 8)
                            }
                            HStack {
                                Text(DayText.month(flow.month))
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(Theme.ink)
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text("Net \(MaskedMoney.signed(flow.netProgress, masked: privacyMasked))")
                                        .font(.subheadline.weight(.semibold))
                                        .monospacedDigit()
                                        .foregroundStyle(flow.netProgress >= 0 ? Theme.good : Theme.bad)
                                    Text("Paid \(MaskedMoney.yen(flow.repaid, masked: privacyMasked)) · Borrowed \(MaskedMoney.yen(flow.borrowed, masked: privacyMasked))")
                                        .font(.caption2)
                                        .monospacedDigit()
                                        .foregroundStyle(Theme.muted)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func actionsCard(debt: DebtEntry) -> some View {
        FinanceCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("Tools", symbol: "slider.horizontal.3")
                PrimaryActionButton(title: "Open payoff calculator") {
                    showingPayoffCalculator = true
                }
                Button {
                    let query = debt.name.split(separator: " ").first.map(String.init) ?? debt.name
                    dismiss()
                    session.openPayments(month: nil, category: nil, query: query)
                } label: {
                    HStack {
                        Text("View debt rows in Payments")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                        Spacer()
                        Image(systemName: "arrow.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(Theme.accentWash, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func recentRowsCard(items: [BudgetItem]) -> some View {
        FinanceCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel("Recent activity", symbol: "list.bullet")
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(items.prefix(10).enumerated()), id: \.offset) { idx, item in
                        if idx > 0 {
                            HairlineDivider().padding(.vertical, 8)
                        }
                        Button {
                            inspectedPayment = InspectedPayment(item: item)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(MaskedMoney.redactText(item.merchant, masked: privacyMasked))
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(Theme.ink)
                                        .lineLimit(1)
                                    Text("\(DayText.short(item.date)) · \(item.source)")
                                        .font(.caption)
                                        .foregroundStyle(Theme.muted)
                                }
                                Spacer()
                                Text(MaskedMoney.payment(item.amount, masked: privacyMasked))
                                    .font(.subheadline.weight(.semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(item.amount < 0 ? Theme.bad : Theme.good)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func saveBalance(for debt: DebtEntry) {
        let digits = balanceInput.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(digits), value >= 0 else { return }
        editingBalance = false
        guard !session.isDemo else { return }
        Task {
            try? await model.setDebtBalanceOverride(debtName: debt.name, balance: value)
        }
    }
}

// MARK: - 3. Category Mini-Dashboard (12-Period Sparkline + Live On-Phone Cap Editor)

struct CategoryDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.privacyMasked) private var privacyMasked
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var session: AppSession

    let categoryName: String
    let periodID: String?

    @State private var editingTarget = false
    @State private var targetInput = ""
    @State private var inspectedPayment: InspectedPayment?

    private var activeData: FinanceData? {
        session.resolvedData(from: model)
    }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: Theme.cardSpacing) {
                    if let data = activeData {
                        let periods = data.periods(for: session.periodMode)
                        let totals = data.totals(for: session.periodMode)
                        let selected = periodID.flatMap { id in periods.first(where: { $0.id == id }) } ?? periods.last
                        let history = CategoryHistory.compute(
                            category: categoryName,
                            periods: periods,
                            totalsByPeriod: totals,
                            selectedPeriod: selected,
                            allItems: data.allItems,
                            plan: data.effectivePlan,
                            config: data.bundle.layerConfig,
                            layers: data.bundle.layers
                        )
                        let pace = selected?.paceProgress(on: session.today)

                        heroCard(history: history, pace: pace)
                        targetCard(history: history, pace: pace)
                        trendCard(history: history)
                        recentItemsCard(history: history, selectedPeriod: selected)
                    } else {
                        NoDataView()
                    }
                }
                .verticalScrollPage()
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.page)
            .navigationTitle(categoryName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $inspectedPayment) { inspected in
                if let data = activeData {
                    PaymentDetailSheet(item: inspected.item, data: data)
                }
            }
            .onChange(of: privacyMasked) { _, masked in
                if masked {
                    editingTarget = false
                    targetInput = ""
                }
            }
        }
    }

    private func heroCard(history: CategoryHistory, pace: Double?) -> some View {
        HeroVaultCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel(history.selectedPeriodTitle, symbol: CategoryStyle.forCategory(categoryName).symbol, color: Theme.heroInkMuted)
                HeroMoneyText(amount: history.selectedPeriodTotal, color: Theme.heroInk)
                HStack(spacing: 10) {
                    FrostedMetricTile {
                        Text("Period avg")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(Theme.heroInkMuted)
                        Text(MaskedMoney.yen(history.averagePerPeriod, masked: privacyMasked))
                            .font(.subheadline.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(Theme.heroInk)
                    }
                    FrostedMetricTile {
                        Text("\(history.transactionCount) visits · avg")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(Theme.heroInkMuted)
                        Text(MaskedMoney.yen(history.averageTransaction, masked: privacyMasked))
                            .font(.subheadline.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(Theme.heroAccent)
                    }
                }
            }
        }
    }

    private func targetCard(history: CategoryHistory, pace: Double?) -> some View {
        FinanceCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionLabel("Monthly target", symbol: "target")
                    Spacer()
                    Button(editingTarget ? "Cancel" : (history.currentTarget == nil ? "Set cap" : "Edit cap")) {
                        editingTarget.toggle()
                        targetInput = (editingTarget && !privacyMasked) ? String(history.currentTarget ?? history.averagePerPeriod) : ""
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .buttonStyle(.plain)
                }

                if editingTarget {
                    HStack(spacing: 8) {
                        TextField("Monthly cap yen", text: $targetInput)
                            .keyboardType(.numberPad)
                            .font(.headline.weight(.semibold))
                            .monospacedDigit()
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Theme.well, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        Button("Save") {
                            saveTarget()
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .buttonStyle(.plain)
                    }
                    if model.localModifications.targetOverrides[categoryName] != nil {
                        Button("Reset to PC default", role: .destructive) {
                            editingTarget = false
                            guard !session.isDemo else { return }
                            Task { try? await model.setTargetOverride(category: categoryName, target: nil) }
                        }
                        .font(.caption)
                    }
                } else if let target = history.currentTarget, target > 0 {
                    let ratio = Double(max(0, history.selectedPeriodTotal)) / Double(target)
                    let tint: Color = privacyMasked
                        ? Theme.accent
                        : (history.selectedPeriodTotal > target ? Theme.bad : (ratio >= 0.8 ? Theme.warn : Theme.good))
                    HStack {
                        Text("\(MaskedMoney.yen(history.selectedPeriodTotal, masked: privacyMasked)) spent")
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle((!privacyMasked && history.selectedPeriodTotal > target) ? Theme.bad : Theme.ink)
                        Spacer()
                        Text("Cap \(MaskedMoney.yen(target, masked: privacyMasked))")
                            .font(.caption.weight(.medium))
                            .monospacedDigit()
                            .foregroundStyle(Theme.muted)
                    }
                    ProgressMeter(ratio: privacyMasked ? 0 : ratio, tint: tint, height: 7, paceRatio: pace)
                    if pace != nil {
                        Text("The vertical notch marks today's position in this period.")
                            .font(.caption2)
                            .foregroundStyle(Theme.muted)
                    }
                } else {
                    Text("No cap set yet. Tap Set cap to track a monthly target on your phone and sync it back to your PC.")
                        .font(.footnote)
                        .foregroundStyle(Theme.muted)
                }
            }
        }
    }

    private func trendCard(history: CategoryHistory) -> some View {
        FinanceCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("12-period trend", symbol: "chart.bar.fill")
                PlanSparkline(points: history.points, target: history.currentTarget)
                    .frame(height: 58)
                    .padding(8)
                    .background(Theme.well.opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private func recentItemsCard(history: CategoryHistory, selectedPeriod: BudgetPeriod?) -> some View {
        FinanceCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionLabel("Payments in period", symbol: "list.bullet")
                    Spacer()
                    Button("Open in Payments") {
                        dismiss()
                        if let p = selectedPeriod {
                            if p.mode == .payCycle {
                                session.openPayments(cycleID: p.id, category: categoryName)
                            } else {
                                session.openPayments(month: p.id, category: categoryName)
                            }
                        } else {
                            session.openPayments(month: nil, category: categoryName)
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .buttonStyle(.plain)
                }

                if history.periodItems.isEmpty {
                    Text("No payments in this period.")
                        .font(.footnote)
                        .foregroundStyle(Theme.muted)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(history.periodItems.prefix(15).enumerated()), id: \.offset) { idx, item in
                            if idx > 0 { HairlineDivider().padding(.vertical, 8) }
                            Button {
                                inspectedPayment = InspectedPayment(item: item)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(MaskedMoney.redactText(item.merchant, masked: privacyMasked))
                                            .font(.subheadline.weight(.medium))
                                            .foregroundStyle(Theme.ink)
                                            .lineLimit(1)
                                        Text("\(DayText.short(item.date)) · \(item.source)")
                                            .font(.caption)
                                            .foregroundStyle(Theme.muted)
                                    }
                                    Spacer()
                                    Text(MaskedMoney.payment(item.amount, masked: privacyMasked))
                                        .font(.subheadline.weight(.semibold))
                                        .monospacedDigit()
                                        .foregroundStyle(Theme.ink)
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

    private func saveTarget() {
        let digits = targetInput.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(digits), value >= 0 else { return }
        editingTarget = false
        guard !session.isDemo else { return }
        Task {
            try? await model.setTargetOverride(category: categoryName, target: value)
        }
    }
}

// MARK: - 4. Merchant Mini-Dashboard

struct MerchantDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.privacyMasked) private var privacyMasked
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var session: AppSession

    let merchantName: String
    let periodID: String?

    @State private var inspectedPayment: InspectedPayment?

    private var activeData: FinanceData? {
        session.resolvedData(from: model)
    }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: Theme.cardSpacing) {
                    if let data = activeData {
                        let periods = data.periods(for: session.periodMode)
                        let selected = periodID.flatMap { id in periods.first(where: { $0.id == id }) } ?? periods.last
                        let history = MerchantHistory.compute(
                            merchant: merchantName,
                            periods: periods,
                            selectedPeriod: selected,
                            allItems: data.allItems
                        )

                        HeroVaultCard {
                            VStack(alignment: .leading, spacing: 12) {
                                SectionLabel(history.category, symbol: "storefront.fill", color: Theme.heroInkMuted)
                                HeroMoneyText(amount: history.selectedPeriodTotal, color: Theme.heroInk)
                                Text("\(history.selectedPeriodTitle) · \(history.sources.joined(separator: ", "))")
                                    .font(.caption)
                                    .foregroundStyle(Theme.heroInkMuted)
                                HStack(spacing: 10) {
                                    FrostedMetricTile {
                                        Text("All-time total")
                                            .font(.caption2.weight(.medium))
                                            .foregroundStyle(Theme.heroInkMuted)
                                        Text(MaskedMoney.yen(history.allTimeTotal, masked: privacyMasked))
                                            .font(.subheadline.weight(.bold))
                                            .monospacedDigit()
                                            .foregroundStyle(Theme.heroInk)
                                    }
                                    FrostedMetricTile {
                                        Text("\(history.visitCount) visits · avg")
                                            .font(.caption2.weight(.medium))
                                            .foregroundStyle(Theme.heroInkMuted)
                                        Text(MaskedMoney.yen(history.averageVisit, masked: privacyMasked))
                                            .font(.subheadline.weight(.bold))
                                            .monospacedDigit()
                                            .foregroundStyle(Theme.heroAccent)
                                    }
                                }
                            }
                        }

                        FinanceCard {
                            VStack(alignment: .leading, spacing: 10) {
                                SectionLabel("12-period spend", symbol: "chart.bar.fill")
                                PlanSparkline(points: history.points, target: nil)
                                    .frame(height: 54)
                                    .padding(8)
                                    .background(Theme.well.opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                        }

                        FinanceCard {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    SectionLabel("Recent visits", symbol: "list.bullet")
                                    Spacer()
                                    Button("All in Payments") {
                                        dismiss()
                                        session.openPayments(month: nil, category: nil, query: history.merchant)
                                    }
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Theme.accent)
                                    .buttonStyle(.plain)
                                }

                                VStack(alignment: .leading, spacing: 0) {
                                    ForEach(Array(history.recentItems.prefix(15).enumerated()), id: \.offset) { idx, item in
                                        if idx > 0 { HairlineDivider().padding(.vertical, 8) }
                                        Button {
                                            inspectedPayment = InspectedPayment(item: item)
                                        } label: {
                                            HStack {
                                                VStack(alignment: .leading, spacing: 2) {
                                                    Text(DayText.long(item.date))
                                                        .font(.subheadline.weight(.medium))
                                                        .foregroundStyle(Theme.ink)
                                                    Text("\(item.category) · \(item.source)")
                                                        .font(.caption)
                                                        .foregroundStyle(Theme.muted)
                                                }
                                                Spacer()
                                                Text(MaskedMoney.payment(item.amount, masked: privacyMasked))
                                                    .font(.subheadline.weight(.semibold))
                                                    .monospacedDigit()
                                                    .foregroundStyle(Theme.ink)
                                            }
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    } else {
                        NoDataView()
                    }
                }
                .verticalScrollPage()
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .background(Theme.page)
            .navigationTitle(MaskedMoney.redactText(merchantName, masked: privacyMasked))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $inspectedPayment) { inspected in
                if let data = activeData {
                    PaymentDetailSheet(item: inspected.item, data: data)
                }
            }
        }
    }
}

// MARK: - 5. Add Custom Reminder / Bill Sheet

struct AddReminderSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var session: AppSession

    let defaultTitle: String?
    let defaultDate: String?
    let defaultNote: String?

    @State private var title = ""
    @State private var isEvent = true
    @State private var amountText = ""
    @State private var date = Date()
    @State private var note = ""
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title (e.g. Cancel plan, Water slip)", text: $title)
                        .font(.subheadline)
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                        .font(.subheadline)
                        .environment(\.timeZone, JST.timeZone)
                        .environment(\.calendar, DayText.calendar)
                    Toggle("Reminder event only (no yen amount)", isOn: $isEvent)
                        .font(.subheadline)
                        .tint(Theme.accent)
                    if !isEvent {
                        HStack {
                            Text("¥")
                                .foregroundStyle(Theme.muted)
                            TextField("Amount", text: $amountText)
                                .keyboardType(.numberPad)
                                .monospacedDigit()
                        }
                    }
                    TextField("Note (optional)", text: $note)
                        .font(.subheadline)
                } header: {
                    SectionLabel("Coming up reminder")
                } footer: {
                    Text("Appears in Coming up, triggers local bill reminders, and syncs back to your PC via encrypted Drive.")
                        .font(.footnote)
                        .foregroundStyle(Theme.muted)
                }
                .listRowBackground(Theme.surface)
            }
            .scrollContentBackground(.hidden)
            .background(Theme.page)
            .navigationTitle("Add reminder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") {
                        save()
                    }
                    .fontWeight(.semibold)
                    .disabled(saving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                if let defaultTitle { title = defaultTitle }
                if let defaultDate, let parsed = DayText.date(defaultDate) { date = parsed }
                if let defaultNote { note = defaultNote }
            }
        }
    }

    private func save() {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return }
        let amount = isEvent ? 0 : (Int(amountText.replacingOccurrences(of: ",", with: "")) ?? 0)
        let cleanNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let reminder = CustomReminder(
            date: JST.day(date),
            title: cleanTitle,
            amount: amount,
            note: cleanNote.isEmpty ? nil : cleanNote,
            isEvent: isEvent
        )
        if session.isDemo {
            dismiss()
            return
        }
        saving = true
        Task {
            defer { saving = false }
            try? await model.addCustomReminder(reminder)
            dismiss()
        }
    }
}

// MARK: - 6. Live Bank Cash Breakdown Sheet

/// Line-by-line transparent breakdown showing exactly how `Until payday` is computed from real bank balances.
struct BankCashBreakdownSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.privacyMasked) private var privacyMasked
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var session: AppSession

    let liveCash: LiveCashSummary
    let payday: PaydayView?
    let onOpenRunway: () -> Void

    @State private var refreshing = false

    var body: some View {
        NavigationStack {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: Theme.cardSpacing) {
                    HeroVaultCard(accentTint: (!privacyMasked && liveCash.cashLeftUntilPayday < 0) ? Theme.heroCoral : Theme.heroGlow) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                SectionLabel("Live bank cash math", symbol: "building.columns.fill", color: Theme.heroInkMuted)
                                Spacer()
                                if liveCash.isEstimate {
                                    QuietTag("Estimate", tone: .hero)
                                }
                            }
                            HeroMoneyText(
                                amount: liveCash.cashLeftUntilPayday,
                                color: (!privacyMasked && liveCash.cashLeftUntilPayday < 0) ? Theme.heroCoral : Theme.heroInk
                            )
                            if let payday {
                                Text("Cash left until \(DayText.long(payday.next.date)) after all unsettled bills.")
                                    .font(.footnote)
                                    .foregroundStyle(Theme.heroInkMuted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }

                    FinanceCard {
                        VStack(alignment: .leading, spacing: 12) {
                            SectionLabel("Bank accounts", symbol: "banknote")
                            ForEach(Array(liveCash.accounts.enumerated()), id: \.element.id) { index, acc in
                                if index > 0 {
                                    HairlineDivider()
                                }
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(alignment: .firstTextBaseline) {
                                        Text(acc.label)
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(Theme.ink)
                                        Spacer()
                                        Text(MaskedMoney.yen(acc.estimatedBalance, masked: privacyMasked))
                                            .font(.subheadline.weight(.bold))
                                            .monospacedDigit()
                                            .foregroundStyle(privacyMasked ? Theme.ink : (acc.estimatedBalance < 0 ? Theme.bad : Theme.good))
                                    }
                                    breakdownSubRow(
                                        label: "Confirmed balance (through \(DayText.short(acc.asOf)))",
                                        value: MaskedMoney.yen(acc.confirmedBalance, masked: privacyMasked)
                                    )
                                    if acc.postCoverageDelta != 0 {
                                        breakdownSubRow(
                                            label: "Bank rows since \(DayText.short(acc.asOf))",
                                            value: MaskedMoney.signed(acc.postCoverageDelta, masked: privacyMasked),
                                            color: acc.postCoverageDelta < 0 ? Theme.ink2 : Theme.good
                                        )
                                    }
                                    if acc.pendingDebitOutflow != 0 {
                                        breakdownSubRow(
                                            label: "Unsettled debit notices",
                                            value: MaskedMoney.signed(-acc.pendingDebitOutflow, masked: privacyMasked),
                                            color: Theme.accent
                                        )
                                    }
                                }
                            }
                            HairlineDivider()
                            HStack {
                                Text("Total estimated cash in banks")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Theme.ink)
                                Spacer()
                                Text(MaskedMoney.yen(liveCash.estimatedBankCash, masked: privacyMasked))
                                    .font(.subheadline.weight(.bold))
                                    .monospacedDigit()
                                    .foregroundStyle(Theme.ink)
                            }
                        }
                    }

                    FinanceCard {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionLabel("Until next payday", symbol: "equal.circle")
                            breakdownRow(
                                label: "Estimated cash in banks",
                                value: MaskedMoney.yen(liveCash.estimatedBankCash, masked: privacyMasked),
                                color: Theme.ink
                            )
                            if liveCash.remainingInflowsSum > 0 {
                                breakdownRow(
                                    label: "Expected inflows before payday",
                                    value: MaskedMoney.signed(liveCash.remainingInflowsSum, masked: privacyMasked),
                                    color: Theme.good
                                )
                            }
                            if liveCash.estimatedInflowsSum > 0 {
                                breakdownRow(
                                    label: "Estimated inflows (not counted yet)",
                                    value: MaskedMoney.signed(liveCash.estimatedInflowsSum, masked: privacyMasked),
                                    color: Theme.muted
                                )
                            }
                            breakdownRow(
                                label: "Unpaid scheduled bills (\(liveCash.remainingBillsCount))",
                                value: MaskedMoney.signed(-liveCash.remainingBillsSum, masked: privacyMasked),
                                color: Theme.ink2
                            )
                            if liveCash.phoneCheckedBillsSum > 0 {
                                breakdownRow(
                                    label: "Marked paid on phone (awaiting bank debit)",
                                    value: MaskedMoney.signed(-liveCash.phoneCheckedBillsSum, masked: privacyMasked),
                                    color: Theme.muted
                                )
                            }
                            HairlineDivider()
                            HStack {
                                Text("Cash left until payday")
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(Theme.ink)
                                Spacer()
                                Text(MaskedMoney.yen(liveCash.cashLeftUntilPayday, masked: privacyMasked))
                                    .font(.headline.weight(.bold))
                                    .monospacedDigit()
                                    .foregroundStyle(privacyMasked ? Theme.ink : (liveCash.cashLeftUntilPayday < 0 ? Theme.bad : Theme.good))
                            }
                            Text("Deferred credit card purchases are not subtracted here because they leave your bank on next month's scheduled card bill.")
                                .font(.caption)
                                .foregroundStyle(Theme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 2)
                        }
                    }

                    FinanceCard {
                        VStack(spacing: 10) {
                            PrimaryActionButton(title: "Open 90-day runway & What-If") {
                                onOpenRunway()
                            }
                            if !session.isDemo {
                                Button {
                                    refreshing = true
                                    Task {
                                        defer { refreshing = false }
                                        await model.syncGmail()
                                    }
                                } label: {
                                    HStack(spacing: 6) {
                                        if refreshing {
                                            ProgressView().controlSize(.small).tint(Theme.accent)
                                        } else {
                                            Image(systemName: "arrow.clockwise")
                                                .font(.caption.weight(.semibold))
                                        }
                                        Text(refreshing ? "Refreshing…" : "Refresh bank & email sync")
                                            .font(.subheadline.weight(.medium))
                                    }
                                    .foregroundStyle(Theme.accent)
                                    .frame(maxWidth: .infinity, minHeight: 40)
                                    .background(Theme.accentWash, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }
                                .buttonStyle(TactileCardButtonStyle())
                                .disabled(refreshing)
                            }
                        }
                    }
                }
                .verticalScrollPage()
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .background(Theme.page)
            .navigationTitle("Bank cash breakdown")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    private func breakdownSubRow(label: String, value: String, color: Color = Theme.muted) -> some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(value)
                        .font(.caption.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(color)
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Text(value)
                        .font(.caption.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(color)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
        }
    }

    private func breakdownRow(label: String, value: String, color: Color) -> some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.subheadline)
                        .foregroundStyle(Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(value)
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(color)
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(label)
                        .font(.subheadline)
                        .foregroundStyle(Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Text(value)
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(color)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
        }
    }
}
