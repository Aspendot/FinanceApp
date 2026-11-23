import Foundation

/// Merpay and メルカード notices.
///
/// Payment notices give the shop, the time, the 取引番号 and the total, often
/// split into credit, points, wallet balance, pay-later and discount. The split
/// must add up to the total, or the notice is quarantined. Most other mail from
/// this sender is marketing, so only known subjects are parsed.
enum MerpayParser {
    static let sender = "no-reply@mercari.jp"
    static let version = "merpay/1"

    static let purchaseSubjects: Set<String> = Set([
        "メルカードのご利用がありました",
        "Mastercardでお支払いがありました",
        "Apple Payでお支払いがありました",
        "ネット決済でお支払いがありました",
        "iD決済でお支払いがありました",
        "コード決済でお支払いがありました",
    ].map(TextFold.key))
    static let cancellationSubject = TextFold.key("メルカードで決済された取引がキャンセルされました")
    /// The final amount of an earlier payment, for example after currency conversion.
    static let settlementSubject = TextFold.key("メルカードの決済金額が確定しました")
    static let marketPurchaseSubject = TextFold.key("【メルカリ】ご購入ありがとうございます")
    static let partNames = [
        "クレジット": "credit", "ポイント": "points", "メルペイ残高": "balance", "残高": "balance",
        "メルペイのあと払い": "deferred", "値引き": "discount",
    ]

    static func parse(_ email: NoticeEmail) -> ParseOutcome {
        let subject = TextFold.key(email.subject)
        let raw = email.subject
        if purchaseSubjects.contains(subject) {
            return payment(email, kind: .purchase)
        }
        if subject == cancellationSubject {
            return payment(email, kind: .cancellation)
        }
        if subject == settlementSubject {
            return payment(email, kind: .settlement)
        }
        if subject == marketPurchaseSubject {
            return marketPurchase(email)
        }
        if raw.hasPrefix("【メルカリ】振込申請が完了しました") {
            return .ignored("Merpay: transfer request; the completion notice counts")
        }
        if raw.hasPrefix("【メルカリ】振込完了のお知らせ") {
            return proceedsTransfer(email)
        }
        if raw.contains("できません") || raw.contains("対象外取引") || raw.hasPrefix("残高不足") {
            return payment(email, kind: .decline)
        }
        if raw.contains("返金がありました") || raw.contains("調整がありました") {
            return refund(email)
        }
        if raw.contains("チャージに失敗しました") {
            return subjectAmount(email, kind: .decline)
        }
        if raw.contains("チャージしました") {
            return subjectAmount(email, kind: .topUp)
        }
        if raw.hasPrefix("【メルペイ】"), raw.hasSuffix("請求の支払いが完了しました") {
            return billPaid(email)
        }
        if raw.hasPrefix("【メルペイ】"), raw.hasSuffix("のご請求金額のお知らせ") {
            return bill(email)
        }
        return NoticeParsers.unknown(email, "Merpay")
    }

    /// Payments, declines and cancellations share one layout.
    private static func payment(_ email: NoticeEmail, kind: NoticeKind) -> ParseOutcome {
        let f = Fields(email.text)
        guard let totalText = f["決済金額"] ?? f["取引金額合計"], let total = Yen.parse(totalText) else {
            return .quarantined("Merpay: no whole-yen total")
        }
        guard let when = time(f["決済日時"] ?? f["取引日時"]) else {
            return .quarantined("Merpay: no readable time")
        }
        let reference = f["取引番号"]
        if kind == .purchase || kind == .cancellation, reference?.isEmpty ?? true {
            return .quarantined("Merpay: \(kind.rawValue) without 取引番号")
        }
        guard let parts = splitParts(email.text) else {
            return .quarantined("Merpay: unreadable split line")
        }
        if !parts.isEmpty, parts.values.reduce(0, +) != total {
            return .quarantined("Merpay: split does not add up to the total")
        }
        let merchant = [f["店舗名"], f["ネットショップ"], f["サービス名"]].compactMap { $0 }.first { !$0.isEmpty }
        let sign = kind == .cancellation ? -1 : 1
        // ¥1 authorizations and their releases only check the card.
        let finalKind: NoticeKind = (kind == .purchase || kind == .cancellation) && total == 1 ? .cardCheck : kind
        return .notice(Notice(
            messageID: email.messageID,
            source: .merpay,
            kind: finalKind,
            receivedAt: JST.timestamp(email.receivedAt),
            occurredAt: when.at,
            occurredOn: when.on,
            amount: sign * total,
            currency: "JPY",
            foreignAmount: f["現地利用金額"],
            merchant: merchant,
            reference: reference,
            orderID: f["Apple ご注文番号"],
            parts: parts.isEmpty ? nil : parts.mapValues { sign * $0 },
            parser: version
        ))
    }

    /// 「￥…の返金がありました」, 「メルカードで返金がありました」 and
    /// 「取引キャンセルに伴い、メルペイで￥…の調整がありました」. Money back, so the
    /// amount is negative. When the notice also shows the original payment, its
    /// 取引番号 becomes the related reference.
    private static func refund(_ email: NoticeEmail) -> ParseOutcome {
        let f = Fields(email.text)
        guard let totalText = f["返金額合計"] ?? f["調整金額合計"] ?? f["キャンセル金額"], let total = Yen.parse(totalText) else {
            return .quarantined("Merpay: refund without a whole-yen amount")
        }
        guard let when = time(f["取引日時"]) else {
            return .quarantined("Merpay: refund without a readable date")
        }
        guard let parts = splitParts(email.text) else {
            return .quarantined("Merpay: unreadable split line")
        }
        if !parts.isEmpty, parts.values.reduce(0, +) != total {
            return .quarantined("Merpay: split does not add up to the total")
        }
        let refs = f.all("取引番号")
        let merchant = f["店舗名"].flatMap { $0.isEmpty ? nil : $0 }
        return .notice(Notice(
            messageID: email.messageID,
            source: .merpay,
            kind: .refund,
            receivedAt: JST.timestamp(email.receivedAt),
            occurredAt: when.at,
            occurredOn: when.on,
            amount: -total,
            currency: "JPY",
            merchant: merchant,
            reference: refs.first,
            relatedReference: refs.count > 1 ? refs[1] : nil,
            parts: parts.isEmpty ? nil : parts.mapValues { -$0 },
            parser: version
        ))
    }

    /// Top-ups and failed top-ups carry their amount in the subject, and the
    /// bank before "から" when there is one. The emails themselves are HTML only.
    private static func subjectAmount(_ email: NoticeEmail, kind: NoticeKind) -> ParseOutcome {
        guard let amount = NoticeParsers.yenInSubject(email.subject), amount > 0 else {
            return .quarantined("Merpay: no amount in the subject")
        }
        let bank = email.subject.range(of: "から").map { String(email.subject[..<$0.lowerBound]) }
        return .notice(Notice(
            messageID: email.messageID,
            source: .merpay,
            kind: kind,
            receivedAt: JST.timestamp(email.receivedAt),
            amount: amount,
            currency: "JPY",
            merchant: bank.flatMap { $0.isEmpty || $0.contains("￥") ? nil : $0 },
            parser: version
        ))
    }

    /// A purchase on the Mercari marketplace, paid through Merpay. The item name
    /// stands in for the merchant; the item ID is the reference.
    private static func marketPurchase(_ email: NoticeEmail) -> ParseOutcome {
        let f = Fields(email.text)
        guard let amountText = f["支払い金額"], let amount = Yen.parse(amountText) else {
            return .quarantined("Merpay: marketplace purchase without a whole-yen amount")
        }
        return .notice(Notice(
            messageID: email.messageID,
            source: .merpay,
            kind: .purchase,
            receivedAt: JST.timestamp(email.receivedAt),
            amount: amount,
            currency: "JPY",
            merchant: f["商品名"],
            reference: f["商品ID"],
            parser: version
        ))
    }

    /// Sales proceeds sent from the Mercari balance to a bank account. Not spending.
    private static func proceedsTransfer(_ email: NoticeEmail) -> ParseOutcome {
        let f = Fields(email.text)
        let amount = f["振込金額"].flatMap(Yen.parse)
            ?? f.entries.lazy.filter { $0.key.contains("金額") }.compactMap { Yen.parse($0.value) }.first
        return .notice(Notice(
            messageID: email.messageID,
            source: .merpay,
            kind: .withdrawal,
            receivedAt: JST.timestamp(email.receivedAt),
            amount: amount,
            currency: "JPY",
            parser: version
        ))
    }

    private static func billPaid(_ email: NoticeEmail) -> ParseOutcome {
        let f = Fields(email.text)
        let amountText = ["お支払い金額", "お支払金額", "支払金額", "ご請求金額", "請求金額"].lazy.compactMap { f[$0] }.first
        return .notice(Notice(
            messageID: email.messageID,
            source: .merpay,
            kind: .billPaid,
            receivedAt: JST.timestamp(email.receivedAt),
            amount: amountText.flatMap(Yen.parse),
            currency: "JPY",
            parser: version
        ))
    }

    /// 「【メルペイ】N月のご請求金額のお知らせ」: the amount due, split into
    /// 翌月払い and 分割払い. Values can carry a note mark, such as "¥40,033(※)".
    private static func bill(_ email: NoticeEmail) -> ParseOutcome {
        let f = Fields(email.text)
        func yen(_ key: String) -> Int? {
            f[key].flatMap { Yen.parse($0.prefix { $0 != "(" && $0 != "（" }.trimmingCharacters(in: .whitespaces)) }
        }
        guard let total = yen("ご請求金額") else {
            return .quarantined("Merpay: bill without a whole-yen amount")
        }
        var parts: [String: Int] = [:]
        if let v = yen("翌月払い") { parts["next_month"] = v }
        if let v = yen("分割払い") { parts["installments"] = v }
        if let v = yen("定額払い") { parts["fixed"] = v }
        return .notice(Notice(
            messageID: email.messageID,
            source: .merpay,
            kind: .bill,
            receivedAt: JST.timestamp(email.receivedAt),
            amount: total,
            currency: "JPY",
            parts: parts.isEmpty ? nil : parts,
            parser: version
        ))
    }

    /// "2026/01/15 09:20" gives a time; "2026/01/15" gives only a date.
    private static func time(_ text: String?) -> (at: String?, on: String?)? {
        guard let text else { return nil }
        if let at = JST.timestamp(slashed: text) { return (at, nil) }
        if let on = JST.day(slashed: text) { return (nil, on) }
        return nil
    }

    /// Lines such as "　└ クレジット　：　￥584" or "└ポイント：P350". Returns nil
    /// if a split line can't be read.
    static func splitParts(_ text: String) -> [String: Int]? {
        var parts: [String: Int] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("└") else { continue }
            let body = trimmed.dropFirst()
            guard let sep = body.firstIndex(where: { $0 == ":" || $0 == "：" }) else { return nil }
            let label = body[..<sep].trimmingCharacters(in: .whitespaces)
            var value = body[body.index(after: sep)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("P") || value.hasPrefix("Ｐ") {
                value.removeFirst()
            }
            guard !label.isEmpty, let amount = Yen.parse(value) else { return nil }
            parts[partNames[label] ?? label, default: 0] += amount
        }
        return parts
    }
}
