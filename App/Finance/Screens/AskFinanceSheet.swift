import FinanceCore
import SwiftUI
#if canImport(FoundationModels)
import FoundationModels
#endif

/// On-device financial Q&A sheet backed by the exact yen ledger in `FinanceQueryEngine`.
///
/// Runs 100% offline with zero network calls. Every yen amount comes directly from `FinanceCore`.
struct AskFinanceSheet: View {
    struct ConversationTurn: Identifiable {
        let id = UUID()
        let question: String
        let answer: QueryAnswer
        let summaryNote: String?
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var session: AppSession

    @State private var input = ""
    @State private var turns: [ConversationTurn] = []
    @State private var thinking = false

    private var activeData: FinanceData? {
        session.resolvedData(from: model)
    }

    private var queryContext: FinanceQueryEngine.Context? {
        guard let data = activeData else { return nil }
        return FinanceQueryEngine.Context(
            bundle: data.bundle,
            allItems: data.allItems,
            totalsByMonth: data.totalsByMonth,
            timeline: data.timeline,
            payday: data.payday,
            planSummary: data.planSummary,
            subscriptionSummary: data.subscriptionSummary,
            today: session.today
        )
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: Theme.cardSpacing) {
                            if let ctx = queryContext {
                                if turns.isEmpty {
                                    introCard(context: ctx)
                                } else {
                                    ForEach(turns) { turn in
                                        turnView(turn)
                                            .id(turn.id)
                                    }
                                    promptChipsRow(prompts: FinanceQueryEngine.suggestedPrompts(for: ctx))
                                }
                            } else {
                                NoDataView()
                            }
                        }
                        .padding(.horizontal, Theme.screenPadding)
                        .padding(.vertical, 12)
                    }
                    .onChange(of: turns.count) { _, _ in
                        if let lastID = turns.last?.id {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(lastID, anchor: .bottom)
                            }
                        }
                    }
                }

                HairlineDivider()

                HStack(spacing: 10) {
                    TextField("Ask about spending, bills, debt…", text: $input)
                        .font(.subheadline)
                        .foregroundStyle(Theme.ink)
                        .submitLabel(.send)
                        .onSubmit { submit(input) }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                        .background(Theme.surface, in: Capsule())
                        .overlay(
                            Capsule().strokeBorder(Theme.line, lineWidth: 0.75)
                        )

                    Button {
                        submit(input)
                    } label: {
                        let isEmpty = input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || thinking
                        ZStack {
                            Circle()
                                .fill(isEmpty ? Theme.track : Theme.accent)
                                .frame(width: 38, height: 38)
                            Image(systemName: "arrow.up")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(
                                    isEmpty
                                        ? Theme.muted
                                        : (colorScheme == .dark ? Theme.page : Color.white)
                                )
                        }
                    }
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || thinking)
                    .accessibilityLabel("Send question")
                }
                .padding(.horizontal, Theme.screenPadding)
                .padding(.vertical, 10)
                .background(Theme.page)
            }
            .background(Theme.page)
            .navigationTitle("Ask Finance")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                if session.isDemo, turns.isEmpty, let ctx = queryContext {
                    let q = "How much is left until payday?"
                    turns.append(ConversationTurn(
                        question: q,
                        answer: FinanceQueryEngine.answer(q, context: ctx),
                        summaryNote: nil
                    ))
                }
            }
        }
    }

    private func introCard(context: FinanceQueryEngine.Context) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HeroVaultCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        SectionLabel("On-device ledger Q&A", symbol: "text.magnifyingglass", color: Theme.heroInkMuted)
                        Spacer()
                        QuietTag("Offline", tone: .hero)
                    }
                    Text("Ask about any category, shop, month, bill, subscription, debt or cut target.")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(Theme.heroInk)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Every yen comes straight from your local ledger with zero network calls.")
                        .font(.footnote)
                        .foregroundStyle(Theme.heroInkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Try asking")
                    .padding(.horizontal, 4)
                ForEach(FinanceQueryEngine.suggestedPrompts(for: context), id: \.self) { prompt in
                    Button {
                        submit(prompt)
                    } label: {
                        HStack(spacing: 12) {
                            IconMedallion(symbol: "text.bubble.fill", tint: Theme.accent, size: 30)
                            Text(prompt)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Theme.ink)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 8)
                            Image(systemName: "arrow.up.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.muted)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .frame(minHeight: Theme.minTouchTarget)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 15, style: .continuous)
                                .strokeBorder(Theme.line.opacity(0.8), lineWidth: 0.6)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func promptChipsRow(prompts: [String]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(prompts, id: \.self) { prompt in
                    FilterChip(title: prompt, isSelected: false) {
                        submit(prompt)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func turnView(_ turn: ConversationTurn) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Spacer(minLength: 36)
                Text(turn.question)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(colorScheme == .dark ? Theme.page : Color.white)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 10)
                    .background(
                        Theme.accent,
                        in: UnevenRoundedRectangle(
                            topLeadingRadius: 18,
                            bottomLeadingRadius: 18,
                            bottomTrailingRadius: 6,
                            topTrailingRadius: 18,
                            style: .continuous
                        )
                    )
                    .shadow(color: Theme.accent.opacity(0.20), radius: 8, y: 3)
            }

            FinanceCard {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(turn.answer.headline)
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Theme.ink)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(turn.answer.subtitle)
                            .font(.footnote)
                            .foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let summaryNote = turn.summaryNote, !summaryNote.isEmpty {
                        Text(summaryNote)
                            .font(.subheadline)
                            .foregroundStyle(Theme.ink2)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.accentWash, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if !turn.answer.rows.isEmpty {
                        HairlineDivider()
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(turn.answer.rows) { row in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(row.label)
                                            .font(.subheadline.weight(.medium))
                                            .foregroundStyle(Theme.ink)
                                            .fixedSize(horizontal: false, vertical: true)
                                        if let detail = row.detail, !detail.isEmpty {
                                            Text(detail)
                                                .font(.caption)
                                                .foregroundStyle(Theme.muted)
                                        }
                                    }
                                    Spacer(minLength: 8)
                                    Text(row.value)
                                        .font(.subheadline.weight(.semibold))
                                        .monospacedDigit()
                                        .foregroundStyle(Theme.ink)
                                        .fixedSize(horizontal: true, vertical: false)
                                }
                            }
                        }
                    }

                    if let note = turn.answer.note, !note.isEmpty {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let actionTitle = turn.answer.actionTitle, let action = turn.answer.action {
                        Button {
                            perform(action)
                        } label: {
                            HStack(spacing: 6) {
                                Text(actionTitle)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Theme.accent)
                                Spacer()
                                Image(systemName: "arrow.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Theme.accent)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(Theme.accentWash, in: RoundedRectangle(cornerRadius: Theme.innerRadius, style: .continuous))
                            .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func submit(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let ctx = queryContext else { return }
        input = ""
        let exactAnswer = FinanceQueryEngine.answer(trimmed, context: ctx)
        turns.append(ConversationTurn(question: trimmed, answer: exactAnswer, summaryNote: nil))

        // On devices with Apple Intelligence enabled, optionally add a concise one-sentence plain-English takeaway
        // grounded strictly in the exact ledger facts computed above.
        #if canImport(FoundationModels)
        if !session.isDemo, #available(iOS 26.0, *) {
            let turnIndex = turns.count - 1
            Task {
                if let takeaway = await Self.optionalOnDeviceTakeaway(question: trimmed, answer: exactAnswer) {
                    if turns.indices.contains(turnIndex) {
                        turns[turnIndex] = ConversationTurn(
                            question: trimmed,
                            answer: exactAnswer,
                            summaryNote: takeaway
                        )
                    }
                }
            }
        }
        #endif
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private static func optionalOnDeviceTakeaway(question: String, answer: QueryAnswer) async -> String? {
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        guard !answer.rows.isEmpty else { return nil }
        let facts = answer.rows.map { "\($0.label): \($0.value) (\($0.detail ?? ""))" }.joined(separator: "; ")
        let prompt = """
        Summarize this personal finance answer in one short, calm English sentence. Do not invent or round numbers. No emoji or exclamation marks.
        Question: \(question)
        Headline: \(answer.headline) (\(answer.subtitle))
        Facts: \(facts)
        """
        do {
            let modelSession = LanguageModelSession()
            let response = try await modelSession.respond(to: prompt)
            let cleaned = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? nil : cleaned
        } catch {
            return nil
        }
    }
    #endif

    private func perform(_ action: QueryAnswer.Action) {
        dismiss()
        switch action {
        case .openPayments(let month, let category, let query):
            session.openPayments(month: month, category: category, query: query)
        case .openMonths(let month):
            session.openMonths(month: month)
        case .openNow:
            session.selectedTab = .now
        }
    }
}
