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
    @State private var busy = false
    @State private var feedback: String?

    private var mfState: MoneyForwardState {
        model.moneyForwardState
    }

    private var mappableAccounts: [MoneyForwardMappableAccount] {
        mfState.connectedAccounts.flatMap(\.mappableAccounts)
    }

    private var sortedBundleSources: [(key: String, label: String)] {
        guard let labels = model.data?.bundle.sourceLabels else { return [] }
        return labels
            .map { (key: $0.key, label: $0.value) }
            .sorted { ($0.label.lowercased(), $0.key) < ($1.label.lowercased(), $1.key) }
    }

    var body: some View {
        Form {
            Section("Status") {
                LabeledContent("Connection", value: model.moneyForwardStatusLine)
                if let name = mfState.officeName, let code = mfState.officeCode {
                    LabeledContent("Office", value: "\(name) (\(code))")
                } else if let code = mfState.officeCode {
                    LabeledContent("Office code", value: code)
                }
                if let last = mfState.lastSyncAt {
                    LabeledContent("Last synced", value: SyncStorage.formatCheckTime(last))
                }
                LabeledContent("Stored transactions", value: mfState.transactions.count.formatted())

                if mfState.reconnectRequired {
                    Text("Reconnect Money Forward. Stored transactions are kept.")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                } else if let refused = mfState.accessRefusedMessage, !refused.isEmpty {
                    Text(refused)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                } else if let lastError = mfState.lastErrorMessage, !lastError.isEmpty {
                    Text(lastError)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let feedback {
                    Text(feedback)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                SecureField("API key", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.footnote)

                Button(model.moneyForwardConnected ? "Save new API key" : "Connect with API key") {
                    connectWithAPIKey()
                }
                .disabled(busy || model.syncing || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: {
                Text("API key")
            } footer: {
                Text("Create an API key in Money Forward App Portal, then paste it here. The office code is discovered automatically.")
            }

            if mfState.availableOffices.count > 1 {
                Section("Office") {
                    ForEach(mfState.availableOffices) { office in
                        Button {
                            selectOffice(office)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(office.name)
                                    Text(office.code)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if mfState.officeCode == office.code {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                        .disabled(busy)
                    }
                }
            }

            if model.moneyForwardConnected {
                Section("Actions") {
                    Button(model.syncing ? "Syncing…" : "Sync now") {
                        Task {
                            await model.syncGmail(userInitiated: true)
                            feedback = model.syncMessage
                        }
                    }
                    .disabled(busy || model.syncing)

                    Button("Refresh connected accounts") {
                        refreshAccounts()
                    }
                    .disabled(busy || model.syncing)
                }

                Section {
                    if mappableAccounts.isEmpty {
                        Text("No connected accounts loaded yet. Tap Refresh connected accounts.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else if sortedBundleSources.isEmpty {
                        Text("Import a data file first so bundle sources are available for mapping.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(mappableAccounts) { account in
                            Picker(account.displayName, selection: mappingBinding(for: account.id)) {
                                Text("Ignore").tag("")
                                ForEach(sortedBundleSources, id: \.key) { source in
                                    Text(source.label).tag(source.key)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Account mapping")
                } footer: {
                    Text("Map each Money Forward account to a source from your data file, or leave it set to Ignore.")
                }
            }

            Section {
                DisclosureGroup("OAuth 2.0 (optional)", isExpanded: $showOAuth) {
                    TextField("Client ID", text: $oauthClientID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.footnote)
                    SecureField("Client secret", text: $oauthClientSecret)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.footnote)
                    TextField("Redirect URI", text: $oauthRedirectURI)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.footnote.monospaced())
                    Button("Sign in with Money Forward") {
                        connectWithOAuth()
                    }
                    .disabled(
                        busy
                            || model.syncing
                            || oauthClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || oauthClientSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }
            }

            if model.moneyForwardConnected {
                Section {
                    Button("Disconnect Money Forward", role: .destructive) {
                        disconnect()
                    }
                    .disabled(busy || model.syncing)
                }
            }
        }
        .navigationTitle("Money Forward")
        .onAppear {
            model.refreshConnectionStates()
        }
    }

    private func mappingBinding(for accountID: String) -> Binding<String> {
        Binding(
            get: { model.moneyForwardState.accountMapping[accountID] ?? "" },
            set: { newValue in
                do {
                    try MoneyForwardSync.setMapping(accountID: accountID, sourceKey: newValue)
                    Task { await model.reload() }
                } catch {
                    feedback = error.localizedDescription
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
