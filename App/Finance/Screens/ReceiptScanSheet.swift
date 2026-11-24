import FinanceCore
import PhotosUI
import SwiftUI
import UIKit

/// High-accuracy AI Vision + On-Device Apple Vision receipt, paper slip, and batch screenshot importer.
struct ReceiptScanSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var session: AppSession

    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showingCamera = false
    @State private var previewImage: UIImage?
    @State private var scanning = false
    @State private var engineLabel: String?
    @State private var noteMessage: String?
    @State private var errorMessage: String?
    @State private var drafts: [ReceiptDraft] = []
    @State private var saving = false

    private var activeData: FinanceData? {
        session.resolvedData(from: model)
    }

    private var config: VisionScannerConfig {
        VisionScannerStore.load()
    }

    private var hasConfiguredAIKey: Bool {
        config.preferAIVision && VisionKeyStore.hasKey(for: config.provider)
    }

    private var selectedDrafts: [ReceiptDraft] {
        drafts.filter {
            $0.isSelected
                && $0.amount != 0
                && JST.dayNumber($0.date) != nil
                && !$0.merchant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var categoryOptions: [(group: String, category: String)] {
        let existing = activeData?.availableCategories ?? []
        if existing.isEmpty {
            return [
                ("Living", "Groceries"),
                ("Living", "Dining"),
                ("Bills", "Utilities"),
                ("Living", "Transport"),
                ("Living", "Household"),
                ("Other", "Uncategorized"),
            ]
        }
        return existing
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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.cardSpacing) {
                    captureHeroCard

                    if let previewImage {
                        FinanceCard(padding: 12) {
                            HStack(spacing: 12) {
                                Image(uiImage: previewImage)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 64, height: 84)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(scanning ? "Reading image…" : (engineLabel ?? "Ready"))
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(Theme.ink)
                                    if scanning {
                                        ProgressView().tint(Theme.accent)
                                    } else {
                                        Text("EXIF & location metadata stripped before scanning.")
                                            .font(.caption)
                                            .foregroundStyle(Theme.muted)
                                    }
                                }
                                Spacer()
                            }
                        }
                    }

                    if let errorMessage {
                        StateCard(kind: .error, title: "Scan issue", message: errorMessage)
                    }

                    if let noteMessage {
                        FinanceCard {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "info.circle.fill")
                                    .foregroundStyle(Theme.accent)
                                Text(noteMessage)
                                    .font(.caption)
                                    .foregroundStyle(Theme.ink2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }

                    if !drafts.isEmpty {
                        draftsReviewSection
                    }
                }
                .padding(.horizontal, Theme.screenPadding)
                .padding(.vertical, 12)
            }
            .background(Theme.page)
            .navigationTitle("Scan receipt or slip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save (\(selectedDrafts.count))") {
                        saveSelected()
                    }
                    .fontWeight(.semibold)
                    .disabled(saving || selectedDrafts.isEmpty)
                }
            }
            .onChange(of: selectedPhoto) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data)
                    {
                        await runScan(on: image)
                    }
                }
            }
            .fullScreenCover(isPresented: $showingCamera) {
                CameraPickerView { image in
                    showingCamera = false
                    if let image {
                        Task { await runScan(on: image) }
                    }
                }
                .ignoresSafeArea()
            }
            .onAppear {
                if session.isDemo && drafts.isEmpty {
                    loadDemoSampleDrafts()
                }
            }
        }
    }

    private var captureHeroCard: some View {
        let engineBadge = session.isDemo
            ? "Claude · Sonnet"
            : (hasConfiguredAIKey ? config.provider.displayName : "On-device OCR")
        return HeroVaultCard {
            VStack(alignment: .leading, spacing: 14) {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionLabel("Receipt & slip intake", symbol: "doc.text.viewfinder", color: Theme.heroInkMuted)
                        QuietTag(engineBadge, tone: .hero)
                    }
                } else {
                    HStack {
                        SectionLabel("Receipt & slip intake", symbol: "doc.text.viewfinder", color: Theme.heroInkMuted)
                        Spacer()
                        QuietTag(engineBadge, tone: .hero)
                    }
                }

                Text("Snap paper receipts, utility slips, or screenshots")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(Theme.heroInk)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Extracts date, verbatim Japanese store name, exact 合計 total, and category. Multi-row screenshots import in one batch.")
                    .font(.caption)
                    .foregroundStyle(Theme.heroInkMuted)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        Button {
                            showingCamera = true
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "camera.fill")
                                Text("Camera")
                                    .font(.subheadline.weight(.semibold))
                            }
                            .foregroundStyle(Theme.heroTop)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(Theme.heroAccent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(scanning)
                    }

                    PhotosPicker(selection: $selectedPhoto, matching: .images, photoLibrary: .shared()) {
                        HStack(spacing: 6) {
                            Image(systemName: "photo.on.rectangle")
                            Text("Photo / Screenshot")
                                .font(.subheadline.weight(.semibold))
                        }
                        .foregroundStyle(Theme.heroInk)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.7)
                        )
                    }
                    .disabled(scanning)
                }

                if !hasConfiguredAIKey {
                    Button {
                        dismiss()
                        session.selectedTab = .more
                        session.morePath = [.receiptScanner]
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "sparkles")
                                .font(.caption2)
                            Text("Configure Claude / Gemini / OpenAI key in More →")
                                .font(.caption.weight(.medium))
                        }
                        .foregroundStyle(Theme.heroAccent)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var draftsReviewSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionLabel("Review extracted (\(drafts.count))", symbol: "checkmark.rectangle.stack")
                Spacer()
                if let engineLabel {
                    QuietTag(engineLabel, tone: .accent)
                }
            }

            ForEach($drafts) { $draft in
                draftEditorCard(draft: $draft)
            }
        }
    }

    private func draftEditorCard(draft: Binding<ReceiptDraft>) -> some View {
        FinanceCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 10) {
                    Button {
                        draft.isSelected.wrappedValue.toggle()
                    } label: {
                        Image(systemName: draft.isSelected.wrappedValue ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(draft.isSelected.wrappedValue ? Theme.accent : Theme.muted)
                    }
                    .buttonStyle(.plain)

                    TextField("Merchant", text: draft.merchant)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.ink)

                    if draft.isPossibleDuplicate.wrappedValue {
                        QuietTag("Duplicate?", tone: .warn)
                    }
                }

                HStack(spacing: 10) {
                    HStack(spacing: 2) {
                        Text("¥")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.muted)
                        TextField("0", value: draft.amount, format: .number)
                            .keyboardType(.numberPad)
                            .font(.headline.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(Theme.ink)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Theme.well, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                    DatePicker(
                        "Date",
                        selection: Binding(
                            get: { DayText.date(draft.date.wrappedValue) ?? Date() },
                            set: { draft.date.wrappedValue = JST.day($0) }
                        ),
                        displayedComponents: .date
                    )
                    .labelsHidden()
                    .datePickerStyle(.compact)
                    .tint(Theme.accent)
                    .environment(\.timeZone, JST.timeZone)
                    .environment(\.calendar, DayText.calendar)
                }

                HStack(spacing: 10) {
                    Picker("Category", selection: Binding(
                        get: { draft.category.wrappedValue },
                        set: { newCat in
                            draft.category.wrappedValue = newCat
                            if let match = categoryOptions.first(where: { $0.category == newCat }) {
                                draft.group.wrappedValue = match.group
                            }
                        }
                    )) {
                        ForEach(categoryOptions, id: \.category) { opt in
                            Text(opt.category).tag(opt.category)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(Theme.accent)

                    Spacer()

                    Picker("Source", selection: draft.source) {
                        ForEach(sourceOptions, id: \.self) { src in
                            Text(src).tag(src)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(Theme.ink2)
                }

                TextField("Note (optional)", text: Binding(
                    get: { draft.note.wrappedValue ?? "" },
                    set: { draft.note.wrappedValue = $0.isEmpty ? nil : $0 }
                ))
                .font(.caption)
                .foregroundStyle(Theme.ink2)

                if !draft.lineItems.wrappedValue.isEmpty {
                    Text(draft.lineItems.wrappedValue.joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(Theme.muted)
                        .lineLimit(2)
                }
            }
            .opacity(draft.isSelected.wrappedValue ? 1.0 : 0.55)
        }
    }

    private func runScan(on image: UIImage) async {
        previewImage = image
        scanning = true
        errorMessage = nil
        noteMessage = nil
        drafts = []
        defer { scanning = false }

        let data = activeData
        do {
            let result = try await ReceiptScannerService.scan(
                image: image,
                defaultSource: config.defaultSource,
                today: session.today,
                availableCategories: categoryOptions,
                rules: data?.bundle.rules ?? RuleSet(),
                existingItems: data?.allItems ?? []
            )
            drafts = result.drafts
            engineLabel = result.engineLabel
            noteMessage = result.fallbackNote
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func saveSelected() {
        let toSave = selectedDrafts.map { $0.asManualEntry(origin: .manual) }
        guard !toSave.isEmpty else { return }
        if session.isDemo {
            dismiss()
            return
        }
        saving = true
        Task {
            defer { saving = false }
            do {
                try await model.addManualEntries(toSave)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func loadDemoSampleDrafts() {
        engineLabel = "Claude (Anthropic) · Sonnet"
        drafts = [
            ReceiptDraft(
                date: session.today,
                merchant: "あおばスーパー 駅前店",
                amount: 2_480,
                group: "Living",
                category: "Groceries",
                source: "Cash",
                note: "Milk, vegetables, bento",
                lineItems: ["牛乳 ¥218", "野菜セット ¥580", "弁当 ¥648"],
                confidence: "high",
                isPossibleDuplicate: false,
                isSelected: true
            ),
            ReceiptDraft(
                date: session.today,
                merchant: "みなと水道 納付書",
                amount: 4_300,
                group: "Bills",
                category: "Utilities",
                source: "Cash",
                note: "Konbini water payment slip",
                lineItems: ["水道料金 ¥4,300"],
                confidence: "high",
                isPossibleDuplicate: false,
                isSelected: true
            ),
        ]
    }
}

/// UIKit camera sheet wrapper for instant receipt photography.
private struct CameraPickerView: UIViewControllerRepresentable {
    let onCapture: (UIImage?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let onCapture: (UIImage?) -> Void
        init(onCapture: @escaping (UIImage?) -> Void) { self.onCapture = onCapture }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let image = info[.originalImage] as? UIImage
            onCapture(image)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCapture(nil)
        }
    }
}
