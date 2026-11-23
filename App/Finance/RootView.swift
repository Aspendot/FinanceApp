import LocalAuthentication
import SwiftUI

struct RootView: View {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var phase

    var body: some View {
        LockGate {
            TabView {
                NowView().tabItem { Label("Now", systemImage: "calendar") }
                PaymentsView().tabItem { Label("Payments", systemImage: "list.bullet") }
                MoreView().tabItem { Label("More", systemImage: "ellipsis.circle") }
            }
        }
        .environmentObject(model)
        .task {
            model.checkInbox()
            await model.syncGmail()
        }
        .onChange(of: phase) { _, newPhase in
            guard newPhase == .active else { return }
            model.checkInbox()
            model.reload()
            Task { await model.syncGmail() }
        }
    }
}

/// Hides the app behind Face ID (or the passcode) until unlocked, and again after
/// it goes to the background. It can be turned off under More.
struct LockGate<Content: View>: View {
    @AppStorage("faceIDLock") private var enabled = true
    @Environment(\.scenePhase) private var phase
    @State private var unlocked = false
    @State private var message = ""
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ZStack {
            content
            if enabled && !unlocked {
                Color(.systemBackground).ignoresSafeArea()
                VStack(spacing: 14) {
                    Image(systemName: "lock.fill").font(.system(size: 34)).foregroundStyle(.secondary)
                    Text("Finance is locked").font(.headline)
                    if !message.isEmpty {
                        Text(message).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    Button("Unlock") { Task { await unlock() } }
                        .buttonStyle(.borderedProminent)
                }
                .padding(32)
                .task { await unlock() }
            }
        }
        .onChange(of: phase) { _, newPhase in
            if newPhase == .background { unlocked = false }
        }
    }

    private func unlock() async {
        let context = LAContext()
        do {
            unlocked = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock Finance")
        } catch {
            message = error.localizedDescription
        }
    }
}

struct NoDataView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No data yet").font(.headline)
            Text("On your PC, open the Apple Devices app, choose your iPhone, then Files → Finance, and drag in finance-bundle.json from Documents\\Finance\\data\\export. Then come back to this app.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }
}
