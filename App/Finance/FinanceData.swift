import FinanceCore
import Foundation
import WidgetKit

/// Everything the screens show: the imported data file plus the Gmail notices kept
/// on the phone, which become pending payments with the PC's own rules.
struct FinanceData {
    let bundle: DataBundle
    let pending: [BudgetItem]
    /// Notices dated inside the statements' period that no statement row explains.
    let unmatched: [Notice]
    let today: String

    /// Reads the stored data file and the kept notices. GmailSync lives on the main actor.
    @MainActor
    static func load(now: Date = Date()) -> FinanceData? {
        guard let raw = BundleInbox.storedData(), let bundle = try? DataBundle.decode(from: raw) else { return nil }
        let categorizer = Categorizer(rules: bundle.rules)
        let result = PendingBuilder.build(notices: GmailSync.recentNotices(), bundle: bundle,
                                          categorizer: categorizer, config: bundle.layerConfig)
        return FinanceData(bundle: bundle, pending: result.items, unmatched: result.unmatched, today: JST.day(now))
    }

    var items: [BudgetItem] { bundle.items + pending }
    var payday: PaydayView? { PaydayView.compute(timeline: bundle.timeline, today: today) }
    var comingUp: [ComingUpGroup] { ComingUp.groups(timeline: bundle.timeline, today: today) }
    var incomeGroup: String { bundle.layerConfig.incomeGroup ?? "Income" }

    /// The latest payday on or before today.
    var lastPayday: String? {
        bundle.timeline.filter { $0.payday == true && $0.date <= today }.map(\.date).max()
    }

    /// Spending since the last payday, from statements and pending bank emails.
    var spentSincePayday: Int? {
        lastPayday.map { PaydayView.spentSince(day: $0, items: items, config: bundle.layerConfig, layers: bundle.layers) }
    }

    var pendingSincePayday: Int {
        guard let start = lastPayday else { return 0 }
        return pending.filter { $0.date >= start }.count
    }

    var months: [String] { Set(items.map { String($0.date.prefix(7)) }).sorted() }

    /// A month's payments, newest first, as the dashboard lists them (income left out).
    func payments(in month: String) -> [BudgetItem] {
        items.filter { $0.date.hasPrefix(month) && $0.group != incomeGroup }
            .sorted { ($0.date, $0.amount) > ($1.date, $1.amount) }
    }

    func layer(of item: BudgetItem) -> String? {
        item.layer ?? bundle.layer(for: item)
    }

    var widgetSnapshot: WidgetSnapshot {
        guard let p = payday else {
            return WidgetSnapshot(title: "Finance", value: "–", detail: "No payday in the data file", updatedAt: Date())
        }
        let spent = spentSincePayday.map { " · spent " + Money.yen($0) } ?? ""
        return WidgetSnapshot(title: "Until payday · \(p.daysToPayday) days", value: Money.yen(p.left),
                              detail: "for everything else" + spent, updatedAt: Date())
    }

    /// Writes the widget's value from the current data, if there is a data file.
    @MainActor
    static func refreshWidget() {
        guard let data = load() else { return }
        SharedStore.write(data.widgetSnapshot)
        WidgetCenter.shared.reloadAllTimelines()
    }
}

/// Yen as the dashboard writes it.
enum Money {
    static func yen(_ value: Int) -> String {
        (value < 0 ? "−¥" : "¥") + value.magnitude.formatted()
    }

    /// A payment: money out as "¥1,234", money in as "+¥1,234".
    static func payment(_ value: Int) -> String {
        value < 0 ? "+¥" + value.magnitude.formatted() : "¥" + value.formatted()
    }

    /// A ledger line: "+¥1,234" or "−¥1,234".
    static func signed(_ value: Int) -> String {
        (value < 0 ? "−¥" : "+¥") + value.magnitude.formatted()
    }
}

/// Japan-time calendar days as text, in English.
enum DayText {
    static func date(_ day: String) -> Date? {
        let p = day.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = JST.timeZone
        return calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
    }

    static func format(_ day: String, template: String) -> String {
        guard let d = date(day) else { return day }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.timeZone = JST.timeZone
        f.setLocalizedDateFormatFromTemplate(template)
        return f.string(from: d)
    }

    static func long(_ day: String) -> String { format(day, template: "EEEEMMMMd") }
    static func short(_ day: String) -> String { format(day, template: "MMMdEEE") }
    static func weekday(_ day: String) -> String { format(day, template: "EEE").uppercased() }
    static func dayOfMonth(_ day: String) -> String { String(Int(day.suffix(2)) ?? 0) }
    static func month(_ month: String) -> String { format(month + "-01", template: "MMMMyyyy") }
}
