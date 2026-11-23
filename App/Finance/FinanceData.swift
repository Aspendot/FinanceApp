import FinanceCore
import Foundation
import WidgetKit

/// Everything the screens show: the imported data file, confirmed Money Forward bank
/// transactions after each source's statement cutoff, and remaining pending Gmail notices.
struct FinanceData: Sendable {
    let bundle: DataBundle
    /// Notices before effective coverage, kept outside the pending totals.
    let unmatched: [Notice]
    let payday: PaydayView?
    let comingUp: [ComingUpGroup]
    let lastPayday: String?
    let spentSincePayday: Int?
    let pendingSincePayday: Int
    /// All pending payments built from bank emails not yet matched by Money Forward.
    let pendingCount: Int
    /// Confirmed items added from Money Forward after bundle coverage end.
    let confirmedBankCount: Int
    /// Per-source coverage extended to the newest mapped Money Forward row.
    let effectiveCoverage: [String: CoverageRange]
    let months: [String]
    let paymentsByMonth: [String: [NumberedRow<BudgetItem>]]

    static func load(
        notices: [Notice],
        bankTransactions: [BankTransaction]? = nil,
        accountMapping: [String: String]? = nil,
        now: Date = Date()
    ) async -> FinanceData? {
        await Task.detached(priority: .utility) {
            guard let raw = BundleInbox.storedData(), let bundle = try? DataBundle.decode(from: raw) else { return nil }
            let mfState = (bankTransactions == nil || accountMapping == nil)
                ? (try? MoneyForwardStore.loadState())
                : nil
            let resolvedTxs = bankTransactions ?? mfState?.transactions ?? []
            let resolvedMapping = accountMapping ?? mfState?.accountMapping ?? [:]
            return FinanceData(
                bundle: bundle,
                notices: notices,
                bankTransactions: resolvedTxs,
                accountMapping: resolvedMapping,
                today: JST.day(now)
            )
        }.value
    }

    init(
        bundle: DataBundle,
        notices: [Notice],
        bankTransactions: [BankTransaction] = [],
        accountMapping: [String: String] = [:],
        today: String
    ) {
        self.bundle = bundle
        let config = bundle.layerConfig
        let layered = BankLayering.build(
            bundle: bundle,
            bankTransactions: bankTransactions,
            accountMapping: accountMapping,
            notices: notices,
            categorizer: Categorizer(rules: bundle.rules),
            config: config
        )
        unmatched = layered.unmatched
        pendingCount = layered.pendingItems.count
        confirmedBankCount = layered.bankItems.count
        effectiveCoverage = layered.effectiveCoverage
        let items = bundle.items + layered.bankItems + layered.pendingItems

        let upcoming = PaydayView.compute(timeline: bundle.timeline, today: today)
        payday = upcoming.flatMap { $0.daysToPayday >= 0 ? $0 : nil }
        comingUp = ComingUp.groups(timeline: bundle.timeline, today: today)
        let start = bundle.timeline.filter { $0.payday == true && $0.date <= today }.map(\.date).max()
        lastPayday = start
        spentSincePayday = start.map {
            PaydayView.spentSince(day: $0, items: items, config: config, layers: bundle.layers)
        }
        pendingSincePayday = start.map { day in
            layered.pendingItems.filter {
                $0.date >= day && config.resolvedLayer(for: $0, layers: bundle.layers) != nil
            }.count
        } ?? 0

        let incomeGroup = config.resolvedIncomeGroup ?? "Income"
        let payments = items.filter { $0.group != incomeGroup }
            .sorted { ($0.date, $0.amount) > ($1.date, $1.amount) }
        paymentsByMonth = Dictionary(grouping: NumberedRow.make(from: payments)) { String($0.value.date.prefix(7)) }
        months = paymentsByMonth.keys.sorted()
    }

    func layer(of item: BudgetItem) -> String? {
        bundle.layerConfig.resolvedLayer(for: item, layers: bundle.layers)
    }

    var widgetSnapshot: WidgetSnapshot {
        guard let p = payday else {
            return WidgetSnapshot(title: "Finance", value: "–", detail: "No upcoming payday in the data file", updatedAt: Date())
        }
        let spent = spentSincePayday.map { " · spent " + Money.yen($0) } ?? ""
        return WidgetSnapshot(title: "Until payday · \(p.daysToPayday) days", value: Money.yen(p.left),
                              detail: "for everything else" + spent, updatedAt: Date())
    }

    static func publishWidget(_ snapshot: WidgetSnapshot, force: Bool = false) {
        guard SharedStore.groupID != nil else { return }
        if !force, let current = SharedStore.read(),
           current.title == snapshot.title, current.value == snapshot.value, current.detail == snapshot.detail {
            return
        }
        SharedStore.write(snapshot)
        WidgetCenter.shared.reloadTimelines(ofKind: "FinanceWidget")
    }

    /// Fallback widget snapshot when no data file has been imported yet.
    static func noticeOnlySnapshot(notices: [Notice], now: Date = Date()) -> WidgetSnapshot {
        let since = JST.timestamp(now.addingTimeInterval(-7 * 86_400))
        let amounts = notices.filter {
            $0.receivedAt >= since && [.purchase, .refund, .settlement, .cancellation].contains($0.kind)
        }.compactMap(\.amount)
        return WidgetSnapshot(
            title: "Card notices, 7 days",
            value: "¥" + amounts.reduce(0, +).formatted(),
            detail: "\(amounts.count) notices",
            updatedAt: now
        )
    }
}

/// Values identify rows across filters. The occurrence keeps identical rows distinct.
struct NumberedRow<Value: Hashable & Sendable>: Identifiable, Sendable {
    struct ID: Hashable, Sendable {
        let value: Value
        let occurrence: Int
    }

    let id: ID
    var value: Value { id.value }

    static func make(from values: [Value]) -> [Self] {
        var counts: [Value: Int] = [:]
        return values.map { value in
            let occurrence = counts[value, default: 0]
            counts[value] = occurrence + 1
            return Self(id: ID(value: value, occurrence: occurrence))
        }
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
