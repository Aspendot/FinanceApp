import SwiftUI

@main
struct FinanceApp: App {
    init() {
        BackgroundRefresh.register()
    }

    var body: some Scene {
        WindowGroup {
            SpikeView()
        }
    }
}
