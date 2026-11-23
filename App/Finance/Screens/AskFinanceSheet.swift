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
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Theme.line, lineWidth: 0.5)
                        )

                    Button {
                        submit(input)
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(
                                input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || thinking
                                    ? Theme.muted
                                    : Theme.accent
                            )
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
        VStack(alignment: .leading, spacing: 14) {
            FinanceCard {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        SectionLabel("On-device answers")
                        Spacer()
                        QuietTag("Private · offline", tone: .good)
                    }
                    Text("Ask in plain English about any category, shop, month, bill, subscription, debt or cut target. Every yen comes directly from your local ledger.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Try asking")
                    .padding(.horizontal, 2)
                ForEach(FinanceQueryEngine.suggestedPrompts(for: context), id: \.self) { prompt in
                    Button {
                        submit(prompt)
                    } label: {
                        HStack {
                            Text(prompt)
                                .font(.subheadline)
                                .foregroundStyle(Theme.ink)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.muted)
                        }
                        .padding(.horizontal, Theme.cardPadding)
                        .padding(.vertical, 12)
                        .frame(minHeight: Theme.minTouchTarget)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Theme.line, lineWidth: 0.5)
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
        }
    }

    private func turnView(_ turn: ConversationTurn) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(turn.question)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 2)

            FinanceCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text(turn.answer.headline)
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(turn.answer.subtitle)
                        .font(.footnote)
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)

                    if let summaryNote = turn.summaryNote, !summaryNote.isEmpty {
                        Text(summaryNote)
                            .font(.subheadline)
                            .foregroundStyle(Theme.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if !turn.answer.rows.isEmpty {
                        HairlineDivider()
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(turn.answer.rows) { row in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(row.label)
                                            .font(.subheadline)
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
                                        .font(.subheadline.weight(.medium))
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
                        HairlineDivider()
                        Button {
                            perform(action)
                        } label: {
                            HStack(spacing: 6) {
                                Text(actionTitle)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Theme.accent)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Theme.accent)
                            }
                            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
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
