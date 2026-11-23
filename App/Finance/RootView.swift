import Combine
import LocalAuthentication
import SwiftUI
import UIKit

struct RootView: View {
    @StateObject private var model = AppModel()
    @StateObject private var session = AppSession()
    @Environment(\.scenePhase) private var phase

    var body: some View {
        Group {
            if session.isDemo {
                mainTabs
            } else {
                LockGate {
                    mainTabs
                }
            }
        }
        .tint(Theme.accent)
        .preferredColorScheme(session.demoColorScheme)
        .environmentObject(model)
        .environmentObject(session)
        .onChange(of: phase, initial: true) { _, newPhase in
            guard !session.isDemo else { return }
            if newPhase == .background {
                Task {
                    await BackgroundAssertion.run(name: "FinanceScheduleRefresh") {
                        await BackgroundRefresh.scheduleIfNeeded()
                    }
                }
            } else if newPhase == .active {
                model.refreshRunLog()
                Task {
                    await model.checkInbox()
                    session.hasCompletedInitialLoad = true
                    guard UIApplication.shared.applicationState == .active else { return }
                    await model.syncGmail()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .backgroundGmailSyncUpdated).receive(on: DispatchQueue.main)) { _ in
            guard !session.isDemo, phase == .active else { return }
            Task { await model.reload() }
        }
    }

    private var mainTabs: some View {
        TabView(selection: $session.selectedTab) {
            Tab("Now", systemImage: "calendar", value: AppTab.now) {
                NowView()
            }
            Tab("Payments", systemImage: "list.bullet", value: AppTab.payments) {
                PaymentsView()
            }
            Tab("Months", systemImage: "chart.bar", value: AppTab.months) {
                MonthsView()
            }
            Tab("More", systemImage: "ellipsis.circle", value: AppTab.more) {
                MoreView()
            }
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
                Theme.page.ignoresSafeArea()
            }
            if phase == .active && enabled && !unlocked {
                VStack(spacing: 14) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 32, weight: .medium))
                        .foregroundStyle(Theme.muted)
                        .accessibilityHidden(true)
                    Text("Finance is locked")
                        .font(.headline)
                        .foregroundStyle(Theme.ink)
                    if !message.isEmpty {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(Theme.muted)
                            .multilineTextAlignment(.center)
                    }
                    Button("Unlock") { Task { await unlock() } }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                        .frame(minHeight: Theme.minTouchTarget)
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
            cover.backgroundColor = UIColor(named: "Page") ?? .systemBackground
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
        StateCard(
            kind: .empty,
            title: "No data yet",
            message: "Turn on Google Drive sync in More → Connections."
        )
    }
}
