import FinanceCore
import Foundation

/// Loads the bundled invented demo data used when the app launches with `-demo`.
enum DemoData {
    struct Loaded {
        let data: FinanceData
        let today: String
        let runLog: [SyncRunRecord]
    }

    /// Fixed Japan-time anchor day matching the invented timeline and pending notices.
    static let anchorToday = "2026-04-14"

    static func load() -> Loaded? {
        guard let bundleURL = Bundle.main.url(forResource: "demo-bundle", withExtension: "json"),
              let bundleRaw = try? Data(contentsOf: bundleURL),
              let bundle = try? DataBundle.decode(from: bundleRaw)
        else {
            return nil
        }

        let notices: [Notice]
        if let noticesURL = Bundle.main.url(forResource: "demo-notices", withExtension: "json"),
           let noticesRaw = try? Data(contentsOf: noticesURL),
           let decoded = try? JSONDecoder().decode([Notice].self, from: noticesRaw) {
            notices = decoded
        } else {
            notices = []
        }

        let data = FinanceData(bundle: bundle, notices: notices, today: anchorToday)
        let now = Date()
        let runLog = [
            SyncRunRecord(
                trigger: .background,
                startedAt: now.addingTimeInterval(-42 * 60),
                durationSeconds: 2.1,
                outcome: .updated,
                newNotices: 2,
                newPayments: 2,
                notifiedCount: 0
            ),
            SyncRunRecord(
                trigger: .app,
                startedAt: now.addingTimeInterval(-4 * 3600),
                durationSeconds: 1.4,
                outcome: .skipped
            )
        ]

        return Loaded(data: data, today: anchorToday, runLog: runLog)
    }
}
