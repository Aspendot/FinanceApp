import Foundation

/// Merpay and メルカード notices.
///
/// Payment notices give the shop, the time to the minute, the 取引番号 and the
/// total, often split into credit, points, wallet balance and discount. The split
/// must add up to the total, or the notice is quarantined. Most other mail from
/// this sender is marketing, so only known subjects are parsed; unknown subjects
/// that sound like money are quarantined.
enum MerpayParser {
    static let sender = "no-reply@mercari.jp"
    static let version = "merpay/1"

    static let purchaseSubjects: Set<String> = Set([
        "メルカードのご利用がありました",
        "Mastercardでお支払いがありました",
        "Apple Payでお支払いがありました",
        "ネット決済でお支払いがありました",
    ].map(TextFold.key))
    static let declineSubject = TextFold.key("メルカードの利用限度額不足でお支払いできません")
    static let subjectWatchWords = ["お支払いがありました", "ご利用がありました", "チャージ", "返金", "キャンセル", "請求", "お支払いできません"]
    static let partNames = ["クレジット": "credit", "ポイント": "points", "メルペイ残高": "balance", "値引き": "discount"]

    static func parse(_ email: NoticeEmail) -> ParseOutcome {
        let subject = TextFold.key(email.subject)
        if purchaseSubjects.contains(subject) {
            return payment(email, kind: .purchase)
        }
        if subject == declineSubject {
            return payment(email, kind: .decline)
        }
        if let outcome = topUp(email) {
            return outcome
        }
        if subject.hasPrefix(TextFold.key("【メルペイ】")), subject.hasSuffix(TextFold.key("請求の支払いが完了しました")) {
            return billPaid(email)
        }
        if subjectWatchWords.contains(where: { email.subject.contains($0) }) {
            return .quarantined("Merpay: unknown layout that mentions money")
        }
        return .ignored("Merpay: not a money notice")
    }

    private static func payment(_ email: NoticeEmail, kind: NoticeKind) -> ParseOutcome {
        let f = Fields(email.text)
        guard let totalText = f["決済金額"] ?? f["取引金額合計"], let total = Yen.parse(totalText) else {
            return .quarantined("Merpay: no whole-yen total")
        }
        guard let whenText = f["決済日時"] ?? f["取引日時"], let occurredAt = JST.timestamp(slashed: whenText) else {
            return .quarantined("Merpay: no readable time")
        }
        let reference = f["取引番号"]
        if kind == .purchase, reference?.isEmpty ?? true {
            return .quarantined("Merpay: payment without 取引番号")
        }
        guard let parts = splitParts(email.text) else {
            return .quarantined("Merpay: unreadable split line")
        }
        if !parts.isEmpty, parts.values.reduce(0, +) != total {
            return .quarantined("Merpay: split does not add up to the total")
        }
        let merchant = [f["店舗名"], f["ネットショップ"], f["サービス名"]].compactMap { $0 }.first { !$0.isEmpty }
        return .notice(Notice(
            messageID: email.messageID,
            source: .merpay,
            kind: kind,
            receivedAt: JST.timestamp(email.receivedAt),
            occurredAt: occurredAt,
            amount: total,
            currency: "JPY",
            merchant: merchant,
            reference: reference,
            orderID: f["Apple ご注文番号"],
            parts: parts.isEmpty ? nil : parts,
            parser: version
        ))
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

    /// The top-up email is HTML only, but its subject carries everything:
    /// "<bank>から￥54,321チャージしました".
    private static func topUp(_ email: NoticeEmail) -> ParseOutcome? {
        let suffix = "チャージしました"
        let subject = email.subject.trimmingCharacters(in: .whitespaces)
        guard subject.hasSuffix(suffix), let from = subject.range(of: "から") else { return nil }
        let bank = String(subject[..<from.lowerBound])
        let amountText = String(subject[from.upperBound..<subject.index(subject.endIndex, offsetBy: -suffix.count)])
        guard !bank.isEmpty, let amount = Yen.parse(amountText), amount > 0 else {
            return .quarantined("Merpay: unreadable top-up subject")
        }
        return .notice(Notice(
            messageID: email.messageID,
            source: .merpay,
            kind: .topUp,
            receivedAt: JST.timestamp(email.receivedAt),
            amount: amount,
            currency: "JPY",
            merchant: bank,
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
}
