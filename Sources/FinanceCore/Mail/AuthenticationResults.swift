import Foundation

/// Parsed representation of an RFC 8601 `Authentication-Results` header value.
public struct AuthenticationResults: Equatable, Sendable {
    /// A single method result reported within an `Authentication-Results` header.
    public struct Entry: Equatable, Sendable {
        /// Authentication method name, lowercased (for example `dkim`, `spf`, or `dmarc`).
        public var method: String
        /// Outcome reported for the method, lowercased (for example `pass` or `fail`).
        public var result: String
        /// Properties associated with the result, keyed by lowercased `ptype.property` name.
        public var properties: [String: String]

        public init(method: String, result: String, properties: [String: String] = [:]) {
            self.method = method
            self.result = result
            self.properties = properties
        }
    }

    /// Authentication service identifier at the start of the header, lowercased.
    public var authservID: String
    /// Method results in the order they appeared in the header.
    public var results: [Entry]

    public init(authservID: String, results: [Entry] = []) {
        self.authservID = authservID
        self.results = results
    }

    /// Parses an `Authentication-Results` header value, tolerating comments and folded whitespace.
    public static func parse(_ headerValue: String) -> AuthenticationResults? {
        let clauses = splitClausesStrippingComments(headerValue)
        guard let firstClause = clauses.first else { return nil }

        let authTokens = firstClause
            .split(whereSeparator: { $0 == " " })
            .map(String.init)
        guard let rawAuthserv = authTokens.first, !rawAuthserv.isEmpty, !rawAuthserv.contains("=") else {
            return nil
        }
        // RFC 8601 allows an optional integer authres-version after authserv-id.
        if authTokens.count > 2 {
            return nil
        }
        if authTokens.count == 2 && !authTokens[1].allSatisfy({ $0.isASCII && $0.isNumber }) {
            return nil
        }

        var entries: [Entry] = []
        for clause in clauses.dropFirst() {
            let trimmed = clause.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.lowercased() == "none" {
                continue
            }
            if let entry = parseResultClause(trimmed) {
                entries.append(entry)
            }
        }

        return AuthenticationResults(authservID: rawAuthserv.lowercased(), results: entries)
    }

    /// Removes RFC 5322 comments (including nested parentheses), unfolds whitespace,
    /// and splits on `;` outside quoted strings.
    private static func splitClausesStrippingComments(_ input: String) -> [String] {
        var clauses: [String] = []
        var current = ""
        var inQuotes = false
        var escaped = false
        var commentDepth = 0

        for scalar in input.unicodeScalars {
            if escaped {
                if commentDepth == 0 {
                    current.unicodeScalars.append(scalar)
                }
                escaped = false
                continue
            }

            if scalar == "\\" && (inQuotes || commentDepth > 0) {
                if commentDepth == 0 {
                    current.append("\\")
                }
                escaped = true
                continue
            }

            if !inQuotes {
                if scalar == "(" {
                    if commentDepth == 0 {
                        current.append(" ")
                    }
                    commentDepth += 1
                    continue
                }
                if scalar == ")" && commentDepth > 0 {
                    commentDepth -= 1
                    continue
                }
            }

            if commentDepth > 0 {
                continue
            }

            if scalar == "\"" {
                inQuotes.toggle()
                current.append("\"")
                continue
            }

            if !inQuotes {
                if scalar == ";" {
                    clauses.append(current)
                    current = ""
                    continue
                }
                if scalar == "\r" || scalar == "\n" || scalar == "\t" {
                    current.append(" ")
                    continue
                }
            }

            current.unicodeScalars.append(scalar)
        }

        clauses.append(current)
        return clauses
    }

    private static func parseResultClause(_ clause: String) -> Entry? {
        let scalars = Array(clause.unicodeScalars)
        var i = 0
        var pairs: [(String, String)] = []

        func skipSpaces() {
            while i < scalars.count && scalars[i] == " " {
                i += 1
            }
        }

        func readKey() -> String {
            var key = ""
            while i < scalars.count {
                let s = scalars[i]
                if s == "=" {
                    break
                }
                if s == " " {
                    // Tolerate CFWS around `.` inside `ptype . property`.
                    let saved = i
                    skipSpaces()
                    if i < scalars.count && scalars[i] == "." {
                        key.append(".")
                        i += 1
                        skipSpaces()
                        continue
                    } else if key.hasSuffix(".") {
                        continue
                    } else {
                        i = saved
                        break
                    }
                }
                key.unicodeScalars.append(s)
                i += 1
            }
            return key
        }

        func readValue() -> String {
            skipSpaces()
            guard i < scalars.count else { return "" }
            if scalars[i] == "\"" {
                i += 1
                var value = ""
                var escaped = false
                while i < scalars.count {
                    let s = scalars[i]
                    i += 1
                    if escaped {
                        value.unicodeScalars.append(s)
                        escaped = false
                    } else if s == "\\" {
                        escaped = true
                    } else if s == "\"" {
                        break
                    } else {
                        value.unicodeScalars.append(s)
                    }
                }
                return value
            } else {
                var value = ""
                while i < scalars.count && scalars[i] != " " {
                    value.unicodeScalars.append(scalars[i])
                    i += 1
                }
                return value
            }
        }

        while i < scalars.count {
            skipSpaces()
            guard i < scalars.count else { break }

            let key = readKey()
            skipSpaces()
            guard !key.isEmpty, i < scalars.count, scalars[i] == "=" else {
                // Skip any unexpected token that does not form a key=value pair.
                while i < scalars.count && scalars[i] != " " {
                    i += 1
                }
                continue
            }
            i += 1 // consume "="
            let value = readValue()
            pairs.append((key, value))
        }

        guard let first = pairs.first, !first.1.isEmpty else { return nil }

        // Strip optional `/version` suffix on the method name (RFC 8601).
        let rawMethod = first.0.lowercased()
        let method: String
        if let slash = rawMethod.firstIndex(of: "/") {
            method = String(rawMethod[..<slash])
        } else {
            method = rawMethod
        }
        guard !method.isEmpty else { return nil }

        let result = first.1.lowercased()
        var properties: [String: String] = [:]
        for (propKey, propValue) in pairs.dropFirst() {
            properties[propKey.lowercased()] = propValue
        }

        return Entry(method: method, result: result, properties: properties)
    }
}
