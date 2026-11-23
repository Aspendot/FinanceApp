import FinanceCore
import Foundation
import UserNotifications

/// Schedules and reconciles local notifications for upcoming unpaid bills in the timeline.
///
/// Automatically clears reminders when a bill is marked paid (via Money Forward, Drive bundle,
/// or local checkoff) or when reminders are disabled.
enum BillReminderScheduler {
    static let categoryIdentifier = "finance.bill_reminder"
    static let identifierPrefix = "bill-reminder-"
    private static let maxScheduledBills = 12

    static func sync(
        timeline: [TimelineEntry],
        preferences: NotificationPreferences,
        now: Date = Date()
    ) async {
        let center = UNUserNotificationCenter.current()
        let existingPending = await center.pendingNotificationRequests()
        let oldIDs = existingPending
            .map(\.identifier)
            .filter { $0.hasPrefix(identifierPrefix) }
        if !oldIDs.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: oldIDs)
        }

        guard preferences.billRemindersEnabled,
              await PaymentNotifications.isAuthorized()
        else { return }

        let today = JST.day(now)
        let unpaid = timeline
            .filter { entry in
                entry.done != true
                    && entry.event != true
                    && entry.borrowed != true
                    && entry.amount > 0
                    && entry.date >= today
            }
            .sorted { ($0.date, $0.amount) < ($1.date, $1.amount) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = JST.timeZone
        let daysBefore = max(0, min(3, preferences.billReminderDaysBefore))
        let hour = max(6, min(22, preferences.billReminderHourJST))

        var scheduled = 0
        for entry in unpaid {
            guard scheduled < maxScheduledBills else { break }
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
            content.title = "\(timingLabel): \(entry.item)"
            let amountText = Money.yen(entry.amount) + est
            if let note = entry.note, !note.isEmpty {
                content.body = "\(amountText) · \(note)"
            } else {
                content.body = "\(amountText) · scheduled for \(DayText.short(entry.date))"
            }
            content.sound = .default
            content.threadIdentifier = "bill-reminders"
            content.categoryIdentifier = categoryIdentifier

            let id = identifierPrefix + "\(entry.date)-\(abs(entry.item.hashValue))-\(entry.amount)"
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
            try? await center.add(request)
            scheduled += 1
        }
    }

    static func scheduledCount() async -> Int {
        let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
        return pending.filter { $0.identifier.hasPrefix(identifierPrefix) }.count
    }
}
