import Foundation

/// Japan Standard Time. Japan has no daylight saving time, so +09:00 is exact.
public enum JST {
    public static let timeZone = TimeZone(secondsFromGMT: 9 * 3600)!

    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }()

    /// Formats a moment as "2026-01-15T09:30:00+09:00".
    public static func timestamp(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return pad(c.year, 4) + "-" + pad(c.month) + "-" + pad(c.day) + "T"
            + pad(c.hour) + ":" + pad(c.minute) + ":" + pad(c.second) + "+09:00"
    }

    /// Formats a moment as a Japan-time calendar day "2026-01-15".
    public static func day(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return pad(c.year, 4) + "-" + pad(c.month) + "-" + pad(c.day)
    }

    /// Reads "2026/01/15 09:30:00" or "2026/01/15 09:30" (Japan time) as
    /// "2026-01-15T09:30:00+09:00". Returns nil unless the date and time are real.
    public static func timestamp(slashed text: String) -> String? {
        let parts = text.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 2, let day = day(slashed: String(parts[0])) else { return nil }
        let raw = parts[1].split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(raw.count), raw.allSatisfy({ $0.count == 2 }) else { return nil }
        let t = raw.map { Int($0) }
        guard let h = t[0], let m = t[1], let s = t.count == 3 ? t[2] : 0,
              (0...23).contains(h), (0...59).contains(m), (0...59).contains(s)
        else { return nil }
        return day + "T" + pad(h) + ":" + pad(m) + ":" + pad(s) + "+09:00"
    }

    /// Reads "2026/01/15" as "2026-01-15". Returns nil unless the date is real.
    public static func day(slashed text: String) -> String? {
        let raw = text.split(separator: "/", omittingEmptySubsequences: false)
        guard raw.count == 3, raw[0].count == 4, (1...2).contains(raw[1].count), (1...2).contains(raw[2].count),
              raw.allSatisfy({ $0.allSatisfy { ("0"..."9").contains($0) } })
        else { return nil }
        let d = raw.map { Int($0) }
        guard let y = d[0], let mo = d[1], let da = d[2],
              let date = calendar.date(from: DateComponents(year: y, month: mo, day: da)),
              calendar.dateComponents([.year, .month, .day], from: date) == DateComponents(year: y, month: mo, day: da)
        else { return nil }
        return pad(y, 4) + "-" + pad(mo) + "-" + pad(da)
    }

    /// Adds `days` (positive or negative) to a `"YYYY-MM-DD"` date string.
    public static func addingDays(_ days: Int, to day: String) -> String? {
        guard let number = dayNumber(day) else { return nil }
        return self.day(fromDayNumber: number + days)
    }

    /// Converts days since 1970-01-01 back into `"YYYY-MM-DD"`, by pure arithmetic.
    public static func day(fromDayNumber z: Int) -> String {
        let shifted = z + 719_468
        let era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
        let doe = shifted - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp + (mp < 10 ? 3 : -9)
        let year = y + (m <= 2 ? 1 : 0)
        return pad(year, 4) + "-" + pad(m) + "-" + pad(d)
    }

    private static func pad(_ value: Int?, _ width: Int = 2) -> String {
        let s = String(value ?? 0)
        return String(repeating: "0", count: max(0, width - s.count)) + s
    }
}
