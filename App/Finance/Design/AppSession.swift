import Combine
import FinanceCore
import Foundation

/// Top-level tabs in the app.
enum AppTab: String, CaseIterable, Hashable {
    case now
    case payments
    case months
    case more
}

/// Shared UI coordination across tabs and launch-argument demo mode.
///
/// Keeps screen navigation, category cross-filtering, and `-demo` / `-screen` launch
/// arguments outside `AppModel` and `FinanceData`.
@MainActor
final class AppSession: ObservableObject {
    let isDemo: Bool
    let demoData: FinanceData?
    let demoToday: String?
    let demoRunLog: [SyncRunRecord]

    @Published var selectedTab: AppTab
    @Published var paymentsMonth: String?
    @Published var paymentsCategory: String?
    @Published var hasCompletedInitialLoad: Bool

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        let demo = arguments.contains("-demo")
        self.isDemo = demo
        self.selectedTab = Self.parseInitialTab(from: arguments)
        if demo {
            let loaded = DemoData.load()
            self.demoData = loaded?.data
            self.demoToday = loaded?.today
            self.demoRunLog = loaded?.runLog ?? []
            self.hasCompletedInitialLoad = true
        } else {
            self.demoData = nil
            self.demoToday = nil
            self.demoRunLog = []
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

    private static func parseInitialTab(from arguments: [String]) -> AppTab {
        guard let index = arguments.firstIndex(of: "-screen"),
              arguments.indices.contains(index + 1) else {
            return .now
        }
        return AppTab(rawValue: arguments[index + 1].lowercased()) ?? .now
    }
}
