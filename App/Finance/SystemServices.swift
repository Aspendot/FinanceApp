import BackgroundTasks
import Foundation
import LocalAuthentication
import UserNotifications
import WidgetKit

/// Face ID.
enum Biometrics {
    static func unlock() async -> String {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return "Not available: " + (error?.localizedDescription ?? "no Face ID on this device")
        }
        do {
            let ok = try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "Unlock your finances")
            return ok ? "Unlocked with Face ID" : "Not unlocked"
        } catch {
            return "Not unlocked: " + error.localizedDescription
        }
    }
}

/// Local notifications. The app never uses remote push.
enum Notifier {
    static func requestPermission() async -> String {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            return granted ? "Notifications allowed" : "Notifications not allowed (change it in Settings)"
        } catch {
            return "Could not ask: " + error.localizedDescription
        }
    }

    static func post(title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}

/// A record of background runs, so the app can show that they happen.
struct SpikeLog: Codable {
    var backgroundRuns: [Date] = []

    private static let key = "spikeLog"

    static func load() -> SpikeLog {
        let store = SharedStore.defaults ?? .standard
        guard let data = store.data(forKey: key), let log = try? JSONDecoder().decode(SpikeLog.self, from: data) else {
            return SpikeLog()
        }
        return log
    }

    func save() {
        let store = SharedStore.defaults ?? .standard
        if let data = try? JSONEncoder().encode(self) {
            store.set(data, forKey: Self.key)
        }
    }
}

/// Background refresh. iOS decides when it runs; asking for 15 minutes is only a floor.
enum BackgroundRefresh {
    static let identifier = "io.github.aspendot.financeapp.refresh"

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(refresh)
        }
    }

    static func schedule() -> String {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
            return "Scheduled; iOS runs it when it chooses (often within hours)"
        } catch {
            return "Could not schedule: " + error.localizedDescription
        }
    }

    private static func handle(_ task: BGAppRefreshTask) {
        _ = schedule()
        let work = Task {
            var log = SpikeLog.load()
            log.backgroundRuns.append(Date())
            log.save()
            SharedStore.write(WidgetSnapshot(
                title: "Background refresh",
                value: "\(log.backgroundRuns.count) runs",
                detail: "Last " + Date().formatted(date: .omitted, time: .shortened),
                updatedAt: Date()))
            WidgetCenter.shared.reloadAllTimelines()
            await Notifier.post(title: "Background refresh ran", body: "Run \(log.backgroundRuns.count). The widget was updated.")
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = {
            work.cancel()
            task.setTaskCompleted(success: false)
        }
    }
}
