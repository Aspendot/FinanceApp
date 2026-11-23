import BackgroundTasks
import FinanceCore
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
    private static let identifier = (Bundle.main.object(
        forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers"
    ) as? [String])?.first { $0.hasSuffix(".refresh") }

    private static let registered: Bool = {
        guard let identifier else { return false }
        return BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(refresh)
        }
    }()

    static func register() {
        _ = registered
    }

    static func schedule() -> String {
        guard let identifier, registered else { return "Background refresh is unavailable in this install" }
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
        // The launch handler runs on the main queue, so expiration is set before work starts.
        let work = Task { @MainActor in
            var succeeded = false
            defer { task.setTaskCompleted(success: succeeded && !Task.isCancelled) }
            guard !Task.isCancelled else { return }
            var log = SpikeLog.load()
            log.backgroundRuns.append(Date())
            log.save()
            if GmailSync.isSignedIn {
                do {
                    let fresh = try await GmailSync.run(days: 3)
                    let spending = fresh.filter { [.purchase, .refund, .settlement].contains($0.kind) }
                    for n in spending.prefix(3) {
                        let amount = n.amount.map { ($0 < 0 ? "+¥" : "¥") + abs($0).formatted() } ?? "an amount"
                        await Notifier.post(title: amount, body: (n.merchant ?? "A payment") + " · " + n.source.rawValue)
                    }
                    succeeded = true
                } catch {
                    return
                }
                return
            }
            SharedStore.write(WidgetSnapshot(
                title: "Background refresh",
                value: "\(log.backgroundRuns.count) runs",
                detail: "Last " + Date().formatted(date: .omitted, time: .shortened),
                updatedAt: Date()))
            WidgetCenter.shared.reloadAllTimelines()
            await Notifier.post(title: "Background refresh ran", body: "Run \(log.backgroundRuns.count). The widget was updated.")
            succeeded = true
        }
        task.expirationHandler = {
            work.cancel()
        }
    }
}
