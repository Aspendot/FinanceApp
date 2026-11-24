import Foundation

/// Supported AI vision providers for high-accuracy Japanese receipt & screenshot extraction.
public enum VisionProvider: String, Codable, Sendable, CaseIterable, Identifiable {
    case anthropic
    case gemini
    case openAICompatible

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .anthropic: return "Claude (Anthropic)"
        case .gemini: return "Gemini (Google)"
        case .openAICompatible: return "OpenAI / Compatible"
        }
    }

    public var defaultModel: String {
        switch self {
        case .anthropic: return "claude-sonnet-4-5-20250929"
        case .gemini: return "gemini-2.5-flash"
        case .openAICompatible: return "gpt-4.1-mini"
        }
    }

    public var defaultEndpoint: String {
        switch self {
        case .anthropic: return "https://api.anthropic.com/v1/messages"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent"
        case .openAICompatible: return "https://api.openai.com/v1/chat/completions"
        }
    }
}

/// One extracted receipt or statement row awaiting user review before saving into `LocalModifications`.
public struct ReceiptDraft: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var date: String
    public var merchant: String
    public var amount: Int
    public var group: String
    public var category: String
    public var source: String
    public var note: String?
    public var lineItems: [String]
    public var confidence: String?
    public var isPossibleDuplicate: Bool
    public var isSelected: Bool

    public init(
        id: UUID = UUID(),
        date: String,
        merchant: String,
        amount: Int,
        group: String,
        category: String,
        source: String = "Cash",
        note: String? = nil,
        lineItems: [String] = [],
        confidence: String? = nil,
        isPossibleDuplicate: Bool = false,
        isSelected: Bool = true
    ) {
        self.id = id
        self.date = date
        self.merchant = merchant
        self.amount = amount
        self.group = group
        self.category = category
        self.source = source
        self.note = note
        self.lineItems = lineItems
        self.confidence = confidence
        self.isPossibleDuplicate = isPossibleDuplicate
        self.isSelected = isSelected
    }

    public func asManualEntry(origin: ManualEntry.Origin = .manual) -> ManualEntry {
        let trimmedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ManualEntry(
            date: date,
            source: source,
            merchant: merchant.trimmingCharacters(in: .whitespacesAndNewlines),
            amount: amount,
            group: group,
            category: category,
            note: trimmedNote?.isEmpty == true ? nil : trimmedNote,
            origin: origin
        )
    }
}

/// Prompt builder, strict JSON normalizer, duplicate checker, and offline OCR fallback
/// for Japanese paper receipts, konbini payment slips, and mobile statement screenshots.
public enum ReceiptExtraction {
    /// Builds the instruction prompt passed alongside a receipt or screenshot image.
    public static func systemPrompt(
        categories: [(group: String, category: String)],
        today: String
    ) -> String {
        let categoryList = categories.map(\.category).joined(separator: ", ")
        return """
        You extract personal finance transactions from Japanese or English images:
        1) Paper store receipts (レシート / 領収書)
        2) Japanese konbini / utility / municipal payment slips (払込票 / 収納代行 / 水道料金 / 住民税)
        3) Mobile app transaction history screenshots (multiple rows)

        Rules:
        - Return STRICT JSON ONLY (no markdown, no explanation):
          {"items":[{"date":"YYYY-MM-DD","merchant":"...","amount":1234,"category":"...","source":"Cash","note":"...","lineItems":["..."],"confidence":"high"}]}
        - For a single paper receipt or slip, return exactly ONE object inside "items" using the final amount paid (合計 / お買上計 / 領収金額 / 合計金額 / 収納金額). NEVER use 小計 (subtotal), お預り (tendered), お釣り (change), or 消費税 alone.
        - For a multi-row transaction history screenshot, return one item per visible transaction row (skip running balances or headers).
        - Keep Japanese merchant/utility names verbatim (e.g. あおばスーパー, サンプルコンビニ, サンプル市上下水道局).
        - Positive integer yen for money out; negative integer yen only for explicit refunds/credits.
        - Convert Japanese era years accurately (令和6年=2024, 令和7年=2025, 令和8年=2026). If date is missing, use "\(today)".
        - Pick "category" strictly from this list if one fits: [\(categoryList.isEmpty ? "Groceries, Dining, Transport, Utilities, Household, Pharmacy, Uncategorized" : categoryList)]. Otherwise use "Uncategorized".
        - Keep "note" brief (e.g., short summary of items or utility period). Put up to 5 key purchased items in "lineItems".
        """
    }

    private struct RawEnvelope: Decodable {
        var items: [RawItem]?
    }

    private struct RawItem: Decodable {
        var date: String?
        var merchant: String?
        var amount: Int?
        var category: String?
        var source: String?
        var note: String?
        var lineItems: [String]?
        var confidence: String?

        private enum CodingKeys: String, CodingKey {
            case date, merchant, amount, category, source, note, lineItems, confidence
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            date = try c.decodeIfPresent(String.self, forKey: .date)
            merchant = try c.decodeIfPresent(String.self, forKey: .merchant)
            if let intVal = try? c.decodeIfPresent(Int.self, forKey: .amount) {
                amount = intVal
            } else if let dblVal = try? c.decodeIfPresent(Double.self, forKey: .amount) {
                amount = Int(dblVal.rounded())
            } else if let strVal = try? c.decodeIfPresent(String.self, forKey: .amount) {
                let cleaned = strVal
                    .replacingOccurrences(of: ",", with: "")
                    .replacingOccurrences(of: "¥", with: "")
                    .replacingOccurrences(of: "￥", with: "")
                    .replacingOccurrences(of: "円", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                amount = Int(cleaned)
            } else {
                amount = nil
            }
            category = try c.decodeIfPresent(String.self, forKey: .category)
            source = try c.decodeIfPresent(String.self, forKey: .source)
            note = try c.decodeIfPresent(String.self, forKey: .note)
            lineItems = try c.decodeIfPresent([String].self, forKey: .lineItems)
            confidence = try c.decodeIfPresent(String.self, forKey: .confidence)
        }
    }

    /// Parses strict or fence-wrapped JSON returned by Claude, Gemini, or OpenAI vision models.
    public static func parseAIResponse(
        _ rawText: String,
        today: String,
        defaultSource: String = "Cash",
        availableCategories: [(group: String, category: String)],
        categorizer: Categorizer,
        existingItems: [BudgetItem]
    ) -> [ReceiptDraft] {
        let jsonString = extractJSONBlock(from: rawText)
        guard let data = jsonString.data(using: .utf8) else { return [] }

        var rawItems: [RawItem] = []
        if let envelope = try? JSONDecoder().decode(RawEnvelope.self, from: data),
           let items = envelope.items, !items.isEmpty
        {
            rawItems = items
        } else if let array = try? JSONDecoder().decode([RawItem].self, from: data), !array.isEmpty {
            rawItems = array
        } else if let single = try? JSONDecoder().decode(RawItem.self, from: data) {
            rawItems = [single]
        } else {
            return []
        }

        let categoryLookup = Dictionary(
            availableCategories.map { ($0.category.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )

        return rawItems.compactMap { raw -> ReceiptDraft? in
            guard let amount = raw.amount, amount != 0 else { return nil }
            let merchant = (raw.merchant ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !merchant.isEmpty else { return nil }
            let date = normalizeDate(raw.date, fallback: today)
            let source = (raw.source?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
                $0.isEmpty ? nil : $0
            } ?? defaultSource

            let resolvedPair: (group: String, category: String)
            if let cat = raw.category?.trimmingCharacters(in: .whitespacesAndNewlines),
               cat.caseInsensitiveCompare("Uncategorized") != .orderedSame,
               let exact = categoryLookup[cat.lowercased()]
            {
                resolvedPair = exact
            } else {
                let guessed = categorizer.categorize(merchant: merchant, amount: amount, date: date)
                resolvedPair = (guessed.group, guessed.category)
            }

            let isDup = isPossibleDuplicate(date: date, amount: amount, merchant: merchant, in: existingItems)
            return ReceiptDraft(
                date: date,
                merchant: merchant,
                amount: amount,
                group: resolvedPair.group,
                category: resolvedPair.category,
                source: source,
                note: raw.note?.trimmingCharacters(in: .whitespacesAndNewlines),
                lineItems: raw.lineItems ?? [],
                confidence: raw.confidence,
                isPossibleDuplicate: isDup,
                isSelected: !isDup
            )
        }
    }

    /// Offline heuristic parser for Apple Vision (`VNRecognizeTextRequest`) OCR lines.
    public static func parseOfflineOCR(
        lines: [String],
        today: String,
        defaultSource: String = "Cash",
        availableCategories: [(group: String, category: String)],
        categorizer: Categorizer,
        existingItems: [BudgetItem]
    ) -> [ReceiptDraft] {
        let cleaned = lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return [] }

        let date = extractDate(from: cleaned) ?? today
        let amount = extractTotalAmount(from: cleaned)
        guard let amount, amount > 0 else { return [] }
        let merchant = extractMerchant(from: cleaned) ?? "Scanned receipt"

        let guessed = categorizer.categorize(merchant: merchant, amount: amount, date: date)
        let isDup = isPossibleDuplicate(date: date, amount: amount, merchant: merchant, in: existingItems)

        return [
            ReceiptDraft(
                date: date,
                merchant: merchant,
                amount: amount,
                group: guessed.group,
                category: guessed.category,
                source: defaultSource,
                note: "Offline OCR",
                lineItems: [],
                confidence: "offline",
                isPossibleDuplicate: isDup,
                isSelected: !isDup
            )
        ]
    }

    // MARK: - Helpers

    private static func extractJSONBlock(from text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") {
            let lines = trimmed.components(separatedBy: .newlines)
            let stripped = lines.dropFirst().drop { $0.trimmingCharacters(in: .whitespaces).isEmpty }
            var body = Array(stripped)
            if let last = body.last, last.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                body.removeLast()
            }
            trimmed = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let firstObj = trimmed.firstIndex(of: "{")
        let lastObj = trimmed.lastIndex(of: "}")
        let firstArr = trimmed.firstIndex(of: "[")
        let lastArr = trimmed.lastIndex(of: "]")
        if let fa = firstArr, let la = lastArr, fa < la {
            if let fo = firstObj, let lo = lastObj, fo < lo, fo < fa {
                return String(trimmed[fo...lo])
            }
            return String(trimmed[fa...la])
        }
        if let fo = firstObj, let lo = lastObj, fo < lo {
            return String(trimmed[fo...lo])
        }
        return trimmed
    }

    private static func normalizeDate(_ raw: String?, fallback: String) -> String {
        guard let raw else { return fallback }
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count == 10, JST.dayNumber(s) != nil {
            return s
        }
        if let slashed = JST.day(slashed: s.replacingOccurrences(of: "-", with: "/")) {
            return slashed
        }
        return extractDate(from: [s]) ?? fallback
    }

    private static func extractDate(from lines: [String]) -> String? {
        let joined = lines.joined(separator: "\n")
        // Western YYYY/MM/DD or YYYY-MM-DD or YYYY年M月D日
        let westernPattern = #"(20\d{2})\s*[年/\-\.]\s*(\d{1,2})\s*[月/\-\.]\s*(\d{1,2})"#
        if let regex = try? NSRegularExpression(pattern: westernPattern) {
            let range = NSRange(joined.startIndex..<joined.endIndex, in: joined)
            if let m = regex.firstMatch(in: joined, range: range),
               let rY = Range(m.range(at: 1), in: joined),
               let rM = Range(m.range(at: 2), in: joined),
               let rD = Range(m.range(at: 3), in: joined)
            {
                let candidate = "\(joined[rY])/\(joined[rM])/\(joined[rD])"
                if let valid = JST.day(slashed: candidate) { return valid }
            }
        }
        // Japanese Reiwa era (令和8年 -> 2026)
        let reiwaPattern = #"令和\s*(\d{1,2})\s*年\s*(\d{1,2})\s*月\s*(\d{1,2})\s*日"#
        if let regex = try? NSRegularExpression(pattern: reiwaPattern) {
            let range = NSRange(joined.startIndex..<joined.endIndex, in: joined)
            if let m = regex.firstMatch(in: joined, range: range),
               let rE = Range(m.range(at: 1), in: joined),
               let rM = Range(m.range(at: 2), in: joined),
               let rD = Range(m.range(at: 3), in: joined),
               let era = Int(joined[rE])
            {
                let candidate = "\(2018 + era)/\(joined[rM])/\(joined[rD])"
                if let valid = JST.day(slashed: candidate) { return valid }
            }
        }
        return nil
    }

    private static func extractTotalAmount(from lines: [String]) -> Int? {
        let totalKeywords = ["合計", "お買上計", "お買上げ計", "領収金額", "お支払", "請求金額", "収納金額", "grand total", "total"]
        let subtotalKeywords = ["小計", "subtotal", "sub-total", "sub total"]
        let skipKeywords = ["お預り", "お預かり", "お釣り", "おつり", "釣銭", "ポイント", "change", "cash tendered"]
        let amountRegex = try? NSRegularExpression(pattern: #"[¥￥]?\s*([1-9][0-9,]{1,8})\s*円?"#)

        func numbers(in text: String) -> [Int] {
            guard let amountRegex else { return [] }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            return amountRegex.matches(in: text, range: range).compactMap { m -> Int? in
                guard let r = Range(m.range(at: 1), in: text) else { return nil }
                let val = Int(text[r].replacingOccurrences(of: ",", with: ""))
                // Reject phone numbers / postal / receipt serial codes (> ¥5,000,000).
                if let val, val > 0, val <= 5_000_000 { return val }
                return nil
            }
        }

        // Pass 1: look for explicit payable total lines (excluding subtotal lines like "Subtotal" / "小計").
        for (idx, line) in lines.enumerated() {
            let lower = line.lowercased()
            if skipKeywords.contains(where: { lower.contains($0) }) { continue }
            if subtotalKeywords.contains(where: { lower.contains($0) }) { continue }
            if totalKeywords.contains(where: { lower.contains($0) }) {
                if let val = numbers(in: line).last { return val }
                if idx + 1 < lines.count, let nextVal = numbers(in: lines[idx + 1]).last {
                    return nextVal
                }
            }
        }

        // Pass 2: fallback to largest plausible yen-marked amount.
        let yenRegex = try? NSRegularExpression(pattern: #"(?:[¥￥]\s*([1-9][0-9,]{1,7})|([1-9][0-9,]{1,7})\s*円)"#)
        var yenCandidates: [Int] = []
        for line in lines {
            let lower = line.lowercased()
            if skipKeywords.contains(where: { lower.contains($0) }) { continue }
            guard let yenRegex else { continue }
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            for m in yenRegex.matches(in: line, range: range) {
                for g in 1...2 {
                    let ns = m.range(at: g)
                    if ns.location != NSNotFound, let r = Range(ns, in: line),
                       let v = Int(line[r].replacingOccurrences(of: ",", with: "")),
                       v > 0, v <= 5_000_000
                    {
                        yenCandidates.append(v)
                    }
                }
            }
        }
        return yenCandidates.max()
    }

    private static func extractMerchant(from lines: [String]) -> String? {
        let boilerplate = ["領収証", "領収書", "レシート", "お買い上げ", "電話", "tel", "登録番号", "t1", "t2", "t3", "t4", "t5", "t6", "t7", "t8", "t9"]
        for line in lines.prefix(6) {
            let lower = line.lowercased()
            if line.count < 2 || line.count > 48 { continue }
            if boilerplate.contains(where: { lower.hasPrefix($0) || lower == $0 }) { continue }
            // Skip lines that are mostly digits/dates/phone numbers.
            let digits = line.filter(\.isNumber).count
            if Double(digits) / Double(max(1, line.count)) > 0.55 { continue }
            return line
        }
        return lines.first
    }

    private static func isPossibleDuplicate(
        date: String,
        amount: Int,
        merchant: String,
        in existingItems: [BudgetItem]
    ) -> Bool {
        guard let targetDay = JST.dayNumber(date) else { return false }
        let folded = TextFold.key(merchant)
        return existingItems.contains { item in
            guard item.amount == amount, let itemDay = JST.dayNumber(item.date) else { return false }
            let diff = abs(itemDay - targetDay)
            if diff == 0 { return true }
            if diff <= 2 && !folded.isEmpty {
                let other = TextFold.key(item.merchant)
                return other == folded || other.contains(folded) || folded.contains(other)
            }
            return false
        }
    }
}
