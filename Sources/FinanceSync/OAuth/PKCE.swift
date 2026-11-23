import Foundation

/// A PKCE verifier and its S256 challenge (RFC 7636).
public struct PKCE: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    /// The challenge method sent in the OAuth authorization request.
    public static let challengeMethod = "S256"
    /// Minimum allowed verifier length per RFC 7636 section 4.1.
    public static let minVerifierLength = 43
    /// Maximum allowed verifier length per RFC 7636 section 4.1.
    public static let maxVerifierLength = 128

    /// The secret code verifier sent when exchanging the authorization code.
    public let verifier: String
    /// The base64url-encoded SHA-256 digest of the ASCII verifier.
    public let challenge: String

    /// Creates a PKCE pair from an existing verifier.
    ///
    /// Throws `OAuthError.invalidPKCEVerifier` if the verifier length is outside
    /// 43 to 128 characters or contains characters outside `[A-Za-z0-9-._~]`.
    public init(verifier: String) throws {
        guard Self.isValidVerifier(verifier) else {
            throw OAuthError.invalidPKCEVerifier
        }
        self.verifier = verifier
        self.challenge = Base64URLEncoder.encode(SHA256.hash(Data(verifier.utf8)))
    }

    /// Generates a new random PKCE pair using the system CSPRNG.
    ///
    /// `byteCount` must be between 32 and 96 so the base64url verifier is
    /// between 43 and 128 characters long. Defaults to 32 bytes (43 characters).
    public static func generate(byteCount: Int = 32) throws -> PKCE {
        guard (32...96).contains(byteCount) else {
            throw OAuthError.invalidPKCEVerifier
        }
        let verifier = Base64URLEncoder.encode(RandomBytes.generate(count: byteCount))
        return try PKCE(verifier: verifier)
    }

    /// Validates a verifier against RFC 7636 section 4.1.
    public static func isValidVerifier(_ verifier: String) -> Bool {
        let count = verifier.unicodeScalars.count
        guard (minVerifierLength...maxVerifierLength).contains(count) else {
            return false
        }
        for scalar in verifier.unicodeScalars {
            guard isUnreserved(scalar) else {
                return false
            }
        }
        return true
    }

    private static func isUnreserved(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x41...0x5A, // A-Z
             0x61...0x7A, // a-z
             0x30...0x39, // 0-9
             0x2D,        // -
             0x2E,        // .
             0x5F,        // _
             0x7E:        // ~
            return true
        default:
            return false
        }
    }

    public var description: String {
        "PKCE(challengeMethod: \(Self.challengeMethod), verifier: <redacted>)"
    }

    public var debugDescription: String {
        description
    }
}
