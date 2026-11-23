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

    private var connectionColor: Color {
        if driveState.needsDriveConsent {
            return Theme.bad
        }
        if model.gmailConnected && model.driveScopeGranted && model.driveKeyPaired {
            return Theme.good
        }
        return Theme.muted
    }

    var body: some View {
        List {
            Section {
                SettingsValueRow(
                    label: "Connection",
                    value: model.driveStatusLine,
                    valueColor: connectionColor
                )
                if let keyID = DriveSync.currentKeyIDFormatted() {
                    SettingsValueRow(
                        label: "Key ID",
                        value: keyID,
                        monospaced: true,
                        selectable: true
                    )
                }
                if let last = driveState.lastCheckedAt {
                    SettingsValueRow(
                        label: "Last checked",
                        value: SyncStorage.formatCheckTime(last)
                    )
                }
                if let importedAt = driveState.lastImportedGeneratedAt {
                    SettingsValueRow(
                        label: "Latest file",
                        value: FinanceFormat.bundleTimestamp(importedAt)
                    )
                }
                if let error = driveState.lastErrorMessage, !error.isEmpty {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(Theme.bad)
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
                if !model.gmailConnected {
                    Text("Sign in to Gmail first to use Google Drive sync.")
                        .font(.footnote)
                        .foregroundStyle(Theme.muted)
                } else if !model.driveScopeGranted || driveState.needsDriveConsent {
                    PrimaryActionButton(title: "Turn on Drive sync") {
                        turnOnDriveSync()
                    }
                    .disabled(busy || model.syncing)
                    .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                } else {
                    SettingsValueRow(
                        label: "Access",
                        value: "Granted",
                        valueColor: Theme.good
                    )
                }
            } header: {
                SectionLabel("Google Drive access")
            } footer: {
                Text("Uses a private app folder only this app can read.")
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
            }
            .listRowBackground(Theme.surface)

            Section {
                if !model.driveKeyPaired {
                    PrimaryActionButton(title: "Scan QR code") {
                        showingScanner = true
                    }
                    .disabled(busy)
                    .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                } else {
                    Button {
                        showingScanner = true
                    } label: {
                        Text("Scan QR code")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(busy ? Theme.muted : Theme.accent)
                    }
                    .disabled(busy)
                }

                TextField("finance-key:v1:...", text: $pastedKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.footnote.monospaced())
                    .foregroundStyle(Theme.ink)

                Button {
                    savePastedKey()
                } label: {
                    Text("Save pasted key")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(
                            busy || pastedKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? Theme.muted
                                : Theme.accent
                        )
                }
                .disabled(busy || pastedKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if model.driveKeyPaired {
                    Button(role: .destructive) {
                        removeKey()
                    } label: {
                        Text("Remove key")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(busy || model.syncing ? Theme.muted : Theme.bad)
                    }
                    .disabled(busy || model.syncing)
                }
            } header: {
                SectionLabel("Encryption key")
            } footer: {
                Text("Match the Key ID with your PC exporter to confirm both devices share the same key.")
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
            }
            .listRowBackground(Theme.surface)

            Section {
                if model.gmailConnected && model.driveScopeGranted && model.driveKeyPaired {
                    PrimaryActionButton(title: model.syncing ? "Syncing…" : "Sync now") {
                        Task {
                            await model.syncGmail(userInitiated: true)
                            feedback = model.syncMessage
                        }
                    }
                    .disabled(busy || model.syncing)
                    .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                }

                Button {
                    Task {
                        await model.checkInbox()
                        feedback = model.importMessage ?? "No new file found"
                    }
                } label: {
                    Text(model.checkingInbox ? "Checking for a file…" : "Import a file instead")
                        .font(.subheadline)
                        .foregroundStyle(model.checkingInbox ? Theme.muted : Theme.ink2)
                }
                .disabled(model.checkingInbox)
            } header: {
                SectionLabel("Sync")
            } footer: {
                Text("Import a file instead checks the app's local Documents folder.")
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
            }
            .listRowBackground(Theme.surface)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.page)
        .navigationTitle("Google Drive")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingScanner) {
            KeyPairingScannerSheet { scannedKey in
                showingScanner = false
                do {
                    try DriveSync.saveKey(scannedKey)
                    feedback = "Paired key \(scannedKey.keyIDFormatted)"
                    model.refreshConnectionStates()
                } catch {
                    feedback = error.localizedDescription
                }
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
            try DriveSync.saveKey(key)
            pastedKey = ""
            feedback = "Saved key \(key.keyIDFormatted)"
            model.refreshConnectionStates()
        } catch {
            feedback = error.localizedDescription
        }
    }

    private func removeKey() {
        do {
            try DriveSync.clearKey()
            feedback = "Key removed"
            model.refreshConnectionStates()
        } catch {
            feedback = error.localizedDescription
        }
    }
}
