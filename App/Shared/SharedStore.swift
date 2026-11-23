import Foundation

/// What the app shows in its widget.
struct WidgetSnapshot: Codable, Equatable, Sendable {
    var title: String
    var value: String
    var detail: String
    var updatedAt: Date

    static let placeholder = WidgetSnapshot(title: "Finance", value: "–", detail: "Open the app to sync", updatedAt: .distantPast)
}

/// Data shared between the app and its widget through an App Group.
enum SharedStore {
    /// The App Group this install can actually use, or nil if it has none.
    ///
    /// SideStore can rename App Groups when it signs the app with a free Apple ID, so
    /// the compiled name is only one candidate. The others are any groups listed under
    /// `ALTAppGroups` in Info.plist (written by AltStore-family installers) and a
    /// name derived from the installed bundle ID. The first group whose container
    /// exists wins.
    static let groupID: String? = {
        var candidates: [String] = []
        if let listed = Bundle.main.object(forInfoDictionaryKey: "ALTAppGroups") as? [String] {
            candidates += listed
        }
        if let compiled = Bundle.main.object(forInfoDictionaryKey: "FinanceAppGroup") as? String {
            candidates.append(compiled)
        }
        if let bundleID = Bundle.main.bundleIdentifier {
            let base = bundleID.hasSuffix(".widget") ? String(bundleID.dropLast(".widget".count)) : bundleID
            candidates.append("group." + base)
        }
        return candidates.first {
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) != nil
        }
    }()

    static var defaults: UserDefaults? {
        groupID.flatMap { UserDefaults(suiteName: $0) }
    }

    private static let snapshotKey = "widgetSnapshot"

    static func write(_ snapshot: WidgetSnapshot) {
        guard let defaults, let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: snapshotKey)
    }

    static func read() -> WidgetSnapshot? {
        guard let data = defaults?.data(forKey: snapshotKey) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }
}
