import Foundation

/// Parses whole-yen amounts as banks and apps write them.
public enum Yen {
    /// Accepts forms like "1,234円", "１，２３４円", "¥1,234", "￥1,234", "1234.00",
    /// "-1,234" and "▲1,234". Returns nil for anything else, including amounts with
    /// non-zero decimals, which are not yen.
    public static func parse(_ text: String) -> Int? {
        let normalized = text.precomposedStringWithCompatibilityMapping
        var s = Substring(normalized.trimmingCharacters(in: .whitespaces))
        var sign = 1
        if let first = s.first, "-−▲△".contains(first) {
            sign = -1
            s = s.dropFirst()
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
        s = Substring(s.trimmingCharacters(in: .whitespaces))
        if let dot = s.firstIndex(of: ".") {
            let decimals = s[s.index(after: dot)...]
            guard !decimals.isEmpty, decimals.allSatisfy({ $0 == "0" }) else { return nil }
            s = s[..<dot]
        }
        let groups = s.split(separator: ",", omittingEmptySubsequences: false)
        guard let head = groups.first, !head.isEmpty,
              head.count <= (groups.count > 1 ? 3 : 15),
              groups.dropFirst().allSatisfy({ $0.count == 3 }),
              groups.allSatisfy({ $0.allSatisfy { ("0"..."9").contains($0) } }),
              let value = Int(groups.joined())
        else { return nil }
        return sign * value
    }
}
