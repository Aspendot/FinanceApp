import CryptoKit
import FinanceCore
import Foundation
import Security

/// User preferences for local notifications (payment alerts, declines and bill reminders).
struct NotificationPreferences: Codable, Equatable, Sendable {
    var paymentAlertsEnabled: Bool = true
    var declineAlertsEnabled: Bool = true
    var billRemindersEnabled: Bool = true
    /// Days before due date to remind (0 = morning of due date, 1 = day before, 2 = two days before).
    var billReminderDaysBefore: Int = 1
    /// Hour in Japan time (0...23) for scheduled bill reminders.
    var billReminderHourJST: Int = 9

    static let `default` = NotificationPreferences()
}

/// Atomic file-protected storage for phone-local manual entries, CSV imports,
/// category overrides, bill checkoffs and notification preferences.
enum LocalDataStore {
    private static let lock = NSLock()

    private static var dataDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FinanceData", isDirectory: true)
    }

    private static var modificationsURL: URL {
        dataDirectory.appendingPathComponent("local-modifications.json")
    }

    private static var notificationPrefsURL: URL {
        dataDirectory.appendingPathComponent("notification-prefs.json")
    }

    private static func ensureDirectory() throws {
        var folder = dataDirectory
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
    }

    private static func writeProtected(_ data: Data, to url: URL) throws {
        try ensureDirectory()
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func loadModifications() -> LocalModifications {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: modificationsURL),
              let decoded = try? JSONDecoder().decode(LocalModifications.self, from: data)
        else {
            return LocalModifications()
        }
        return decoded
    }

    static func saveModifications(_ mods: LocalModifications) throws {
        lock.lock()
        defer { lock.unlock() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(mods)
        try writeProtected(data, to: modificationsURL)
    }

    static func loadNotificationPreferences() -> NotificationPreferences {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: notificationPrefsURL),
              let decoded = try? JSONDecoder().decode(NotificationPreferences.self, from: data)
        else {
            return .default
        }
        return decoded
    }

    static func saveNotificationPreferences(_ prefs: NotificationPreferences) throws {
        lock.lock()
        defer { lock.unlock() }
        let data = try JSONEncoder().encode(prefs)
        try writeProtected(data, to: notificationPrefsURL)
    }
}

/// Encrypted local backup format (`FINB1`) sealed with AES-256-GCM using a user passphrase.
enum LocalBackupCodec {
    private static let magic = Data("FINB1".utf8)
    private static let saltLength = 16
    private static let keyDerivationRounds = 120_000

    enum BackupError: Error, LocalizedError {
        case emptyPassphrase
        case invalidFormat
        case decryptionFailed

        var errorDescription: String? {
            switch self {
            case .emptyPassphrase:
                return "Enter a passphrase to protect the backup."
            case .invalidFormat:
                return "This file is not a supported Finance backup."
            case .decryptionFailed:
                return "Could not unlock the backup. Check the passphrase and try again."
            }
        }
    }

    /// Encrypts `LocalModifications` with a salted key derived from `passphrase`.
    static func seal(_ modifications: LocalModifications, passphrase: String) throws -> Data {
        let clean = passphrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw BackupError.emptyPassphrase }

        let plaintext = try JSONEncoder().encode(modifications)
        var salt = Data(count: saltLength)
        let status = salt.withUnsafeMutableBytes { ptr in
            SecRandomCopyBytes(kSecRandomDefault, saltLength, ptr.baseAddress!)
        }
        guard status == errSecSuccess else { throw BackupError.invalidFormat }

        let key = deriveKey(passphrase: clean, salt: salt)
        let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: magic + salt)
        guard let combined = sealed.combined else { throw BackupError.invalidFormat }

        var output = Data()
        output.append(magic)
        output.append(salt)
        output.append(combined)
        return output
    }

    /// Decrypts a `FINB1` backup envelope back into `LocalModifications`.
    static func open(_ data: Data, passphrase: String) throws -> LocalModifications {
        let clean = passphrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw BackupError.emptyPassphrase }

        let headerLen = magic.count + saltLength
        guard data.count > headerLen + 28, data.prefix(magic.count) == magic else {
            throw BackupError.invalidFormat
        }
        let salt = data[magic.count..<headerLen]
        let combined = data[headerLen...]
        let key = deriveKey(passphrase: clean, salt: Data(salt))

        do {
            let box = try AES.GCM.SealedBox(combined: combined)
            let plaintext = try AES.GCM.open(box, using: key, authenticating: magic + salt)
            return try JSONDecoder().decode(LocalModifications.self, from: plaintext)
        } catch {
            throw BackupError.decryptionFailed
        }
    }

    /// Iterated HMAC-SHA256 stretching + HKDF to produce a 256-bit AES key without extra dependencies.
    private static func deriveKey(passphrase: String, salt: Data) -> SymmetricKey {
        let pwData = Data(passphrase.utf8)
        let macKey = SymmetricKey(data: pwData)
        var block = Data(HMAC<SHA256>.authenticationCode(for: salt + Data([0, 0, 0, 1]), using: macKey))
        var result = block
        for _ in 1..<keyDerivationRounds {
            block = Data(HMAC<SHA256>.authenticationCode(for: block, using: macKey))
            for i in 0..<result.count {
                result[i] ^= block[i]
            }
        }
        return SymmetricKey(data: result)
    }
}
