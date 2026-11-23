import SwiftUI

/// Visual style metadata (symbol + curated calm color) for categories, cards and settings rows.
///
/// Health and clinic categories intentionally stay understated in calm slate so sensitive
/// medical entries never draw undue attention on screen.
enum CategoryStyle {
    struct Spec {
        let symbol: String
        let tint: Color
    }

    static func forCategory(_ raw: String) -> Spec {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // Discreet presentation for health / pharmacy / clinic entries
        if key.contains("clinic") || key.contains("health") || key.contains("medical")
            || key.contains("pharmacy") || key.contains("dental") || key.contains("hospital")
            || key.contains("doctor") || key.contains("薬") || key.contains("病院")
        {
            return Spec(symbol: "cross.case", tint: Color(red: 0.44, green: 0.50, blue: 0.53))
        }

        if key.contains("rent") || key.contains("housing") || key.contains("家賃") {
            return Spec(symbol: "house.fill", tint: Color("LayerRent"))
        }
        if key.contains("grocer") || key.contains("super") || key.contains("market") || key.contains("食料") {
            return Spec(symbol: "basket.fill", tint: Color("LayerSubscriptions"))
        }
        if key.contains("coffee") || key.contains("cafe") || key.contains("珈琲") || key.contains("カフェ") {
            return Spec(symbol: "cup.and.saucer.fill", tint: Color(red: 0.66, green: 0.42, blue: 0.24))
        }
        if key.contains("dining") || key.contains("food") || key.contains("restaurant")
            || key.contains("lunch") || key.contains("eat") || key.contains("外食") || key.contains("conbini") || key.contains("convenience")
        {
            return Spec(symbol: "fork.knife", tint: Color("LayerDayToDay"))
        }
        if key.contains("transport") || key.contains("transit") || key.contains("train")
            || key.contains("commut") || key.contains("taxi") || key.contains("suica") || key.contains("icoca") || key.contains("交通")
        {
            return Spec(symbol: "tram.fill", tint: Color("LayerRent"))
        }
        if key.contains("electric") || key.contains("gas") || key.contains("water")
            || key.contains("utilit") || key.contains("bill") || key.contains("tax") || key.contains("光熱")
        {
            return Spec(symbol: "bolt.fill", tint: Color("LayerBills"))
        }
        if key.contains("phone") || key.contains("mobile") || key.contains("internet")
            || key.contains("wifi") || key.contains("telecom") || key.contains("通信")
        {
            return Spec(symbol: "wifi", tint: Color(red: 0.26, green: 0.46, blue: 0.66))
        }
        if key.contains("sub") || key.contains("ai") || key.contains("cloud")
            || key.contains("software") || key.contains("app") || key.contains("membership")
        {
            return Spec(symbol: "repeat", tint: Color("LayerSubscriptions"))
        }
        if key.contains("household") || key.contains("home") || key.contains("daily") || key.contains("日用品") {
            return Spec(symbol: "shippingbox.fill", tint: Color(red: 0.47, green: 0.42, blue: 0.64))
        }
        if key.contains("shop") || key.contains("cloth") || key.contains("fashion") || key.contains("amazon") {
            return Spec(symbol: "bag.fill", tint: Color(red: 0.56, green: 0.37, blue: 0.54))
        }
        if key.contains("travel") || key.contains("hotel") || key.contains("flight") || key.contains("trip") {
            return Spec(symbol: "airplane", tint: Color("LayerRent"))
        }
        if key.contains("entertain") || key.contains("music") || key.contains("movie") || key.contains("game") || key.contains("book") {
            return Spec(symbol: "sparkles", tint: Color(red: 0.52, green: 0.40, blue: 0.68))
        }
        if key.contains("salary") || key.contains("income") || key.contains("payday") || key.contains("bonus") || key.contains("給与") {
            return Spec(symbol: "arrow.down.left.circle.fill", tint: Color("Good"))
        }
        if key.contains("debt") || key.contains("loan") || key.contains("repay") || key.contains("card") {
            return Spec(symbol: "percent", tint: Color("Bad"))
        }
        if key.contains("people") || key.contains("transfer") || key.contains("friend") || key.contains("gift") || key.contains("送金") {
            return Spec(symbol: "arrow.left.arrow.right", tint: Color(red: 0.36, green: 0.49, blue: 0.58))
        }
        if key.contains("work") || key.contains("office") || key.contains("business") {
            return Spec(symbol: "briefcase.fill", tint: Color("LayerRent"))
        }

        return Spec(symbol: "yensign", tint: Color("Accent"))
    }

    static func forSource(_ raw: String) -> Spec {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if key.contains("cash") || key.contains("現金") {
            return Spec(symbol: "banknote.fill", tint: Color("Good"))
        }
        if key.contains("bank") || key.contains("銀行") || key.contains("mufg") || key.contains("docomo") || key.contains("smtb") {
            return Spec(symbol: "building.columns.fill", tint: Color("LayerRent"))
        }
        if key.contains("paypay") || key.contains("merpay") || key.contains("wallet") || key.contains("メル") {
            return Spec(symbol: "qrcode", tint: Color("LayerBills"))
        }
        if key.contains("transit") || key.contains("suica") || key.contains("icoca") || key.contains("pasmo") {
            return Spec(symbol: "tram.card.fill", tint: Color("LayerSubscriptions"))
        }
        return Spec(symbol: "creditcard.fill", tint: Color("Accent"))
    }
}

/// Tactile softly tinted squircle badge holding a semantic SF Symbol for categories, cards, and settings.
struct IconMedallion: View {
    @Environment(\.colorScheme) private var colorScheme
    let symbol: String
    let tint: Color
    var size: CGFloat = 34
    var iconScale: CGFloat = 0.44

    var body: some View {
        let corner = size * 0.30
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        ZStack {
            shape
                .fill(tint.opacity(colorScheme == .dark ? 0.18 : 0.11))
            shape
                .strokeBorder(tint.opacity(colorScheme == .dark ? 0.28 : 0.16), lineWidth: 0.75)
            Image(systemName: symbol)
                .font(.system(size: size * iconScale, weight: .semibold))
                .foregroundStyle(tint)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Convenience wrapper rendering a category's curated icon medallion.
struct CategoryBadge: View {
    let category: String
    var size: CGFloat = 36

    var body: some View {
        let spec = CategoryStyle.forCategory(category)
        IconMedallion(symbol: spec.symbol, tint: spec.tint, size: size)
    }
}

/// Compact monogram medallion for subscriptions and merchants.
struct MonogramBadge: View {
    @Environment(\.colorScheme) private var colorScheme
    let text: String
    let tint: Color
    var size: CGFloat = 34

    private var glyph: String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "¥" }
        return String(first).uppercased()
    }

    var body: some View {
        let corner = size * 0.30
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        ZStack {
            shape
                .fill(tint.opacity(colorScheme == .dark ? 0.18 : 0.11))
            shape
                .strokeBorder(tint.opacity(colorScheme == .dark ? 0.26 : 0.15), lineWidth: 0.75)
            Text(glyph)
                .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
