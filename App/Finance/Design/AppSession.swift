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
    case diagnostics
}

/// Shared UI coordination across tabs and launch-argument demo mode.
///
/// Keeps screen navigation, category cross-filtering, and `-demo` / `-screen` / `-appearance`
/// launch arguments outside `AppModel` and `FinanceData`.
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
    @Published var hasCompletedInitialLoad: Bool

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        let demo = arguments.contains("-demo")
        let target = Self.parseInitialScreen(from: arguments)
        self.isDemo = demo
        self.selectedTab = target.tab
        self.morePath = target.destination.map { [$0] } ?? []
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

    /// Navigates from Months to Payments with the tapped month and category applied.
    func openPayments(month: String, category: String?) {
        paymentsMonth = month
        paymentsCategory = category
        selectedTab = .payments
    }

    private static func parseInitialScreen(from arguments: [String]) -> (tab: AppTab, destination: MoreDestination?) {
        guard let index = arguments.firstIndex(of: "-screen"),
              arguments.indices.contains(index + 1) else {
            return (.now, nil)
        }
        switch arguments[index + 1].lowercased() {
        case "now":
            return (.now, nil)
        case "payments":
            return (.payments, nil)
        case "months":
            return (.months, nil)
        case "more":
            return (.more, nil)
        case "gmail":
            return (.more, .gmail)
        case "money-forward", "moneyforward":
            return (.more, .moneyForward)
        case "drive", "google-drive":
            return (.more, .drive)
        default:
            return (.now, nil)
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
