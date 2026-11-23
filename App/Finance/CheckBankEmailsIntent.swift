import AppIntents
import Foundation

/// Shortcuts action that syncs Drive, Gmail and Money Forward in the background without opening the app.
struct CheckBankEmailsIntent: AppIntent {
    static let title: LocalizedStringResource = "Check bank emails"
    static let description = IntentDescription(
        "Syncs the encrypted Drive data file, recent bank emails and Money Forward transactions, then updates the Finance widget."
    )
    static let supportedModes: IntentModes = .background
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let report = await BackgroundAssertion.run(name: "FinanceShortcutSync") {
            await SyncEngine.shared.run(trigger: .shortcut, minimumInterval: 180, timeLimit: 25)
        }
        let message: String
        switch report.outcome {
        case .updated:
            if report.newBankTransactions > 0 {
                let word = report.newBankTransactions == 1 ? "new transaction" : "new transactions"
                message = "\(report.newBankTransactions) \(word)"
            } else if report.newPayments == 1 {
                message = "1 new payment"
            } else if report.newPayments > 1 {
                message = "\(report.newPayments) new payments"
            } else if report.driveImported {
                message = "Updated data file"
            } else {
                message = "Up to date"
            }
        case .skipped:
            message = "Up to date"
        case .notSignedIn:
            message = "No accounts connected"
        case .signInRequired:
            message = "Sign in to Gmail again"
        case .busy:
            message = "Sync already running"
        case .timedOut:
            if report.newPayments == 1 {
                message = "1 new payment so far"
            } else if report.newPayments > 1 {
                message = "\(report.newPayments) new payments so far"
            } else {
                message = "Sync timed out"
            }
        case .cancelled:
            message = "Sync cancelled"
        case .failed:
            message = "Could not sync Finance"
        }
        return .result(dialog: IntentDialog("\(message)"))
    }
}

/// Exposes the Gmail check action in Apple Shortcuts with no setup.
struct FinanceShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CheckBankEmailsIntent(),
            phrases: [
                "Check bank emails in \(.applicationName)",
                "Sync bank emails with \(.applicationName)",
            ],
            shortTitle: "Check bank emails",
            systemImageName: "envelope.badge"
        )
    }
}
