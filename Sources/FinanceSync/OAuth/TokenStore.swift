import Foundation
#if canImport(Security)
import Security
#endif

/// Errors thrown by `TokenStore` implementations.
public enum TokenStoreError: Error, LocalizedError, Equatable, Sendable {
    /// Stored tokens could not be encoded for persistence.
    case encodingFailed
    /// Stored tokens could not be decoded from persistence.
    case decodingFailed
    /// A Keychain operation failed with the given `OSStatus`.
    case keychainFailure(operation: String, status: Int32)

    public var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Could not encode OAuth tokens for storage."
        case .decodingFailed:
            return "Could not decode OAuth tokens from storage."
        case .keychainFailure(let operation, let status):
            return "Keychain \(operation) failed with status \(status)."
        }
    }
}

/// Persistent or transient storage for Google OAuth tokens.
public protocol TokenStore: Sendable {
    /// Loads the currently stored tokens, or `nil` if no tokens are saved.
    func load() async throws -> OAuthTokens?
    /// Saves or replaces the stored tokens.
    func save(_ tokens: OAuthTokens) async throws
    /// Removes any stored tokens.
    func clear() async throws
}

/// Thread-safe in-memory `TokenStore`, intended for tests and ephemeral sessions.
public actor InMemoryTokenStore: TokenStore {
    private var tokens: OAuthTokens?

    public init(tokens: OAuthTokens? = nil) {
        self.tokens = tokens
    }

    public func load() async throws -> OAuthTokens? {
        tokens
    }

    public func save(_ tokens: OAuthTokens) async throws {
        self.tokens = tokens
    }

    public func clear() async throws {
        tokens = nil
    }
}

#if canImport(Security)
/// Apple Keychain `TokenStore` backed by `kSecClassGenericPassword`.
///
/// Uses `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` so background syncs
/// can read tokens while the device is locked without migrating credentials
/// across devices via backups.
public struct KeychainTokenStore: TokenStore, Sendable {
    /// Keychain service identifier (`kSecAttrService`).
    public let service: String
    /// Keychain account identifier (`kSecAttrAccount`).
    public let account: String
    /// Optional Keychain access group (`kSecAttrAccessGroup`).
    public let accessGroup: String?

    public init(
        service: String = "FinanceApp.GmailOAuth",
        account: String = "default",
        accessGroup: String? = nil
    ) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
    }

    public func load() throws -> OAuthTokens? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw TokenStoreError.keychainFailure(operation: "read", status: status)
        }
        guard let data = item as? Data else {
            throw TokenStoreError.decodingFailed
        }
        do {
            return try JSONDecoder().decode(OAuthTokens.self, from: data)
        } catch {
            throw TokenStoreError.decodingFailed
        }
    }

    public func save(_ tokens: OAuthTokens) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(tokens)
        } catch {
            throw TokenStoreError.encodingFailed
        }

        var addQuery = baseQuery()
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecSuccess {
            return
        }
        guard addStatus == errSecDuplicateItem else {
            throw TokenStoreError.keychainFailure(operation: "save", status: addStatus)
        }

        let updateAttributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(baseQuery() as CFDictionary, updateAttributes as CFDictionary)
        guard updateStatus == errSecSuccess else {
            throw TokenStoreError.keychainFailure(operation: "update", status: updateStatus)
        }
    }

    public func clear() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TokenStoreError.keychainFailure(operation: "delete", status: status)
        }
    }

    private func baseQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }
}
#endif
