import FinanceCore
import SwiftUI

/// Identifiable wrapper so sheets can inspect any `BudgetItem` without retroactive protocol conformances.
struct InspectedPayment: Identifiable {
    let id = UUID()
    let item: BudgetItem
}

/// Detailed transaction inspector with notice metadata, merchant history and on-device re-categorization.
struct PaymentDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.privacyMasked) private var privacyMasked
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var session: AppSession

    let item: BudgetItem
    let data: FinanceData
    var onCategorySaved: (() -> Void)? = nil

    @State private var selectedCategory: String
    @State private var selectedGroup: String
    @State private var applyToAllMerchant = true
    @State private var showingCategoryEditor = false
    @State private var confirmDelete = false
    @State private var feedback: String?

    init(item: BudgetItem, data: FinanceData, onCategorySaved: (() -> Void)? = nil) {
        self.item = item
        self.data = data
        self.onCategorySaved = onCategorySaved
        _selectedCategory = State(initialValue: item.category)
        _selectedGroup = State(initialValue: item.group)
    }

    private var counted: Bool {
        data.layer(of: item) != nil
    }

    private var isLocal: Bool {
        data.isLocalItem(item)
    }

    private var localEntryID: UUID? {
        data.localEntryID(for: item)
    }

    private var matchedNotice: Notice? {
        data.matchedNotice(for: item)
    }

    private var merchantHistory: [BudgetItem] {
        let key = TextFold.key(item.merchant)
        guard !key.isEmpty else { return [] }
        return data.allItems
            .filter { TextFold.key($0.merchant) == key }
            .sorted { ($0.date, $0.amount) > ($1.date, $1.amount) }
    }

    private var historyTotal: Int {
        merchantHistory.reduce(0) { $0 + $1.amount }
    }

    private var historyAverage: Int {
        let positives = merchantHistory.filter { $0.amount > 0 }
        guard !positives.isEmpty else { return 0 }
        let sum = positives.reduce(0) { $0 + $1.amount }
        return Int((Double(sum) / Double(positives.count)).rounded())
    }

    var body: some View {
        NavigationStack {
            List {
                // Hero amount & verbatim merchant name with category medallion
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .center, spacing: 14) {
                            CategoryBadge(category: item.amount < 0 ? "Salary" : item.category, size: 48)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(MaskedMoney.redactText(item.merchant, masked: privacyMasked))
                                    .font(.headline.weight(.semibold))
                                    .foregroundStyle(Theme.ink)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text("\(item.category) · \(item.source)")
                                    .font(.caption)
                                    .foregroundStyle(Theme.muted)
                            }
                        }

                        HeroMoneyText(
                            amount: item.amount < 0 ? -item.amount : item.amount,
                            color: item.amount < 0 ? Theme.good : Theme.ink,
                            signed: item.amount < 0
                        )

                        FlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                            if item.isPending {
                                QuietTag("Pending email notice", tone: .accent)
                            } else if isLocal {
                                QuietTag("Saved on phone", tone: .accent)
                            } else {
                                QuietTag("Confirmed", tone: .good)
                            }
                            if let layer = data.layer(of: item) {
                                QuietTag(layer, tone: .neutral)
                            } else {
                                QuietTag("Not spending (\(item.group))", tone: .neutral)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
                .listRowBackground(Theme.surface)

                // Core details & notice metadata
                Section {
                    SettingsValueRow(label: "Date", value: DayText.long(item.date))
                    if let occurredAt = matchedNotice?.occurredAt, occurredAt.count >= 16 {
                        SettingsValueRow(label: "Time", value: String(occurredAt.dropFirst(11).prefix(5)) + " JST")
                    }
                    SettingsValueRow(label: "Source", value: item.source)
                    SettingsValueRow(label: "Category", value: item.category)
                    SettingsValueRow(label: "Group", value: item.group)

                    if let foreign = matchedNotice?.foreignAmount, !foreign.isEmpty {
                        SettingsValueRow(label: "Original amount", value: privacyMasked ? "•••" : foreign)
                    }
                    if let ref = matchedNotice?.reference, !ref.isEmpty {
                        SettingsValueRow(label: "Reference", value: ref, monospaced: true, selectable: true)
                    }
                    if let parts = matchedNotice?.parts, !parts.isEmpty {
                        ForEach(parts.keys.sorted(), id: \.self) { key in
                            if let partVal = parts[key] {
                                SettingsValueRow(label: "Split · \(key.capitalized)", value: MaskedMoney.yen(partVal, masked: privacyMasked))
                            }
                        }
                    }
                } header: {
                    SectionLabel("Details")
                }
                .listRowBackground(Theme.surface)

                // Re-categorize directly on the phone
                Section {
                    DisclosureGroup("Change category", isExpanded: $showingCategoryEditor) {
                        Picker("Category", selection: $selectedCategory) {
                            ForEach(data.availableCategories, id: \.category) { option in
                                Text(option.category).tag(option.category)
                            }
                        }
                        .font(.subheadline)
                        .foregroundStyle(Theme.ink)
                        .onChange(of: selectedCategory) { _, newCat in
                            if let match = data.availableCategories.first(where: { $0.category == newCat }) {
                                selectedGroup = match.group
                            }
                        }

                        Toggle("Apply to all payments at this shop", isOn: $applyToAllMerchant)
                            .font(.subheadline)
                            .foregroundStyle(Theme.ink)
                            .tint(Theme.accent)

                        PrimaryActionButton(title: "Save category") {
                            saveCategory()
                        }
                        .disabled(selectedCategory == item.category && selectedGroup == item.group)
                        .padding(.vertical, 4)
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accent)

                    if let feedback {
                        Text(feedback)
                            .font(.footnote)
                            .foregroundStyle(Theme.good)
                    }
                } header: {
                    SectionLabel("Category")
                } footer: {
                    Text("Saved locally on this phone. Totals in Months, Payments and targets update right away.")
                        .font(.footnote)
                        .foregroundStyle(Theme.muted)
                }
                .listRowBackground(Theme.surface)

                // Merchant history
                if merchantHistory.count > 1 {
                    Section {
                        SettingsValueRow(label: "All-time total", value: MaskedMoney.yen(historyTotal, masked: privacyMasked))
                        SettingsValueRow(label: "Payments", value: "\(merchantHistory.count)")
                        if historyAverage > 0 {
                            SettingsValueRow(label: "Average payment", value: MaskedMoney.yen(historyAverage, masked: privacyMasked))
                        }
                        ForEach(Array(merchantHistory.prefix(5).enumerated()), id: \.offset) { _, row in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(DayText.short(row.date))
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(Theme.ink)
                                    Text(row.source)
                                        .font(.caption)
                                        .foregroundStyle(Theme.muted)
                                }
                                Spacer()
                                Text(MaskedMoney.payment(row.amount, masked: privacyMasked))
                                    .font(.subheadline.weight(.semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(row.amount < 0 ? Theme.good : Theme.ink)
                            }
                        }
                        Button {
                            let shop = item.merchant
                            dismiss()
                            session.openPayments(month: nil, category: nil, query: shop)
                        } label: {
                            Text("See all \(merchantHistory.count) payments at this shop")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.accent)
                        }
                    } header: {
                        SectionLabel("Merchant history")
                    }
                    .listRowBackground(Theme.surface)
                }

                // Delete action for manual / imported entries
                if let entryID = localEntryID {
                    Section {
                        Button(role: .destructive) {
                            confirmDelete = true
                        } label: {
                            Text("Delete local entry")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.bad)
                        }
                        .confirmationDialog(
                            "Delete this local payment?",
                            isPresented: $confirmDelete,
                            titleVisibility: .visible
                        ) {
                            Button("Delete", role: .destructive) {
                                deleteEntry(id: entryID)
                            }
                            Button("Cancel", role: .cancel) {}
                        }
                    }
                    .listRowBackground(Theme.surface)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.page)
            .navigationTitle("Payment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func saveCategory() {
        if session.isDemo {
            feedback = "Saved in demo mode"
            showingCategoryEditor = false
            return
        }
        Task {
            do {
                try await model.setCategoryOverride(
                    for: item,
                    group: selectedGroup,
                    category: selectedCategory,
                    applyToAllFromMerchant: applyToAllMerchant
                )
                feedback = applyToAllMerchant
                    ? "Updated all payments at this shop to \(selectedCategory)"
                    : "Updated this payment to \(selectedCategory)"
                showingCategoryEditor = false
                onCategorySaved?()
            } catch {
                feedback = error.localizedDescription
            }
        }
    }

    private func deleteEntry(id: UUID) {
        if session.isDemo {
            dismiss()
            return
        }
        Task {
            try? await model.deleteLocalEntry(id: id)
            dismiss()
        }
    }
}
