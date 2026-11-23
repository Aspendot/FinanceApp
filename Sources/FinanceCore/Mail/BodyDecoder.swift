import Foundation

enum BodyDecoder {
    struct DecodedBody: Equatable, Sendable {
        var text: String?
        var issues: [String]
    }

    /// Maps declared MIME charset names to Foundation string encodings.
    static func encoding(for charset: String) -> String.Encoding? {
        let normalized = charset
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'")))
            .lowercased()
        switch normalized {
        case "iso-2022-jp", "iso-2022-jp-1", "csiso2022jp":
            return .iso2022JP
        case "shift_jis", "shift-jis", "sjis", "x-sjis", "cp932", "ms932", "windows-31j", "csshiftjis":
            return .shiftJIS
        case "euc-jp", "euc_jp", "eucjp", "x-euc-jp", "cseucpkdfmtjapanese":
            return .japaneseEUC
        case "utf-8", "utf8":
            return .utf8
        case "us-ascii", "ascii", "ansi_x3.4-1968":
            return .ascii
        case "iso-8859-1", "iso_8859-1", "latin1", "latin-1", "l1":
            return .isoLatin1
        default:
            return nil
        }
    }

    /// Decodes a base64url body string into text according to the fallback decoding order.
    static func decodeBase64URL(_ encoded: String, declaredCharset: String?) -> DecodedBody {
        guard let bytes = Base64URL.decode(encoded) else {
            return DecodedBody(text: nil, issues: ["Failed to decode base64url body data."])
        }
        return decodeBytes(bytes, declaredCharset: declaredCharset)
    }

    /// Decodes raw body bytes into text according to the fallback decoding order.
    static func decodeBytes(_ data: Data, declaredCharset: String?) -> DecodedBody {
        var issues: [String] = []
        let text: String?

        let hasNonASCII = data.contains { $0 >= 0x80 }

        if hasNonASCII && isValidUTF8(data), let decoded = String(data: data, encoding: .utf8) {
            text = decoded
        } else if !hasNonASCII && containsISO2022JPEscape(data) {
            if let decoded = String(data: data, encoding: .iso2022JP) {
                text = decoded
            } else {
                issues.append("Failed to decode body bytes as ISO-2022-JP.")
                return DecodedBody(text: nil, issues: issues)
            }
        } else if !hasNonASCII {
            if let decoded = String(data: data, encoding: .ascii) {
                text = decoded
            } else {
                issues.append("Failed to decode pure ASCII body bytes.")
                return DecodedBody(text: nil, issues: issues)
            }
        } else if let charset = declaredCharset, !charset.isEmpty {
            guard let enc = encoding(for: charset) else {
                issues.append("Unsupported declared charset: \(charset).")
                return DecodedBody(text: nil, issues: issues)
            }
            if let decoded = decodeString(data, encoding: enc) {
                text = decoded
            } else {
                issues.append("Failed to decode body bytes using declared charset \(charset).")
                return DecodedBody(text: nil, issues: issues)
            }
        } else {
            issues.append("Failed to decode non-UTF-8 body bytes with no declared charset.")
            return DecodedBody(text: nil, issues: issues)
        }

        if let text, containsPrivateUseScalar(text) {
            issues.append("Decoded text contains Private Use Area characters.")
        }

        return DecodedBody(text: text, issues: issues)
    }

    /// Decodes bytes with the given Foundation encoding, with a portable fallback for
    /// EUC-JP on platforms where Foundation's `.japaneseEUC` converter is unavailable.
    static func decodeString(_ data: Data, encoding: String.Encoding) -> String? {
        if encoding == .utf8 && !isValidUTF8(data) {
            return nil
        }
        if let decoded = String(data: data, encoding: encoding) {
            return decoded
        }
        if encoding == .japaneseEUC {
            return decodeEUCJPViaISO2022JP(data)
        }
        return nil
    }

    /// Converts EUC-JP (ASCII, JIS X 0208, and JIS X 0201 half-width katakana) to
    /// ISO-2022-JP bytes and decodes via Foundation's `.iso2022JP`.
    private static func decodeEUCJPViaISO2022JP(_ data: Data) -> String? {
        enum Mode {
            case ascii
            case jis0208
            case halfWidthKana
        }

        let bytes = Array(data)
        var iso = Data()
        iso.reserveCapacity(bytes.count + 16)
        var mode: Mode = .ascii

        func switchMode(to next: Mode) {
            guard mode != next else { return }
            switch next {
            case .ascii:
                iso.append(contentsOf: [0x1B, 0x28, 0x42]) // ESC ( B
            case .jis0208:
                iso.append(contentsOf: [0x1B, 0x24, 0x42]) // ESC $ B
            case .halfWidthKana:
                iso.append(contentsOf: [0x1B, 0x28, 0x49]) // ESC ( I
            }
            mode = next
        }

        var i = 0
        while i < bytes.count {
            let b0 = bytes[i]
            if b0 < 0x80 {
                switchMode(to: .ascii)
                iso.append(b0)
                i += 1
            } else if b0 == 0x8E {
                guard i + 1 < bytes.count else { return nil }
                let b1 = bytes[i + 1]
                guard b1 >= 0xA1 && b1 <= 0xDF else { return nil }
                switchMode(to: .halfWidthKana)
                iso.append(b1 & 0x7F)
                i += 2
            } else if b0 >= 0xA1 && b0 <= 0xFE {
                guard i + 1 < bytes.count else { return nil }
                let b1 = bytes[i + 1]
                guard b1 >= 0xA1 && b1 <= 0xFE else { return nil }
                switchMode(to: .jis0208)
                iso.append(b0 & 0x7F)
                iso.append(b1 & 0x7F)
                i += 2
            } else {
                return nil
            }
        }
        switchMode(to: .ascii)
        return String(data: iso, encoding: .iso2022JP)
    }

    /// Extracts the `charset` parameter from a `Content-Type` header value, if present.
    static func charset(fromContentType contentType: String?) -> String? {
        guard let contentType else { return nil }
        let parts = splitHeaderParameters(contentType)
        for param in parts.dropFirst() {
            guard let eqIndex = param.firstIndex(of: "=") else { continue }
            let key = param[..<eqIndex].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if key == "charset" {
                var value = String(param[param.index(after: eqIndex)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if value.count >= 2 && ((value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'"))) {
                    value = String(value.dropFirst().dropLast())
                }
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    /// Splits a MIME header value on `;` outside quoted strings and comments.
    static func splitHeaderParameters(_ value: String) -> [String] {
        var result: [String] = []
        var current = ""
        var inQuotes = false
        var escaped = false
        var commentDepth = 0

        for ch in value {
            if escaped {
                if commentDepth == 0 { current.append(ch) }
                escaped = false
                continue
            }
            if ch == "\\" && (inQuotes || commentDepth > 0) {
                escaped = true
                continue
            }
            if !inQuotes {
                if ch == "(" {
                    commentDepth += 1
                    continue
                }
                if ch == ")" && commentDepth > 0 {
                    commentDepth -= 1
                    continue
                }
            }
            if commentDepth > 0 {
                continue
            }
            if ch == "\"" {
                inQuotes.toggle()
                current.append(ch)
                continue
            }
            if ch == ";" && !inQuotes {
                result.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        result.append(current)
        return result
    }

    /// Strictly validates UTF-8 per RFC 3629 so non-UTF-8 encodings are never accepted as UTF-8.
    static func isValidUTF8(_ data: Data) -> Bool {
        var i = data.startIndex
        let end = data.endIndex
        while i < end {
            let b0 = data[i]
            if b0 < 0x80 {
                i = data.index(after: i)
            } else if b0 >= 0xC2 && b0 <= 0xDF {
                let i1 = data.index(after: i)
                guard i1 < end, (data[i1] & 0xC0) == 0x80 else { return false }
                i = data.index(after: i1)
            } else if b0 >= 0xE0 && b0 <= 0xEF {
                let i1 = data.index(after: i)
                guard i1 < end else { return false }
                let i2 = data.index(after: i1)
                guard i2 < end else { return false }
                let b1 = data[i1]
                let b2 = data[i2]
                guard (b1 & 0xC0) == 0x80, (b2 & 0xC0) == 0x80 else { return false }
                if b0 == 0xE0 && b1 < 0xA0 { return false }
                if b0 == 0xED && b1 >= 0xA0 { return false } // UTF-16 surrogates
                i = data.index(after: i2)
            } else if b0 >= 0xF0 && b0 <= 0xF4 {
                let i1 = data.index(after: i)
                guard i1 < end else { return false }
                let i2 = data.index(after: i1)
                guard i2 < end else { return false }
                let i3 = data.index(after: i2)
                guard i3 < end else { return false }
                let b1 = data[i1]
                let b2 = data[i2]
                let b3 = data[i3]
                guard (b1 & 0xC0) == 0x80, (b2 & 0xC0) == 0x80, (b3 & 0xC0) == 0x80 else { return false }
                if b0 == 0xF0 && b1 < 0x90 { return false }
                if b0 == 0xF4 && b1 >= 0x90 { return false }
                i = data.index(after: i3)
            } else {
                return false
            }
        }
        return true
    }

    /// Checks whether the byte buffer contains an ISO-2022-JP shift escape sequence:
    /// ESC $ B, ESC $ @, ESC ( J, or ESC ( I.
    static func containsISO2022JPEscape(_ data: Data) -> Bool {
        let bytes = Array(data)
        guard bytes.count >= 3 else { return false }
        for idx in 0...(bytes.count - 3) {
            if bytes[idx] == 0x1B {
                let b1 = bytes[idx + 1]
                let b2 = bytes[idx + 2]
                if b1 == 0x24 && (b2 == 0x42 || b2 == 0x40) {
                    return true
                }
                if b1 == 0x28 && (b2 == 0x4A || b2 == 0x49) {
                    return true
                }
            }
        }
        return false
    }

    static func containsPrivateUseScalar(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if (v >= 0xE000 && v <= 0xF8FF)
                || (v >= 0xF0000 && v <= 0xFFFFD)
                || (v >= 0x100000 && v <= 0x10FFFD)
            {
                return true
            }
        }
        return false
    }
}
