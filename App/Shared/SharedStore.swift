import Foundation

/// Compact bill summary rendered in medium widgets.
struct WidgetBill: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var title: String
    var date: String
    var dateLabel: String
    var amount: Int
    var isEstimate: Bool

    init(
        id: String? = nil,
        title: String,
        date: String,
        dateLabel: String,
        amount: Int,
        isEstimate: Bool
    ) {
        self.id = id ?? "\(date)|\(title)|\(amount)"
        self.title = title
        self.date = date
        self.dateLabel = dateLabel
        self.amount = amount
        self.isEstimate = isEstimate
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, date, dateLabel, amount, isEstimate
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let title = try c.decode(String.self, forKey: .title)
        let date = try c.decode(String.self, forKey: .date)
        let dateLabel = try c.decode(String.self, forKey: .dateLabel)
        let amount = try c.decode(Int.self, forKey: .amount)
        let isEstimate = try c.decode(Bool.self, forKey: .isEstimate)
        let id = try c.decodeIfPresent(String.self, forKey: .id) ?? "\(date)|\(title)|\(amount)"
        self.init(id: id, title: title, date: date, dateLabel: dateLabel, amount: amount, isEstimate: isEstimate)
    }
}

/// Shared Privacy Mode yen redactor compiled into both the main app and the WidgetKit extension.
///
/// Uses strictly ICU-valid `\x{…}` escapes and fails fast if a pattern ever stops compiling.
enum SharedMoneyRedactor {
    private static let patterns: [NSRegularExpression] = {
        let sp = #"[\x{0020}\x{00A0}\x{2000}-\x{200A}\x{202F}\x{3000}\t]"#
        let groupSep = #"[,，'’\x{0020}\x{00A0}\x{2000}-\x{200A}\x{202F}]"#
        let tightGroupSep = #"[,，'’\x{00A0}\x{2000}-\x{200A}\x{202F}]"#
        let euroGroupedNum = #"[0-9０-９]{1,3}(?:[\.．][0-9０-９]{3})+(?:[,，][0-9０-９]{1,2}(?![0-9０-９]))?"#
        let groupedNum = #"(?:"# + euroGroupedNum + #"|(?:[0-9０-９]{1,3}(?:"# + groupSep + #"[0-9０-９]{3})+|[0-9０-９]+)(?:[\.．][0-9０-９]+|[,，][0-9０-９]{1,2}(?![0-9０-９]))?)"#
        let tightGroupedNum = #"(?:"# + euroGroupedNum + #"|(?:[0-9０-９]{1,3}(?:"# + tightGroupSep + #"[0-9０-９]{3})+|[0-9０-９]+)(?:[\.．][0-9０-９]+|[,，][0-9０-９]{1,2}(?![0-9０-９]))?)"#
        let rangeTail = #"[KkMm]?(?:"# + sp + #"*[\-–—〜~]"# + sp + #"*"# + groupedNum + #"[KkMm]?)?"#
        let jpSimpleNum = #"(?:[0-9０-９]{1,3}(?:"# + tightGroupSep + #"[0-9０-９]{3})+|[0-9０-９]+|[一二三四五六七八九〇十百千]+)(?:[\.．][0-9０-９]+)?"#
        let jpRange = jpSimpleNum + #"(?:"# + sp + #"*[\-–—〜~]"# + sp + #"*"# + jpSimpleNum + #")?"#
        let jpUnitTerm = jpRange + #"(?:億|万|千|百|十)"#
        let jpUnit = jpUnitTerm + #"(?:(?:"# + sp + #"*[\-–—〜~]"# + sp + #"*)?"# + jpUnitTerm + #")*(?:"# + jpSimpleNum + #")?"# + sp + #"*円"#
        let jpKanjiYen = #"(?<![0-9０-９一二三四五六七八九〇十百千])[一二三四五六七八九〇十百千万億]+(?:"# + sp + #"*[\-–—〜~]"# + sp + #"*[一二三四五六七八九〇十百千万億]+)?"# + sp + #"*円"#
        let jpManOnly = #"(?<![0-9０-９一二三四五六七八九〇十百千])"# + jpRange + #"(?:億|万)(?:(?:"# + jpSimpleNum + #"(?:千|百|十)?)*)?(?![人名回件個枚本台歳年円歩曲話日週月秒分])"#
        let currencyCodes = #"JPY|USD|EUR|GBP|AUD|CAD|NZD|HKD|SGD|TWD|MXN|KRW|CNY|RMB|CHF|THB|PHP|INR|VND|MYR|IDR|SEK|NOK|DKK|BRL|ZAR"#
        let yenUnitSuffix = sp + #"*(?:[円元¥￥\$＄€£₱₩₹฿₫]|(?:yen|"# + currencyCodes + #")(?![A-Za-z0-9]))"#
        let specs: [(String, String, NSRegularExpression.Options)] = [
            ("yenPrefix", #"[+−\-－＋]?[¥￥]"# + sp + #"*[+−\-－＋]?"# + sp + #"*"# + groupedNum + rangeTail, []),
            ("usdPrefix", #"(?:(?<![A-Za-z0-9])[+−\-－＋]?(?:US|USD|CA|CAD|AU|AUD|NZ|NZD|HK|HKD|SG|SGD|NT|TWD|MX|MXN)"# + sp + #"*)?[+−\-－＋]?[\$＄]"# + sp + #"*[+−\-－＋]?"# + sp + #"*"# + groupedNum + rangeTail, [.caseInsensitive]),
            ("otherSymbolPrefix", #"[+−\-－＋]?[€£₱₩₹฿₫]"# + sp + #"*[+−\-－＋]?"# + sp + #"*"# + groupedNum + rangeTail, []),
            ("currencyCodePrefix", #"(?<![A-Za-z0-9])(?:"# + currencyCodes + #")"# + sp + #"+[+−\-－＋]?"# + sp + #"*"# + groupedNum + rangeTail, [.caseInsensitive]),
            ("jpyCompactPrefix", #"(?<![A-Za-z0-9])(?:"# + currencyCodes + #")"# + #"[+−\-－＋]?"# + groupedNum + rangeTail, [.caseInsensitive]),
            ("jpUnit", jpUnit, []),
            ("jpKanjiYen", jpKanjiYen, []),
            ("jpManOnly", jpManOnly, []),
            ("yenSuffixSpaceGrouped", #"(?<![0-9０-９\-/])(?:[0-9０-９]{1,3}(?:[\x{0020}\x{00A0}\x{202F}][0-9０-９]{3})+)(?:[\.．][0-9０-９]+|[,，][0-9０-９]{1,2}(?![0-9０-９]))?"# + rangeTail + yenUnitSuffix, [.caseInsensitive]),
            ("yenSuffixRange", #"(?<![0-9０-９\-/])"# + tightGroupedNum + #"[KkMm]?"# + sp + #"*[\-–—〜~]"# + sp + #"*"# + tightGroupedNum + #"[KkMm]?"# + yenUnitSuffix, [.caseInsensitive]),
            ("yenSuffix", #"(?<![0-9０-９])"# + tightGroupedNum + #"[KkMm]?"# + yenUnitSuffix, [.caseInsensitive]),
        ]
        return specs.map { name, pattern, options in
            do {
                return try NSRegularExpression(pattern: pattern, options: options)
            } catch {
                preconditionFailure("SharedMoneyRedactor invalid regex '\(name)': \(error)")
            }
        }
    }()

    static func redact(_ text: String) -> String {
        var out = text
        for regex in patterns {
            let range = NSRange(out.startIndex..<out.endIndex, in: out)
            out = regex.stringByReplacingMatches(in: out, options: [], range: range, withTemplate: "¥•••,•••")
        }
        return out
    }
}

/// What the app shows in its Home Screen and Lock Screen widgets.
///
/// New fields are optional so snapshots written by earlier app versions continue to decode cleanly.
struct WidgetSnapshot: Codable, Equatable, Sendable {
    var title: String
    var value: String
    var detail: String
    var updatedAt: Date
    var compactValue: String? = nil
    var daysToPayday: Int? = nil
    /// Target payday date (`"YYYY-MM-DD"`) so the widget advances the countdown automatically at JST midnight.
    var paydayDate: String? = nil
    var cycleProgress: Double? = nil
    var billsSum: Int? = nil
    var leftSum: Int? = nil
    var borrowedSum: Int? = nil
    var upcomingBills: [WidgetBill]? = nil
    /// True when published while Privacy Mode is enabled so widgets hide exact yen amounts.
    var isPrivacyMasked: Bool? = nil

    init(
        title: String,
        value: String,
        detail: String,
        updatedAt: Date,
        compactValue: String? = nil,
        daysToPayday: Int? = nil,
        paydayDate: String? = nil,
        cycleProgress: Double? = nil,
        billsSum: Int? = nil,
        leftSum: Int? = nil,
        borrowedSum: Int? = nil,
        upcomingBills: [WidgetBill]? = nil,
        isPrivacyMasked: Bool? = nil
    ) {
        self.title = title
        self.value = value
        self.detail = detail
        self.updatedAt = updatedAt
        self.compactValue = compactValue
        self.daysToPayday = daysToPayday
        self.paydayDate = paydayDate
        self.cycleProgress = cycleProgress
        self.billsSum = billsSum
        self.leftSum = leftSum
        self.borrowedSum = borrowedSum
        self.upcomingBills = upcomingBills
        self.isPrivacyMasked = isPrivacyMasked
    }

    private enum CodingKeys: String, CodingKey {
        case title, value, detail, updatedAt, compactValue, daysToPayday, paydayDate
        case cycleProgress, billsSum, leftSum, borrowedSum, upcomingBills, isPrivacyMasked
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        value = try c.decode(String.self, forKey: .value)
        detail = try c.decode(String.self, forKey: .detail)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        compactValue = try c.decodeIfPresent(String.self, forKey: .compactValue)
        daysToPayday = try c.decodeIfPresent(Int.self, forKey: .daysToPayday)
        paydayDate = try c.decodeIfPresent(String.self, forKey: .paydayDate)
        cycleProgress = try c.decodeIfPresent(Double.self, forKey: .cycleProgress)
        billsSum = try c.decodeIfPresent(Int.self, forKey: .billsSum)
        leftSum = try c.decodeIfPresent(Int.self, forKey: .leftSum)
        borrowedSum = try c.decodeIfPresent(Int.self, forKey: .borrowedSum)
        isPrivacyMasked = try c.decodeIfPresent(Bool.self, forKey: .isPrivacyMasked)
        if var bills = try c.decodeIfPresent([WidgetBill].self, forKey: .upcomingBills) {
            // Guarantee strictly unique IDs even across mixed explicit and legacy fallback snapshots.
            var seen = Set<String>()
            for idx in bills.indices {
                var candidate = bills[idx].id
                var suffix = 0
                while !seen.insert(candidate).inserted {
                    candidate = "\(idx)-\(suffix)|\(bills[idx].id)"
                    suffix += 1
                }
                bills[idx].id = candidate
            }
            upcomingBills = bills
        } else {
            upcomingBills = nil
        }
    }

    static let placeholder = WidgetSnapshot(
        title: "Finance",
        value: "–",
        detail: "Open the app to sync",
        updatedAt: .distantPast
    )
}

/// Data shared between the app and its widget through an App Group.
enum SharedStore {
    /// The App Group this install can actually use, or nil if it has none.
    ///
    /// SideStore can rename App Groups when it signs the app with a free Apple ID, so
    /// the compiled name is only one candidate. The others are any groups listed under
    /// `ALTAppGroups` in Info.plist (written by AltStore-family installers) and a
    /// name derived from the installed bundle ID. The first group whose container
    /// exists wins.
    static let groupID: String? = {
        var candidates: [String] = []
        if let listed = Bundle.main.object(forInfoDictionaryKey: "ALTAppGroups") as? [String] {
            candidates += listed
        }
        if let compiled = Bundle.main.object(forInfoDictionaryKey: "FinanceAppGroup") as? String {
            candidates.append(compiled)
        }
        if let bundleID = Bundle.main.bundleIdentifier {
            let base = bundleID.hasSuffix(".widget") ? String(bundleID.dropLast(".widget".count)) : bundleID
            candidates.append("group." + base)
        }
        return candidates.first {
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) != nil
        }
    }()

    static var defaults: UserDefaults? {
        groupID.flatMap { UserDefaults(suiteName: $0) }
    }

    private static let snapshotKey = "widgetSnapshot"
    private static let privacyMaskedKey = "financePrivacyMasked"
    private static let pendingActionKey = "pendingControlAction"
    private static let pendingActionTimestampKey = "pendingControlActionAt"

    /// Mirrors the app's Train Privacy Mask in the App Group so widgets and notifications obey it too.
    static var privacyMasked: Bool {
        get {
            if let defaults, defaults.object(forKey: privacyMaskedKey) != nil {
                return defaults.bool(forKey: privacyMaskedKey)
            }
            return UserDefaults.standard.bool(forKey: privacyMaskedKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: privacyMaskedKey)
            defaults?.set(newValue, forKey: privacyMaskedKey)
        }
    }

    static func write(_ snapshot: WidgetSnapshot) {
        guard let defaults, let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: snapshotKey)
    }

    static func read() -> WidgetSnapshot? {
        guard let data = defaults?.data(forKey: snapshotKey) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    /// Records a deep-link action triggered from a Control Center or Lock Screen widget.
    static func setPendingAction(_ action: String) {
        let store = defaults ?? UserDefaults.standard
        store.set(action, forKey: pendingActionKey)
        store.set(Date().timeIntervalSince1970, forKey: pendingActionTimestampKey)
    }

    /// Consumes a recent pending action (within 30 seconds) once the app becomes active.
    static func consumePendingAction() -> String? {
        let store = defaults ?? UserDefaults.standard
        guard let action = store.string(forKey: pendingActionKey) else { return nil }
        let timestamp = store.double(forKey: pendingActionTimestampKey)
        store.removeObject(forKey: pendingActionKey)
        store.removeObject(forKey: pendingActionTimestampKey)
        guard Date().timeIntervalSince1970 - timestamp < 30 else { return nil }
        return action
    }
}

extension Notification.Name {
    static let financePendingControlAction = Notification.Name("financePendingControlAction")
}
