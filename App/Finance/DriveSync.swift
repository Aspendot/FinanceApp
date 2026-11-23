import FinanceCore
import FinanceSync
import Foundation
import Security

/// Persisted state for encrypted Google Drive bundle sync.
struct DriveSyncState: Codable, Equatable, Sendable {
    var lastImportedMD5: String? = nil
    var lastImportedFileID: String? = nil
    var lastImportedModifiedTime: String? = nil
    var lastImportedGeneratedAt: String? = nil
    var lastCheckedAt: Date? = nil
    var lastErrorMessage: String? = nil
    var needsDriveConsent: Bool = false
}

/// Keychain storage for the 32-byte Drive encryption key (`AfterFirstUnlockThisDeviceOnly`).
struct KeychainDriveKeyStore: Sendable {
    let service: String
    let account: String

    init(service: String = "FinanceApp.DriveSyncKey", account: String = "default") {
        self.service = service
        self.account = account
    }

    func load() throws -> DriveSyncKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw TokenStoreError.keychainFailure(operation: "read", status: status)
        }
        guard let data = item as? Data else {
            throw TokenStoreError.decodingFailed
        }
        return try DriveSyncKey(keyBytes: data)
    }

    func save(_ key: DriveSyncKey) throws {
        var addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: key.keyBytes,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecSuccess { return }
        guard addStatus == errSecDuplicateItem else {
            throw TokenStoreError.keychainFailure(operation: "save", status: addStatus)
        }

        addQuery.removeValue(forKey: kSecValueData as String)
        addQuery.removeValue(forKey: kSecAttrAccessible as String)
        let updateAttributes: [String: Any] = [
            kSecValueData as String: key.keyBytes,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(addQuery as CFDictionary, updateAttributes as CFDictionary)
        guard updateStatus == errSecSuccess else {
            throw TokenStoreError.keychainFailure(operation: "update", status: updateStatus)
        }
    }

    func clear() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TokenStoreError.keychainFailure(operation: "delete", status: status)
        }
    }
}

/// App-local atomic file storage for Drive sync metadata.
enum DriveSyncStore {
    private static var dataDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FinanceData", isDirectory: true)
    }

    private static var stateURL: URL {
        dataDirectory.appendingPathComponent("drive-sync-state.json")
    }

    static func loadState() throws -> DriveSyncState {
        do {
            let data = try Data(contentsOf: stateURL)
            return try JSONDecoder().decode(DriveSyncState.self, from: data)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return DriveSyncState()
        }
    }

    static func saveState(_ state: DriveSyncState) throws {
        var folder = dataDirectory
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        let data = try JSONEncoder().encode(state)
        try data.write(to: stateURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func clearState() throws {
        do {
            try FileManager.default.removeItem(at: stateURL)
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            // Nothing stored yet.
        }
    }
}

/// Encrypted Google Drive `appDataFolder` sync helpers.
enum DriveSync {
    enum Outcome: Equatable, Sendable {
        case disabled
        case needsConsent
        case noFile
        case upToDate
        case imported(generatedAt: String, items: Int)
        case notNewer
    }

    static func loadKey() throws -> DriveSyncKey? {
        try KeychainDriveKeyStore().load()
    }

    static func hasKey() -> Bool {
        (try? loadKey()) != nil
    }

    static func currentKeyIDFormatted() -> String? {
        (try? loadKey())?.keyIDFormatted
    }

    static func saveKey(_ key: DriveSyncKey) throws {
        try KeychainDriveKeyStore().save(key)
        var state = (try? DriveSyncStore.loadState()) ?? DriveSyncState()
        // Force a fresh check with the newly paired key if a file was previously skipped.
        state.lastImportedMD5 = nil
        state.lastErrorMessage = nil
        try? DriveSyncStore.saveState(state)
    }

    static func clearKey() throws {
        try KeychainDriveKeyStore().clear()
        try DriveSyncStore.clearState()
    }

    /// Requests incremental Google OAuth consent adding `drive.appdata`.
    @MainActor
    static func turnOnDriveSync() async throws {
        guard let clientID = GmailSync.clientID else {
            throw GmailSync.SyncProblem.noClientID
        }
        try await GmailSync.signIn(
            clientID: clientID,
            scopes: [GoogleOAuth.gmailReadOnlyScope, GoogleOAuth.driveAppDataScope],
            includeGrantedScopes: true
        )
        var state = (try? DriveSyncStore.loadState()) ?? DriveSyncState()
        state.needsDriveConsent = !GmailSync.hasDriveScope()
        state.lastErrorMessage = nil
        try? DriveSyncStore.saveState(state)
    }

    /// Checks Google Drive's `appDataFolder` for `finance-bundle.fnb`, downloading and
    /// decrypting only when `md5Checksum` changed since the last import.
    static func checkAndImport(
        client: GoogleDriveClient,
        key: DriveSyncKey,
        now: Date = Date()
    ) async throws -> Outcome {
        var state = (try? DriveSyncStore.loadState()) ?? DriveSyncState()
        let files: [DriveFileMetadata]
        do {
            files = try await client.listAppDataFiles(name: GoogleDriveClient.bundleFileName)
        } catch let error as GoogleDriveClientError where error.requiresDriveConsent {
            state.needsDriveConsent = true
            state.lastErrorMessage = error.localizedDescription
            try? DriveSyncStore.saveState(state)
            return .needsConsent
        } catch {
            state.lastErrorMessage = diagnostic(for: error)
            try? DriveSyncStore.saveState(state)
            throw error
        }

        state.needsDriveConsent = false
        guard let newest = files.first else {
            state.lastCheckedAt = now
            state.lastErrorMessage = nil
            try? DriveSyncStore.saveState(state)
            return .noFile
        }

        if let md5 = newest.md5Checksum, !md5.isEmpty, md5 == state.lastImportedMD5 {
            state.lastCheckedAt = now
            state.lastErrorMessage = nil
            try? DriveSyncStore.saveState(state)
            return .upToDate
        }

        let encrypted: Data
        do {
            encrypted = try await client.downloadFile(id: newest.id)
        } catch {
            state.lastErrorMessage = diagnostic(for: error)
            try? DriveSyncStore.saveState(state)
            throw error
        }

        let plaintext: Data
        do {
            plaintext = try DriveEnvelope.open(encrypted, key: key)
        } catch {
            state.lastErrorMessage = error.localizedDescription
            try? DriveSyncStore.saveState(state)
            throw error
        }

        let stored: BundleInbox.StoreOutcome
        do {
            stored = try BundleInbox.storeIfNewer(plaintext)
        } catch {
            state.lastErrorMessage = "Downloaded Drive bundle is invalid."
            try? DriveSyncStore.saveState(state)
            throw error
        }

        state.lastImportedMD5 = newest.md5Checksum
        state.lastImportedFileID = newest.id
        state.lastImportedModifiedTime = newest.modifiedTime
        state.lastCheckedAt = now
        state.lastErrorMessage = nil
        switch stored {
        case .imported(let generatedAt, let items):
            state.lastImportedGeneratedAt = generatedAt
            try? DriveSyncStore.saveState(state)
            return .imported(generatedAt: generatedAt, items: items)
        case .notNewer:
            try? DriveSyncStore.saveState(state)
            return .notNewer
        }
    }

    static func diagnostic(for error: any Error) -> String {
        if let envelopeError = error as? DriveEnvelopeError {
            return envelopeError.localizedDescription
        }
        if let driveError = error as? GoogleDriveClientError {
            switch driveError {
            case .missingDriveScope:
                return "Drive access not granted yet."
            case .httpError(let status, _):
                return "Google Drive request failed (HTTP \(status))."
            case .networkError:
                return "Could not reach Google Drive."
            default:
                return driveError.localizedDescription
            }
        }
        return "Drive sync failed."
    }
}
