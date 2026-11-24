import FinanceCore
import FinanceSync
import SwiftUI

/// Settings screen for Money Forward Cloud API authentication and data-driven account mapping.
struct MoneyForwardSettingsView: View {
    @EnvironmentObject private var model: AppModel

    @State private var apiKey = ""
    @State private var oauthClientID = ""
    @State private var oauthClientSecret = ""
    @State private var oauthRedirectURI = MoneyForwardAuth.defaultRedirectURI
    @State private var showOAuth = false
    private static let showsOAuth = false
    @State private var busy = false
    @State private var feedback: String?

    private var mfState: MoneyForwardState {
        model.moneyForwardState
    }

    private var mappableAccounts: [MoneyForwardMappableAccount] {
        mfState.connectedAccounts.flatMap(\.mappableAccounts)
    }

    private var sortedBundleSources: [(key: String, label: String)] {
        guard let bundle = model.data?.bundle else { return [] }
        return bundle.coverage.keys
            .map { (key: $0, label: bundle.sourceLabels[$0] ?? $0) }
            .sorted { ($0.label.lowercased(), $0.key) < ($1.label.lowercased(), $1.key) }
    }

    private var connectionColor: Color {
        if mfState.reconnectRequired || mfState.accessRefusedMessage != nil {
            return Theme.bad
        }
        return model.moneyForwardConnected ? Theme.good : Theme.muted
    }

    var body: some View {
        List {
            Section {
                SettingsValueRow(
                    label: "Connection",
                    value: model.moneyForwardStatusLine,
                    valueColor: connectionColor
                )
                if let name = mfState.officeName, let code = mfState.officeCode {
                    SettingsValueRow(label: "Office", value: "\(name) (\(code))")
                } else if let code = mfState.officeCode {
                    SettingsValueRow(label: "Office code", value: code)
                }
                if let last = mfState.lastSyncAt {
                    SettingsValueRow(label: "Last synced", value: SyncStorage.formatCheckTime(last))
                }
                SettingsValueRow(
                    label: "Transactions",
                    value: mfState.transactions.count.formatted()
                )

                if mfState.reconnectRequired {
                    Text("Reconnect Money Forward. Stored transactions are kept.")
                        .font(.footnote)
                        .foregroundStyle(Theme.bad)
                } else if let refused = mfState.accessRefusedMessage, !refused.isEmpty {
                    Text(refused)
                        .font(.footnote)
                        .foregroundStyle(Theme.bad)
                } else if let lastError = mfState.lastErrorMessage, !lastError.isEmpty {
                    Text(lastError)
                        .font(.footnote)
                        .foregroundStyle(Theme.muted)
                }

                if let feedback {
                    Text(feedback)
                        .font(.footnote)
                        .foregroundStyle(Theme.muted)
                }
            } header: {
                SectionLabel("Status")
            }
            .listRowBackground(Theme.surface)

            Section {
                SecureField("API key", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.footnote.monospaced())
                    .foregroundStyle(Theme.ink)

                PrimaryActionButton(
                    title: model.moneyForwardConnected ? "Save API key" : "Connect with API key"
                ) {
                    connectWithAPIKey()
                }
                .disabled(busy || model.syncing || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
            } header: {
                SectionLabel("API key")
            } footer: {
                Text("Paste an API key from Money Forward App Portal. The office is detected automatically.")
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
            }
            .listRowBackground(Theme.surface)

            if mfState.availableOffices.count > 1 {
                Section {
                    ForEach(mfState.availableOffices) { office in
                        Button {
                            selectOffice(office)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(office.name)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(Theme.ink)
                                    Text(office.code)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(Theme.muted)
                                }
                                Spacer()
                                if mfState.officeCode == office.code {
                                    Image(systemName: "checkmark")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(Theme.accent)
                                }
                            }
                        }
                        .disabled(busy)
                    }
                } header: {
                    SectionLabel("Office")
                }
                .listRowBackground(Theme.surface)
            }

            if model.moneyForwardConnected {
                Section {
                    PrimaryActionButton(title: model.syncing ? "Syncing…" : "Sync now") {
                        Task {
                            await model.syncGmail(userInitiated: true)
                            feedback = model.syncMessage
                        }
                    }
                    .disabled(busy || model.syncing)
                    .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))

                    Button {
                        refreshAccounts()
                    } label: {
                        Text("Refresh accounts")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(busy || model.syncing ? Theme.muted : Theme.accent)
                    }
                    .disabled(busy || model.syncing)
                } header: {
                    SectionLabel("Sync")
                }
                .listRowBackground(Theme.surface)

                Section {
                    if mappableAccounts.isEmpty {
                        Text("No accounts loaded yet. Tap Refresh accounts.")
                            .font(.footnote)
                            .foregroundStyle(Theme.muted)
                    } else if sortedBundleSources.isEmpty {
                        Text("Sync a data file first to map accounts.")
                            .font(.footnote)
                            .foregroundStyle(Theme.muted)
                    } else {
                        ForEach(mappableAccounts) { account in
                            Picker(account.displayName, selection: mappingBinding(for: account.id)) {
                                Text("Inherit / Default").tag("__inherit__")
                                Text("Ignore").tag("")
                                ForEach(sortedBundleSources, id: \.key) { source in
                                    Text(source.label).tag(source.key)
                                }
                            }
                            .font(.subheadline)
                            .foregroundStyle(Theme.ink)
                        }
                    }
                } header: {
                    SectionLabel("Account mapping")
                } footer: {
                    Text("Match each account to a statement source, or leave set to Ignore.")
                        .font(.footnote)
                        .foregroundStyle(Theme.muted)
                }
                .listRowBackground(Theme.surface)
            }

            // The API key covers everything the app needs; OAuth stays in code but out of sight.
            if Self.showsOAuth {
            Section {
                DisclosureGroup("OAuth 2.0 (optional)", isExpanded: $showOAuth) {
                    TextField("Client ID", text: $oauthClientID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.footnote.monospaced())
                        .foregroundStyle(Theme.ink)
                    SecureField("Client secret", text: $oauthClientSecret)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.footnote.monospaced())
                        .foregroundStyle(Theme.ink)
                    TextField("Redirect URI", text: $oauthRedirectURI)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.footnote.monospaced())
                        .foregroundStyle(Theme.ink)
                    Button {
                        connectWithOAuth()
                    } label: {
                        Text("Sign in with Money Forward")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(
                                busy
                                    || model.syncing
                                    || oauthClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    || oauthClientSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    ? Theme.muted
                                    : Theme.accent
                            )
                    }
                    .disabled(
                        busy
                            || model.syncing
                            || oauthClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || oauthClientSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }
                .font(.subheadline)
                .foregroundStyle(Theme.ink)
            }
            .listRowBackground(Theme.surface)
            }

            if model.moneyForwardConnected {
                Section {
                    Button(role: .destructive) {
                        disconnect()
                    } label: {
                        Text("Disconnect Money Forward")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(busy || model.syncing ? Theme.muted : Theme.bad)
                    }
                    .disabled(busy || model.syncing)
                }
                .listRowBackground(Theme.surface)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.page)
        .navigationTitle("Money Forward")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            model.refreshConnectionStates()
        }
    }

    private func mappingBinding(for accountID: String) -> Binding<String> {
        Binding(
            get: {
                guard let key = model.moneyForwardState.accountMapping[accountID] else {
                    return "__inherit__"
                }
                if key.isEmpty { return "" }
                return sortedBundleSources.contains { $0.key == key } ? key : "__inherit__"
            },
            set: { newValue in
                let stored: String? = (newValue == "__inherit__") ? nil : newValue
                Task {
                    do {
                        try await MoneyForwardSync.setMapping(accountID: accountID, sourceKey: stored)
                        await model.reload()
                    } catch {
                        feedback = error.localizedDescription
                    }
                }
            }
        )
    }

    private func connectWithAPIKey() {
        let candidate = apiKey
        busy = true
        feedback = nil
        Task {
            defer { busy = false }
            do {
                let offices = try await MoneyForwardSync.connectAPIKey(candidate)
                apiKey = ""
                if offices.count == 1, let only = offices.first {
                    feedback = "Connected to \(only.name)"
                } else {
                    feedback = "Found \(offices.count) offices. Choose one below."
                }
                await model.reload()
            } catch {
                feedback = error.localizedDescription
                model.refreshConnectionStates()
            }
        }
    }

    private func selectOffice(_ office: MoneyForwardOffice) {
        busy = true
        feedback = nil
        Task {
            defer { busy = false }
            do {
                try await MoneyForwardSync.selectOffice(office)
                feedback = "Selected \(office.name)"
                await model.reload()
            } catch {
                feedback = error.localizedDescription
                model.refreshConnectionStates()
            }
        }
    }

    private func refreshAccounts() {
        busy = true
        feedback = nil
        Task {
            defer { busy = false }
            do {
                try await MoneyForwardSync.refreshConnectedAccounts()
                feedback = "Updated connected accounts"
                await model.reload()
            } catch {
                feedback = error.localizedDescription
                model.refreshConnectionStates()
            }
        }
    }

    private func connectWithOAuth() {
        busy = true
        feedback = nil
        Task {
            defer { busy = false }
            do {
                try await MoneyForwardSync.connectOAuth(
                    clientID: oauthClientID,
                    clientSecret: oauthClientSecret,
                    redirectURI: oauthRedirectURI
                )
                oauthClientSecret = ""
                feedback = "Connected via OAuth"
                await model.reload()
            } catch {
                feedback = error.localizedDescription
                model.refreshConnectionStates()
            }
        }
    }

    private func disconnect() {
        busy = true
        feedback = nil
        Task {
            defer { busy = false }
            do {
                try await MoneyForwardSync.disconnect()
                feedback = "Disconnected"
                await model.reload()
            } catch {
                feedback = error.localizedDescription
            }
        }
    }
}
