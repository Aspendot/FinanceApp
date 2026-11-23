import Foundation

/// Takes in the data file the owner drops into the app's Documents folder (with the
/// Apple Devices app on Windows, or the Files app). The file is checked, moved into
/// private storage that Files and Apple Devices can't see, and removed from Documents.
enum BundleInbox {
    static let expectedFormat = "finance-bundle/1"

    enum Outcome: Equatable {
        case nothingNew
        case imported(generatedAt: String, items: Int)
        case rejected(String)
    }

    private static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// Where the current data file lives: Application Support, excluded from backups,
    /// protected until the phone is first unlocked after a restart.
    static var storedURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("finance-bundle.json")
    }

    /// The stored data file, if there is one.
    static func storedData() -> Data? {
        try? Data(contentsOf: storedURL)
    }

    /// Looks for a new data file in Documents and takes the newest valid one.
    static func check() -> Outcome {
        let fm = FileManager.default
        let candidates = ((try? fm.contentsOfDirectory(at: documents, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { modified($0) > modified($1) }
        guard let newest = candidates.first else { return .nothingNew }

        guard let data = try? Data(contentsOf: newest),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return .rejected("\(newest.lastPathComponent) isn't readable JSON")
        }
        guard object["format"] as? String == expectedFormat else {
            return .rejected("\(newest.lastPathComponent) isn't a Finance data file")
        }
        let generatedAt = object["generatedAt"] as? String ?? "?"
        if let current = storedData(),
           let stored = try? JSONSerialization.jsonObject(with: current) as? [String: Any],
           let storedAt = stored["generatedAt"] as? String, storedAt > generatedAt {
            try? fm.removeItem(at: newest)
            return .rejected("\(newest.lastPathComponent) is older than the data already imported")
        }
        do {
            try fm.createDirectory(at: storedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: storedURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            var url = storedURL
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
            for file in candidates { try? fm.removeItem(at: file) }
        } catch {
            return .rejected("Could not store the data file: \(error.localizedDescription)")
        }
        return .imported(generatedAt: generatedAt, items: (object["items"] as? [Any])?.count ?? 0)
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}
