import Foundation

enum Base64URL {
    /// Decodes a base64url string (RFC 4648 section 5) into raw bytes.
    static func decode(_ input: String) -> Data? {
        var standard = String()
        standard.reserveCapacity(input.count + 2)
        for scalar in input.unicodeScalars {
            switch scalar {
            case " ", "\t", "\r", "\n":
                continue
            case "-":
                standard.append("+")
            case "_":
                standard.append("/")
            default:
                guard scalar.isASCII else { return nil }
                standard.append(Character(scalar))
            }
        }
        if standard.isEmpty {
            return Data()
        }
        let remainder = standard.count % 4
        if remainder == 1 {
            return nil
        }
        if remainder > 0 {
            standard.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: standard)
    }
}
