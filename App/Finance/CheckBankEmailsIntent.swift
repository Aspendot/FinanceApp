import AppIntents
import Foundation

/// Shortcuts action that checks Gmail in the background without opening the app.
struct CheckBankEmailsIntent: AppIntent {
    static let title: LocalizedStringResource = "Check bank emails"
    static let description = IntentDescription(
        "Checks Gmail for recent bank and card notices and updates the Finance widget."
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
            if report.newPayments == 1 {
                message = "1 new payment"
            } else if report.newPayments > 1 {
                message = "\(report.newPayments) new payments"
            } else {
                message = "Up to date"
            }
        case .skipped:
            message = "Up to date"
        case .notSignedIn:
            message = "Not signed in to Gmail"
        case .signInRequired:
            message = "Sign in to Gmail again"
        case .busy:
            message = "Already checking bank emails"
        case .timedOut:
            if report.newPayments == 1 {
                message = "1 new payment"
            } else if report.newPayments > 1 {
                message = "\(report.newPayments) new payments"
            } else {
                message = "Checked recent bank emails"
            }
        case .cancelled:
            message = "Check cancelled"
        case .failed:
            message = "Could not check bank emails"
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
