import FinanceCore
import Foundation
import UserNotifications

/// Schedules and reconciles local notifications for upcoming unpaid bills in the timeline.
///
/// Operations are FIFO-serialized on a single actor with synchronous monotonic generation
/// invalidation, so an in-flight `center.add` always finishes before `clearAll()` removes pending
/// requests and can never resurrect an unmasked alert or overwrite a newer masked alert.
actor BillReminderSchedulerCoordinator {
    static let shared = BillReminderSchedulerCoordinator()
    private var generation: UInt64 = 0
    private var lastOperation: Task<Void, Never>?

    func clearAll() async {
        generation &+= 1
        let previous = lastOperation
        // Register the queued clear synchronously BEFORE any await so any follow-up masked sync
        // chains strictly AFTER this clear while existing reminders are still wiped immediately.
        let immediateSweep = Task {
            await self.performClearAll()
        }
        let op = Task {
            await previous?.value
            await immediateSweep.value
            await self.performClearAll()
        }
        lastOperation = op
        await op.value
    }

    func sync(
        timeline: [TimelineEntry],
        preferences: NotificationPreferences,
        now: Date,
        privacyMasked: Bool
    ) async {
        generation &+= 1
        let token = generation
        let previous = lastOperation
        let op = Task {
            await previous?.value
            await self.performSync(
                token: token,
                timeline: timeline,
                preferences: preferences,
                now: now,
                privacyMasked: privacyMasked
            )
        }
        lastOperation = op
        await op.value
    }

    private func performClearAll() async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let pendingIDs = pending.map(\.identifier).filter { $0.hasPrefix(BillReminderScheduler.identifierPrefix) }
        if !pendingIDs.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: pendingIDs)
        }
        let delivered = await center.deliveredNotifications()
        let deliveredIDs = delivered.map(\.request.identifier).filter { $0.hasPrefix(BillReminderScheduler.identifierPrefix) }
        if !deliveredIDs.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: deliveredIDs)
        }
    }

    private func performSync(
        token: UInt64,
        timeline: [TimelineEntry],
        preferences: NotificationPreferences,
        now: Date,
        privacyMasked: Bool
    ) async {
        guard token == generation else { return }

        let center = UNUserNotificationCenter.current()
        let existingPending = await center.pendingNotificationRequests()
        guard token == generation else { return }
        let oldIDs = existingPending
            .map(\.identifier)
            .filter { $0.hasPrefix(BillReminderScheduler.identifierPrefix) }
        if !oldIDs.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: oldIDs)
        }

        guard preferences.billRemindersEnabled else { return }
        let authorized = await PaymentNotifications.isAuthorized()
        guard authorized, token == generation else { return }

        // Re-check live privacy setting after awaits so turning Privacy Mode on mid-sync always wins.
        let effectiveMasked = privacyMasked || SharedStore.privacyMasked

        let today = JST.day(now)
        let unpaid = timeline
            .filter { entry in
                guard entry.done != true, entry.borrowed != true, entry.cardBilled != true, entry.date >= today else { return false }
                return entry.amount > 0 || entry.event == true
            }
            .sorted { ($0.date, $0.amount, $0.item) < ($1.date, $1.amount, $1.item) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = JST.timeZone
        let daysBefore = max(0, min(3, preferences.billReminderDaysBefore))
        let hour = max(6, min(22, preferences.billReminderHourJST))

        var scheduled = 0
        for (idx, entry) in unpaid.enumerated() {
            guard token == generation else { return }
            guard scheduled < BillReminderScheduler.maxScheduledBills else { break }
            guard let reminderDay = JST.addingDays(-daysBefore, to: entry.date) else { continue }
            let parts = reminderDay.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { continue }

            var comps = DateComponents()
            comps.timeZone = JST.timeZone
            comps.year = parts[0]
            comps.month = parts[1]
            comps.day = parts[2]
            comps.hour = hour
            comps.minute = 0

            guard let fireDate = calendar.date(from: comps), fireDate > now else { continue }

            let content = UNMutableNotificationContent()
            let est = entry.estimate == true ? " (estimate)" : ""
            let timingLabel: String
            switch daysBefore {
            case 0: timingLabel = "Today"
            case 1: timingLabel = "Tomorrow"
            default: timingLabel = "In \(daysBefore) days"
            }
            let safeItem = MaskedMoney.redactText(entry.item, masked: effectiveMasked)
            content.title = "\(timingLabel): \(safeItem)"
            if entry.event == true && entry.amount == 0 {
                if let note = entry.note, !note.isEmpty {
                    content.body = MaskedMoney.redactText(note, masked: effectiveMasked)
                } else {
                    content.body = "Reminder for \(DayText.short(entry.date))"
                }
            } else if effectiveMasked {
                content.body = "Scheduled bill · \(DayText.short(entry.date))"
            } else {
                let amountText = Money.yen(entry.amount) + est
                if let note = entry.note, !note.isEmpty {
                    content.body = "\(amountText) · \(note)"
                } else {
                    content.body = "\(amountText) · scheduled for \(DayText.short(entry.date))"
                }
            }
            content.sound = .default
            content.threadIdentifier = "bill-reminders"
            content.categoryIdentifier = BillReminderScheduler.categoryIdentifier

            let id: String
            if effectiveMasked {
                id = BillReminderScheduler.identifierPrefix + "masked-\(entry.date)-\(idx)"
            } else {
                let stableSlug = TextFold.key(entry.item).prefix(24)
                id = BillReminderScheduler.identifierPrefix + "\(entry.date)-\(idx)-\(stableSlug)-\(entry.amount)"
            }
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
            try? await center.add(request)
            if token != generation {
                center.removePendingNotificationRequests(withIdentifiers: [id])
                return
            }
            scheduled += 1
        }
    }
}

enum BillReminderScheduler {
    static let categoryIdentifier = "finance.bill_reminder"
    static let identifierPrefix = "bill-reminder-"
    fileprivate static let maxScheduledBills = 12

    static func sync(
        timeline: [TimelineEntry],
        preferences: NotificationPreferences,
        now: Date = Date(),
        privacyMasked: Bool = SharedStore.privacyMasked
    ) async {
        await BillReminderSchedulerCoordinator.shared.sync(
            timeline: timeline,
            preferences: preferences,
            now: now,
            privacyMasked: privacyMasked
        )
    }

    static func clearAll() async {
        await BillReminderSchedulerCoordinator.shared.clearAll()
    }

    static func clearDelivered() async {
        let center = UNUserNotificationCenter.current()
        let delivered = await center.deliveredNotifications()
        let ids = delivered
            .map(\.request.identifier)
            .filter { $0.hasPrefix(identifierPrefix) }
        if !ids.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: ids)
        }
    }

    static func scheduledCount() async -> Int {
        let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
        return pending.filter { $0.identifier.hasPrefix(identifierPrefix) }.count
    }
}
