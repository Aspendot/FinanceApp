import FinanceSync
import SwiftUI

/// Settings screen for read-only Gmail notice sync.
struct GmailSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var clientID = GmailSync.clientID ?? ""
    @State private var signInTask: Task<Void, Never>?
    @State private var statusMessage: String?

    var body: some View {
        Form {
            Section("Status") {
                LabeledContent("Connection", value: model.gmailStatusLine)
                if let last = model.gmailLastSyncAt {
                    LabeledContent("Last synced", value: SyncStorage.formatCheckTime(last))
                }
                if let statusMessage {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if let syncMessage = model.syncMessage {
                    Text(syncMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Google account") {
                TextField("Google iOS client ID", text: $clientID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.footnote)

                if let signInTask {
                    Button("Cancel sign-in") {
                        signInTask.cancel()
                    }
                } else {
                    Button(model.gmailConnected ? "Reconnect Gmail" : "Sign in with Google") {
                        startSignIn()
                    }
                    .disabled(model.syncing)
                }

                if model.gmailConnected {
                    Button(model.syncing ? "Syncing…" : "Sync now") {
                        Task {
                            await model.syncGmail(userInitiated: true)
                            statusMessage = model.syncMessage
                        }
                    }
                    .disabled(model.syncing || signInTask != nil)
                }
            }

            if model.gmailConnected {
                Section {
                    Button("Sign out", role: .destructive) {
                        Task {
                            do {
                                try await GmailSync.signOut()
                                statusMessage = "Signed out"
                            } catch {
                                statusMessage = error.localizedDescription
                            }
                            await model.reload()
                        }
                    }
                    .disabled(model.syncing || signInTask != nil)
                }
            }

            Section("App identifier") {
                Text(Bundle.main.bundleIdentifier ?? "Unknown")
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
            }
        }
        .navigationTitle("Gmail")
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
