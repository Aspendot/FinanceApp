import Combine
import FinanceCore
import Foundation
import SwiftUI

/// Top-level tabs in the app.
enum AppTab: String, CaseIterable, Hashable {
    case now
    case payments
    case months
    case more
}

/// Settings screens reachable from the More tab.
enum MoreDestination: String, Hashable {
    case gmail
    case moneyForward
    case drive
    case receiptScanner
    case notifications
    case localData
    case syncHealth
    case diagnostics
}

/// Modal sheets launchable from any primary tab, deep links, or demo arguments.
enum ActiveSheet: Identifiable, Equatable {
    case quickAdd
    case scanReceipt
    case ask
    case debtPayoff
    case targets
    case reviewInbox
    case runway
    case addReminder(defaultTitle: String?, defaultDate: String?, defaultNote: String?)
    case subscriptionDetail(SubscriptionItem)
    case debtDetail(DebtEntry)
    case categoryDetail(name: String, periodID: String?)
    case merchantDetail(name: String, periodID: String?)

    var id: String {
        switch self {
        case .quickAdd: return "quickAdd"
        case .scanReceipt: return "scanReceipt"
        case .ask: return "ask"
        case .debtPayoff: return "debtPayoff"
        case .targets: return "targets"
        case .reviewInbox: return "reviewInbox"
        case .runway: return "runway"
        case .addReminder(let t, let d, _): return "addReminder:\(t ?? ""):\(d ?? "")"
        case .subscriptionDetail(let sub): return "sub:\(sub.id)"
        case .debtDetail(let debt): return "debt:\(debt.name)"
        case .categoryDetail(let name, let p): return "cat:\(name):\(p ?? "")"
        case .merchantDetail(let name, let p): return "merchant:\(name):\(p ?? "")"
        }
    }
}

/// Shared UI coordination across tabs, global period mode, privacy mask, deep links, and demo mode.
@MainActor
final class AppSession: ObservableObject {
    let isDemo: Bool
    let demoData: FinanceData?
    let demoToday: String?
    let demoRunLog: [SyncRunRecord]
    let demoColorScheme: ColorScheme?

    @Published var selectedTab: AppTab
    @Published var morePath: [MoreDestination]
    @Published var periodMode: BudgetPeriodMode = .calendarMonth
    @Published var privacyMasked: Bool {
        didSet {
            if !isDemo {
                UserDefaults.standard.set(privacyMasked, forKey: Self.privacyMaskedKey)
            }
        }
    }
    /// Calendar day string ("YYYY-MM-DD") in Japan time, refreshed on foreground and midnight rollover.
    @Published private(set) var today: String
    /// Incremented on every programmatic drill-down to Payments so local kind/status filters reset cleanly.
    @Published private(set) var paymentsRouteRevision: Int = 0
    /// Deep link or CSV URL received while Face ID lock was active, executed once unlocked.
    var pendingLockedURL: URL?

    @Published var paymentsMonth: String?
    @Published var paymentsCycleID: String?
    @Published var paymentsCategory: String?
    @Published var paymentsQuery: String = ""
    @Published var paymentsAllMonths: Bool = false
    @Published var paymentsOnlyUncategorized: Bool = false
    @Published var paymentsSource: String? = nil
    @Published var paymentsLayer: SpendingLayer? = nil
    @Published var paymentsDateRange: ClosedRange<String>? = nil
    @Published var paymentsDateRangeLabel: String? = nil

    @Published var monthsSelectedMonth: String?
    @Published var monthsSelectedCycleID: String?
    @Published var activeSheet: ActiveSheet?
    @Published var hasCompletedInitialLoad: Bool

    private static let privacyMaskedKey = "financePrivacyMasked"

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        let demo = arguments.contains("-demo")
        let target = Self.parseInitialScreen(from: arguments)
        self.isDemo = demo
        self.selectedTab = target.tab
        self.morePath = target.destination.map { [$0] } ?? []
        self.activeSheet = target.sheet
        self.periodMode = target.periodMode
        self.privacyMasked = demo ? false : UserDefaults.standard.bool(forKey: Self.privacyMaskedKey)
        if demo {
            let loaded = DemoData.load()
            self.demoData = loaded?.data
            self.demoToday = loaded?.today
            self.today = loaded?.today ?? JST.day(Date())
            self.demoRunLog = loaded?.runLog ?? []
            self.demoColorScheme = Self.parseColorScheme(from: arguments)
            self.hasCompletedInitialLoad = true
        } else {
            self.demoData = nil
            self.demoToday = nil
            self.today = JST.day(Date())
            self.demoRunLog = []
            self.demoColorScheme = nil
            self.hasCompletedInitialLoad = false
        }
    }

    /// Refreshes `today` in JST and returns `true` when the calendar day rolled over.
    @discardableResult
    func refreshTodayIfNeeded(now: Date = Date()) -> Bool {
        guard !isDemo else { return false }
        let latest = JST.day(now)
        if latest != today {
            today = latest
            return true
        }
        return false
    }

    /// Data to display across all screens (bundled demo data in `-demo` mode, live data otherwise).
    func resolvedData(from model: AppModel) -> FinanceData? {
        isDemo ? demoData : model.data
    }

    /// Sync log entries for More (invented calm records in `-demo` mode, live run log otherwise).
    func resolvedRunLog(from model: AppModel) -> [SyncRunRecord] {
        isDemo ? demoRunLog : model.runLog
    }

    /// Navigates to Payments with optional month/cycle, category, layer, date range, search query, source, or uncategorized filter.
    func openPayments(
        month: String? = nil,
        cycleID: String? = nil,
        category: String? = nil,
        query: String? = nil,
        source: String? = nil,
        layer: SpendingLayer? = nil,
        dateRange: ClosedRange<String>? = nil,
        dateRangeLabel: String? = nil,
        onlyUncategorized: Bool = false
    ) {
        if let dateRange {
            paymentsDateRange = dateRange
            paymentsDateRangeLabel = dateRangeLabel
            paymentsAllMonths = true
        } else {
            paymentsDateRange = nil
            paymentsDateRangeLabel = nil
            if let cycleID {
                periodMode = .payCycle
                paymentsCycleID = cycleID
                paymentsAllMonths = false
            } else if let month {
                if month.hasPrefix("cycle:") {
                    periodMode = .payCycle
                    paymentsCycleID = month
                } else {
                    periodMode = .calendarMonth
                    paymentsMonth = month
                }
                paymentsAllMonths = false
            } else {
                paymentsAllMonths = true
            }
        }
        paymentsCategory = category
        paymentsQuery = query ?? ""
        paymentsSource = source
        paymentsLayer = layer
        paymentsOnlyUncategorized = onlyUncategorized
        paymentsRouteRevision &+= 1
        selectedTab = .payments
    }

    /// Navigates to Months focused on a specific month or pay cycle.
    func openMonths(month: String?) {
        if let month {
            if month.hasPrefix("cycle:") {
                periodMode = .payCycle
                monthsSelectedCycleID = month
            } else {
                periodMode = .calendarMonth
                monthsSelectedMonth = month
            }
        }
        selectedTab = .months
    }

    /// Handles `financeapp://` deep links from Control Center widgets, Lock Screen widgets, or Shortcuts.
    @discardableResult
    func handleDeepLink(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "financeapp" else { return false }
        let host = (url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).lowercased()
        switch host {
        case "quick-add", "add":
            selectedTab = .now
            activeSheet = .quickAdd
            return true
        case "scan-receipt", "scan", "receipt":
            selectedTab = .now
            activeSheet = .scanReceipt
            return true
        case "runway", "forecast":
            selectedTab = .now
            activeSheet = .runway
            return true
        case "review", "inbox":
            selectedTab = .now
            activeSheet = .reviewInbox
            return true
        case "ask":
            selectedTab = .now
            activeSheet = .ask
            return true
        case "payments":
            selectedTab = .payments
            return true
        case "months":
            selectedTab = .months
            return true
        default:
            return false
        }
    }

    private static func parseInitialScreen(
        from arguments: [String]
    ) -> (tab: AppTab, destination: MoreDestination?, sheet: ActiveSheet?, periodMode: BudgetPeriodMode) {
        guard let index = arguments.firstIndex(of: "-screen"),
              arguments.indices.contains(index + 1) else {
            return (.now, nil, nil, .calendarMonth)
        }
        switch arguments[index + 1].lowercased() {
        case "now":
            return (.now, nil, nil, .calendarMonth)
        case "payments":
            return (.payments, nil, nil, .calendarMonth)
        case "months":
            return (.months, nil, nil, .calendarMonth)
        case "months-cycle", "cycle":
            return (.months, nil, nil, .payCycle)
        case "more":
            return (.more, nil, nil, .calendarMonth)
        case "gmail":
            return (.more, .gmail, nil, .calendarMonth)
        case "money-forward", "moneyforward":
            return (.more, .moneyForward, nil, .calendarMonth)
        case "drive", "google-drive":
            return (.more, .drive, nil, .calendarMonth)
        case "scanner-settings", "receipt-scanner":
            return (.more, .receiptScanner, nil, .calendarMonth)
        case "notifications":
            return (.more, .notifications, nil, .calendarMonth)
        case "local-data", "imports":
            return (.more, .localData, nil, .calendarMonth)
        case "sync-health":
            return (.more, .syncHealth, nil, .calendarMonth)
        case "ask":
            return (.now, nil, .ask, .calendarMonth)
        case "targets", "plan":
            return (.months, nil, .targets, .calendarMonth)
        case "debt-payoff", "payoff":
            return (.now, nil, .debtPayoff, .calendarMonth)
        case "quick-add":
            return (.now, nil, .quickAdd, .calendarMonth)
        case "scan-receipt":
            return (.now, nil, .scanReceipt, .calendarMonth)
        case "review", "inbox":
            return (.now, nil, .reviewInbox, .calendarMonth)
        case "runway", "forecast":
            return (.now, nil, .runway, .calendarMonth)
        default:
            return (.now, nil, nil, .calendarMonth)
        }
    }

    private static func parseColorScheme(from arguments: [String]) -> ColorScheme? {
        guard let index = arguments.firstIndex(of: "-appearance"),
              arguments.indices.contains(index + 1) else {
            return nil
        }
        switch arguments[index + 1].lowercased() {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }
}
