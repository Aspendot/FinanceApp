import FinanceCore
import SwiftUI

/// Fast on-device entry sheet for cash, wallet, or manual payments.
struct QuickAddSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var session: AppSession

    @State private var amountText = ""
    @State private var isMoneyIn = false
    @State private var merchant = ""
    @State private var source = "Cash"
    @State private var selectedGroup = "Living"
    @State private var selectedCategory = "Uncategorized"
    @State private var categoryManuallyPicked = false
    @State private var date = Date()
    @State private var note = ""
    @State private var saving = false
    @State private var errorMessage: String?

    private var activeData: FinanceData? {
        session.resolvedData(from: model)
    }

    private var parsedAmount: Int? {
        let digits = amountText
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "¥", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(digits), value > 0 else { return nil }
        return isMoneyIn ? -value : value
    }

    private var merchantSuggestions: [String] {
        guard let data = activeData else { return [] }
        let trimmed = merchant.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return Array(data.knownMerchants.prefix(8))
        }
        let folded = TextFold.key(trimmed)
        return data.knownMerchants
            .filter {
                $0.localizedCaseInsensitiveContains(trimmed)
                    || (!folded.isEmpty && TextFold.key($0).contains(folded))
            }
            .prefix(6)
            .map { $0 }
    }

    private var sourceOptions: [String] {
        var base = ["Cash", "PayPay", "PayPay Card"]
        if let existing = activeData?.availableSources {
            for s in existing where !base.contains(s) {
                base.append(s)
            }
        }
        return base
    }

    private var categoryOptions: [(group: String, category: String)] {
        let existing = activeData?.availableCategories ?? []
        if existing.isEmpty {
            return [
                ("Living", "Groceries"),
                ("Living", "Dining"),
                ("Living", "Transport"),
                ("Living", "Household"),
                ("Other", "Uncategorized"),
            ]
        }
        return existing
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(isMoneyIn ? "+¥" : "¥")
                            .font(.system(size: 26, weight: .semibold, design: .rounded))
                            .foregroundStyle((isMoneyIn ? Theme.good : Theme.ink).opacity(0.72))
                        TextField("0", text: $amountText)
                            .keyboardType(.numberPad)
                            .font(.system(size: 38, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(isMoneyIn ? Theme.good : Theme.ink)
                    }
                    .padding(.vertical, 4)

                    Picker("Direction", selection: $isMoneyIn) {
                        Text("Money out").tag(false)
                        Text("Money in / refund").tag(true)
                    }
                    .pickerStyle(.segmented)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach([300, 500, 1000, 2000, 5000], id: \.self) { step in
                                Button("+\(Money.yen(step))") {
                                    let current = abs(parsedAmount ?? 0)
                                    amountText = String(current + step)
                                }
                                .font(.caption.weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(Theme.accent)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 6)
                                .background(Theme.accentWash, in: Capsule())
                                .overlay(
                                    Capsule().strokeBorder(Theme.accent.opacity(0.22), lineWidth: 0.6)
                                )
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    SectionLabel("Amount")
                }
                .listRowBackground(Theme.surface)

                Section {
                    HStack(spacing: 10) {
                        CategoryBadge(category: isMoneyIn ? "Salary" : selectedCategory, size: 32)
                        TextField("Shop or description", text: $merchant)
                            .font(.subheadline)
                            .foregroundStyle(Theme.ink)
                            .onChange(of: merchant) { _, newValue in
                                autoCategorize(merchant: newValue)
                            }
                    }

                    if !merchantSuggestions.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(merchantSuggestions, id: \.self) { suggestion in
                                    Button(suggestion) {
                                        merchant = suggestion
                                        autoCategorize(merchant: suggestion)
                                    }
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(Theme.ink2)
                                    .padding(.horizontal, 11)
                                    .padding(.vertical, 6)
                                    .background(Theme.well, in: Capsule())
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }

                    Picker("Category", selection: Binding(
                        get: { selectedCategory },
                        set: { newCategory in
                            selectedCategory = newCategory
                            categoryManuallyPicked = true
                            if let match = categoryOptions.first(where: { $0.category == newCategory }) {
                                selectedGroup = match.group
                            }
                        }
                    )) {
                        ForEach(categoryOptions, id: \.category) { option in
                            Text(option.category).tag(option.category)
                        }
                        if !categoryOptions.contains(where: { $0.category == selectedCategory }) {
                            Text(selectedCategory).tag(selectedCategory)
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(Theme.ink)

                    Picker("Source", selection: $source) {
                        ForEach(sourceOptions, id: \.self) { option in
                            Text(option).tag(option)
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(Theme.ink)

                    DatePicker("Date", selection: $date, displayedComponents: .date)
                        .font(.subheadline)
                        .foregroundStyle(Theme.ink)
                        .environment(\.timeZone, JST.timeZone)
                        .environment(\.calendar, DayText.calendar)

                    TextField("Note (optional)", text: $note)
                        .font(.subheadline)
                        .foregroundStyle(Theme.ink)
                } header: {
                    SectionLabel("Details")
                } footer: {
                    Text("Saved privately on this phone and included in Payments, Months and budget targets.")
                        .font(.footnote)
                        .foregroundStyle(Theme.muted)
                }
                .listRowBackground(Theme.surface)

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(Theme.bad)
                    }
                    .listRowBackground(Theme.surface)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.page)
            .navigationTitle("Add payment")
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
                    .disabled(saving || parsedAmount == nil || merchant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                if let first = categoryOptions.first {
                    selectedCategory = first.category
                    selectedGroup = first.group
                }
            }
        }
    }

    private func autoCategorize(merchant raw: String) {
        guard !categoryManuallyPicked, let data = activeData else { return }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let categorizer = Categorizer(rules: data.bundle.rules)
        let res = categorizer.categorize(merchant: trimmed, amount: parsedAmount ?? 1000, date: JST.day(date))
        if res.category != "Uncategorized" {
            selectedGroup = res.group
            selectedCategory = res.category
        } else if let past = data.allItems.first(where: { TextFold.key($0.merchant) == TextFold.key(trimmed) }) {
            selectedGroup = past.group
            selectedCategory = past.category
        }
    }

    private func save() {
        guard let amount = parsedAmount else { return }
        let trimmedMerchant = merchant.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMerchant.isEmpty else { return }
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)

        let entry = ManualEntry(
            date: JST.day(date),
            source: source,
            merchant: trimmedMerchant,
            amount: amount,
            group: selectedGroup,
            category: selectedCategory,
            note: trimmedNote.isEmpty ? nil : trimmedNote,
            origin: .manual
        )

        if session.isDemo {
            dismiss()
            return
        }

        saving = true
        errorMessage = nil
        Task {
            defer { saving = false }
            do {
                try await model.addManualEntry(entry)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
