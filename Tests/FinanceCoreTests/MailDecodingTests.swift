import Foundation
import Testing
@testable import FinanceCore

private func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private func base64URL(_ text: String) -> String {
    base64URL(Data(text.utf8))
}

@Suite("GmailMessage and MailMessage")
struct MailDecodingTests {
    @Test("Decodes Gmail format=full JSON into MailMessage")
    func decodesGmailJSON() throws {
        let bodyText = "デビットカードご利用のお知らせ\n店舗: テスト商店\n金額: 1,000円"
        let encodedBody = base64URL(bodyText)
        let json = """
        {
          "id": "msg-001",
          "threadId": "thr-001",
          "labelIds": ["INBOX", "UNREAD"],
          "internalDate": "1735689600000",
          "payload": {
            "partId": "",
            "mimeType": "text/plain",
            "filename": "",
            "headers": [
              { "name": "From", "value": "Sample Bank <mail@debit.bk.mufg.jp>" },
              { "name": "Subject", "value": "Notice from SAMPLE STORE" },
              { "name": "Received", "value": "hop-1" },
              { "name": "received", "value": "hop-2" },
              { "name": "Content-Type", "value": "text/plain; charset=UTF-8" }
            ],
            "body": {
              "size": 72,
              "data": "\(encodedBody)"
            }
          }
        }
        """

        let gmail = try JSONDecoder().decode(GmailMessage.self, from: Data(json.utf8))
        #expect(gmail.id == "msg-001")
        #expect(gmail.threadId == "thr-001")
        #expect(gmail.labelIds == ["INBOX", "UNREAD"])

        let message = MailMessage(gmail: gmail)
        #expect(message.id == "msg-001")
        #expect(message.receivedAt == Date(timeIntervalSince1970: 1_735_689_600))
        #expect(message.from == MailAddress(displayName: "Sample Bank", address: "mail@debit.bk.mufg.jp"))
        #expect(message.from?.domain == "debit.bk.mufg.jp")
        #expect(message.subject == "Notice from SAMPLE STORE")
        #expect(message.textBody == bodyText)
        #expect(message.htmlBody == nil)
        #expect(message.issues.isEmpty)

        // Case-insensitive lookup returns all values in original order.
        #expect(message.headers.values(for: "RECEIVED") == ["hop-1", "hop-2"])
        #expect(message.headers["received"] == ["hop-1", "hop-2"])
        #expect(message.headers.first(for: "received") == "hop-1")
    }

    @Test("Records an issue when internalDate is missing or invalid")
    func invalidInternalDate() {
        let gmail = GmailMessage(
            id: "msg-bad-date",
            internalDate: "not-a-timestamp",
            payload: GmailPart(mimeType: "text/plain", body: GmailBody(size: 5, data: base64URL("hello")))
        )
        let message = MailMessage(gmail: gmail)
        #expect(message.receivedAt == nil)
        #expect(message.textBody == "hello")
        #expect(!message.issues.isEmpty)
    }

    @Test("Prefers UTF-8 when body declares ISO-2022-JP but contains valid UTF-8")
    func utf8OverridesDeclaredISO2022JP() {
        let expected = "テスト商店 1,000円"
        let part = GmailPart(
            mimeType: "text/plain",
            headers: [
                GmailHeader(name: "Content-Type", value: "text/plain; charset=ISO-2022-JP"),
            ],
            body: GmailBody(size: expected.utf8.count, data: base64URL(expected))
        )
        let message = MailMessage(gmail: GmailMessage(id: "msg-utf8-jis", internalDate: "1735689600000", payload: part))
        #expect(message.textBody == expected)
        #expect(message.issues.isEmpty)
    }

    @Test("Decodes 7-bit ISO-2022-JP bytes with ESC $ B, ESC $ @, ESC ( J and ESC ( I")
    func decodesISO2022JPSequences() {
        // ESC $ B + "テスト" (JIS 2546 2539 2548) + ESC ( B
        let escDollarB = Data([
            0x1B, 0x24, 0x42,
            0x25, 0x46, 0x25, 0x39, 0x25, 0x48,
            0x1B, 0x28, 0x42,
        ])
        let resB = BodyDecoder.decodeBytes(escDollarB, declaredCharset: nil)
        #expect(resB.text == "テスト")
        #expect(resB.issues.isEmpty)

        // ESC $ @ (JIS C 6226-1978) + "テスト" + ESC ( J (JIS X 0201 Roman) + " 100"
        let escDollarAtAndJ = Data([
            0x1B, 0x24, 0x40,
            0x25, 0x46, 0x25, 0x39, 0x25, 0x48,
            0x1B, 0x28, 0x4A,
            0x20, 0x31, 0x30, 0x30,
        ])
        let resAtJ = BodyDecoder.decodeBytes(escDollarAtAndJ, declaredCharset: "us-ascii")
        #expect(resAtJ.text == "テスト 100")
        #expect(resAtJ.issues.isEmpty)

        // ESC ( I (JIS X 0201 half-width katakana) + "ﾃｽﾄ" (0x43, 0x3D, 0x44) + ESC ( B
        let escParenI = Data([
            0x1B, 0x28, 0x49,
            0x43, 0x3D, 0x44,
            0x1B, 0x28, 0x42,
        ])
        let resI = BodyDecoder.decodeBytes(escParenI, declaredCharset: nil)
        #expect(resI.text == "ﾃｽﾄ")
        #expect(resI.issues.isEmpty)

        // Round-trip via String.data(using: .iso2022JP) inside a full GmailMessage.
        let original = "ご利用店舗: テスト商店\n金額: 2,000円"
        let jisBytes = original.data(using: .iso2022JP)!
        let part = GmailPart(
            mimeType: "text/plain",
            headers: [GmailHeader(name: "Content-Type", value: "text/plain; charset=\"ISO-2022-JP\"")],
            body: GmailBody(size: jisBytes.count, data: base64URL(jisBytes))
        )
        let msg = MailMessage(gmail: GmailMessage(id: "msg-jis", internalDate: "1735689600000", payload: part))
        #expect(msg.textBody == original)
        #expect(msg.issues.isEmpty)
    }

    @Test("Decodes pure ASCII without requiring a declared charset")
    func pureASCII() {
        let res = BodyDecoder.decodeBytes(Data("SAMPLE STORE 500 JPY".utf8), declaredCharset: nil)
        #expect(res.text == "SAMPLE STORE 500 JPY")
        #expect(res.issues.isEmpty)
    }

    @Test("Decodes Shift_JIS, EUC-JP and ISO-8859-1 via declared charset fallback")
    func declaredCharsetFallbacks() {
        // Shift_JIS bytes for "テスト商店": 83 65 83 58 83 67 8F A4 93 58
        let sjisBytes = Data([0x83, 0x65, 0x83, 0x58, 0x83, 0x67, 0x8F, 0xA4, 0x93, 0x58])
        for label in ["shift_jis", "sjis", "cp932", "windows-31j"] {
            let res = BodyDecoder.decodeBytes(sjisBytes, declaredCharset: label)
            #expect(res.text == "テスト商店")
            #expect(res.issues.isEmpty)
        }

        // EUC-JP bytes for "テスト商店": A5 C6 A5 B9 A5 C8 BE A6 C5 B9
        let eucBytes = Data([0xA5, 0xC6, 0xA5, 0xB9, 0xA5, 0xC8, 0xBE, 0xA6, 0xC5, 0xB9])
        let eucRes = BodyDecoder.decodeBytes(eucBytes, declaredCharset: "euc-jp")
        #expect(eucRes.text == "テスト商店")
        #expect(eucRes.issues.isEmpty)

        // EUC-JP half-width katakana (SS2 0x8E prefix) + ASCII: "ﾃｽﾄ 100"
        let eucHalfKana = Data([0x8E, 0xC3, 0x8E, 0xBD, 0x8E, 0xC4, 0x20, 0x31, 0x30, 0x30])
        let eucHalfRes = BodyDecoder.decodeBytes(eucHalfKana, declaredCharset: "euc-jp")
        #expect(eucHalfRes.text == "ﾃｽﾄ 100")
        #expect(eucHalfRes.issues.isEmpty)

        // ISO-8859-1 bytes for "Caf\u{00E9} \u{00A5}500"
        let latin1Bytes = Data([0x43, 0x61, 0x66, 0xE9, 0x20, 0xA5, 0x35, 0x30, 0x30])
        let latin1Res = BodyDecoder.decodeBytes(latin1Bytes, declaredCharset: "iso-8859-1")
        #expect(latin1Res.text == "Caf\u{00E9} ¥500")
        #expect(latin1Res.issues.isEmpty)
    }

    @Test("Records an issue and returns nil when decoding fails")
    func decodingFailureRecordsIssue() {
        // Invalid base64url (length mod 4 == 1)
        let badBase64 = BodyDecoder.decodeBase64URL("A", declaredCharset: "utf-8")
        #expect(badBase64.text == nil)
        #expect(!badBase64.issues.isEmpty)

        // Non-UTF-8 bytes with no declared charset
        let noCharset = BodyDecoder.decodeBytes(Data([0x83, 0x65]), declaredCharset: nil)
        #expect(noCharset.text == nil)
        #expect(!noCharset.issues.isEmpty)

        // Unsupported charset
        let unsupported = BodyDecoder.decodeBytes(Data([0x83, 0x65]), declaredCharset: "x-unknown-999")
        #expect(unsupported.text == nil)
        #expect(!unsupported.issues.isEmpty)

        // Invalid UTF-8 bytes declaring utf-8
        let invalidUTF8 = BodyDecoder.decodeBytes(Data([0xFF, 0xFE]), declaredCharset: "utf-8")
        #expect(invalidUTF8.text == nil)
        #expect(!invalidUTF8.issues.isEmpty)

        // Truncated EUC-JP byte sequence
        let invalidEUC = BodyDecoder.decodeBytes(Data([0xA5]), declaredCharset: "euc-jp")
        #expect(invalidEUC.text == nil)
        #expect(!invalidEUC.issues.isEmpty)
    }

    @Test("Records an issue when decoded text contains Private Use Area scalars")
    func detectsPrivateUseAreaScalars() {
        let withPUA = "テスト\u{E001}商店"
        let res = BodyDecoder.decodeBytes(Data(withPUA.utf8), declaredCharset: "utf-8")
        #expect(res.text == withPUA)
        #expect(res.issues.contains { $0.contains("Private Use Area") })
    }

    @Test("Does not decode quoted-printable because Gmail format=full already removed it")
    func quotedPrintableFreePath() {
        let literal = "Total=3D1000=20JPY\nLine=\nContinued"
        let part = GmailPart(
            mimeType: "text/plain",
            headers: [
                GmailHeader(name: "Content-Type", value: "text/plain; charset=UTF-8"),
                GmailHeader(name: "Content-Transfer-Encoding", value: "quoted-printable"),
            ],
            body: GmailBody(size: literal.utf8.count, data: base64URL(literal))
        )
        let message = MailMessage(gmail: GmailMessage(id: "msg-qp", internalDate: "1735689600000", payload: part))
        #expect(message.textBody == literal)
        #expect(message.issues.isEmpty)
    }

    @Test("Walks nested multiparts: signed, mixed, alternative, related, skipping attachments and signatures")
    func nestedMultipartsAndSkips() {
        let plainText = "テスト商店 1,500円"
        let htmlText = "<table><tr><td>テスト商店</td><td>&yen;1,500</td></tr></table>"

        let related = GmailPart(
            mimeType: "multipart/related",
            parts: [
                GmailPart(
                    mimeType: "text/html",
                    headers: [GmailHeader(name: "Content-Type", value: "text/html; charset=UTF-8")],
                    body: GmailBody(size: htmlText.utf8.count, data: base64URL(htmlText))
                ),
                GmailPart(
                    mimeType: "image/png",
                    filename: "logo.png",
                    body: GmailBody(size: 100, attachmentId: "att-logo")
                ),
            ]
        )

        let alternative = GmailPart(
            mimeType: "multipart/alternative",
            parts: [
                GmailPart(
                    mimeType: "text/plain",
                    headers: [GmailHeader(name: "Content-Type", value: "text/plain; charset=UTF-8")],
                    body: GmailBody(size: plainText.utf8.count, data: base64URL(plainText))
                ),
                related,
            ]
        )

        let mixed = GmailPart(
            mimeType: "multipart/mixed",
            parts: [
                alternative,
                GmailPart(
                    mimeType: "text/plain",
                    filename: "receipt.txt",
                    body: GmailBody(size: 20, data: base64URL("ATTACHMENT SHOULD BE SKIPPED"))
                ),
                GmailPart(
                    mimeType: "text/plain",
                    body: GmailBody(size: 20, data: base64URL("ATTACH ID SKIPPED"), attachmentId: "att-2")
                ),
                GmailPart(
                    mimeType: "application/pdf",
                    filename: "statement.pdf",
                    body: GmailBody(size: 500, attachmentId: "att-pdf")
                ),
            ]
        )

        let signed = GmailPart(
            mimeType: "multipart/signed",
            headers: [
                GmailHeader(name: "From", value: "mail@direct-11.bk.mufg.jp"),
                GmailHeader(name: "Subject", value: "Signed notice"),
            ],
            parts: [
                mixed,
                GmailPart(
                    mimeType: "application/pkcs7-signature",
                    filename: "smime.p7s",
                    body: GmailBody(size: 128, data: base64URL("not-a-text-body"))
                ),
            ]
        )

        let message = MailMessage(gmail: GmailMessage(id: "msg-nested", internalDate: "1735689600000", payload: signed))
        #expect(message.textBody == plainText)
        #expect(message.htmlBody == htmlText)
        #expect(message.issues.isEmpty)
    }

    @Test("Decodes RFC 2047 B and Q encoded words in Subject and From display name")
    func decodesRFC2047() {
        // Adjacent UTF-8 B-encoded words separated by folding whitespace should join without space.
        let part1 = Data("ご利用".utf8).base64EncodedString()
        let part2 = Data("のお知らせ".utf8).base64EncodedString()
        let encodedSubject = "=?UTF-8?B?\(part1)?=\r\n =?UTF-8?B?\(part2)?= (SAMPLE STORE)"

        // ISO-2022-JP B-encoded From display name.
        let bankNameJIS = "サンプル銀行".data(using: .iso2022JP)!.base64EncodedString()
        let encodedFrom = "=?ISO-2022-JP?B?\(bankNameJIS)?= <post_master@netbk.co.jp>"

        let payload = GmailPart(
            mimeType: "text/plain",
            headers: [
                GmailHeader(name: "From", value: encodedFrom),
                GmailHeader(name: "Subject", value: encodedSubject),
            ],
            body: GmailBody(size: 2, data: base64URL("ok"))
        )
        let message = MailMessage(gmail: GmailMessage(id: "msg-2047", internalDate: "1735689600000", payload: payload))
        #expect(message.subject == "ご利用のお知らせ (SAMPLE STORE)")
        #expect(message.from == MailAddress(displayName: "サンプル銀行", address: "post_master@netbk.co.jp"))

        // Q-encoding with underscores and hex escapes.
        let qDecoded = RFC2047.decode("=?UTF-8?Q?Sample_Receipt_=C2=A5?= =?UTF-8?Q?1,000?=")
        #expect(qDecoded == "Sample Receipt ¥1,000")

        // Text without "=?" is returned untouched.
        let plain = "Plain subject with_underscores and =3D"
        #expect(RFC2047.decode(plain) == plain)

        // Quoted RFC 2047 display name in From.
        let quotedFrom = MailAddress.parse("\"=?UTF-8?Q?Sample_Bank?=\" <no-reply@mercari.jp>")
        #expect(quotedFrom == MailAddress(displayName: "Sample Bank", address: "no-reply@mercari.jp"))
    }
}
