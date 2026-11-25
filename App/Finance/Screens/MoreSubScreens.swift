import FinanceCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Notification preferences

struct NotificationSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var prefs: NotificationPreferences = LocalDataStore.loadNotificationPreferences()
    @State private var permissionStatus = ""
    @State private var scheduledBills = 0

    var body: some View {
        List {
            Section {
                SettingsValueRow(label: "Permission", value: permissionStatus.isEmpty ? "Checking…" : permissionStatus)
                if permissionStatus.contains("Not asked") || permissionStatus.contains("off") {
                    Button("Allow notifications") {
                        Task {
                            permissionStatus = await Notifier.requestPermission()
                            await model.updateNotificationPreferences(prefs)
                            scheduledBills = await BillReminderScheduler.scheduledCount()
                        }
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.accent)
                }
            } header: {
                SectionLabel("Status")
            }
            .listRowBackground(Theme.surface)

            Section {
                Toggle("New card payments & deposits", isOn: $prefs.paymentAlertsEnabled)
                    .font(.subheadline)
                    .foregroundStyle(Theme.ink)
                    .tint(Theme.accent)

                Toggle("Declined or failed payments", isOn: $prefs.declineAlertsEnabled)
                    .font(.subheadline)
                    .foregroundStyle(Theme.ink)
                    .tint(Theme.accent)
            } header: {
                SectionLabel("Real-time alerts")
            } footer: {
                Text("Discreet categories omit shop names from lock-screen alerts.")
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
            }
            .listRowBackground(Theme.surface)

            Section {
                Toggle("Upcoming bill reminders", isOn: $prefs.billRemindersEnabled)
                    .font(.subheadline)
                    .foregroundStyle(Theme.ink)
                    .tint(Theme.accent)

                if prefs.billRemindersEnabled {
                    Picker("Remind", selection: $prefs.billReminderDaysBefore) {
                        Text("Morning of due date").tag(0)
                        Text("1 day before").tag(1)
                        Text("2 days before").tag(2)
                    }
                    .font(.subheadline)
                    .foregroundStyle(Theme.ink)

                    Picker("Time (JST)", selection: $prefs.billReminderHourJST) {
                        ForEach([7, 8, 9, 10, 12, 18, 20], id: \.self) { hour in
                            Text(String(format: "%02d:00", hour)).tag(hour)
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(Theme.ink)

                    SettingsValueRow(label: "Scheduled reminders", value: "\(scheduledBills)")
                }
            } header: {
                SectionLabel("Bill reminders")
            } footer: {
                Text("All alerts are local notifications scheduled on this phone. Paid bills are cleared automatically.")
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
            }
            .listRowBackground(Theme.surface)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.page)
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            prefs = model.notificationPreferences
            Task {
                permissionStatus = await Notifier.status()
                scheduledBills = await BillReminderScheduler.scheduledCount()
            }
        }
        .onChange(of: prefs) { _, updated in
            Task {
                await model.updateNotificationPreferences(updated)
                scheduledBills = await BillReminderScheduler.scheduledCount()
            }
        }
    }
}

// MARK: - Local data, PayPay CSV import, overrides & encrypted backup

struct FinanceBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        self.data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct LocalDataSettingsView: View {
    @Environment(\.privacyMasked) private var privacyMasked
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var session: AppSession

    @State private var showingCSVImporter = false
    @State private var showingBackupExporter = false
    @State private var showingBackupImporter = false
    @State private var showingJSONExporter = false
    @State private var passphrase = ""
    @State private var exportDocument: FinanceBackupDocument?
    @State private var exportFilename = "finance-backup.fnbk"
    @State private var feedback: String?
    @State private var isError = false

    private var mods: LocalModifications {
        model.localModifications
    }

    var body: some View {
        List {
            if let feedback {
                Section {
                    Text(feedback)
                        .font(.footnote)
                        .foregroundStyle(isError ? Theme.bad : Theme.good)
                }
                .listRowBackground(Theme.surface)
            }

            Section {
                PrimaryActionButton(title: "Import PayPay CSV") {
                    showingCSVImporter = true
                }
                .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))

                SettingsValueRow(label: "Manual entries", value: "\(mods.manualEntries.count)")
                SettingsValueRow(label: "CSV-imported entries", value: "\(mods.importedEntries.count)")
                SettingsValueRow(label: "Category overrides", value: "\(mods.categoryOverrides.count)")
                SettingsValueRow(label: "Edited targets", value: "\(mods.targetOverrides.count)")
                SettingsValueRow(label: "Edited debt balances", value: "\(mods.debtBalanceOverrides.count)")
                SettingsValueRow(label: "Custom reminders", value: "\(mods.customReminders.count)")
                if model.gmailConnected && model.driveScopeGranted && model.driveKeyPaired {
                    Button("Push phone edits to Drive now") {
                        Task {
                            let status = await model.pushPhoneEditsNow()
                            feedback = status
                            isError = status.lowercased().contains("fail") || status.lowercased().contains("grant")
                        }
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.accent)
                }
            } header: {
                SectionLabel("On-device records")
            } footer: {
                Text("You can also share a PayPay Transactions CSV straight into Finance from the PayPay app or Files. Duplicate rows are skipped automatically.")
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
            }
            .listRowBackground(Theme.surface)

            if !mods.categoryOverrides.isEmpty {
                Section {
                    ForEach(mods.categoryOverrides) { ov in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(MaskedMoney.redactText(overrideTitle(ov), masked: privacyMasked))
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(Theme.ink)
                                    .lineLimit(1)
                                Text("→ \(ov.category) (\(overrideScopeLabel(ov)))")
                                    .font(.caption)
                                    .foregroundStyle(Theme.muted)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                Task { try? await model.removeCategoryOverride(id: ov.id) }
                            } label: {
                                Image(systemName: "trash")
                                    .font(.caption)
                                    .foregroundStyle(Theme.bad)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } header: {
                    SectionLabel("Saved category rules")
                }
                .listRowBackground(Theme.surface)
            }

            if !mods.customReminders.isEmpty {
                Section {
                    ForEach(mods.customReminders) { rem in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(MaskedMoney.redactText(rem.title, masked: privacyMasked))
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(Theme.ink)
                                    .lineLimit(1)
                                let amtPart = rem.isEvent || rem.amount == 0
                                    ? "Reminder"
                                    : MaskedMoney.yen(rem.amount, masked: privacyMasked)
                                Text("\(DayText.short(rem.date)) · \(amtPart)")
                                    .font(.caption)
                                    .foregroundStyle(Theme.muted)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                Task { try? await model.removeCustomReminder(id: rem.id) }
                            } label: {
                                Image(systemName: "trash")
                                    .font(.caption)
                                    .foregroundStyle(Theme.bad)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } header: {
                    SectionLabel("Custom reminders")
                }
                .listRowBackground(Theme.surface)
            }

            if !mods.targetOverrides.isEmpty {
                Section {
                    ForEach(mods.targetOverrides.keys.sorted(), id: \.self) { category in
                        if let cap = mods.targetOverrides[category] {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(category)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(Theme.ink)
                                    Text("Monthly cap: \(MaskedMoney.yen(cap, masked: privacyMasked))")
                                        .font(.caption)
                                        .foregroundStyle(Theme.muted)
                                }
                                Spacer()
                                Button(role: .destructive) {
                                    Task { try? await model.setTargetOverride(category: category, target: nil) }
                                } label: {
                                    Image(systemName: "arrow.uturn.backward")
                                        .font(.caption)
                                        .foregroundStyle(Theme.bad)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                } header: {
                    SectionLabel("Edited monthly targets")
                }
                .listRowBackground(Theme.surface)
            }

            if !mods.debtBalanceOverrides.isEmpty {
                Section {
                    ForEach(mods.debtBalanceOverrides.keys.sorted(), id: \.self) { debtName in
                        if let bal = mods.debtBalanceOverrides[debtName] {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(debtName)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(Theme.ink)
                                    Text("Balance: \(MaskedMoney.yen(bal, masked: privacyMasked))")
                                        .font(.caption)
                                        .foregroundStyle(Theme.muted)
                                }
                                Spacer()
                                Button(role: .destructive) {
                                    Task { try? await model.setDebtBalanceOverride(debtName: debtName, balance: nil) }
                                } label: {
                                    Image(systemName: "arrow.uturn.backward")
                                        .font(.caption)
                                        .foregroundStyle(Theme.bad)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                } header: {
                    SectionLabel("Edited debt balances")
                }
                .listRowBackground(Theme.surface)
            }

            if !mods.dismissedAlertIDs.isEmpty {
                Section {
                    Button("Show \(mods.dismissedAlertIDs.count) dismissed alerts again") {
                        Task {
                            await model.restoreDismissedAlerts()
                            feedback = "Dismissed alerts restored"
                            isError = false
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(Theme.accent)
                } header: {
                    SectionLabel("Alerts")
                }
                .listRowBackground(Theme.surface)
            }

            Section {
                SecureField("Backup passphrase", text: $passphrase)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.subheadline)
                    .foregroundStyle(Theme.ink)

                Button {
                    startEncryptedExport()
                } label: {
                    Text("Export encrypted backup to Files")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(passphrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Theme.muted : Theme.accent)
                }
                .disabled(passphrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button {
                    showingBackupImporter = true
                } label: {
                    Text("Restore from encrypted backup")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(passphrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Theme.muted : Theme.accent)
                }
                .disabled(passphrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button {
                    startJSONExport()
                } label: {
                    Text("Export local changes as JSON (for PC)")
                        .font(.subheadline)
                        .foregroundStyle(Theme.ink2)
                }
            } header: {
                SectionLabel("Encrypted backup")
            } footer: {
                Text("Seals your manual entries, CSV imports and category overrides with AES-256-GCM before saving to Files.")
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
            }
            .listRowBackground(Theme.surface)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.page)
        .navigationTitle("Imports & Backup")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(
            isPresented: $showingCSVImporter,
            allowedContentTypes: [.commaSeparatedText, .plainText],
            allowsMultipleSelection: false
        ) { result in
            handleCSVSelection(result)
        }
        .fileImporter(
            isPresented: $showingBackupImporter,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            handleBackupRestore(result)
        }
        .fileExporter(
            isPresented: $showingBackupExporter,
            document: exportDocument,
            contentType: .data,
            defaultFilename: exportFilename
        ) { result in
            switch result {
            case .success:
                feedback = "Encrypted backup saved"
                isError = false
                passphrase = ""
            case .failure(let error):
                feedback = error.localizedDescription
                isError = true
            }
        }
        .fileExporter(
            isPresented: $showingJSONExporter,
            document: exportDocument,
            contentType: .json,
            defaultFilename: "finance-local-changes.json"
        ) { result in
            switch result {
            case .success:
                feedback = "Local changes JSON exported"
                isError = false
            case .failure(let error):
                feedback = error.localizedDescription
                isError = true
            }
        }
    }

    private func overrideTitle(_ ov: CategoryOverride) -> String {
        switch ov.scope {
        case .merchant(_, let display): return display
        case .transaction(_, let display, _, _): return display
        }
    }

    private func overrideScopeLabel(_ ov: CategoryOverride) -> String {
        switch ov.scope {
        case .merchant: return "all payments"
        case .transaction(_, _, let date, let amount): return "\(date) · \(MaskedMoney.yen(amount, masked: privacyMasked))"
        }
    }

    private func handleCSVSelection(_ result: Result<[URL], any Error>) {
        guard case .success(let urls) = result, let url = urls.first else {
            if case .failure(let err) = result {
                feedback = err.localizedDescription
                isError = true
            }
            return
        }
        Task {
            do {
                let imported = try await model.importPayPayCSV(url: url)
                let rangeText = imported.earliestDate.flatMap { start in
                    imported.latestDate.map { " (\(start) to \($0))" }
                } ?? ""
                feedback = "Imported \(imported.entries.count) rows\(rangeText). Skipped \(imported.skippedDuplicates) duplicates."
                isError = false
            } catch {
                feedback = error.localizedDescription
                isError = true
            }
        }
    }

    private func startEncryptedExport() {
        do {
            let sealed = try model.exportEncryptedBackup(passphrase: passphrase)
            exportDocument = FinanceBackupDocument(data: sealed)
            exportFilename = "finance-backup-\(JST.day(Date())).fnbk"
            showingBackupExporter = true
        } catch {
            feedback = error.localizedDescription
            isError = true
        }
    }

    private func startJSONExport() {
        do {
            let json = try model.exportLocalChangesJSON()
            exportDocument = FinanceBackupDocument(data: json)
            showingJSONExporter = true
        } catch {
            feedback = error.localizedDescription
            isError = true
        }
    }

    private func handleBackupRestore(_ result: Result<[URL], any Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        Task {
            do {
                let restored = try await model.restoreEncryptedBackup(from: url, passphrase: passphrase)
                feedback = "Restored \(restored.manualEntries.count) manual entries, \(restored.importedEntries.count) imports and \(restored.categoryOverrides.count) category rules."
                isError = false
                passphrase = ""
            } catch {
                feedback = error.localizedDescription
                isError = true
            }
        }
    }
}

// MARK: - Sync health & per-source coverage

struct SyncHealthView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var session: AppSession

    private var activeData: FinanceData? {
        session.resolvedData(from: model)
    }

    private var runs: [SyncRunRecord] {
        session.resolvedRunLog(from: model)
    }

    var body: some View {
        List {
            if let data = activeData {
                Section {
                    SettingsValueRow(label: "Bundle snapshot", value: DayText.short(data.bundle.asOf))
                    SettingsValueRow(label: "Generated", value: FinanceFormat.bundleTimestamp(data.bundle.generatedAt))
                    SettingsValueRow(label: "Total items", value: data.allItems.count.formatted())
                    SettingsValueRow(label: "Confirmed MF rows", value: "\(data.confirmedBankCount)")
                    SettingsValueRow(label: "Pending emails", value: "\(data.pendingCount)")
                    SettingsValueRow(label: "Local entries", value: "\(data.localItemKeys.count)")
                } header: {
                    SectionLabel("Data freshness")
                }
                .listRowBackground(Theme.surface)

                if !data.effectiveCoverage.isEmpty {
                    Section {
                        ForEach(data.effectiveCoverage.keys.sorted(), id: \.self) { key in
                            if let range = data.effectiveCoverage[key] {
                                let label = data.bundle.sourceLabels[key] ?? key
                                SettingsValueRow(label: label, value: "\(range.start) → \(range.end)")
                            }
                        }
                    } header: {
                        SectionLabel("Statement coverage")
                    } footer: {
                        Text("Emails dated before a source's coverage end stay out of totals so nothing is counted twice.")
                            .font(.footnote)
                            .foregroundStyle(Theme.muted)
                    }
                    .listRowBackground(Theme.surface)
                }
            }

            Section {
                if runs.isEmpty {
                    Text("No background or foreground sync runs yet.")
                        .font(.footnote)
                        .foregroundStyle(Theme.muted)
                } else {
                    ForEach(Array(runs.prefix(20))) { run in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline) {
                                Text("\(SyncStorage.formatCheckTime(run.startedAt)) · \(run.trigger.rawValue)")
                                    .font(.subheadline)
                                    .foregroundStyle(Theme.ink)
                                Spacer()
                                Text(runSummary(run))
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(run.outcome == .failed || run.outcome == .signInRequired ? Theme.bad : Theme.muted)
                            }
                            if let error = run.errorMessage, !error.isEmpty, error != run.outcome.label {
                                Text(error)
                                    .font(.caption)
                                    .foregroundStyle(Theme.muted)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
            } header: {
                SectionLabel("Recent sync runs")
            }
            .listRowBackground(Theme.surface)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.page)
        .navigationTitle("Sync health")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func runSummary(_ run: SyncRunRecord) -> String {
        var bits: [String] = []
        if run.driveImported == true { bits.append("Drive") }
        if let mf = run.newBankTransactions, mf > 0 { bits.append("\(mf) bank") }
        if run.newPayments > 0 { bits.append("\(run.newPayments) email") }
        return bits.isEmpty ? run.outcome.label : bits.joined(separator: " · ")
    }
}

// MARK: - AI Vision & On-Device Receipt Scanner Settings

struct ReceiptScannerSettingsView: View {
    @EnvironmentObject private var session: AppSession

    @State private var config: VisionScannerConfig = VisionScannerStore.load()
    @State private var apiKeyInput = ""
    @State private var hasStoredKey = false
    @State private var feedback: String?
    @State private var feedbackIsError = false
    @State private var testingKey = false

    private static func presets(for provider: VisionProvider) -> [String] {
        switch provider {
        case .anthropic:
            return ["claude-sonnet-4-5-20250929", "claude-sonnet-4-6", "claude-haiku-4-5-20251001"]
        case .gemini:
            return ["gemini-2.5-flash", "gemini-2.5-pro"]
        case .openAICompatible:
            return ["gpt-4.1-mini", "gpt-4.1", "gpt-4o-mini"]
        }
    }

    private var presetModels: [String] {
        Self.presets(for: config.provider)
    }

    var body: some View {
        List {
            if let feedback {
                Section {
                    Text(feedback)
                        .font(.footnote)
                        .foregroundStyle(feedbackIsError ? Theme.bad : Theme.good)
                }
                .listRowBackground(Theme.surface)
            }

            Section {
                Toggle("Use AI Vision when API key is set", isOn: $config.preferAIVision)
                    .font(.subheadline)
                    .foregroundStyle(Theme.ink)
                    .tint(Theme.accent)

                SettingsValueRow(
                    label: "Active engine",
                    value: (config.preferAIVision && hasStoredKey)
                        ? config.provider.displayName
                        : "Apple Vision (on-device)",
                    valueColor: (config.preferAIVision && hasStoredKey) ? Theme.good : Theme.ink2
                )
            } header: {
                SectionLabel("Scanner mode")
            } footer: {
                Text("EXIF and location metadata are stripped on-device before any image is sent. Offline scans fall back automatically to Apple Vision.")
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
            }
            .listRowBackground(Theme.surface)

            Section {
                Picker("Provider", selection: $config.provider) {
                    ForEach(VisionProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .font(.subheadline)
                .foregroundStyle(Theme.ink)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Model ID")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.muted)
                    TextField(config.provider.defaultModel, text: $config.model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.footnote.monospaced())
                        .foregroundStyle(Theme.ink)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(presetModels, id: \.self) { modelID in
                            FilterChip(title: modelID, isSelected: config.model == modelID) {
                                config.model = modelID
                                VisionScannerStore.save(config)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }

                if config.provider == .openAICompatible {
                    TextField("Custom endpoint URL (optional)", text: $config.customEndpoint)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .font(.footnote.monospaced())
                        .foregroundStyle(Theme.ink)
                }
            } header: {
                SectionLabel("Vision model")
            } footer: {
                Text("Type any model ID supported by your provider (for example claude-sonnet-4-6, gemini-2.5-pro, or newer models as they release).")
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
            }
            .listRowBackground(Theme.surface)

            Section {
                SettingsValueRow(
                    label: "API key",
                    value: hasStoredKey ? "Saved in Keychain" : "Not set",
                    valueColor: hasStoredKey ? Theme.good : Theme.muted
                )

                SecureField("Paste \(config.provider.displayName) API key", text: $apiKeyInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.footnote.monospaced())
                    .foregroundStyle(Theme.ink)

                Button("Save API key") {
                    do {
                        try VisionKeyStore.saveKey(apiKeyInput, for: config.provider)
                        apiKeyInput = ""
                        hasStoredKey = VisionKeyStore.hasKey(for: config.provider)
                        feedback = "API key saved to Keychain for \(config.provider.displayName)"
                        feedbackIsError = false
                    } catch {
                        feedback = error.localizedDescription
                        feedbackIsError = true
                    }
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Theme.muted : Theme.accent)
                .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if hasStoredKey {
                    Button(testingKey ? "Testing connection…" : "Test API key") {
                        testSavedKey()
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(testingKey ? Theme.muted : Theme.accent)
                    .disabled(testingKey)

                    Button("Remove API key", role: .destructive) {
                        VisionKeyStore.clearKey(for: config.provider)
                        hasStoredKey = false
                        feedback = "API key removed"
                        feedbackIsError = false
                    }
                    .font(.subheadline.weight(.medium))
                }
            } header: {
                SectionLabel("Keychain credentials")
            } footer: {
                Text("Stored strictly in this iPhone's Keychain (this device only, never synced or exported).")
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
            }
            .listRowBackground(Theme.surface)

            Section {
                PrimaryActionButton(title: "Open receipt scanner") {
                    session.activeSheet = .scanReceipt
                }
                .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
            }
            .listRowBackground(Theme.surface)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.page)
        .navigationTitle("Receipt scanner")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            config = VisionScannerStore.load()
            hasStoredKey = VisionKeyStore.hasKey(for: config.provider)
        }
        .onChange(of: config.provider) { oldProvider, newProvider in
            let oldPresets = Set(Self.presets(for: oldProvider) + [oldProvider.defaultModel])
            if config.model.isEmpty || oldPresets.contains(config.model) {
                config.model = newProvider.defaultModel
            }
            VisionScannerStore.save(config)
            hasStoredKey = VisionKeyStore.hasKey(for: newProvider)
            feedback = nil
        }
        .onChange(of: config) { _, updated in
            VisionScannerStore.save(updated)
        }
    }

    private func testSavedKey() {
        guard let key = VisionKeyStore.loadKey(for: config.provider) else {
            feedback = "Save an API key first."
            feedbackIsError = true
            return
        }
        testingKey = true
        feedback = nil
        let snapshot = config
        Task {
            defer { testingKey = false }
            do {
                let message = try await ReceiptScannerService.testConnection(config: snapshot, apiKey: key)
                feedback = message
                feedbackIsError = false
            } catch {
                feedback = error.localizedDescription
                feedbackIsError = true
            }
        }
    }
}
