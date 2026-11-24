import FinanceCore
import SwiftUI

/// Interactive arithmetic payoff calculator for tracked debts (transparent loan math, no investment advice).
struct DebtPayoffSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.privacyMasked) private var privacyMasked
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var session: AppSession

    @State private var selectedIndex = 0
    @State private var annualRate: Double = 15.0
    @State private var monthlyPayment: Double = 15000
    @State private var extraPayment: Double = 10000

    private var activeData: FinanceData? {
        session.resolvedData(from: model)
    }

    private var debts: [DebtEntry] {
        activeData?.effectiveDebts ?? []
    }

    private var currentDebt: DebtEntry? {
        guard debts.indices.contains(selectedIndex) else { return debts.first }
        return debts[selectedIndex]
    }

    private var startMonth: String {
        String(session.today.prefix(7))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.cardSpacing) {
                    if let debt = currentDebt {
                        if debts.count > 1 {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(Array(debts.enumerated()), id: \.offset) { idx, entry in
                                        FilterChip(title: entry.name, isSelected: idx == selectedIndex) {
                                            selectedIndex = idx
                                            loadDefaults(for: entry)
                                        }
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }

                        let comparison = SpendingInsights.compareDebtPayoff(
                            balance: debt.balance,
                            annualRatePercent: annualRate,
                            basePayment: Int(monthlyPayment.rounded()),
                            extraPayment: Int(extraPayment.rounded()),
                            startMonth: startMonth
                        )

                        summaryCard(debt: debt, comparison: comparison)
                        controlsCard(debt: debt)
                        comparisonCard(comparison: comparison)
                    } else {
                        StateCard(
                            kind: .empty,
                            title: "No debts recorded",
                            message: "When debt balances are in your data file, you can model payoff timelines here."
                        )
                    }
                }
                .padding(.horizontal, Theme.screenPadding)
                .padding(.vertical, 12)
            }
            .background(Theme.page)
            .navigationTitle("Payoff calculator")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                if let first = currentDebt {
                    loadDefaults(for: first)
                }
            }
        }
    }

    private func summaryCard(debt: DebtEntry, comparison: DebtPayoffComparison) -> some View {
        HeroVaultCard(accentTint: Theme.heroCoral) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionLabel(debt.name, symbol: "percent", color: Theme.heroInkMuted)
                    Spacer()
                    QuietTag("Estimate", tone: .hero)
                }
                HeroMoneyText(amount: debt.balance, color: Theme.heroInk)
                Text("Monthly interest at \(String(format: "%.1f", annualRate))% is about \(MaskedMoney.yen(comparison.baseline.firstMonthInterest, masked: privacyMasked)) right now.")
                    .font(.footnote)
                    .foregroundStyle(Theme.heroInkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func controlsCard(debt: DebtEntry) -> some View {
        let maxBase = max(50_000.0, Double(debt.balance) / 2.0)
        return FinanceCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionLabel("Assumptions", symbol: "slider.horizontal.3")

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Annual rate")
                            .font(.subheadline)
                            .foregroundStyle(Theme.ink2)
                        Spacer()
                        Text(String(format: "%.1f%%", annualRate))
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(Theme.ink)
                    }
                    Slider(value: $annualRate, in: 0...20, step: 0.5)
                        .tint(Theme.accent)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Base monthly payment")
                            .font(.subheadline)
                            .foregroundStyle(Theme.ink2)
                        Spacer()
                        Text(MaskedMoney.yen(Int(monthlyPayment.rounded()), masked: privacyMasked))
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(Theme.ink)
                    }
                    Slider(value: $monthlyPayment, in: 5_000...maxBase, step: 1_000)
                        .tint(Theme.accent)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Extra each month")
                            .font(.subheadline)
                            .foregroundStyle(Theme.ink2)
                        Spacer()
                        Text("+\(MaskedMoney.yen(Int(extraPayment.rounded()), masked: privacyMasked))")
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(Theme.good)
                    }
                    Slider(value: $extraPayment, in: 0...100_000, step: 1_000)
                        .tint(Theme.good)
                }
            }
        }
    }

    private func comparisonCard(comparison: DebtPayoffComparison) -> some View {
        FinanceCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel("Projected payoff", symbol: "calendar.badge.checkmark")

                if let baseMonths = comparison.baseline.monthsToPayoff,
                   let baseInterest = comparison.baseline.totalInterest
                {
                    LedgerRow(
                        title: "At \(MaskedMoney.yen(comparison.baseline.monthlyPayment, masked: privacyMasked))/mo",
                        detail: comparison.baseline.payoffMonth.map { "Paid off around \(DayText.month($0)) · interest \(MaskedMoney.yen(baseInterest, masked: privacyMasked))" },
                        value: "\(baseMonths) mo",
                        accessibilityValue: "\(baseMonths) months",
                        valueColor: Theme.ink
                    )
                } else {
                    Text("At \(MaskedMoney.yen(comparison.baseline.monthlyPayment, masked: privacyMasked))/mo, payment does not exceed monthly interest (\(MaskedMoney.yen(comparison.baseline.firstMonthInterest, masked: privacyMasked))).")
                        .font(.footnote)
                        .foregroundStyle(Theme.bad)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if extraPayment > 0 {
                    HairlineDivider()
                    if let accMonths = comparison.accelerated.monthsToPayoff,
                       let accInterest = comparison.accelerated.totalInterest
                    {
                        LedgerRow(
                            title: "With +\(MaskedMoney.yen(Int(extraPayment.rounded()), masked: privacyMasked))/mo (\(MaskedMoney.yen(comparison.accelerated.monthlyPayment, masked: privacyMasked))/mo)",
                            detail: comparison.accelerated.payoffMonth.map { "Paid off around \(DayText.month($0)) · interest \(MaskedMoney.yen(accInterest, masked: privacyMasked))" },
                            value: "\(accMonths) mo",
                            accessibilityValue: "\(accMonths) months",
                            valueColor: Theme.good,
                            emphasized: true
                        )

                        if let monthsSaved = comparison.monthsSaved, let interestSaved = comparison.interestSaved {
                            HStack(spacing: 10) {
                                MetricWell(tint: Theme.good) {
                                    Text("Time saved")
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(Theme.muted)
                                    Text("\(monthsSaved) \(monthsSaved == 1 ? "month" : "months")")
                                        .font(.headline.weight(.bold))
                                        .monospacedDigit()
                                        .foregroundStyle(Theme.good)
                                }
                                MetricWell(tint: Theme.good) {
                                    Text("Interest saved")
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(Theme.muted)
                                    Text(MaskedMoney.yen(interestSaved, masked: privacyMasked))
                                        .font(.headline.weight(.bold))
                                        .monospacedDigit()
                                        .foregroundStyle(Theme.good)
                                }
                            }
                            .padding(.top, 2)
                        }
                    }
                }

                Text("Arithmetic estimate assuming fixed monthly payments and no new borrowing.")
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func loadDefaults(for debt: DebtEntry) {
        annualRate = SpendingInsights.extractAnnualRate(from: debt.lines) ?? 15.0
        let extractedPayment = SpendingInsights.extractMonthlyPayment(from: debt.lines)
            ?? max(10_000, Int((Double(debt.balance) * 0.05 / 1000.0).rounded() * 1000.0))
        monthlyPayment = Double(max(5_000, extractedPayment))
        extraPayment = 10_000
    }
}
