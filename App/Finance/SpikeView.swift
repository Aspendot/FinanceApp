import FinanceCore
import SwiftUI
import UIKit
import WidgetKit

/// Step 0 of the iPhone app: one screen that tests each risky piece on a real phone
/// after SideStore has signed the app. Each row shows the latest result.
struct SpikeView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var groupResult = SharedStore.groupID.map { "App Group: \($0)" } ?? "No App Group available"
    @State private var faceIDResult = "Not tried yet"
    @State private var notifyResult = "Not tried yet"
    @State private var refreshResult = "Not scheduled yet"
    @State private var runs = SpikeLog.load().backgroundRuns
    @State private var clientID = GmailSync.clientID ?? ""
    @State private var gmailResult = GmailSync.isSignedIn ? "Signed in" : "Not signed in"
    @State private var notices = GmailSync.recentNotices()

    var body: some View {
        NavigationStack {
            List {
                Section("Widget") {
                    Text(groupResult).font(.footnote).foregroundStyle(.secondary)
                    Button("Send a test value to the widget") {
                        SharedStore.write(WidgetSnapshot(title: "Test value", value: "¥12,345", detail: "Sent " + Date().formatted(date: .omitted, time: .shortened), updatedAt: Date()))
                        WidgetCenter.shared.reloadAllTimelines()
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
                    Button("Send a test notification") {
                        Task {
                            await Notifier.post(title: "Finance", body: "Test notification")
                            notifyResult = "Sent; it shows when the app is in the background"
                        }
                    }
                }
                Section("Background refresh") {
                    Text(refreshResult).font(.footnote).foregroundStyle(.secondary)
                    Text(runs.isEmpty ? "No background runs yet" : "\(runs.count) runs, last \(runs.last!.formatted(date: .abbreviated, time: .shortened))")
                        .font(.footnote)
                    Button("Schedule background refresh") {
                        refreshResult = BackgroundRefresh.schedule()
                    }
                    Button("Reload the run count") {
                        runs = SpikeLog.load().backgroundRuns
                    }
                }
                Section("Gmail (read-only)") {
                    TextField("Google iOS client ID", text: $clientID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.footnote)
                    Text(gmailResult).font(.footnote).foregroundStyle(.secondary)
                    Button("Sign in with Google") {
                        Task {
                            do {
                                try await GmailSync.signIn(clientID: clientID)
                                notices = GmailSync.recentNotices()
                                gmailResult = "Signed in with read-only Gmail access"
                            } catch {
                                gmailResult = "Sign-in failed: " + error.localizedDescription
                            }
                        }
                    }
                    Button("Fetch bank emails from the last 7 days") {
                        Task {
                            do {
                                let fresh = try await GmailSync.run(days: 7)
                                notices = GmailSync.recentNotices()
                                gmailResult = "\(fresh.count) new notices; the widget was updated"
                            } catch {
                                gmailResult = "Fetch failed: " + error.localizedDescription
                            }
                        }
                    }
                    Button("Sign out", role: .destructive) {
                        do {
                            try GmailSync.signOut()
                            notices = []
                            gmailResult = "Signed out"
                        } catch {
                            gmailResult = "Sign-out failed: " + error.localizedDescription
                        }
                    }
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
                                Text(n.amount.map { ($0 < 0 ? "+¥" : "¥") + abs($0).formatted() } ?? "–")
                                    .font(.subheadline.monospacedDigit())
                            }
                        }
                    }
                }
                Section("This install") {
                    LabeledContent("Bundle ID", value: Bundle.main.bundleIdentifier ?? "?")
                    LabeledContent("Version", value: (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?")
                    LabeledContent("iOS", value: UIDevice.current.systemVersion)
                }
            }
            .navigationTitle("Finance test")
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { notices = GmailSync.recentNotices() }
            }
        }
    }
}
