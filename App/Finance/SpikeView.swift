import FinanceCore
import SwiftUI
import UIKit
import WidgetKit

/// Step 0 of the iPhone app: one screen that tests each risky piece on a real phone
/// after SideStore has signed the app. Each row shows the latest result.
struct SpikeView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var model: AppModel
    @State private var groupResult = SharedStore.groupID.map { "App Group: \($0)" } ?? "No App Group available"
    @State private var faceIDResult = "Not tried yet"
    @State private var notifyResult = "Not tried yet"
    @State private var refreshResult = "Not scheduled yet"
    @State private var clientID = GmailSync.clientID ?? ""
    @State private var signInTask: Task<Void, Never>?
    @State private var gmailResult = (try? GmailSync.hasCredentials()) == true ? "Signed in" : "Not signed in"
    @State private var notices = GmailSync.recentNotices()

    var body: some View {
        Group {
            List {
                ConnectionsSection()
                Section("Data file") {
                    Text(model.importMessage ?? (model.data == nil ? "No data file yet" : "A data file is stored"))
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Check for a new data file") { Task { await model.checkInbox() } }
                        .disabled(model.checkingInbox)
                }
                Section("Widget") {
                    Text(groupResult).font(.footnote).foregroundStyle(.secondary)
                    Button("Send a test value to the widget") {
                        SharedStore.write(WidgetSnapshot(title: "Test value", value: "¥12,345", detail: "Sent " + Date().formatted(date: .omitted, time: .shortened), updatedAt: Date()))
                        WidgetCenter.shared.reloadTimelines(ofKind: "FinanceWidget")
                        groupResult = SharedStore.groupID.map { "Sent through \($0). Add the Finance widget to see it." } ?? "No App Group: the widget can't receive data"
                    }
                }
                Section("Face ID") {
                    Text(faceIDResult).font(.footnote).foregroundStyle(.secondary)
                    Button("Unlock with Face ID") {
                        Task { faceIDResult = await Biometrics.unlock() }
                    }
                }
                Section("Notifications") {
                    Text(notifyResult).font(.footnote).foregroundStyle(.secondary)
                    Button("Allow notifications") {
                        Task { notifyResult = await Notifier.requestPermission() }
                    }
                    Button("Send a test notification now") {
                        Task {
                            await Notifier.post(title: "Finance", body: "Test notification")
                            notifyResult = await Notifier.status() + ". Sent one now."
                        }
                    }
                    Button("Send one in 10 seconds (lock the phone)") {
                        Task {
                            await Notifier.post(title: "Finance", body: "Test notification on the lock screen", after: 10)
                            notifyResult = await Notifier.status() + ". One arrives in 10 seconds."
                        }
                    }
                }
                .task { notifyResult = await Notifier.status() }
                Section("Background refresh") {
                    Text(refreshResult).font(.footnote).foregroundStyle(.secondary)
                    Button("Schedule background refresh") {
                        Task { refreshResult = await BackgroundRefresh.scheduleIfNeeded() }
                    }
                    Button("Reload run log") {
                        model.refreshRunLog()
                    }
                }
                Section("Background checks") {
                    if model.runLog.isEmpty {
                        Text("No checks recorded yet").font(.footnote).foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(model.runLog.prefix(20))) { run in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text("\(SyncStorage.formatCheckTime(run.startedAt)) · \(run.trigger.rawValue)")
                                        .font(.subheadline)
                                    Spacer()
                                    Text(Self.outcomeSummary(run))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                if let error = run.errorMessage, !error.isEmpty, error != run.outcome.label {
                                    Text(error)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                        }
                    }
                }
                Section("Gmail (read-only)") {
                    TextField("Google iOS client ID", text: $clientID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.footnote)
                    Text(gmailResult).font(.footnote).foregroundStyle(.secondary)
                    if let signInTask {
                        Button("Cancel sign-in") { signInTask.cancel() }
                    } else {
                        Button("Sign in with Google") {
                            signInTask = Task { @MainActor in
                                defer { signInTask = nil }
                                do {
                                    try await GmailSync.signIn(clientID: clientID)
                                    notices = GmailSync.recentNotices()
                                    gmailResult = "Signed in with read-only Gmail access"
                                    await model.reload()
                                } catch {
                                    gmailResult = Task.isCancelled
                                        ? "Sign-in cancelled"
                                        : "Sign-in failed: " + error.localizedDescription
                                }
                            }
                        }
                    }
                    Button("Fetch bank emails from the last 7 days") {
                        Task {
                            await model.syncGmail(userInitiated: true)
                            notices = GmailSync.recentNotices()
                            if let message = model.syncMessage { gmailResult = message }
                        }
                    }
                    .disabled(model.syncing || signInTask != nil)
                    Button("Sign out", role: .destructive) {
                        Task {
                            do {
                                try await GmailSync.signOut()
                                gmailResult = "Signed out"
                            } catch {
                                gmailResult = "Sign-out failed: " + error.localizedDescription
                            }
                            notices = GmailSync.recentNotices()
                            await model.reload()
                        }
                    }
                    .disabled(model.syncing || signInTask != nil)
                }
                if !notices.isEmpty {
                    Section("Recent notices") {
                        ForEach(notices.prefix(40), id: \.messageID) { n in
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(n.merchant ?? "(no shop name)").font(.subheadline).lineLimit(1)
                                    Text("\(n.day) · \(n.source.rawValue) · \(n.kind.rawValue)").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(n.amount.map { ($0 < 0 ? "+¥" : "¥") + $0.magnitude.formatted() } ?? "–")
                                    .font(.subheadline.monospacedDigit())
                            }
                        }
                    }
                }
                Section("This install") {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Bundle ID (press and hold to copy it for Google)").font(.caption).foregroundStyle(.secondary)
                        Text(Bundle.main.bundleIdentifier ?? "?").font(.footnote.monospaced()).textSelection(.enabled)
                    }
                    LabeledContent("Version", value: (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?")
                    LabeledContent("iOS", value: UIDevice.current.systemVersion)
                }
            }
            .navigationTitle("Finance test")
            .onAppear {
                notices = GmailSync.recentNotices()
                model.refreshRunLog()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    notices = GmailSync.recentNotices()
                    model.refreshRunLog()
                }
            }
        }
    }

    private static func outcomeSummary(_ run: SyncRunRecord) -> String {
        if run.outcome == .updated, run.newPayments > 0 {
            return "Updated (\(run.newPayments) new)"
        }
        return run.outcome.label
    }
}
