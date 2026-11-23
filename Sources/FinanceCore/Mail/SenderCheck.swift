import Foundation

/// Verifies that an email message's sender is authenticated by Gmail DKIM for an allowed domain.
public enum SenderCheck {
    /// Result of verifying a message against a set of allowed domains.
    public enum Verdict: Equatable, Sendable {
        /// The message passed all authentication and alignment checks.
        case pass
        /// The message failed verification, with one or more plain-English reasons.
        case fail(reasons: [String])
    }

    /// Verifies that `message` has a first `Authentication-Results` header from `mx.google.com`
    /// with a `dkim=pass` result aligned to an allowed domain that also matches the `From` domain.
    public static func verify(_ message: MailMessage, allowedDomains: Set<String>) -> Verdict {
        let normalizedAllowed = Set(allowedDomains.compactMap(normalizeDomain))
        guard !normalizedAllowed.isEmpty else {
            return .fail(reasons: ["No allowed domains were provided."])
        }

        var reasons: [String] = []

        let fromDomain = message.from?.domain.flatMap(normalizeDomain)
        let fromMatchedAllowed: Set<String>
        if let fromDomain {
            fromMatchedAllowed = normalizedAllowed.filter { domainMatches(fromDomain, allowed: $0) }
            if fromMatchedAllowed.isEmpty {
                reasons.append("From domain '\(fromDomain)' is not in the allowed domains.")
            }
        } else {
            fromMatchedAllowed = []
            reasons.append("Message has no valid From address.")
        }

        guard let firstAuthHeader = message.headers.first(for: "Authentication-Results") else {
            reasons.append("Message has no Authentication-Results header.")
            return .fail(reasons: reasons)
        }

        guard let authResults = AuthenticationResults.parse(firstAuthHeader) else {
            reasons.append("First Authentication-Results header could not be parsed.")
            return .fail(reasons: reasons)
        }

        guard authResults.authservID == "mx.google.com" else {
            reasons.append("First Authentication-Results header is from '\(authResults.authservID)', expected 'mx.google.com'.")
            return .fail(reasons: reasons)
        }

        let dkimPasses = authResults.results.filter { $0.method == "dkim" && $0.result == "pass" }
        guard !dkimPasses.isEmpty else {
            reasons.append("First Authentication-Results header has no dkim=pass result.")
            return .fail(reasons: reasons)
        }

        var dkimDomains: [String] = []
        for entry in dkimPasses {
            if let domain = extractDKIMDomain(from: entry) {
                dkimDomains.append(domain)
                if fromMatchedAllowed.contains(where: { domainMatches(domain, allowed: $0) }) {
                    return .pass
                }
            }
        }

        if dkimDomains.isEmpty {
            reasons.append("No dkim=pass result included a valid header.d or header.i domain.")
        } else if !fromMatchedAllowed.isEmpty {
            reasons.append("No dkim=pass domain aligned with the allowed domain for From.")
        } else if !dkimDomains.contains(where: { d in normalizedAllowed.contains { domainMatches(d, allowed: $0) } }) {
            reasons.append("No dkim=pass domain matched any allowed domain.")
        }

        return .fail(reasons: reasons)
    }

    private static func extractDKIMDomain(from entry: AuthenticationResults.Entry) -> String? {
        if let rawD = entry.properties["header.d"],
           let normalized = normalizeDomain(rawD)
        {
            return normalized
        }
        if let rawI = entry.properties["header.i"] {
            let trimmed = rawI.trimmingCharacters(in: .whitespacesAndNewlines)
            if let at = trimmed.lastIndex(of: "@") {
                let domainPart = String(trimmed[trimmed.index(after: at)...])
                return normalizeDomain(domainPart)
            }
        }
        return nil
    }

    private static func normalizeDomain(_ raw: String) -> String? {
        var domain = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if domain.hasSuffix(".") {
            domain.removeLast()
        }
        guard !domain.isEmpty,
              !domain.hasPrefix("."),
              !domain.contains(".."),
              !domain.contains(where: { $0.isWhitespace })
        else { return nil }
        return domain
    }

    private static func domainMatches(_ candidate: String, allowed: String) -> Bool {
        candidate == allowed || candidate.hasSuffix("." + allowed)
    }
}
