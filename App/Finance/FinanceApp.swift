import SwiftUI
import UserNotifications

@main
struct FinanceApp: App {
    @MainActor init() {
        if !ProcessInfo.processInfo.arguments.contains("-demo") {
            PaymentNotifications.registerCategory()
            UNUserNotificationCenter.current().delegate = ForegroundNotifications.shared
            BackgroundRefresh.register()
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
