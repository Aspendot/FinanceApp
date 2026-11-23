import SwiftUI
import UserNotifications

@main
struct FinanceApp: App {
    init() {
        PaymentNotifications.registerCategory()
        UNUserNotificationCenter.current().delegate = ForegroundNotifications.shared
        BackgroundRefresh.register()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
