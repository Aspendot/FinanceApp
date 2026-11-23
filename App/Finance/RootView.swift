import LocalAuthentication
import SwiftUI
import UIKit

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
    @State private var context: LAContext?
    @State private var triedAutomatically = false
    @State private var snapshotCover: UIView?
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ZStack {
            if !enabled || unlocked {
                content
                    .accessibilityHidden(phase != .active)
                    .allowsHitTesting(phase == .active)
            }
            if phase != .active || (enabled && !unlocked) {
                Color(.systemBackground).ignoresSafeArea()
            }
            if phase == .active && enabled && !unlocked {
                VStack(spacing: 14) {
                    Image(systemName: "lock.fill").font(.system(size: 34)).foregroundStyle(.secondary)
                    Text("Finance is locked").font(.headline)
                    if !message.isEmpty {
                        Text(message).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    Button("Unlock") { Task { await unlock() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(context != nil)
                }
                .padding(32)
            }
        }
        .onChange(of: phase, initial: true) { _, newPhase in
            guard newPhase == .active, enabled, !unlocked, !triedAutomatically else { return }
            triedAutomatically = true
            Task { await unlock() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIScene.didEnterBackgroundNotification)) { notification in
            unlocked = false
            triedAutomatically = false
            context?.invalidate()
            context = nil
            message = ""
            // UIKit may take the switcher snapshot before SwiftUI renders its next frame.
            guard let scene = notification.object as? UIWindowScene,
                  let window = scene.keyWindow ?? scene.windows.first(where: { $0.rootViewController != nil })
            else { return }
            snapshotCover?.removeFromSuperview()
            let cover = UIView(frame: window.bounds)
            cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            cover.backgroundColor = .systemBackground
            window.addSubview(cover)
            snapshotCover = cover
        }
        .onReceive(NotificationCenter.default.publisher(for: UIScene.didActivateNotification)) { _ in
            snapshotCover?.removeFromSuperview()
            snapshotCover = nil
        }
    }

    private func unlock() async {
        guard phase == .active, enabled, !unlocked, context == nil else { return }
        let request = LAContext()
        context = request
        message = ""
        defer {
            if context === request { context = nil }
        }
        do {
            let accepted = try await request.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock Finance")
            if context === request { unlocked = accepted }
        } catch {
            guard context === request else { return }
            if (error as? LAError)?.code == .passcodeNotSet {
                message = "Set a device passcode in Settings, then try again."
            } else {
                message = error.localizedDescription
            }
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
