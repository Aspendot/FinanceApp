import FinanceCore
import SwiftUI

/// 10-second daily triage queue for new pending bank emails, uncategorized items, and anomalies.
struct ReviewInboxSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.privacyMasked) private var privacyMasked
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var session: AppSession

    @State private var inspectedEntry: ReviewQueueItem?
    @State private var demoClearedIDs: Set<String> = []

    private var activeData: FinanceData? {
        session.resolvedData(from: model)
    }

    private var items: [ReviewQueueItem] {
        let base = activeData?.reviewQueue ?? []
        if session.isDemo {
            return base.filter { !demoClearedIDs.contains($0.id) }
        }
        return base
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.cardSpacing) {
                    headerCard
                    if items.isEmpty {
                        StateCard(
                            kind: .empty,
                            title: "All caught up",
                            message: "No pending notices, uncategorized charges, or anomalies waiting for review."
                        )
                    } else {
                        ForEach(items) { entry in
                            reviewCard(entry)
                        }
                    }
                }
                .padding(.horizontal, Theme.screenPadding)
                .padding(.vertical, 12)
            }
            .background(Theme.page)
            .navigationTitle("Review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !items.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Clear all") {
                            markAllReviewed()
                        }
                        .font(.subheadline.weight(.medium))
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .sheet(item: $inspectedEntry) { entry in
                if let data = activeData, let item = entry.item {
                    PaymentDetailSheet(item: item, data: data) {
                        markSingleReviewed(entry.id)
                    }
                }
            }
        }
    }

    private var headerCard: some View {
        HeroVaultCard(accentTint: items.isEmpty ? Theme.heroAccent : Theme.heroGlow) {
            VStack(alignment: .leading, spacing: 8) {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionLabel("Daily triage", symbol: "tray.full.fill", color: Theme.heroInkMuted)
                        QuietTag(items.isEmpty ? "Clear" : "\(items.count) left", tone: .hero)
                    }
                } else {
                    HStack {
                        SectionLabel("Daily triage", symbol: "tray.full.fill", color: Theme.heroInkMuted)
                        Spacer()
                        QuietTag(items.isEmpty ? "Clear" : "\(items.count) left", tone: .hero)
                    }
                }
                Text(items.isEmpty ? "Ledger is clean" : "\(items.count) \(items.count == 1 ? "item" : "items") to check")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Theme.heroInk)
                Text("Confirm categories in one tap or exclude non-spending charges. Changes sync back to your PC automatically.")
                    .font(.footnote)
                    .foregroundStyle(Theme.heroInkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func reviewCard(_ entry: ReviewQueueItem) -> some View {
        FinanceCard {
            if let item = entry.item {
                itemReviewBody(entry: entry, item: item)
            } else if let alert = entry.alert {
                alertReviewBody(entry: entry, alert: alert)
            }
        }
    }

    private func itemReviewBody(entry: ReviewQueueItem, item: BudgetItem) -> some View {
        let tone: QuietTag.Tone = entry.reason == .uncategorized ? .warn : .accent
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                if !dynamicTypeSize.isAccessibilitySize {
                    CategoryBadge(category: item.category, size: 36)
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.merchant)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(2)
                        Spacer(minLength: 6)
                        Text(MaskedMoney.payment(item.amount, masked: privacyMasked))
                            .font(.subheadline.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(item.amount < 0 ? Theme.good : Theme.ink)
                    }
                    HStack(spacing: 6) {
                        Text("\(DayText.short(item.date)) · \(item.source)")
                            .font(.caption)
                            .foregroundStyle(Theme.muted)
                        Spacer(minLength: 4)
                        QuietTag(entry.reason.rawValue, tone: tone)
                    }
                }
            }

            if !entry.suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Quick categorize")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.muted)
                    FlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                        ForEach(entry.suggestions) { suggestion in
                            let isCurrent = suggestion.category == item.category
                            Button {
                                applyCategory(entry: entry, item: item, suggestion: suggestion)
                            } label: {
                                HStack(spacing: 4) {
                                    if isCurrent {
                                        Image(systemName: "checkmark")
                                            .font(.caption2.weight(.bold))
                                    }
                                    Text(suggestion.category)
                                        .font(.caption.weight(.semibold))
                                }
                                .foregroundStyle(isCurrent ? Theme.good : Theme.accent)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 7)
                                .background(
                                    (isCurrent ? Theme.goodWash : Theme.accentWash),
                                    in: Capsule()
                                )
                                .overlay(
                                    Capsule().strokeBorder(
                                        (isCurrent ? Theme.good : Theme.accent).opacity(0.24),
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

            FlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                Button {
                    markSingleReviewed(entry.id)
                } label: {
                    Label("Looks right", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.good)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .background(Theme.goodWash, in: Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    excludeItem(entry: entry, item: item, label: "Excluded")
                } label: {
                    Label("Exclude", systemImage: "eye.slash")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.ink2)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .background(Theme.well, in: Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    tagWorkItem(entry: entry, item: item)
                } label: {
                    Label("Work", systemImage: "briefcase")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.ink2)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .background(Theme.well, in: Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    inspectedEntry = entry
                } label: {
                    Text("Edit…")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.muted)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func alertReviewBody(entry: ReviewQueueItem, alert: FinanceAlert) -> some View {
        let tone: QuietTag.Tone = alert.severity == .urgent ? .bad : .warn
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                QuietTag(entry.reason.rawValue, tone: tone)
                Text(MaskedMoney.redactText(alert.title, masked: privacyMasked))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(MaskedMoney.redactText(alert.detail, masked: privacyMasked))
                .font(.caption)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)

            HairlineDivider()

            HStack(spacing: 10) {
                Button {
                    if case .openPayments(let month, let category, let query, let onlyUncat) = alert.action {
                        dismiss()
                        session.openPayments(
                            month: month,
                            category: category,
                            query: query,
                            onlyUncategorized: onlyUncat
                        )
                    }
                } label: {
                    Text("Inspect in Payments")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Theme.accentWash, in: Capsule())
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    dismissAlertEntry(entry: entry, alert: alert)
                } label: {
                    Text("Dismiss")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.muted)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Theme.well, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func applyCategory(entry: ReviewQueueItem, item: BudgetItem, suggestion: CategorySuggestion) {
        if session.isDemo {
            withAnimation { _ = demoClearedIDs.insert(entry.id) }
            return
        }
        Task {
            if item.category != suggestion.category || item.group != suggestion.group {
                try? await model.setCategoryOverride(
                    for: item,
                    group: suggestion.group,
                    category: suggestion.category,
                    applyToAllFromMerchant: false
                )
            }
            await model.markReviewed(keys: [entry.id])
        }
    }

    private func excludeItem(entry: ReviewQueueItem, item: BudgetItem, label: String) {
        if session.isDemo {
            withAnimation { _ = demoClearedIDs.insert(entry.id) }
            return
        }
        Task {
            try? await model.excludeAsNonSpending(item: item, categoryLabel: label)
            await model.markReviewed(keys: [entry.id])
        }
    }

    private func tagWorkItem(entry: ReviewQueueItem, item: BudgetItem) {
        if session.isDemo {
            withAnimation { _ = demoClearedIDs.insert(entry.id) }
            return
        }
        Task {
            try? await model.tagAsWorkExpense(item: item)
            await model.markReviewed(keys: [entry.id])
        }
    }

    private func markSingleReviewed(_ id: String) {
        if session.isDemo {
            withAnimation { _ = demoClearedIDs.insert(id) }
            return
        }
        Task { await model.markReviewed(keys: [id]) }
    }

    private func dismissAlertEntry(entry: ReviewQueueItem, alert: FinanceAlert) {
        if session.isDemo {
            withAnimation { _ = demoClearedIDs.insert(entry.id) }
            return
        }
        Task {
            await model.dismissAlert(id: alert.id)
            await model.markReviewed(keys: [entry.id])
        }
    }

    private func markAllReviewed() {
        let keys = items.map(\.id)
        if session.isDemo {
            withAnimation { demoClearedIDs.formUnion(keys) }
            return
        }
        Task { await model.markReviewed(keys: keys) }
    }
}
