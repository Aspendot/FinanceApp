import Foundation
import Testing
@testable import FinanceCore

@Suite("AuthenticationResults")
struct AuthenticationResultsTests {
    @Test("Parses authserv-id, methods, results, properties, comments and folded whitespace")
    func parsesRealStyleHeader() {
        let raw = """
        mx.google.com;
               dkim=pass (2048-bit key; unprotected) header.i=@debit.bk.mufg.jp header.s=s2024 header.b=AbCdEf+/==;
               spf=pass (google.com: domain of mail@debit.bk.mufg.jp (nested comment) designates 192.0.2.1 as permitted sender) smtp.mailfrom=mail@debit.bk.mufg.jp;
               dmarc=pass (p=REJECT sp=REJECT dis=NONE) header.from=debit.bk.mufg.jp
        """

        let parsed = AuthenticationResults.parse(raw)
        #expect(parsed != nil)
        #expect(parsed?.authservID == "mx.google.com")
        #expect(parsed?.results.count == 3)

        #expect(parsed?.results[0] == AuthenticationResults.Entry(
            method: "dkim",
            result: "pass",
            properties: [
                "header.i": "@debit.bk.mufg.jp",
                "header.s": "s2024",
                "header.b": "AbCdEf+/==",
            ]
        ))
        #expect(parsed?.results[1] == AuthenticationResults.Entry(
            method: "spf",
            result: "pass",
            properties: [
                "smtp.mailfrom": "mail@debit.bk.mufg.jp",
            ]
        ))
        #expect(parsed?.results[2] == AuthenticationResults.Entry(
            method: "dmarc",
            result: "pass",
            properties: [
                "header.from": "debit.bk.mufg.jp",
            ]
        ))
    }

    @Test("Handles quoted values containing semicolons and parentheses")
    func quotedValues() {
        let raw = #"mx.google.com; dkim=fail reason="bad (signature); mismatch" header.d=example.com"#
        let parsed = AuthenticationResults.parse(raw)
        #expect(parsed?.authservID == "mx.google.com")
        #expect(parsed?.results == [
            AuthenticationResults.Entry(
                method: "dkim",
                result: "fail",
                properties: [
                    "reason": "bad (signature); mismatch",
                    "header.d": "example.com",
                ]
            ),
        ])
    }

    @Test("Handles none result and optional version number")
    func noneAndVersion() {
        let parsed = AuthenticationResults.parse("MX.GOOGLE.COM 1; none")
        #expect(parsed == AuthenticationResults(authservID: "mx.google.com", results: []))
    }
}

@Suite("SenderCheck")
struct SenderCheckTests {
    private func makeMessage(from: String?, authHeaders: [String]) -> MailMessage {
        var entries: [MailHeaders.Entry] = []
        if let from {
            entries.append(MailHeaders.Entry(name: "From", value: from))
        }
        for auth in authHeaders {
            entries.append(MailHeaders.Entry(name: "Authentication-Results", value: auth))
        }
        return MailMessage(
            id: "msg-auth",
            receivedAt: Date(timeIntervalSince1970: 1_735_689_600),
            headers: MailHeaders(entries),
            from: from.flatMap(MailAddress.parse),
            subject: "Notice",
            textBody: "Body",
            htmlBody: nil
        )
    }

    @Test("Passes when mx.google.com dkim=pass and From align on an allowed domain or subdomain")
    func passesAlignedExactAndSubdomain() {
        // Using header.i subdomain with allowed parent domain.
        let msgI = makeMessage(
            from: "Sample Bank <mail@debit.bk.mufg.jp>",
            authHeaders: [
                "mx.google.com; dkim=pass header.i=@debit.bk.mufg.jp header.s=s1; spf=pass",
            ]
        )
        #expect(SenderCheck.verify(msgI, allowedDomains: ["bk.mufg.jp"]) == .pass)

        // Using header.d exact allowed domain while From is a subdomain of that same allowed domain.
        let msgD = makeMessage(
            from: "Apple Receipt <no_reply@email.apple.com>",
            authHeaders: [
                "mx.google.com; dkim=pass header.d=apple.com header.s=s1",
            ]
        )
        #expect(SenderCheck.verify(msgD, allowedDomains: ["apple.com"]) == .pass)
    }

    @Test("Fails forged message whose first Authentication-Results fails and second passes")
    func rejectsForgedSecondHeaderAfterFail() {
        let message = makeMessage(
            from: "mail@debit.bk.mufg.jp",
            authHeaders: [
                "mx.google.com; dkim=fail header.d=debit.bk.mufg.jp",
                "mx.google.com; dkim=pass header.d=debit.bk.mufg.jp",
            ]
        )
        let verdict = SenderCheck.verify(message, allowedDomains: ["bk.mufg.jp"])
        guard case .fail(let reasons) = verdict else {
            Issue.record("Expected fail, got \(verdict)")
            return
        }
        #expect(!reasons.isEmpty)
    }

    @Test("Fails forged message whose first Authentication-Results has a non-Google authserv-id")
    func rejectsForgedNonGoogleFirstHeader() {
        let message = makeMessage(
            from: "post_master@netbk.co.jp",
            authHeaders: [
                "mx.forger.example.com; dkim=pass header.d=netbk.co.jp",
                "mx.google.com; dkim=pass header.d=netbk.co.jp",
            ]
        )
        let verdict = SenderCheck.verify(message, allowedDomains: ["netbk.co.jp"])
        guard case .fail(let reasons) = verdict else {
            Issue.record("Expected fail, got \(verdict)")
            return
        }
        #expect(reasons.contains { $0.contains("mx.google.com") })
    }

    @Test("Fails when dkim=pass is for an unrelated domain")
    func rejectsUnrelatedDKIMDomain() {
        let message = makeMessage(
            from: "mail@debit.bk.mufg.jp",
            authHeaders: [
                "mx.google.com; dkim=pass header.d=unrelated.example.com",
            ]
        )
        let verdict = SenderCheck.verify(message, allowedDomains: ["bk.mufg.jp"])
        guard case .fail(let reasons) = verdict else {
            Issue.record("Expected fail, got \(verdict)")
            return
        }
        #expect(!reasons.isEmpty)
    }

    @Test("Fails when dkim=pass and From match two different allowed domains")
    func rejectsCrossDomainAllowedMismatch() {
        let message = makeMessage(
            from: "mail@debit.bk.mufg.jp",
            authHeaders: [
                "mx.google.com; dkim=pass header.d=netbk.co.jp",
            ]
        )
        let verdict = SenderCheck.verify(message, allowedDomains: ["bk.mufg.jp", "netbk.co.jp"])
        guard case .fail(let reasons) = verdict else {
            Issue.record("Expected fail, got \(verdict)")
            return
        }
        #expect(!reasons.isEmpty)
    }

    @Test("Fails look-alike From domains such as bk-mufg.jp.example.com or evilbank.example.com")
    func rejectsLookAlikeFromDomains() {
        for spoofed in ["mail@bk-mufg.jp.example.com", "mail@bk.mufg.jp.example.com"] {
            let message = makeMessage(
                from: spoofed,
                authHeaders: [
                    "mx.google.com; dkim=pass header.d=bk.mufg.jp",
                ]
            )
            let verdict = SenderCheck.verify(message, allowedDomains: ["bk.mufg.jp"])
            guard case .fail(let reasons) = verdict else {
                Issue.record("Expected fail for \(spoofed), got \(verdict)")
                return
            }
            #expect(!reasons.isEmpty)
        }

        // Prefix without a dot separator must not match a parent domain.
        let prefixSpoof = makeMessage(
            from: "mail@evilbank.example.com",
            authHeaders: [
                "mx.google.com; dkim=pass header.d=bank.example.com",
            ]
        )
        let prefixVerdict = SenderCheck.verify(prefixSpoof, allowedDomains: ["bank.example.com"])
        guard case .fail(let reasons) = prefixVerdict else {
            Issue.record("Expected fail for prefix spoof, got \(prefixVerdict)")
            return
        }
        #expect(!reasons.isEmpty)
    }

    @Test("Fails when Authentication-Results header or From address is missing")
    func rejectsMissingHeaderOrFrom() {
        let noAuth = makeMessage(from: "no-reply@mercari.jp", authHeaders: [])
        if case .pass = SenderCheck.verify(noAuth, allowedDomains: ["mercari.jp"]) {
            Issue.record("Expected fail when Authentication-Results is missing")
        }

        let noFrom = makeMessage(
            from: nil,
            authHeaders: ["mx.google.com; dkim=pass header.d=mercari.jp"]
        )
        if case .pass = SenderCheck.verify(noFrom, allowedDomains: ["mercari.jp"]) {
            Issue.record("Expected fail when From is missing")
        }
    }
}
