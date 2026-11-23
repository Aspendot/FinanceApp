import FinanceCore
import SwiftUI

/// Visual tokens for the personal-finance design system.
///
/// Colors are loaded from named color sets in `Assets.xcassets` so light and dark
/// mode stay exact without hardcoded hex logic in views.
enum Theme {
    static let page = Color("Page")
    static let surface = Color("Surface")
    static let ink = Color("Ink")
    static let ink2 = Color("Ink2")
    static let muted = Color("Muted")
    static let line = Color("Line")
    static let grid = Color("Grid")
    static let accent = Color("Accent")
    static let accentWash = Color("AccentWash")
    static let good = Color("Good")
    static let goodWash = Color("GoodWash")
    static let bad = Color("Bad")
    static let badWash = Color("BadWash")
    static let track = Color("Track")

    /// Warm burnished amber for approaching limits and cautionary indicators.
    static let warn = Color("LayerDayToDay")

    /// Soft recessed interior container matching the warm alabaster / obsidian palette.
    static let well = Color("Track")

    /// Signature Midnight Forest Obsidian palette for hero centerpieces and widgets.
    static let heroTop = Color(red: 0.055, green: 0.195, blue: 0.149)
    static let heroMid = Color(red: 0.043, green: 0.130, blue: 0.108)
    static let heroBottom = Color(red: 0.045, green: 0.082, blue: 0.078)
    static let heroGlow = Color(red: 0.200, green: 0.780, blue: 0.560)
    static let heroInk = Color(red: 0.976, green: 0.984, blue: 0.980)
    static let heroInkMuted = Color(red: 0.720, green: 0.825, blue: 0.780)
    static let heroAccent = Color(red: 0.360, green: 0.890, blue: 0.660)
    static let heroCoral = Color(red: 0.970, green: 0.520, blue: 0.470)

    static let cardRadius: CGFloat = 20
    static let innerRadius: CGFloat = 13
    static let cardPadding: CGFloat = 18
    static let cardSpacing: CGFloat = 16
    static let screenPadding: CGFloat = 16
    static let minTouchTarget: CGFloat = 44
}

/// The four spending layers in fixed stack order from bottom to top.
///
/// Rent is always at the bottom so it reads as a constant flat band across months.
enum SpendingLayer: Int, CaseIterable, Identifiable, Hashable, Sendable {
    case rent = 0
    case bills = 1
    case subscriptions = 2
    case dayToDay = 3

    var id: Int { rawValue }

    var defaultKey: String {
        switch self {
        case .rent: return "Rent"
        case .bills: return "Bills & taxes"
        case .subscriptions: return "Subscriptions"
        case .dayToDay: return "Day-to-day"
        }
    }

    var color: Color {
        switch self {
        case .rent: return Color("LayerRent")
        case .bills: return Color("LayerBills")
        case .subscriptions: return Color("LayerSubscriptions")
        case .dayToDay: return Color("LayerDayToDay")
        }
    }

    /// Resolves a bundle's layer key string to its canonical ordered `SpendingLayer`.
    static func resolve(key: String, bundleLayers: [LayerDefinition]) -> SpendingLayer {
        if let index = bundleLayers.prefix(4).firstIndex(where: { $0.key == key }),
           let match = SpendingLayer(rawValue: index) {
            return match
        }
        if let index = LayerConfig.defaultLayerKeys.firstIndex(of: key),
           let match = SpendingLayer(rawValue: index) {
            return match
        }
        let lower = key.lowercased()
        if lower.contains("rent") { return .rent }
        if lower.contains("bill") || lower.contains("tax") { return .bills }
        if lower.contains("sub") { return .subscriptions }
        return .dayToDay
    }

    /// Display title for this layer using the bundle's configured label when present.
    func title(in bundleLayers: [LayerDefinition]) -> String {
        if bundleLayers.indices.contains(rawValue), !bundleLayers[rawValue].key.isEmpty {
            return bundleLayers[rawValue].key
        }
        return defaultKey
    }
}

/// Formatting and VoiceOver helpers for yen values and calendar labels.
enum FinanceFormat {
    /// VoiceOver-friendly yen reading for balances and totals.
    static func yenAccessibility(_ value: Int, signed: Bool = false) -> String {
        let formatted = value.magnitude.formatted()
        if value < 0 {
            return "minus \(formatted) yen"
        }
        if signed && value > 0 {
            return "plus \(formatted) yen"
        }
        return "\(formatted) yen"
    }

    /// VoiceOver-friendly yen reading for a payment row (positive is money out, negative is money in).
    static func paymentAccessibility(_ value: Int) -> String {
        let formatted = value.magnitude.formatted()
        if value < 0 {
            return "money in, \(formatted) yen"
        }
        return "\(formatted) yen"
    }

    /// Compact axis label for charts, such as "¥0", "¥50k", "¥200k".
    static func compactYen(_ value: Int) -> String {
        let absValue = abs(value)
        let prefix = value < 0 ? "−¥" : "¥"
        if absValue == 0 { return "¥0" }
        if absValue >= 1_000_000 {
            let m = Double(absValue) / 1_000_000.0
            let text = m.truncatingRemainder(dividingBy: 1) == 0
                ? String(format: "%.0fM", m)
                : String(format: "%.1fM", m)
            return prefix + text
        }
        if absValue >= 1_000 {
            let k = Double(absValue) / 1_000.0
            let text = k.truncatingRemainder(dividingBy: 1) == 0
                ? String(format: "%.0fk", k)
                : String(format: "%.1fk", k)
            return prefix + text
        }
        return prefix + absValue.formatted()
    }

    /// Short month chip label such as "Apr", or "Nov '25" when spanning years.
    static func monthChip(_ month: String, includeYear: Bool) -> String {
        guard let date = DayText.date(month + "-01") else { return month }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.timeZone = JST.timeZone
        formatter.dateFormat = includeYear ? "MMM ''yy" : "MMM"
        return formatter.string(from: date)
    }

    /// Short month axis label ("Nov", "Dec", "Jan") for compact chart axes.
    static func chartMonth(_ month: String) -> String {
        guard let date = DayText.date(month + "-01") else { return month }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.timeZone = JST.timeZone
        formatter.dateFormat = "MMM"
        return formatter.string(from: date)
    }

    /// Day section header in Payments, e.g. "TUE, APR 14".
    static func dayHeader(_ day: String) -> String {
        guard let date = DayText.date(day) else { return day }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.timeZone = JST.timeZone
        formatter.setLocalizedDateFormatFromTemplate("EEEMMMd")
        return formatter.string(from: date).uppercased()
    }

    /// "11 days" / "1 day" / "Today" copy for countdown chips.
    static func daysLabel(_ days: Int) -> String {
        switch days {
        case 0: return "Today"
        case 1: return "1 day"
        default: return "\(days) days"
        }
    }

    /// Timestamp formatted as "YYYY-MM-DD HH:MM".
    static func bundleTimestamp(_ iso: String) -> String {
        String(iso.prefix(16)).replacingOccurrences(of: "T", with: " ")
    }
}
