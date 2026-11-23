import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Errors thrown while parsing pairing keys or parsing/decrypting `FNB1` Drive envelopes.
public enum DriveEnvelopeError: Error, LocalizedError, Equatable, Sendable {
    case invalidKeyPrefix
    case invalidKeyEncoding
    case invalidKeyLength(Int)
    case truncatedEnvelope(Int)
    case invalidMagic(String)
    case keyMismatch(expectedHex: String, actualHex: String)
    case invalidNonceLength(Int)
    case decryptionFailed

    public var errorDescription: String? {
        switch self {
        case .invalidKeyPrefix:
            return "The sync key must start with \"\(DriveSyncKey.prefix)\"."
        case .invalidKeyEncoding:
            return "The sync key is not valid unpadded base64url."
        case .invalidKeyLength(let count):
            return "The sync key must be \(DriveSyncKey.keyByteCount) bytes (got \(count))."
        case .truncatedEnvelope(let count):
            return "The Drive file is too short to be a valid envelope (\(count) bytes)."
        case .invalidMagic(let got):
            return "Unsupported Drive file header \"\(got)\"; expected \"FNB1\"."
        case .keyMismatch(let expected, let actual):
            return "The Drive file was encrypted with key \(actual), but this phone holds key \(expected)."
        case .invalidNonceLength(let count):
            return "Envelope nonce must be \(DriveEnvelope.nonceLength) bytes (got \(count))."
        case .decryptionFailed:
            return "Could not decrypt the Drive file. Check that this phone has the matching key."
        }
    }
}

/// 256-bit symmetric key shared between the PC exporter and the phone via QR code or paste.
///
/// Pairing string format: `"finance-key:v1:"` + unpadded base64url(32-byte key).
/// Key ID: first 8 bytes of `SHA-256(keyBytes)`.
public struct DriveSyncKey: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public static let prefix = "finance-key:v1:"
    public static let keyByteCount = 32
    public static let keyIDByteCount = 8

    /// Raw 32-byte AES-256 key.
    public let keyBytes: Data
    /// First 8 bytes of `SHA-256(keyBytes)`.
    public let keyID: Data

    public init(keyBytes: Data) throws {
        guard keyBytes.count == Self.keyByteCount else {
            throw DriveEnvelopeError.invalidKeyLength(keyBytes.count)
        }
        self.keyBytes = keyBytes
        self.keyID = Data(SHA256.hash(keyBytes).prefix(Self.keyIDByteCount))
    }

    /// Parses `"finance-key:v1:" + base64url(32-byte key)` (no padding).
    public init(pairingString: String) throws {
        let trimmed = pairingString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(Self.prefix) else {
            throw DriveEnvelopeError.invalidKeyPrefix
        }
        let encoded = String(trimmed.dropFirst(Self.prefix.count))
        guard let decoded = Self.decodeUnpaddedBase64URL(encoded) else {
            throw DriveEnvelopeError.invalidKeyEncoding
        }
        try self.init(keyBytes: decoded)
    }

    /// Generates a new random 256-bit key using the OS CSPRNG.
    public static func generate() throws -> DriveSyncKey {
        try DriveSyncKey(keyBytes: RandomBytes.generate(count: keyByteCount))
    }

    /// Canonical pairing string (`"finance-key:v1:"` + unpadded base64url).
    public var pairingString: String {
        Self.prefix + Base64URLEncoder.encode(keyBytes)
    }

    /// 16 lowercase hex characters identifying this key (safe to display and compare with PC).
    public var keyIDHex: String {
        Self.hexString(keyID)
    }

    /// Spaced 4-character hex groups for easy visual comparison (`"a1b2 c3d4 e5f6 0708"`).
    public var keyIDFormatted: String {
        let hex = keyIDHex
        var groups: [Substring] = []
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 4, limitedBy: hex.endIndex) ?? hex.endIndex
            groups.append(hex[idx..<next])
            idx = next
        }
        return groups.joined(separator: " ")
    }

    public var description: String {
        "DriveSyncKey(keyID: \(keyIDHex), keyBytes: <redacted>)"
    }

    public var debugDescription: String {
        description
    }

    public static func hexString(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// Strict RFC 4648 section 5 unpadded base64url decoder.
    static func decodeUnpaddedBase64URL(_ text: String) -> Data? {
        guard !text.isEmpty, text.count % 4 != 1 else { return nil }
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x41...0x5A, // A-Z
                 0x61...0x7A, // a-z
                 0x30...0x39, // 0-9
                 0x2D,        // -
                 0x5F:        // _
                continue
            default:
                // Rejects '=', '+', '/', whitespace and non-ASCII.
                return nil
            }
        }
        var standard = text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = standard.count % 4
        if remainder > 0 {
            standard += String(repeating: "=", count: 4 - remainder)
        }
        guard let decoded = Data(base64Encoded: standard) else {
            return nil
        }
        // Reject non-canonical trailing bits by verifying round-trip encoding.
        guard Base64URLEncoder.encode(decoded) == text else {
            return nil
        }
        return decoded
    }
}

/// Binary envelope v1 (`FNB1`) used to store `finance-bundle.fnb` in Google Drive `appDataFolder`.
///
/// Layout:
/// - Bytes 0...3: ASCII `"FNB1"`
/// - Bytes 4...11: `keyID` = first 8 bytes of `SHA-256(key)`
/// - Bytes 12...23: 12-byte random AES-GCM nonce
/// - Bytes 24..<(n-16): AES-256-GCM ciphertext (UTF-8 `finance-bundle` JSON)
/// - Last 16 bytes: AES-256-GCM authentication tag
///
/// AAD = bytes 0...11 (`"FNB1"` + 8-byte `keyID`).
public struct DriveEnvelope: Equatable, Sendable {
    public static let magic = Data("FNB1".utf8)
    public static let headerLength = 12
    public static let nonceLength = 12
    public static let tagLength = 16
    public static let minimumLength = headerLength + nonceLength + tagLength

    /// 8-byte key identifier (`SHA-256(key)[0..<8]`).
    public let keyID: Data
    /// 12-byte AES-256-GCM nonce.
    public let nonce: Data
    /// AES-256-GCM ciphertext bytes.
    public let ciphertext: Data
    /// 16-byte AES-256-GCM authentication tag.
    public let tag: Data

    public init(keyID: Data, nonce: Data, ciphertext: Data, tag: Data) throws {
        guard keyID.count == DriveSyncKey.keyIDByteCount else {
            throw DriveEnvelopeError.invalidKeyLength(keyID.count)
        }
        guard nonce.count == Self.nonceLength else {
            throw DriveEnvelopeError.invalidNonceLength(nonce.count)
        }
        guard tag.count == Self.tagLength else {
            throw DriveEnvelopeError.truncatedEnvelope(Self.headerLength + nonce.count + ciphertext.count + tag.count)
        }
        self.keyID = keyID
        self.nonce = nonce
        self.ciphertext = ciphertext
        self.tag = tag
    }

    /// Additional Authenticated Data passed to AES-256-GCM: bytes `0...11` (`"FNB1"` + `keyID`).
    public var aad: Data {
        var out = Data(capacity: Self.headerLength)
        out.append(Self.magic)
        out.append(keyID)
        return out
    }

    /// Hex representation of `keyID`.
    public var keyIDHex: String {
        DriveSyncKey.hexString(keyID)
    }

    /// Parses raw `.fnb` bytes into their envelope fields without decrypting.
    public static func parse(_ data: Data) throws -> DriveEnvelope {
        guard data.count >= minimumLength else {
            throw DriveEnvelopeError.truncatedEnvelope(data.count)
        }
        let headerMagic = data.prefix(4)
        guard headerMagic == magic else {
            let label = String(data: headerMagic, encoding: .ascii) ?? DriveSyncKey.hexString(headerMagic)
            throw DriveEnvelopeError.invalidMagic(label)
        }
        let keyID = Data(data[data.startIndex.advanced(by: 4)..<data.startIndex.advanced(by: 12)])
        let nonce = Data(data[data.startIndex.advanced(by: 12)..<data.startIndex.advanced(by: 24)])
        let tagStart = data.endIndex.advanced(by: -tagLength)
        let ciphertext = Data(data[data.startIndex.advanced(by: 24)..<tagStart])
        let tag = Data(data[tagStart..<data.endIndex])
        return try DriveEnvelope(keyID: keyID, nonce: nonce, ciphertext: ciphertext, tag: tag)
    }

    /// Serializes this envelope back into its exact `FNB1` binary format.
    public func serialize() -> Data {
        var out = Data(capacity: Self.headerLength + Self.nonceLength + ciphertext.count + Self.tagLength)
        out.append(Self.magic)
        out.append(keyID)
        out.append(nonce)
        out.append(ciphertext)
        out.append(tag)
        return out
    }

    /// Verifies that the envelope's 8-byte key ID matches `key`.
    public func verifyKeyID(matches key: DriveSyncKey) throws {
        guard keyID == key.keyID else {
            throw DriveEnvelopeError.keyMismatch(expectedHex: key.keyIDHex, actualHex: keyIDHex)
        }
    }

    #if canImport(CryptoKit)
    /// Encrypts UTF-8 plaintext into an `FNB1` binary envelope using AES-256-GCM.
    public static func seal(
        plaintext: Data,
        key: DriveSyncKey,
        nonce: Data? = nil
    ) throws -> Data {
        let nonceBytes = nonce ?? RandomBytes.generate(count: nonceLength)
        guard nonceBytes.count == nonceLength else {
            throw DriveEnvelopeError.invalidNonceLength(nonceBytes.count)
        }
        var aad = Data(capacity: headerLength)
        aad.append(magic)
        aad.append(key.keyID)

        let symmetricKey = SymmetricKey(data: key.keyBytes)
        let gcmNonce = try AES.GCM.Nonce(data: nonceBytes)
        let sealed = try AES.GCM.seal(plaintext, using: symmetricKey, nonce: gcmNonce, authenticating: aad)
        let envelope = try DriveEnvelope(
            keyID: key.keyID,
            nonce: nonceBytes,
            ciphertext: sealed.ciphertext,
            tag: sealed.tag
        )
        return envelope.serialize()
    }

    /// Parses, verifies the key ID, and decrypts an `FNB1` binary envelope using AES-256-GCM.
    public static func open(_ envelopeData: Data, key: DriveSyncKey) throws -> Data {
        let envelope = try parse(envelopeData)
        try envelope.verifyKeyID(matches: key)
        do {
            let gcmNonce = try AES.GCM.Nonce(data: envelope.nonce)
            let box = try AES.GCM.SealedBox(
                nonce: gcmNonce,
                ciphertext: envelope.ciphertext,
                tag: envelope.tag
            )
            let symmetricKey = SymmetricKey(data: key.keyBytes)
            return try AES.GCM.open(box, using: symmetricKey, authenticating: envelope.aad)
        } catch {
            throw DriveEnvelopeError.decryptionFailed
        }
    }
    #endif
}
