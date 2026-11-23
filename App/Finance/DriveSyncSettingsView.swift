import FinanceSync
import SwiftUI

/// Settings screen for encrypted Google Drive `appDataFolder` sync and key pairing.
struct DriveSyncSettingsView: View {
    @EnvironmentObject private var model: AppModel

    @State private var pastedKey = ""
    @State private var showingScanner = false
    @State private var busy = false
    @State private var feedback: String?

    private var driveState: DriveSyncState {
        model.driveState
    }

    var body: some View {
        Form {
            Section("Status") {
                LabeledContent("Connection", value: model.driveStatusLine)
                if let keyID = DriveSync.currentKeyIDFormatted() {
                    LabeledContent("Key ID") {
                        Text(keyID)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                    }
                }
                if let last = driveState.lastCheckedAt {
                    LabeledContent("Last checked", value: SyncStorage.formatCheckTime(last))
                }
                if let importedAt = driveState.lastImportedGeneratedAt {
                    LabeledContent(
                        "Latest file",
                        value: String(importedAt.prefix(16)).replacingOccurrences(of: "T", with: " ")
                    )
                }
                if let error = driveState.lastErrorMessage, !error.isEmpty {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                if let feedback {
                    Text(feedback)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                if !model.gmailConnected {
                    Text("Sign in to Gmail first to use your Google account for Drive sync.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if !model.driveScopeGranted || driveState.needsDriveConsent {
                    Button("Turn on Drive sync") {
                        turnOnDriveSync()
                    }
                    .disabled(busy || model.syncing)
                } else {
                    LabeledContent("Drive access", value: "Granted")
                }
            } header: {
                Text("Google Drive access")
            } footer: {
                Text("Uses the hidden appDataFolder scope so only this app can read its encrypted data file.")
            }

            Section {
                Button("Scan QR code") {
                    showingScanner = true
                }
                .disabled(busy)

                SecureField("finance-key:v1:...", text: $pastedKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.footnote.monospaced())

                Button("Save pasted key") {
                    savePastedKey()
                }
                .disabled(busy || pastedKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if model.driveKeyPaired {
                    Button("Remove key", role: .destructive) {
                        removeKey()
                    }
                    .disabled(busy || model.syncing)
                }
            } header: {
                Text("Encryption key")
            } footer: {
                Text("Compare the Key ID above with the PC exporter to verify both devices share the same key.")
            }

            Section("Sync") {
                if model.gmailConnected && model.driveScopeGranted && model.driveKeyPaired {
                    Button(model.syncing ? "Syncing…" : "Sync now") {
                        Task {
                            await model.syncGmail(userInitiated: true)
                            feedback = model.syncMessage
                        }
                    }
                    .disabled(busy || model.syncing)
                }

                Button(model.checkingInbox ? "Checking Documents folder…" : "Check Documents folder") {
                    Task {
                        await model.checkInbox()
                        feedback = model.importMessage ?? "No new file in Documents"
                    }
                }
                .disabled(model.checkingInbox)
            }
        }
        .navigationTitle("Google Drive")
        .sheet(isPresented: $showingScanner) {
            KeyPairingScannerSheet { scannedKey in
                showingScanner = false
                saveKey(scannedKey)
            }
        }
        .onAppear {
            model.refreshConnectionStates()
        }
    }

    private func turnOnDriveSync() {
        busy = true
        feedback = nil
        Task {
            defer { busy = false }
            do {
                try await DriveSync.turnOnDriveSync()
                feedback = GmailSync.hasDriveScope()
                    ? "Drive sync turned on"
                    : "Drive access was not granted"
                await model.reload()
            } catch {
                feedback = error.localizedDescription
                model.refreshConnectionStates()
            }
        }
    }

    private func savePastedKey() {
        do {
            let key = try DriveSyncKey(pairingString: pastedKey)
            saveKey(key)
        } catch {
            feedback = error.localizedDescription
        }
    }

    private func saveKey(_ key: DriveSyncKey) {
        updateKey {
            try DriveSync.saveKey(key)
        } success: {
            pastedKey = ""
            feedback = "Saved key \(key.keyIDFormatted)"
        }
    }

    private func removeKey() {
        updateKey {
            try DriveSync.clearKey()
        } success: {
            feedback = "Key removed"
        }
    }

    private func updateKey(_ change: @escaping @MainActor @Sendable () throws -> Void, success: @escaping () -> Void) {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await SyncEngine.shared.withSignIn { try change() }
                success()
                model.refreshConnectionStates()
            } catch {
                feedback = error.localizedDescription
            }
        }
    }
}
