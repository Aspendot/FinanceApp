import BackgroundTasks
import Foundation
import LocalAuthentication
import UIKit
import UserNotifications

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

    /// Posts a notification now, or after `delay` seconds.
    static func post(title: String, body: String, after delay: TimeInterval? = nil) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let trigger = delay.map { UNTimeIntervalNotificationTrigger(timeInterval: max(1, $0), repeats: false) }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// Whether notifications are allowed, in plain words.
    static func status() async -> String {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: return "Notifications are allowed"
        case .denied: return "Notifications are off for Finance (Settings → Notifications → Finance)"
        case .notDetermined: return "Not asked yet: tap Allow notifications"
        @unknown default: return "Unknown notification setting"
        }
    }
}

/// Shows the app's own notifications as banners even while the app is open.
/// Without this, iOS shows nothing for a notification that arrives in the foreground.
final class ForegroundNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ForegroundNotifications()

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}

/// Keeps the app alive briefly for foreground and App Intent syncs, cancelling the work
/// if iOS is about to suspend the process.
enum BackgroundAssertion {
    @MainActor
    private final class State {
        var taskID: UIBackgroundTaskIdentifier = .invalid

        func end() {
            guard taskID != .invalid else { return }
            let id = taskID
            taskID = .invalid
            UIApplication.shared.endBackgroundTask(id)
        }
    }

    static func run<T: Sendable>(
        name: String = "FinanceSync",
        operation: @escaping @Sendable () async -> T
    ) async -> T {
        let work = Task {
            await operation()
        }
        let state = await MainActor.run { () -> State in
            let state = State()
            state.taskID = UIApplication.shared.beginBackgroundTask(withName: name) {
                work.cancel()
                MainActor.assumeIsolated { state.end() }
            }
            return state
        }
        return await withTaskCancellationHandler {
            let result = await work.value
            await MainActor.run { state.end() }
            return result
        } onCancel: {
            work.cancel()
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

    /// Submits a background refresh request only if none is currently pending.
    static func scheduleIfNeeded() async {
        guard let identifier, registered else { return }
        let pending = await BGTaskScheduler.shared.pendingTaskRequests()
        if pending.contains(where: { $0.identifier == identifier }) {
            return
        }
        _ = schedule()
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
        // The launch handler runs on the main queue, so expiration is set before work starts.
        let work = Task {
            let report = await SyncEngine.shared.run(trigger: .background, minimumInterval: 600, timeLimit: 25)
            _ = schedule()
            let succeeded: Bool
            switch report.outcome {
            case .updated, .skipped, .notSignedIn, .busy:
                succeeded = true
            case .timedOut, .cancelled, .failed, .signInRequired:
                succeeded = false
            }
            task.setTaskCompleted(success: succeeded && !Task.isCancelled)
        }
        task.expirationHandler = {
            work.cancel()
        }
    }
}
