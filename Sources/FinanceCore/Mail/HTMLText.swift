import Foundation

/// Converts HTML email bodies into readable plain text using a lightweight tokenizer.
public enum HTMLText {
    /// Extracts plain text from an HTML document or fragment.
    ///
    /// Drops `script`, `style`, and `head` content as well as comments; turns common
    /// block elements into line breaks and table cells (`td`/`th`) into `" | "` separators;
    /// decodes common named and numeric HTML entities; collapses spaces within lines;
    /// and removes leading and trailing empty lines.
    public static func plainText(_ html: String) -> String {
        let scalars = Array(html.unicodeScalars)
        let count = scalars.count

        var lines: [String] = []
        var currentLine = ""
        var pendingSpace = false
        var pendingCellSeparator = false
        var skipTag: String? = nil

        func appendDecodedText(_ text: String) {
            for scalar in text.unicodeScalars {
                if isHorizontalOrLineWhitespace(scalar) {
                    pendingSpace = true
                } else {
                    if pendingCellSeparator && !currentLine.isEmpty {
                        currentLine.append(" | ")
                        pendingCellSeparator = false
                        pendingSpace = false
                    } else if pendingSpace && !currentLine.isEmpty {
                        currentLine.append(" ")
                        pendingSpace = false
                    } else {
                        pendingSpace = false
                    }
                    currentLine.unicodeScalars.append(scalar)
                }
            }
        }

        func endLine(force: Bool) {
            pendingSpace = false
            pendingCellSeparator = false
            if !currentLine.isEmpty || force {
                lines.append(currentLine)
                currentLine = ""
            }
        }

        var i = 0
        while i < count {
            if let skipping = skipTag {
                if let afterClose = findClosingTagEnd(skipping, in: scalars, from: i) {
                    skipTag = nil
                    i = afterClose
                } else {
                    break
                }
                continue
            }

            if scalars[i] == "<" {
                // HTML comment: <!-- ... -->
                if matchesPrefix("<!--", in: scalars, at: i) {
                    if let commentEnd = findSequence("-->", in: scalars, from: i + 4) {
                        i = commentEnd + 3
                    } else {
                        break
                    }
                    continue
                }

                // Declaration or processing instruction: <!...> or <?...>
                if i + 1 < count && (scalars[i + 1] == "!" || scalars[i + 1] == "?") {
                    i = skipToTagEnd(in: scalars, from: i + 2)
                    continue
                }

                if let tag = parseTag(in: scalars, from: i) {
                    i = tag.endIndex
                    let name = tag.name
                    if !tag.isClosing && !tag.isSelfClosing && (name == "script" || name == "style" || name == "head") {
                        skipTag = name
                    } else if name == "br" {
                        endLine(force: true)
                    } else if blockTags.contains(name) {
                        endLine(force: false)
                    } else if name == "td" || name == "th" {
                        if !currentLine.isEmpty {
                            pendingCellSeparator = true
                            pendingSpace = false
                        }
                    }
                    continue
                }

                // Bare '<' that does not start a valid tag.
                appendDecodedText("<")
                i += 1
                continue
            }

            // Text run up to the next '<'.
            var textBuffer = ""
            while i < count && scalars[i] != "<" {
                if scalars[i] == "&", let (decoded, nextIndex) = decodeEntity(in: scalars, from: i) {
                    textBuffer.append(decoded)
                    i = nextIndex
                } else {
                    textBuffer.unicodeScalars.append(scalars[i])
                    i += 1
                }
            }
            appendDecodedText(textBuffer)
        }

        if !currentLine.isEmpty {
            lines.append(currentLine)
        }

        while lines.first?.isEmpty == true {
            lines.removeFirst()
        }
        while lines.last?.isEmpty == true {
            lines.removeLast()
        }

        return lines.joined(separator: "\n")
    }

    private struct ParsedTag {
        var name: String
        var isClosing: Bool
        var isSelfClosing: Bool
        var endIndex: Int
    }

    private static let blockTags: Set<String> = [
        "p", "div", "tr", "li", "table",
        "h1", "h2", "h3", "h4", "h5", "h6",
    ]

    private static func isHorizontalOrLineWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        scalar == " " || scalar == "\t" || scalar == "\r" || scalar == "\n" || scalar == "\u{00A0}"
    }

    private static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
        (scalar >= "A" && scalar <= "Z") || (scalar >= "a" && scalar <= "z")
    }

    private static func isASCIIAlnum(_ scalar: Unicode.Scalar) -> Bool {
        isASCIILetter(scalar) || (scalar >= "0" && scalar <= "9")
    }

    private static func isTagNameChar(_ scalar: Unicode.Scalar) -> Bool {
        isASCIIAlnum(scalar) || scalar == "-" || scalar == "_" || scalar == ":"
    }

    private static func lowercaseASCII(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        if scalar >= "A" && scalar <= "Z" {
            return Unicode.Scalar(scalar.value + 32)!
        }
        return scalar
    }

    private static func matchesPrefix(_ literal: String, in scalars: [Unicode.Scalar], at index: Int) -> Bool {
        let target = Array(literal.unicodeScalars)
        guard index + target.count <= scalars.count else { return false }
        for offset in 0..<target.count {
            if scalars[index + offset] != target[offset] {
                return false
            }
        }
        return true
    }

    private static func findSequence(_ literal: String, in scalars: [Unicode.Scalar], from start: Int) -> Int? {
        let target = Array(literal.unicodeScalars)
        guard !target.isEmpty, start + target.count <= scalars.count else { return nil }
        for i in start...(scalars.count - target.count) {
            var matched = true
            for offset in 0..<target.count {
                if scalars[i + offset] != target[offset] {
                    matched = false
                    break
                }
            }
            if matched { return i }
        }
        return nil
    }

    private static func parseTag(in scalars: [Unicode.Scalar], from start: Int) -> ParsedTag? {
        let count = scalars.count
        var i = start + 1
        guard i < count else { return nil }

        var isClosing = false
        if scalars[i] == "/" {
            isClosing = true
            i += 1
        }

        guard i < count, isASCIILetter(scalars[i]) else { return nil }

        var name = ""
        while i < count && isTagNameChar(scalars[i]) {
            name.unicodeScalars.append(lowercaseASCII(scalars[i]))
            i += 1
        }
        guard i < count,
              scalars[i] == ">" || scalars[i] == "/" || isHorizontalOrLineWhitespace(scalars[i])
        else { return nil }

        var quote: Unicode.Scalar? = nil
        var lastNonSpace: Unicode.Scalar? = nil
        while i < count {
            let s = scalars[i]
            if let q = quote {
                if s == q {
                    quote = nil
                }
            } else {
                if s == "\"" || s == "'" {
                    quote = s
                } else if s == ">" {
                    let isSelfClosing = !isClosing && lastNonSpace == "/"
                    return ParsedTag(
                        name: name,
                        isClosing: isClosing,
                        isSelfClosing: isSelfClosing,
                        endIndex: i + 1
                    )
                } else if !isHorizontalOrLineWhitespace(s) {
                    lastNonSpace = s
                }
            }
            i += 1
        }

        return nil
    }

    private static func skipToTagEnd(in scalars: [Unicode.Scalar], from start: Int) -> Int {
        var i = start
        var quote: Unicode.Scalar? = nil
        while i < scalars.count {
            let s = scalars[i]
            if let q = quote {
                if s == q { quote = nil }
            } else if s == "\"" || s == "'" {
                quote = s
            } else if s == ">" {
                return i + 1
            }
            i += 1
        }
        return scalars.count
    }

    private static func findClosingTagEnd(_ tagName: String, in scalars: [Unicode.Scalar], from start: Int) -> Int? {
        let target = Array(tagName.unicodeScalars)
        let count = scalars.count
        var i = start
        while i + 2 + target.count < count {
            if scalars[i] == "<" && scalars[i + 1] == "/" {
                var matched = true
                for offset in 0..<target.count {
                    if lowercaseASCII(scalars[i + 2 + offset]) != target[offset] {
                        matched = false
                        break
                    }
                }
                if matched {
                    var after = i + 2 + target.count
                    if after < count && (scalars[after] == ">" || isHorizontalOrLineWhitespace(scalars[after])) {
                        while after < count && scalars[after] != ">" {
                            after += 1
                        }
                        return after < count ? after + 1 : count
                    }
                }
            }
            i += 1
        }
        return nil
    }

    private static func decodeEntity(in scalars: [Unicode.Scalar], from start: Int) -> (String, Int)? {
        let count = scalars.count
        let maxEntityLength = 16
        var end = start + 1
        while end < count && end - start <= maxEntityLength {
            let s = scalars[end]
            if s == ";" {
                let entity = String(String.UnicodeScalarView(scalars[(start + 1)..<end]))
                if let decoded = resolveEntity(entity) {
                    return (decoded, end + 1)
                }
                return nil
            }
            if s == "&" || s == "<" || isHorizontalOrLineWhitespace(s) {
                return nil
            }
            end += 1
        }
        return nil
    }

    private static func resolveEntity(_ entity: String) -> String? {
        guard !entity.isEmpty else { return nil }

        if entity.hasPrefix("#") {
            let body = entity.dropFirst()
            guard !body.isEmpty else { return nil }
            let codePoint: UInt32?
            if body.hasPrefix("x") || body.hasPrefix("X") {
                codePoint = UInt32(body.dropFirst(), radix: 16)
            } else {
                codePoint = UInt32(body, radix: 10)
            }
            guard let codePoint, codePoint > 0, let scalar = Unicode.Scalar(codePoint) else {
                return nil
            }
            return String(scalar)
        }

        switch entity.lowercased() {
        case "amp":
            return "&"
        case "lt":
            return "<"
        case "gt":
            return ">"
        case "quot":
            return "\""
        case "apos":
            return "'"
        case "nbsp":
            return " "
        case "yen":
            return "¥"
        case "copy":
            return "©"
        default:
            return nil
        }
    }
}
