import Foundation

/// Direction of a bank or card transaction reported by an aggregation API.
public enum BankTransactionSide: String, Codable, Sendable, Equatable {
    case expense = "EXPENSE"
    case income = "INCOME"
}

/// One confirmed bank or card transaction retrieved from Money Forward Cloud.
///
/// Follows the app's sign convention: `amount` is whole yen, positive for money out
/// (`EXPENSE`) and negative for money in (`INCOME`).
public struct BankTransaction: Codable, Sendable, Equatable, Hashable {
    /// Stable transaction ID returned by Money Forward (kept verbatim).
    public var id: String
    /// Parent connected service ID (`connected_account_id`).
    public var connectedAccountID: String
    /// Sub-account ID (`connected_sub_account_id`), when the service has multiple accounts.
    public var connectedSubAccountID: String?
    /// Transaction date in `"YYYY-MM-DD"` format.
    public var date: String
    /// Whole yen; positive is money out, negative is money in.
    public var amount: Int
    /// Transaction description (`content`) exactly as returned by Money Forward.
    public var description: String
    /// Optional memo attached to the transaction in Money Forward.
    public var memo: String?
    /// Journalizing status reported by Money Forward (e.g. `"none"`, `"registered"`, `"excluded"`).
    public var journalizingStatus: String?

    public init(
        id: String,
        connectedAccountID: String,
        connectedSubAccountID: String? = nil,
        date: String,
        amount: Int,
        description: String,
        memo: String? = nil,
        journalizingStatus: String? = nil
    ) {
        self.id = id
        self.connectedAccountID = connectedAccountID
        self.connectedSubAccountID = connectedSubAccountID
        self.date = date
        self.amount = amount
        self.description = description
        self.memo = memo
        self.journalizingStatus = journalizingStatus
    }

    /// Converts a non-negative Money Forward `value` and `side` (`"EXPENSE"` or `"INCOME"`)
    /// into the app's signed yen convention (positive = money out, negative = money in).
    public static func signedAmount(value: Int, side: BankTransactionSide) -> Int? {
        guard value >= 0 else { return nil }
        switch side {
        case .expense:
            return value
        case .income:
            return -value
        }
    }

    /// Converts a non-negative Money Forward `value` and raw `side` string
    /// into the app's signed yen convention.
    public static func signedAmount(value: Int, rawSide: String) -> Int? {
        guard let side = BankTransactionSide(rawValue: rawSide.uppercased()) else {
            return nil
        }
        return signedAmount(value: value, side: side)
    }

    /// Resolves the bundle source key for this transaction from a local account mapping.
    ///
    /// Checks `connectedSubAccountID` first so multi-account institutions can map each
    /// sub-account individually, then falls back to `connectedAccountID`.
    /// Returns `nil` when unmapped or mapped to an empty string ("Ignore").
    public func mappedSource(using mapping: [String: String]) -> String? {
        if let subID = connectedSubAccountID, !subID.isEmpty,
           let mapped = mapping[subID]
        {
            let trimmed = mapped.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let mapped = mapping[connectedAccountID] {
            let trimmed = mapped.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }
}
