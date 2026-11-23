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
    case notifications
    case localData
    case syncHealth
    case diagnostics
}

/// Modal sheets launchable from any primary tab or via demo arguments.
enum ActiveSheet: String, Identifiable, Hashable {
    case quickAdd
    case ask
    case debtPayoff
    case targets

    var id: String { rawValue }
}

/// Shared UI coordination across tabs and launch-argument demo mode.
///
/// Keeps screen navigation, category/query cross-filtering, modal sheets, and
/// `-demo` / `-screen` / `-appearance` launch arguments outside `AppModel` and `FinanceData`.
@MainActor
final class AppSession: ObservableObject {
    let isDemo: Bool
    let demoData: FinanceData?
    let demoToday: String?
    let demoRunLog: [SyncRunRecord]
    let demoColorScheme: ColorScheme?

    @Published var selectedTab: AppTab
    @Published var morePath: [MoreDestination]
    @Published var paymentsMonth: String?
    @Published var paymentsCategory: String?
    @Published var paymentsQuery: String = ""
    @Published var paymentsAllMonths: Bool = false
    @Published var paymentsOnlyUncategorized: Bool = false
    @Published var paymentsSource: String? = nil
    @Published var monthsSelectedMonth: String?
    @Published var activeSheet: ActiveSheet?
    @Published var hasCompletedInitialLoad: Bool

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        let demo = arguments.contains("-demo")
        let target = Self.parseInitialScreen(from: arguments)
        self.isDemo = demo
        self.selectedTab = target.tab
        self.morePath = target.destination.map { [$0] } ?? []
        self.activeSheet = target.sheet
        if demo {
            let loaded = DemoData.load()
            self.demoData = loaded?.data
            self.demoToday = loaded?.today
            self.demoRunLog = loaded?.runLog ?? []
            self.demoColorScheme = Self.parseColorScheme(from: arguments)
            self.hasCompletedInitialLoad = true
        } else {
            self.demoData = nil
            self.demoToday = nil
            self.demoRunLog = []
            self.demoColorScheme = nil
            self.hasCompletedInitialLoad = false
        }
    }

    /// Data to display across all screens (bundled demo data in `-demo` mode, live data otherwise).
    func resolvedData(from model: AppModel) -> FinanceData? {
        isDemo ? demoData : model.data
    }

    /// Sync log entries for More (invented calm records in `-demo` mode, live run log otherwise).
    func resolvedRunLog(from model: AppModel) -> [SyncRunRecord] {
        isDemo ? demoRunLog : model.runLog
    }

    /// Calendar day string ("YYYY-MM-DD") in Japan time. Always the real date outside demo mode.
    var today: String {
        demoToday ?? JST.day(Date())
    }

    /// Navigates to Payments with optional month, category, search query, source, or uncategorized filter.
    func openPayments(
        month: String?,
        category: String?,
        query: String? = nil,
        source: String? = nil,
        onlyUncategorized: Bool = false
    ) {
        if let month {
            paymentsMonth = month
            paymentsAllMonths = false
        } else {
            paymentsAllMonths = true
        }
        paymentsCategory = category
        paymentsQuery = query ?? ""
        paymentsSource = source
        paymentsOnlyUncategorized = onlyUncategorized
        selectedTab = .payments
    }

    /// Navigates to Months focused on a specific month.
    func openMonths(month: String?) {
        if let month {
            monthsSelectedMonth = month
        }
        selectedTab = .months
    }

    private static func parseInitialScreen(
        from arguments: [String]
    ) -> (tab: AppTab, destination: MoreDestination?, sheet: ActiveSheet?) {
        guard let index = arguments.firstIndex(of: "-screen"),
              arguments.indices.contains(index + 1) else {
            return (.now, nil, nil)
        }
        switch arguments[index + 1].lowercased() {
        case "now":
            return (.now, nil, nil)
        case "payments":
            return (.payments, nil, nil)
        case "months":
            return (.months, nil, nil)
        case "more":
            return (.more, nil, nil)
        case "gmail":
            return (.more, .gmail, nil)
        case "money-forward", "moneyforward":
            return (.more, .moneyForward, nil)
        case "drive", "google-drive":
            return (.more, .drive, nil)
        case "notifications":
            return (.more, .notifications, nil)
        case "local-data", "imports":
            return (.more, .localData, nil)
        case "sync-health":
            return (.more, .syncHealth, nil)
        case "ask":
            return (.now, nil, .ask)
        case "targets", "plan":
            return (.months, nil, .targets)
        case "debt-payoff", "payoff":
            return (.now, nil, .debtPayoff)
        case "quick-add":
            return (.now, nil, .quickAdd)
        default:
            return (.now, nil, nil)
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
