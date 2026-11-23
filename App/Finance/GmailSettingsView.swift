import FinanceSync
import SwiftUI

/// Settings screen for read-only Gmail notice sync.
struct GmailSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var clientID = GmailSync.clientID ?? ""
    @State private var signInTask: Task<Void, Never>?
    @State private var statusMessage: String?

    private var connectionColor: Color {
        if model.runLog.first?.outcome == .signInRequired {
            return Theme.bad
        }
        return model.gmailConnected ? Theme.good : Theme.muted
    }

    var body: some View {
        List {
            Section {
                SettingsValueRow(
                    label: "Connection",
                    value: model.gmailStatusLine,
                    valueColor: connectionColor
                )
                if let last = model.gmailLastSyncAt {
                    SettingsValueRow(
                        label: "Last synced",
                        value: SyncStorage.formatCheckTime(last)
                    )
                }
                if let statusMessage {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(Theme.muted)
                } else if let syncMessage = model.syncMessage {
                    Text(syncMessage)
                        .font(.footnote)
                        .foregroundStyle(Theme.muted)
                }
            } header: {
                SectionLabel("Status")
            }
            .listRowBackground(Theme.surface)

            Section {
                TextField("Google iOS client ID", text: $clientID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.footnote.monospaced())
                    .foregroundStyle(Theme.ink)

                if let signInTask {
                    Button {
                        signInTask.cancel()
                    } label: {
                        Text("Cancel sign-in")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Theme.bad)
                    }
                } else if model.gmailConnected {
                    PrimaryActionButton(title: model.syncing ? "Syncing…" : "Sync now") {
                        Task {
                            await model.syncGmail(userInitiated: true)
                            statusMessage = model.syncMessage
                        }
                    }
                    .disabled(model.syncing || signInTask != nil)
                    .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))

                    Button {
                        startSignIn()
                    } label: {
                        Text("Reconnect Gmail")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(model.syncing ? Theme.muted : Theme.accent)
                    }
                    .disabled(model.syncing)
                } else {
                    PrimaryActionButton(title: "Sign in with Google") {
                        startSignIn()
                    }
                    .disabled(model.syncing)
                    .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                }
            } header: {
                SectionLabel("Google account")
            } footer: {
                Text("Read-only access to bank notice emails.")
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
            }
            .listRowBackground(Theme.surface)

            if model.gmailConnected {
                Section {
                    Button(role: .destructive) {
                        Task {
                            do {
                                try await GmailSync.signOut()
                                statusMessage = "Signed out"
                            } catch {
                                statusMessage = error.localizedDescription
                            }
                            await model.reload()
                        }
                    } label: {
                        Text("Sign out")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(model.syncing || signInTask != nil ? Theme.muted : Theme.bad)
                    }
                    .disabled(model.syncing || signInTask != nil)
                }
                .listRowBackground(Theme.surface)
            }

            Section {
                Text(Bundle.main.bundleIdentifier ?? "Unknown")
                    .font(.footnote.monospaced())
                    .foregroundStyle(Theme.muted)
                    .textSelection(.enabled)
            } header: {
                SectionLabel("App identifier")
            }
            .listRowBackground(Theme.surface)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.page)
        .navigationTitle("Gmail")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            model.refreshConnectionStates()
        }
    }

    private func startSignIn() {
        let scopes: [String] = model.driveScopeGranted
            ? [GoogleOAuth.gmailReadOnlyScope, GoogleOAuth.driveAppDataScope]
            : [GoogleOAuth.gmailReadOnlyScope]
        let incremental = model.driveScopeGranted

        signInTask = Task { @MainActor in
            defer { signInTask = nil }
            do {
                try await GmailSync.signIn(
                    clientID: clientID,
                    scopes: scopes,
                    includeGrantedScopes: incremental
                )
                statusMessage = "Connected to Gmail"
                await model.reload()
            } catch {
                statusMessage = Task.isCancelled
                    ? "Sign-in cancelled"
                    : error.localizedDescription
            }
        }
    }
}
