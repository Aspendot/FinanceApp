import Foundation

/// Ordered email headers with case-insensitive lookup.
public struct MailHeaders: Equatable, Sendable {
    /// A single header field in its original casing and value.
    public struct Entry: Equatable, Sendable {
        public var name: String
        public var value: String

        public init(name: String, value: String) {
            self.name = name
            self.value = value
        }
    }

    /// All headers in their original order.
    public var entries: [Entry]

    public init(_ entries: [Entry] = []) {
        self.entries = entries
    }

    public init(_ gmailHeaders: [GmailHeader]) {
        self.entries = gmailHeaders.map { Entry(name: $0.name, value: $0.value) }
    }

    /// Returns all values for headers matching `name` case-insensitively, in original order.
    public func values(for name: String) -> [String] {
        let target = name.lowercased()
        return entries.compactMap { entry in
            entry.name.lowercased() == target ? entry.value : nil
        }
    }

    /// Returns the first value matching `name` case-insensitively, or `nil` if absent.
    public func first(for name: String) -> String? {
        let target = name.lowercased()
        return entries.first { $0.name.lowercased() == target }?.value
    }

    /// Case-insensitive subscript returning all matching header values in original order.
    public subscript(_ name: String) -> [String] {
        values(for: name)
    }
}

/// A parsed email address with an optional display name.
public struct MailAddress: Equatable, Sendable {
    /// Decoded human-readable display name, if present.
    public var displayName: String?
    /// The email address (addr-spec), such as `mail@debit.bk.mufg.jp`.
    public var address: String

    /// Lowercased domain portion after `@`, or `nil` if the address is malformed.
    public var domain: String? {
        MailAddress.extractDomain(from: address)
    }

    public init(displayName: String? = nil, address: String) {
        self.displayName = displayName
        self.address = address
    }

    /// Parses a single mailbox header value (such as `From`), decoding RFC 2047 words in the display name.
    public static func parse(_ headerValue: String) -> MailAddress? {
        let unfolded = unfoldHeader(headerValue).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !unfolded.isEmpty else { return nil }

        // Look for `<addr>` outside quoted strings.
        if let (angleStart, angleEnd) = findAngleAddress(in: unfolded) {
            let rawAddress = unfolded[unfolded.index(after: angleStart)..<angleEnd]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard isValidAddress(rawAddress) else { return nil }

            let beforeAngle = unfolded[..<angleStart].trimmingCharacters(in: .whitespacesAndNewlines)
            var displayName: String?
            if !beforeAngle.isEmpty {
                let unquoted = unquoteIfSingleQuotedString(beforeAngle)
                let decoded = RFC2047.decode(unquoted).trimmingCharacters(in: .whitespacesAndNewlines)
                if !decoded.isEmpty {
                    displayName = decoded
                }
            } else {
                // Support `addr` with trailing comment: `<a@example.com> (Name)`.
                let afterAngle = unfolded[unfolded.index(after: angleEnd)...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let comment = extractOuterComment(afterAngle) {
                    let decoded = RFC2047.decode(comment).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !decoded.isEmpty {
                        displayName = decoded
                    }
                }
            }

            return MailAddress(displayName: displayName, address: rawAddress)
        }

        // Check `address (display name)` form.
        if let parenStart = unfolded.firstIndex(of: "("),
           let comment = extractOuterComment(String(unfolded[parenStart...]))
        {
            let rawAddress = unfolded[..<parenStart].trimmingCharacters(in: .whitespacesAndNewlines)
            guard isValidAddress(rawAddress) else { return nil }
            let decoded = RFC2047.decode(comment).trimmingCharacters(in: .whitespacesAndNewlines)
            return MailAddress(displayName: decoded.isEmpty ? nil : decoded, address: rawAddress)
        }

        // Bare email address.
        guard isValidAddress(unfolded) else { return nil }
        return MailAddress(displayName: nil, address: unfolded)
    }

    static func extractDomain(from address: String) -> String? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains(where: { $0.isWhitespace })
        else { return nil }

        let parts = trimmed.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2,
              !parts[0].isEmpty,
              !parts[1].isEmpty
        else { return nil }

        var domain = String(parts[1]).lowercased()
        if domain.hasSuffix(".") {
            domain.removeLast()
        }
        guard !domain.isEmpty,
              !domain.hasPrefix("."),
              !domain.contains("..")
        else { return nil }

        return domain
    }

    private static func isValidAddress(_ candidate: String) -> Bool {
        extractDomain(from: candidate) != nil
    }

    private static func findAngleAddress(in text: String) -> (String.Index, String.Index)? {
        var inQuotes = false
        var escaped = false
        var openIndex: String.Index?
        var i = text.startIndex

        while i < text.endIndex {
            let ch = text[i]
            if escaped {
                escaped = false
            } else if ch == "\\" && inQuotes {
                escaped = true
            } else if ch == "\"" {
                inQuotes.toggle()
            } else if !inQuotes {
                if ch == "<" {
                    openIndex = i
                } else if ch == ">", let start = openIndex {
                    return (start, i)
                }
            }
            i = text.index(after: i)
        }
        return nil
    }

    private static func unquoteIfSingleQuotedString(_ text: String) -> String {
        guard text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") else {
            return text
        }
        let inner = text.dropFirst().dropLast()
        var out = ""
        var escaped = false
        for ch in inner {
            if escaped {
                out.append(ch)
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "\"" {
                // Unescaped quote in the middle means this is not a single quoted string.
                return text
            } else {
                out.append(ch)
            }
        }
        return escaped ? text : out
    }

    private static func extractOuterComment(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, trimmed.hasPrefix("("), trimmed.hasSuffix(")") else {
            return nil
        }
        var depth = 0
        var escaped = false
        var index = trimmed.startIndex
        while index < trimmed.endIndex {
            let ch = trimmed[index]
            if escaped {
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "(" {
                depth += 1
            } else if ch == ")" {
                depth -= 1
                if depth == 0 && trimmed.index(after: index) != trimmed.endIndex {
                    return nil
                }
            }
            index = trimmed.index(after: index)
        }
        guard depth == 0 else { return nil }
        return String(trimmed.dropFirst().dropLast())
    }
}

/// A normalized email message built from a Gmail API message.
public struct MailMessage: Equatable, Sendable {
    /// Gmail message identifier.
    public var id: String
    /// Message timestamp derived from Gmail's `internalDate` (milliseconds since 1970).
    public var receivedAt: Date?
    /// Ordered top-level headers with case-insensitive lookup.
    public var headers: MailHeaders
    /// Parsed `From` address and decoded display name, if present and valid.
    public var from: MailAddress?
    /// Decoded `Subject` header value, or an empty string if absent.
    public var subject: String
    /// Decoded plain-text body, if present.
    public var textBody: String?
    /// Decoded HTML body, if present.
    public var htmlBody: String?
    /// Problems encountered while decoding headers, dates, or body parts.
    public var issues: [String]

    public init(
        id: String,
        receivedAt: Date?,
        headers: MailHeaders,
        from: MailAddress?,
        subject: String,
        textBody: String?,
        htmlBody: String?,
        issues: [String] = []
    ) {
        self.id = id
        self.receivedAt = receivedAt
        self.headers = headers
        self.from = from
        self.subject = subject
        self.textBody = textBody
        self.htmlBody = htmlBody
        self.issues = issues
    }

    /// Normalizes a decoded `GmailMessage` into a `MailMessage`.
    public init(gmail: GmailMessage) {
        var issues: [String] = []

        self.id = gmail.id

        if let rawDate = gmail.internalDate?.trimmingCharacters(in: .whitespacesAndNewlines),
           let millis = Int64(rawDate)
        {
            self.receivedAt = Date(timeIntervalSince1970: TimeInterval(millis) / 1000.0)
        } else {
            self.receivedAt = nil
            issues.append("Missing or invalid internalDate.")
        }

        let headers = MailHeaders(gmail.payload?.headers ?? [])
        self.headers = headers

        if let rawFrom = headers.first(for: "From") {
            let parsed = MailAddress.parse(rawFrom)
            self.from = parsed
            if parsed == nil && !rawFrom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append("Could not parse From header.")
            }
        } else {
            self.from = nil
        }

        if let rawSubject = headers.first(for: "Subject") {
            let unfolded = unfoldHeader(rawSubject)
            self.subject = RFC2047.decode(unfolded)
        } else {
            self.subject = ""
        }

        if let payload = gmail.payload {
            var textParts: [String] = []
            var htmlParts: [String] = []
            MailMessage.walk(
                part: payload,
                textParts: &textParts,
                htmlParts: &htmlParts,
                issues: &issues
            )
            self.textBody = textParts.isEmpty ? nil : textParts.joined(separator: "\n")
            self.htmlBody = htmlParts.isEmpty ? nil : htmlParts.joined(separator: "\n")
        } else {
            self.textBody = nil
            self.htmlBody = nil
            issues.append("Message payload is missing.")
        }

        self.issues = issues
    }

    private static func walk(
        part: GmailPart,
        textParts: inout [String],
        htmlParts: inout [String],
        issues: inout [String]
    ) {
        let partHeaders = MailHeaders(part.headers ?? [])
        let contentTypeHeader = partHeaders.first(for: "Content-Type")
        let mimeType = normalizedMIMEType(part.mimeType ?? contentTypeHeader)

        if shouldSkipPart(part, mimeType: mimeType, partHeaders: partHeaders) {
            return
        }

        switch mimeType {
        case "multipart/signed":
            if let firstPart = part.parts?.first {
                walk(part: firstPart, textParts: &textParts, htmlParts: &htmlParts, issues: &issues)
            } else {
                issues.append("multipart/signed part has no child parts.")
            }

        case "multipart/alternative":
            var altText: String?
            var altHTML: String?
            for child in part.parts ?? [] {
                var childTexts: [String] = []
                var childHTMLs: [String] = []
                walk(part: child, textParts: &childTexts, htmlParts: &childHTMLs, issues: &issues)
                if altText == nil, !childTexts.isEmpty {
                    altText = childTexts.joined(separator: "\n")
                }
                if altHTML == nil, !childHTMLs.isEmpty {
                    altHTML = childHTMLs.joined(separator: "\n")
                }
            }
            if let altText {
                textParts.append(altText)
            }
            if let altHTML {
                htmlParts.append(altHTML)
            }

        case let type where type.hasPrefix("multipart/"):
            for child in part.parts ?? [] {
                walk(part: child, textParts: &textParts, htmlParts: &htmlParts, issues: &issues)
            }

        case "text/plain":
            if let decoded = decodeLeafPart(part, contentTypeHeader: contentTypeHeader, issues: &issues) {
                textParts.append(decoded)
            }

        case "text/html":
            if let decoded = decodeLeafPart(part, contentTypeHeader: contentTypeHeader, issues: &issues) {
                htmlParts.append(decoded)
            }

        default:
            break
        }
    }

    private static func shouldSkipPart(
        _ part: GmailPart,
        mimeType: String,
        partHeaders: MailHeaders
    ) -> Bool {
        if mimeType == "application/pkcs7-signature" || mimeType == "application/x-pkcs7-signature" {
            return true
        }
        if let filename = part.filename?.trimmingCharacters(in: .whitespacesAndNewlines),
           !filename.isEmpty
        {
            return true
        }
        if let attachmentId = part.body?.attachmentId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !attachmentId.isEmpty
        {
            return true
        }
        if let disposition = partHeaders.first(for: "Content-Disposition") {
            let dispositionType = BodyDecoder.splitHeaderParameters(disposition)
                .first?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if dispositionType == "attachment" {
                return true
            }
        }
        return false
    }

    private static func decodeLeafPart(
        _ part: GmailPart,
        contentTypeHeader: String?,
        issues: inout [String]
    ) -> String? {
        guard let encoded = part.body?.data else {
            if (part.body?.size ?? 0) > 0 {
                issues.append("Body data is missing for non-empty text part.")
            }
            return nil
        }
        let charset = BodyDecoder.charset(fromContentType: contentTypeHeader)
        let decoded = BodyDecoder.decodeBase64URL(encoded, declaredCharset: charset)
        issues.append(contentsOf: decoded.issues)
        return decoded.text
    }

    private static func normalizedMIMEType(_ raw: String?) -> String {
        guard let raw else { return "" }
        let mainType = BodyDecoder.splitHeaderParameters(raw).first ?? raw
        return mainType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

func unfoldHeader(_ value: String) -> String {
    var out = ""
    out.reserveCapacity(value.count)
    let scalars = Array(value.unicodeScalars)
    var i = 0
    while i < scalars.count {
        if scalars[i] == "\r" || scalars[i] == "\n" {
            if scalars[i] == "\r" && i + 1 < scalars.count && scalars[i + 1] == "\n" {
                i += 2
            } else {
                i += 1
            }
            var hadFoldingSpace = false
            while i < scalars.count && (scalars[i] == " " || scalars[i] == "\t") {
                hadFoldingSpace = true
                i += 1
            }
            if hadFoldingSpace {
                out.append(" ")
            }
        } else {
            out.unicodeScalars.append(scalars[i])
            i += 1
        }
    }
    return out
}
