import Combine
import LocalAuthentication
import SwiftUI
import UIKit

struct RootView: View {
    @StateObject private var model = AppModel()
    @StateObject private var session = AppSession()
    @Environment(\.scenePhase) private var phase
    @State private var csvImportAlertMessage: String?

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
        .sheet(item: $session.activeSheet) { sheet in
            Group {
                switch sheet {
                case .quickAdd:
                    QuickAddSheet()
                case .ask:
                    AskFinanceSheet()
                case .debtPayoff:
                    DebtPayoffSheet()
                case .targets:
                    if let data = session.resolvedData(from: model) {
                        NavigationStack {
                            WhereToCutView(plan: data.planSummary, isPresentedModally: true)
                        }
                    } else {
                        NoDataView()
                    }
                }
            }
            .tint(Theme.accent)
            .preferredColorScheme(session.demoColorScheme)
            .environmentObject(model)
            .environmentObject(session)
        }
        .onOpenURL { url in
            guard !session.isDemo, url.pathExtension.lowercased() == "csv" else { return }
            Task {
                do {
                    let result = try await model.importPayPayCSV(url: url)
                    csvImportAlertMessage = "Imported \(result.entries.count) payments from \(url.lastPathComponent). Skipped \(result.skippedDuplicates) duplicates."
                } catch {
                    csvImportAlertMessage = error.localizedDescription
                }
            }
        }
        .alert(
            "CSV Import",
            isPresented: Binding(
                get: { csvImportAlertMessage != nil },
                set: { if !$0 { csvImportAlertMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { csvImportAlertMessage = nil }
        } message: {
            Text(csvImportAlertMessage ?? "")
        }
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
            Tab("Payments", systemImage: "list.bullet.rectangle", value: AppTab.payments) {
                PaymentsView()
            }
            Tab("Months", systemImage: "chart.bar.fill", value: AppTab.months) {
                MonthsView()
            }
            Tab("More", systemImage: "slider.horizontal.3", value: AppTab.more) {
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
                VStack(spacing: 18) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [Theme.heroTop, Theme.heroBottom],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 72, height: 72)
                            .overlay(
                                RoundedRectangle(cornerRadius: 22, style: .continuous)
                                    .strokeBorder(Theme.heroAccent.opacity(0.30), lineWidth: 1)
                            )
                            .shadow(color: Theme.accent.opacity(0.22), radius: 16, y: 8)
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(Theme.heroAccent)
                    }
                    .accessibilityHidden(true)

                    VStack(spacing: 6) {
                        Text("Finance is locked")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(Theme.ink)
                        if !message.isEmpty {
                            Text(message)
                                .font(.footnote)
                                .foregroundStyle(Theme.muted)
                                .multilineTextAlignment(.center)
                        }
                    }

                    PrimaryActionButton(title: "Unlock with Face ID") {
                        Task { await unlock() }
                    }
                    .frame(maxWidth: 220)
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
