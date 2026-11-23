import Foundation

/// Parses whole-yen amounts as banks and apps write them.
public enum Yen {
    /// Accepts forms like "1,234円", "１，２３４円", "¥1,234", "￥1,234", "1234.00",
    /// "-1,234" and "▲1,234". Returns nil for anything else, including amounts with
    /// non-zero decimals, which are not yen.
    public static func parse(_ text: String) -> Int? {
        let normalized = text.folding(options: .widthInsensitive, locale: nil)
        var s = Substring(normalized.trimmingCharacters(in: .whitespacesAndNewlines))
        var negative = false
        if let first = s.first, "-−▲△".contains(first) {
            negative = true
            s = Substring(s.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if s.hasPrefix("¥") {
            s = s.dropFirst()
        } else if s.hasPrefix("JPY") {
            s = s.dropFirst(3)
        }
        if s.hasSuffix("円") {
            s = s.dropLast()
        } else if s.hasSuffix("JPY") {
            s = s.dropLast(3)
        }
        s = Substring(s.trimmingCharacters(in: .whitespacesAndNewlines))
        if let dot = s.firstIndex(of: ".") {
            let decimals = s[s.index(after: dot)...]
            guard !decimals.isEmpty, decimals.allSatisfy({ $0 == "0" }) else { return nil }
            s = s[..<dot]
        }
        let groups = s.split(separator: ",", omittingEmptySubsequences: false)
        guard let head = groups.first, !head.isEmpty,
              (groups.count == 1 || head.count <= 3),
              groups.dropFirst().allSatisfy({ $0.count == 3 }),
              groups.allSatisfy({ $0.allSatisfy { ("0"..."9").contains($0) } })
        else { return nil }
        return Int((negative ? "-" : "") + groups.joined())
    }
}
