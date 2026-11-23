import Foundation
import Testing
@testable import FinanceSync

@Suite("DriveEnvelope, DriveSyncKey and GoogleDriveClient")
struct DriveSyncTests {
    private let sampleClientID = "12345-sample.apps.googleusercontent.com"

    @Test("GoogleOAuth supports incremental drive.appdata scope")
    func incrementalDriveScopeAuthorizationURL() throws {
        let pkce = try PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        let url = try GoogleOAuth.authorizationURL(
            clientID: sampleClientID,
            pkce: pkce,
            state: "drive-state-1",
            scopes: [GoogleOAuth.gmailReadOnlyScope, GoogleOAuth.driveAppDataScope],
            includeGrantedScopes: true
        )
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(query["include_granted_scopes"] == "true")
        #expect(query["scope"] == "\(GoogleOAuth.gmailReadOnlyScope) \(GoogleOAuth.driveAppDataScope)")

        let tokens = OAuthTokens(
            accessToken: "tok",
            expiresAt: Date().addingTimeInterval(3600),
            scope: "\(GoogleOAuth.gmailReadOnlyScope) \(GoogleOAuth.driveAppDataScope)"
        )
        #expect(tokens.hasScope(GoogleOAuth.driveAppDataScope))
        #expect(tokens.hasScope(GoogleOAuth.gmailReadOnlyScope))
        #expect(!tokens.hasScope("https://www.googleapis.com/auth/drive"))
    }

    @Test("DriveSyncKey parses pairing string, computes SHA-256 key ID, and rejects invalid inputs")
    func pairingKeyParsingAndKeyID() throws {
        // 32 bytes: 0x00, 0x01, ..., 0x1f
        let rawKey = Data(0..<32)
        // Expected SHA-256(0x00..0x1f) prefix 8 bytes: 630dcd2966c43366
        let key = try DriveSyncKey(keyBytes: rawKey)
        #expect(key.keyIDHex == "630dcd2966c43366")
        #expect(key.keyIDFormatted == "630d cd29 66c4 3366")
        #expect(key.pairingString == "finance-key:v1:AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8")
        #expect(!String(describing: key).contains("AAECAwQFBgc"))

        let reparsed = try DriveSyncKey(pairingString: "  \(key.pairingString)\n")
        #expect(reparsed == key)

        // Wrong prefix.
        #expect(throws: DriveEnvelopeError.invalidKeyPrefix) {
            _ = try DriveSyncKey(pairingString: "wrong-prefix:AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8")
        }
        // Padding '=' rejected.
        #expect(throws: DriveEnvelopeError.invalidKeyEncoding) {
            _ = try DriveSyncKey(pairingString: key.pairingString + "=")
        }
        // Standard base64 '+'/'/' rejected.
        #expect(throws: DriveEnvelopeError.invalidKeyEncoding) {
            _ = try DriveSyncKey(pairingString: "finance-key:v1:" + String(repeating: "+", count: 43))
        }
        // Wrong length (16 bytes instead of 32).
        #expect(throws: DriveEnvelopeError.invalidKeyLength(16)) {
            _ = try DriveSyncKey(pairingString: "finance-key:v1:AAECAwQFBgcICQoLDA0ODw")
        }
    }

    @Test("DriveEnvelope v1 parses, serializes, exposes AAD, and validates magic/length/keyID")
    func envelopeParsingAndValidation() throws {
        let key = try DriveSyncKey(keyBytes: Data(0..<32))
        let otherKey = try DriveSyncKey(keyBytes: Data(repeating: 0x42, count: 32))
        let nonce = Data(repeating: 0xA1, count: 12)
        let ciphertext = Data("sample-ciphertext-bytes".utf8)
        let tag = Data(repeating: 0xB2, count: 16)

        let built = try DriveEnvelope(keyID: key.keyID, nonce: nonce, ciphertext: ciphertext, tag: tag)
        let serialized = built.serialize()
        #expect(serialized.prefix(4) == Data("FNB1".utf8))
        #expect(serialized.count == 4 + 8 + 12 + ciphertext.count + 16)
        #expect(built.aad == serialized.prefix(12))

        let parsed = try DriveEnvelope.parse(serialized)
        #expect(parsed == built)
        #expect(parsed.keyIDHex == "630dcd2966c43366")
        try parsed.verifyKeyID(matches: key)

        #expect(throws: DriveEnvelopeError.keyMismatch(expectedHex: otherKey.keyIDHex, actualHex: key.keyIDHex)) {
            try parsed.verifyKeyID(matches: otherKey)
        }
        #expect(throws: DriveEnvelopeError.truncatedEnvelope(39)) {
            _ = try DriveEnvelope.parse(Data(repeating: 0, count: 39))
        }
        var badMagic = serialized
        badMagic[3] = UInt8(ascii: "2")
        #expect(throws: DriveEnvelopeError.invalidMagic("FNB2")) {
            _ = try DriveEnvelope.parse(badMagic)
        }
    }

    @Test("GoogleDriveClient lists appDataFolder file, downloads bytes, and reports missing Drive scope")
    func driveClientListDownloadAndMissingScope() async throws {
        let now = Date(timeIntervalSince1970: 1_760_000_000)

        // 1. Missing scope detected immediately from stored token scope.
        let gmailOnlyStore = InMemoryTokenStore(tokens: OAuthTokens(
            accessToken: "gmail-only-token",
            refreshToken: "refresh-1",
            expiresAt: now.addingTimeInterval(3600),
            scope: GoogleOAuth.gmailReadOnlyScope
        ))
        let unusedTransport = FakeHTTPTransport()
        let gmailOnlyClient = GoogleDriveClient(
            clientID: sampleClientID,
            tokenStore: gmailOnlyStore,
            transport: unusedTransport,
            sleeper: RecordingSleeper(),
            now: { now }
        )
        await #expect(throws: GoogleDriveClientError.missingDriveScope) {
            _ = try await gmailOnlyClient.listAppDataFiles()
        }
        #expect(await unusedTransport.requests().isEmpty)

        // 2. With drive.appdata scope: lists finance-bundle.fnb and downloads bytes.
        let driveStore = InMemoryTokenStore(tokens: OAuthTokens(
            accessToken: "drive-token",
            refreshToken: "refresh-2",
            expiresAt: now.addingTimeInterval(3600),
            scope: "\(GoogleOAuth.gmailReadOnlyScope) \(GoogleOAuth.driveAppDataScope)"
        ))
        let transport = FakeHTTPTransport()
        await transport.enqueue(try TestJSON.response(json: [
            "files": [
                [
                    "id": "file-abc-123",
                    "name": "finance-bundle.fnb",
                    "modifiedTime": "2026-04-10T09:30:00.000Z",
                    "md5Checksum": "0123456789abcdef0123456789abcdef",
                    "size": "4096",
                ],
            ],
        ]))
        let rawEnvelope = Data("FNB1".utf8) + Data(repeating: 0x11, count: 40)
        await transport.enqueue(HTTPResponse(statusCode: 200, body: rawEnvelope))

        let client = GoogleDriveClient(
            clientID: sampleClientID,
            tokenStore: driveStore,
            transport: transport,
            sleeper: RecordingSleeper(),
            now: { now }
        )

        let files = try await client.listAppDataFiles()
        #expect(files == [
            DriveFileMetadata(
                id: "file-abc-123",
                name: "finance-bundle.fnb",
                modifiedTime: "2026-04-10T09:30:00.000Z",
                md5Checksum: "0123456789abcdef0123456789abcdef",
                size: "4096"
            ),
        ])
        #expect(files[0].sizeBytes == 4096)

        let downloaded = try await client.downloadFile(id: "file-abc-123")
        #expect(downloaded == rawEnvelope)

        let requests = await transport.requests()
        #expect(requests.count == 2)
        let listComponents = try #require(URLComponents(url: requests[0].url, resolvingAgainstBaseURL: false))
        let listQuery = Dictionary(uniqueKeysWithValues: (listComponents.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(listQuery["spaces"] == "appDataFolder")
        #expect(listQuery["fields"] == "files(id,name,modifiedTime,md5Checksum,size)")
        #expect(requests[1].url.absoluteString.contains("/files/file-abc-123?alt=media"))
    }

    @Test("GoogleDriveClient maps HTTP 403 insufficientPermissions to missingDriveScope")
    func driveClientServerInsufficientScope() async throws {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        // Token without stored scope string; server returns 403 insufficientPermissions.
        let store = InMemoryTokenStore(tokens: OAuthTokens(
            accessToken: "tok",
            refreshToken: "ref",
            expiresAt: now.addingTimeInterval(3600),
            scope: nil
        ))
        let transport = FakeHTTPTransport(responses: [
            try TestJSON.response(statusCode: 403, json: [
                "error": [
                    "code": 403,
                    "message": "Request had insufficient authentication scopes.",
                    "status": "PERMISSION_DENIED",
                    "errors": [
                        ["domain": "global", "reason": "insufficientPermissions", "message": "Insufficient Permission"],
                    ],
                ],
            ]),
        ])
        let client = GoogleDriveClient(
            clientID: sampleClientID,
            tokenStore: store,
            transport: transport,
            sleeper: RecordingSleeper(),
            now: { now }
        )

        await #expect(throws: GoogleDriveClientError.missingDriveScope) {
            _ = try await client.listAppDataFiles()
        }
    }
}
