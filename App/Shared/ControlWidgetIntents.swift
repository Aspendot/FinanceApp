import AppIntents
import Foundation

/// AppIntent compiled into both the main app and widget extension for Control Center / Lock Screen quick-add.
struct OpenQuickAddIntent: AppIntent {
    static let title: LocalizedStringResource = "Add payment"
    static let description = IntentDescription("Opens Finance directly to Add payment.")
    static let openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        SharedStore.setPendingAction("quick-add")
        await MainActor.run {
            NotificationCenter.default.post(name: .financePendingControlAction, object: "quick-add")
        }
        return .result()
    }
}

/// AppIntent compiled into both the main app and widget extension for Control Center / Lock Screen receipt scanning.
struct OpenScanReceiptIntent: AppIntent {
    static let title: LocalizedStringResource = "Scan receipt"
    static let description = IntentDescription("Opens Finance directly to the receipt and slip scanner.")
    static let openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        SharedStore.setPendingAction("scan-receipt")
        await MainActor.run {
            NotificationCenter.default.post(name: .financePendingControlAction, object: "scan-receipt")
        }
        return .result()
    }
}
