import Foundation

/// Errors thrown while reading a Japanese wallet / card CSV export.
public enum PayPayCSVError: Error, LocalizedError, Equatable, Sendable {
    case emptyFile
    case missingRequiredColumns([String])

    public var errorDescription: String? {
        switch self {
        case .emptyFile:
            return "The CSV file is empty."
        case .missingRequiredColumns(let missing):
            return "This does not look like a supported PayPay CSV (missing: \(missing.joined(separator: ", ")))."
        }
    }
}

/// Summary of an on-device PayPay CSV import.
public struct PayPayImportResult: Sendable, Equatable {
    public var entries: [ManualEntry]
    public var skippedDuplicates: Int
    public var skippedNonSpending: Int
    public var earliestDate: String?
    public var latestDate: String?

    public init(
        entries: [ManualEntry],
        skippedDuplicates: Int,
        skippedNonSpending: Int,
        earliestDate: String?,
        latestDate: String?
    ) {
        self.entries = entries
        self.skippedDuplicates = skippedDuplicates
        self.skippedNonSpending = skippedNonSpending
        self.earliestDate = earliestDate
        self.latestDate = latestDate
    }
}

/// Parses PayPay app CSV exports (PayPay balance + PayPay Card) into deduplicated `ManualEntry` records.
///
/// Follows the same rules as the pipeline:
/// - Keeps `支払い` (`PayPay Card` for credit/card methods, `PayPay` otherwise) and
///   `送った金額` / `受け取った金額` (transfers with people).
/// - Skips top-ups (`チャージ`) and non-payment rows so bank top-ups are never double-counted.
/// - Deduplicates by transaction ID (`取引番号`) and against existing bundle items.
public enum PayPayCSVParser {
    private static let requiredColumns = [
        "取引日", "出金金額（円）", "入金金額（円）", "取引内容", "取引先", "取引方法", "取引番号"
    ]

    public static func parse(
        csvText: String,
        categorizer: Categorizer,
        existingItems: [BudgetItem] = [],
        existingExternalIDs: Set<String> = [],
        peopleGroup: String = "People",
        now: Date = Date()
    ) throws -> PayPayImportResult {
        let cleaned = csvText.hasPrefix("\u{FEFF}") ? String(csvText.dropFirst()) : csvText
        let rows = parseRFC4180(cleaned)
        guard let headerRow = rows.first, !headerRow.isEmpty else {
            throw PayPayCSVError.emptyFile
        }

        var colIndex: [String: Int] = [:]
        for (idx, raw) in headerRow.enumerated() {
            colIndex[raw.trimmingCharacters(in: .whitespacesAndNewlines)] = idx
        }
        let missing = requiredColumns.filter { colIndex[$0] == nil }
        if !missing.isEmpty {
            throw PayPayCSVError.missingRequiredColumns(missing)
        }

        func field(_ row: [String], _ name: String) -> String {
            guard let idx = colIndex[name], idx < row.count else { return "" }
            return row[idx].trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Multiset of existing bundle/bank items to prevent duplicates when ranges overlap.
        var existingPool: [String: Int] = [:]
        for item in existingItems {
            let fp = CategoryOverride.transactionFingerprint(for: item)
            existingPool[fp, default: 0] += 1
        }
        var seenExternalIDs = existingExternalIDs

        var imported: [ManualEntry] = []
        var skippedDuplicates = 0
        var skippedNonSpending = 0

        for row in rows.dropFirst() {
            if row.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                continue
            }

            let rawDate = field(row, "取引日")
            guard let date = parseDate(rawDate) else {
                skippedNonSpending += 1
                continue
            }

            let type = field(row, "取引内容")
            let merchant = field(row, "取引先")
            let method = field(row, "取引方法")
            let txID = field(row, "取引番号")
            let outAmt = parseAmount(field(row, "出金金額（円）"))
            let inAmt = parseAmount(field(row, "入金金額（円）"))
            let net = outAmt - inAmt

            guard net != 0 else {
                skippedNonSpending += 1
                continue
            }

            let isPayment = (type == "支払い" || type == "払い戻し")
            let isPersonTransfer = (type == "送った金額" || type == "受け取った金額")
            guard isPayment || isPersonTransfer else {
                skippedNonSpending += 1
                continue
            }

            let source = (isPayment && isCardMethod(method)) ? "PayPay Card" : "PayPay"
            let displayMerchant = merchant.isEmpty ? type : merchant
            let fp = "\(date)|\(source)|\(net)|\(TextFold.key(displayMerchant))"

            let externalKey = txID.isEmpty ? nil : "paypay:\(txID)"
            if let externalKey, !seenExternalIDs.insert(externalKey).inserted {
                // Consume one slot in the fingerprint pool so a distinct new transaction ID on the same day
                // with the same merchant and amount is not falsely suppressed by this already-imported row.
                if let remaining = existingPool[fp], remaining > 0 {
                    existingPool[fp] = remaining - 1
                }
                skippedDuplicates += 1
                continue
            }

            if let remaining = existingPool[fp], remaining > 0 {
                existingPool[fp] = remaining - 1
                skippedDuplicates += 1
                continue
            }

            let group: String
            let category: String
            if isPersonTransfer {
                group = peopleGroup
                category = "Transfers with people"
            } else {
                let categorized = categorizer.categorize(merchant: displayMerchant, amount: net, date: date)
                group = categorized.group
                category = categorized.category
            }

            imported.append(ManualEntry(
                date: date,
                source: source,
                merchant: displayMerchant,
                amount: net,
                group: group,
                category: category,
                note: nil,
                origin: .csvImport,
                externalID: externalKey,
                createdAt: now
            ))
        }

        let dates = imported.map(\.date)
        return PayPayImportResult(
            entries: imported.sorted { ($0.date, $0.merchant, $0.amount) < ($1.date, $1.merchant, $1.amount) },
            skippedDuplicates: skippedDuplicates,
            skippedNonSpending: skippedNonSpending,
            earliestDate: dates.min(),
            latestDate: dates.max()
        )
    }

    private static func isCardMethod(_ method: String) -> Bool {
        let upper = method.uppercased()
        return method.contains("クレジット") || upper.contains("VISA") || upper.contains("MASTERCARD")
            || upper.contains("JCB") || method.contains("PayPayカード")
    }

    private static func parseDate(_ raw: String) -> String? {
        let prefix = String(raw.prefix(10)).replacingOccurrences(of: "/", with: "-")
        guard let dayNum = JST.dayNumber(prefix), JST.day(fromDayNumber: dayNum) == prefix else {
            return nil
        }
        return prefix
    }

    private static func parseAmount(_ raw: String) -> Int {
        let cleaned = raw
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "¥", with: "")
            .replacingOccurrences(of: "￥", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned != "-" else { return 0 }
        return Int(cleaned) ?? 0
    }

    /// Minimal RFC 4180 CSV parser supporting quoted fields, embedded commas and CRLF/LF/CR newlines.
    ///
    /// Iterates `UnicodeScalar`s rather than Swift `Character`s because Swift treats `"\r\n"` as a single
    /// extended grapheme cluster that would not equal `"\r"` or `"\n"`.
    static func parseRFC4180(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = String.UnicodeScalarView()
        var inQuotes = false
        let scalars = Array(text.unicodeScalars)
        var i = 0

        let quote: UnicodeScalar = "\""
        let comma: UnicodeScalar = ","
        let cr: UnicodeScalar = "\r"
        let lf: UnicodeScalar = "\n"

        while i < scalars.count {
            let s = scalars[i]
            if inQuotes {
                if s == quote {
                    if i + 1 < scalars.count && scalars[i + 1] == quote {
                        field.append(quote)
                        i += 2
                        continue
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(s)
                }
            } else {
                if s == quote && field.isEmpty {
                    inQuotes = true
                } else if s == comma {
                    row.append(String(field))
                    field.removeAll(keepingCapacity: true)
                } else if s == cr {
                    row.append(String(field))
                    field.removeAll(keepingCapacity: true)
                    rows.append(row)
                    row = []
                    if i + 1 < scalars.count && scalars[i + 1] == lf {
                        i += 1
                    }
                } else if s == lf {
                    row.append(String(field))
                    field.removeAll(keepingCapacity: true)
                    rows.append(row)
                    row = []
                } else {
                    field.append(s)
                }
            }
            i += 1
        }

        if !field.isEmpty || !row.isEmpty {
            row.append(String(field))
            rows.append(row)
        }
        return rows
    }
}
