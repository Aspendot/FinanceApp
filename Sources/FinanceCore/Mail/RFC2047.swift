import Foundation

/// Decodes RFC 2047 encoded words (`=?charset?B?...?=` and `=?charset?Q?...?=`).
public enum RFC2047 {
    /// Decodes RFC 2047 encoded words in a header value.
    ///
    /// Returns the input unchanged if it does not contain `=?`. Whitespace separating
    /// adjacent encoded words is removed before joining them.
    public static func decode(_ input: String) -> String {
        guard input.contains("=?") else { return input }

        let tokens = tokenize(input)
        var output = ""
        var i = 0

        while i < tokens.count {
            switch tokens[i] {
            case .literal(let text):
                output.append(text)
                i += 1
            case .encoded(let word):
                // Collect a maximal run of adjacent encoded words (separated only by whitespace).
                var run: [EncodedWord] = [word]
                var cursor = i + 1
                while cursor < tokens.count {
                    if case .encoded(let nextWord) = tokens[cursor] {
                        run.append(nextWord)
                        cursor += 1
                    } else if case .literal(let sep) = tokens[cursor],
                              isLinearWhitespace(sep),
                              cursor + 1 < tokens.count,
                              case .encoded(let nextWord) = tokens[cursor + 1]
                    {
                        run.append(nextWord)
                        cursor += 2
                    } else {
                        break
                    }
                }
                output.append(decodeRun(run))
                i = cursor
            }
        }

        return output
    }

    private struct EncodedWord {
        var raw: String
        var charset: String
        var bytes: Data
    }

    private enum Token {
        case literal(String)
        case encoded(EncodedWord)
    }

    private static func tokenize(_ input: String) -> [Token] {
        var tokens: [Token] = []
        var literalBuffer = ""
        var index = input.startIndex
        let end = input.endIndex

        func flushLiteral() {
            if !literalBuffer.isEmpty {
                tokens.append(.literal(literalBuffer))
                literalBuffer = ""
            }
        }

        while index < end {
            if input[index] == "=",
               let next = input.index(index, offsetBy: 1, limitedBy: end),
               next < end,
               input[next] == "?"
            {
                if let (word, afterWord) = parseEncodedWord(in: input, from: index) {
                    flushLiteral()
                    tokens.append(.encoded(word))
                    index = afterWord
                    continue
                }
            }
            literalBuffer.append(input[index])
            index = input.index(after: index)
        }
        flushLiteral()
        return tokens
    }

    private static func parseEncodedWord(in input: String, from start: String.Index) -> (EncodedWord, String.Index)? {
        let end = input.endIndex
        guard let charsetStart = input.index(start, offsetBy: 2, limitedBy: end),
              charsetStart < end
        else { return nil }

        guard let q1 = input[charsetStart...].firstIndex(of: "?") else { return nil }
        let charsetToken = String(input[charsetStart..<q1])
        guard !charsetToken.isEmpty,
              !charsetToken.contains(where: { $0.isWhitespace })
        else { return nil }

        let encStart = input.index(after: q1)
        guard encStart < end else { return nil }
        guard let q2 = input[encStart...].firstIndex(of: "?") else { return nil }
        let encodingToken = String(input[encStart..<q2]).uppercased()
        guard encodingToken == "B" || encodingToken == "Q" else { return nil }

        let textStart = input.index(after: q2)
        guard textStart < end else { return nil }

        // Find the closing "?=". Encoded text must not contain "?" or whitespace.
        var scan = textStart
        var closeStart: String.Index?
        while scan < end {
            let ch = input[scan]
            if ch == "?" {
                let afterQ = input.index(after: scan)
                if afterQ < end && input[afterQ] == "=" {
                    closeStart = scan
                }
                break
            }
            if ch.isWhitespace {
                return nil
            }
            scan = input.index(after: scan)
        }

        guard let payloadEnd = closeStart else { return nil }
        let afterWord = input.index(payloadEnd, offsetBy: 2)
        let payload = String(input[textStart..<payloadEnd])

        // Strip RFC 2231 language tag (charset*lang) if present.
        let baseCharset: String
        if let star = charsetToken.firstIndex(of: "*") {
            baseCharset = String(charsetToken[..<star])
        } else {
            baseCharset = charsetToken
        }

        guard BodyDecoder.encoding(for: baseCharset) != nil else { return nil }

        let bytes: Data?
        if encodingToken == "B" {
            bytes = decodeBase64(payload)
        } else {
            bytes = decodeQ(payload)
        }

        guard let bytes else { return nil }

        let raw = String(input[start..<afterWord])
        return (EncodedWord(raw: raw, charset: baseCharset.lowercased(), bytes: bytes), afterWord)
    }

    private static func decodeRun(_ run: [EncodedWord]) -> String {
        var result = ""
        var i = 0
        while i < run.count {
            let charset = run[i].charset
            var j = i + 1
            while j < run.count && run[j].charset == charset {
                j += 1
            }

            if let enc = BodyDecoder.encoding(for: charset) {
                var combined = Data()
                for k in i..<j {
                    combined.append(run[k].bytes)
                }
                if let decoded = BodyDecoder.decodeString(combined, encoding: enc) {
                    result.append(decoded)
                } else {
                    for k in i..<j {
                        if let single = BodyDecoder.decodeString(run[k].bytes, encoding: enc) {
                            result.append(single)
                        } else {
                            result.append(run[k].raw)
                        }
                    }
                }
            } else {
                for k in i..<j {
                    result.append(run[k].raw)
                }
            }
            i = j
        }
        return result
    }

    private static func decodeBase64(_ text: String) -> Data? {
        if text.isEmpty { return Data() }
        var padded = text
        let rem = padded.count % 4
        if rem == 1 { return nil }
        if rem > 0 {
            padded.append(String(repeating: "=", count: 4 - rem))
        }
        return Data(base64Encoded: padded)
    }

    private static func decodeQ(_ text: String) -> Data? {
        var bytes = Data()
        bytes.reserveCapacity(text.utf8.count)
        let utf8 = Array(text.utf8)
        var i = 0
        while i < utf8.count {
            let b = utf8[i]
            if b == UInt8(ascii: "_") {
                bytes.append(0x20)
                i += 1
            } else if b == UInt8(ascii: "=") {
                guard i + 2 < utf8.count,
                      let hi = hexValue(utf8[i + 1]),
                      let lo = hexValue(utf8[i + 2])
                else { return nil }
                bytes.append((hi << 4) | lo)
                i += 3
            } else {
                bytes.append(b)
                i += 1
            }
        }
        return bytes
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            return byte - UInt8(ascii: "0")
        case UInt8(ascii: "A")...UInt8(ascii: "F"):
            return byte - UInt8(ascii: "A") + 10
        case UInt8(ascii: "a")...UInt8(ascii: "f"):
            return byte - UInt8(ascii: "a") + 10
        default:
            return nil
        }
    }

    private static func isLinearWhitespace(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { scalar in
            scalar == " " || scalar == "\t" || scalar == "\r" || scalar == "\n"
        }
    }
}
