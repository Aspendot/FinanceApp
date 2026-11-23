import FinanceCore
import Foundation

/// Imports a complete bundle from the Documents folder used by Apple Devices and Files.
enum BundleInbox {
    enum Outcome: Equatable {
        case nothingNew
        case imported(generatedAt: String, items: Int, cleanupFailed: Bool)
        case rejected(String)
    }

    private struct FileStamp: Equatable {
        let size: Int
        let modified: Date
        let number: UInt64?
    }

    private struct Candidate {
        let url: URL
        let stamp: FileStamp
        let bytes: Data
        let bundle: DataBundle
        let date: Date
    }

    private static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    private static var storage: URL { support.appendingPathComponent("FinanceData", isDirectory: true) }
    private static var storedURL: URL { storage.appendingPathComponent("finance-bundle.json") }
    private static var legacyURL: URL { support.appendingPathComponent("finance-bundle.json") }

    static func storedData() -> Data? { try? readStoredData() }

    /// Called by the app model's single import task, off the main actor.
    static func check() async -> Outcome {
        let fm = FileManager.default
        let files: [URL]
        do {
            files = try fm.contentsOfDirectory(at: documents, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension.lowercased() == "json" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            return .rejected("Could not open the data file inbox.")
        }
        let initial = files.compactMap { url in stamp(url).map { (url, $0) } }
        guard !initial.isEmpty else { return .nothingNew }

        // A transfer may still be writing the file when the app becomes active.
        try? await Task.sleep(for: .seconds(1))
        let candidates = initial.compactMap { url, original -> Candidate? in
            guard stamp(url) == original, let bytes = try? Data(contentsOf: url),
                  bytes.count == original.size, stamp(url) == original,
                  let bundle = try? DataBundle.decode(from: bytes),
                  let date = timestamp(bundle.generatedAt)
            else { return nil }
            return Candidate(url: url, stamp: original, bytes: bytes, bundle: bundle, date: date)
        }

        guard let newest = candidates.max(by: { $0.date < $1.date }) else {
            return .rejected("No complete Finance data file found. If it’s still copying, check again when it finishes.")
        }

        let isNew: Bool
        do {
            let current = try readStoredData()
            let storedDate = current.flatMap { try? DataBundle.decode(from: $0) }.flatMap { timestamp($0.generatedAt) }
            isNew = storedDate.map { newest.date > $0 } ?? true
            if isNew {
                var folder = storage
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try folder.setResourceValues(values)
                try newest.bytes.write(to: storedURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                try? fm.removeItem(at: legacyURL)
            }
        } catch {
            return .rejected("Could not store the data file.")
        }

        // Only remove bundles we validated. A transfer may have replaced a file since then.
        var cleanupFailed = false
        for candidate in candidates where stamp(candidate.url) == candidate.stamp {
            do {
                try fm.removeItem(at: candidate.url)
            } catch {
                cleanupFailed = true
            }
        }
        if isNew {
            return .imported(generatedAt: newest.bundle.generatedAt, items: newest.bundle.items.count, cleanupFailed: cleanupFailed)
        }
        return .rejected(cleanupFailed
            ? "The file is already imported or older, and a copy remains in Finance’s Documents folder."
            : "The data file is already imported or older than the stored data.")
    }

    private static func readStoredData() throws -> Data? {
        do {
            return try Data(contentsOf: storedURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // Keep reading files imported by earlier versions.
            do {
                return try Data(contentsOf: legacyURL)
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                return nil
            }
        }
    }

    private static func stamp(_ url: URL) -> FileStamp? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              attrs[.type] as? FileAttributeType == .typeRegular,
              let size = attrs[.size] as? NSNumber,
              let modified = attrs[.modificationDate] as? Date
        else { return nil }
        return FileStamp(size: size.intValue, modified: modified, number: (attrs[.systemFileNumber] as? NSNumber)?.uint64Value)
    }

    private static func timestamp(_ value: String) -> Date? {
        let format = ISO8601DateFormatter()
        if let date = format.date(from: value) { return date }
        format.formatOptions.insert(.withFractionalSeconds)
        return format.date(from: value)
    }
}
