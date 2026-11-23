import SwiftUI
import UserNotifications

@main
struct FinanceApp: App {
    init() {
        UNUserNotificationCenter.current().delegate = ForegroundNotifications.shared
        BackgroundRefresh.register()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
