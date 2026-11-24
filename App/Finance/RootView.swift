import Combine
import FinanceCore
import LocalAuthentication
import SwiftUI
import UIKit

struct RootView: View {
    @StateObject private var model = AppModel()
    @StateObject private var session = AppSession()
    @AppStorage("faceIDLock") private var faceIDLockEnabled = true
    @Environment(\.scenePhase) private var phase
    @State private var csvImportAlertMessage: String?
    @State private var isUnlocked = false

    private var canPresentProtectedUI: Bool {
        session.isDemo || !faceIDLockEnabled || isUnlocked
    }

    var body: some View {
        Group {
            if session.isDemo {
                protectedContent
            } else {
                LockGate(unlocked: $isUnlocked, onLock: {
                    session.activeSheet = nil
                }) {
                    protectedContent
                }
            }
        }
        .tint(Theme.accent)
        .preferredColorScheme(session.demoColorScheme)
        .environment(\.privacyMasked, session.privacyMasked)
        .environmentObject(model)
        .environmentObject(session)
        .onOpenURL { url in
            if canPresentProtectedUI {
                processIncomingURL(url)
            } else {
                session.pendingLockedURL = url
            }
        }
        .onChange(of: canPresentProtectedUI) { _, allowed in
            guard allowed else { return }
            if let queued = session.pendingLockedURL {
                session.pendingLockedURL = nil
                processIncomingURL(queued)
            }
            if !session.isDemo,
               let action = SharedStore.consumePendingAction(),
               let url = URL(string: "financeapp://\(action)")
            {
                _ = session.handleDeepLink(url)
            }
        }
        .onChange(of: phase, initial: true) { _, newPhase in
            guard !session.isDemo else { return }
            if newPhase == .background {
                if faceIDLockEnabled {
                    session.activeSheet = nil
                }
                Task {
                    await BackgroundAssertion.run(name: "FinanceScheduleRefresh") {
                        await BackgroundRefresh.scheduleIfNeeded()
                    }
                }
            } else if newPhase == .active {
                let dayChanged = session.refreshTodayIfNeeded()
                if canPresentProtectedUI,
                   let action = SharedStore.consumePendingAction(),
                   let url = URL(string: "financeapp://\(action)")
                {
                    _ = session.handleDeepLink(url)
                }
                model.refreshRunLog()
                Task {
                    await model.checkInbox()
                    if dayChanged {
                        await model.reload()
                    }
                    session.hasCompletedInitialLoad = true
                    guard UIApplication.shared.applicationState == .active else { return }
                    await model.syncGmail(userInitiated: false)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification).receive(on: DispatchQueue.main)) { _ in
            guard !session.isDemo else { return }
            if session.refreshTodayIfNeeded() {
                Task { await model.reload() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .financePendingControlAction).receive(on: DispatchQueue.main)) { note in
            guard !session.isDemo else { return }
            let action = (note.object as? String) ?? SharedStore.consumePendingAction()
            if let action, let url = URL(string: "financeapp://\(action)") {
                _ = SharedStore.consumePendingAction()
                if canPresentProtectedUI {
                    _ = session.handleDeepLink(url)
                } else {
                    session.pendingLockedURL = url
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .backgroundGmailSyncUpdated).receive(on: DispatchQueue.main)) { _ in
            guard !session.isDemo, phase == .active else { return }
            Task { await model.reload() }
        }
    }

    private func processIncomingURL(_ url: URL) {
        if session.handleDeepLink(url) {
            return
        }
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

    private var protectedContent: some View {
        mainTabs
            .sheet(item: $session.activeSheet) { sheet in
                Group {
                    switch sheet {
                    case .quickAdd:
                        QuickAddSheet()
                    case .scanReceipt:
                        ReceiptScanSheet()
                    case .ask:
                        AskFinanceSheet()
                    case .debtPayoff:
                        DebtPayoffSheet()
                    case .targets:
                        if let data = session.resolvedData(from: model) {
                            let mode = session.periodMode
                            let periods = data.periods(for: mode)
                            let totals = data.totals(for: mode)
                            let selectedID = (mode == .payCycle ? session.monthsSelectedCycleID : session.monthsSelectedMonth)
                                ?? periods.last?.id ?? ""
                            let partialID = periods.last(where: { $0.isInProgress })?.id
                            let resolvedPlanSummary = PlanSummary.compute(
                                plan: data.effectivePlan,
                                planWindow: mode == .calendarMonth ? data.bundle.planWindow : nil,
                                totalsByMonth: totals,
                                selectedMonth: selectedID,
                                currentMonth: periods.last?.id ?? selectedID,
                                inProgressMonth: partialID
                            )
                            let pace = periods.first(where: { $0.id == selectedID })?.paceProgress(on: session.today)
                                ?? data.currentPeriod(for: mode, today: session.today)?.paceProgress(on: session.today)
                            NavigationStack {
                                WhereToCutView(
                                    plan: resolvedPlanSummary,
                                    isPresentedModally: true,
                                    activePace: pace
                                )
                            }
                        } else {
                            NoDataView()
                        }
                    case .reviewInbox:
                        ReviewInboxSheet()
                    case .runway:
                        CashFlowRunwayView()
                    case .addReminder(let title, let date, let note):
                        AddReminderSheet(defaultTitle: title, defaultDate: date, defaultNote: note)
                    case .subscriptionDetail(let sub):
                        SubscriptionDetailSheet(subscription: sub)
                    case .debtDetail(let debt):
                        DebtDetailSheet(debt: debt)
                    case .categoryDetail(let name, let periodID):
                        CategoryDetailSheet(categoryName: name, periodID: periodID)
                    case .merchantDetail(let name, let periodID):
                        MerchantDetailSheet(merchantName: name, periodID: periodID)
                    }
                }
                .tint(Theme.accent)
                .preferredColorScheme(session.demoColorScheme)
                .environment(\.privacyMasked, session.privacyMasked)
                .environmentObject(model)
                .environmentObject(session)
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
    @Binding private var unlocked: Bool
    @State private var message = ""
    @State private var context: LAContext?
    @State private var triedAutomatically = false
    @State private var snapshotCover: UIView?
    private let onLock: () -> Void
    private let content: Content

    init(
        unlocked: Binding<Bool>,
        onLock: @escaping () -> Void = {},
        @ViewBuilder content: () -> Content
    ) {
        self._unlocked = unlocked
        self.onLock = onLock
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
            onLock()
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
