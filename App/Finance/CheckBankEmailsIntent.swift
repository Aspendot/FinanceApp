import AppIntents
import FinanceCore
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

/// Logs a cash, wallet, or Apple Pay tap directly from Apple Shortcuts or Wallet Transaction automations.
struct LogPaymentIntent: AppIntent {
    static let title: LocalizedStringResource = "Log a payment"
    static let description = IntentDescription(
        "Records a cash, wallet, or Apple Pay payment locally in Finance and updates the widget."
    )
    static let supportedModes: IntentModes = .background
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @Parameter(title: "Amount (yen)")
    var amount: Int

    @Parameter(title: "Merchant")
    var merchant: String

    @Parameter(title: "Source", default: "Cash")
    var source: String

    @Parameter(title: "Note")
    var note: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Log ¥\(\.$amount) at \(\.$merchant) via \(\.$source)") {
            \.$note
        }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let trimmedMerchant = merchant.trimmingCharacters(in: .whitespacesAndNewlines)
        guard amount != 0, !trimmedMerchant.isEmpty else {
            return .result(dialog: IntentDialog("Enter an amount and merchant name."))
        }

        let today = JST.day(Date())
        let rules: RuleSet
        if let raw = BundleInbox.storedData(), let bundle = try? DataBundle.decode(from: raw) {
            rules = bundle.rules
        } else {
            rules = RuleSet()
        }
        let categorizer = Categorizer(rules: rules)
        let classified = categorizer.categorize(merchant: trimmedMerchant, amount: amount, date: today)
        let cleanSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = ManualEntry(
            date: today,
            source: cleanSource.isEmpty ? "Cash" : cleanSource,
            merchant: trimmedMerchant,
            amount: amount,
            group: classified.group,
            category: classified.category,
            note: note?.trimmingCharacters(in: .whitespacesAndNewlines),
            origin: .manual
        )

        try LocalDataStore.mutateModifications { mods in
            mods.manualEntries.insert(entry, at: 0)
        }
        try? await SyncEngine.shared.publishCurrentWidget()
        NotificationCenter.default.post(name: .backgroundGmailSyncUpdated, object: nil)

        return .result(dialog: IntentDialog("Logged \(Money.payment(amount)) at \(trimmedMerchant) under \(classified.category)."))
    }
}

/// Speaks or returns the current payday budget status without opening the app.
struct PaydaySummaryIntent: AppIntent {
    static let title: LocalizedStringResource = "Check payday budget"
    static let description = IntentDescription(
        "Reports how much is left until payday, how many days remain, and the next scheduled bill."
    )
    static let supportedModes: IntentModes = .background
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let notices = GmailSync.recentNotices()
        guard let data = await FinanceData.load(notices: notices) else {
            return .result(dialog: IntentDialog("No finance data is loaded yet."))
        }
        guard let payday = data.payday else {
            return .result(dialog: IntentDialog("No upcoming payday is in the current schedule."))
        }
        let leftAmount = data.liveCash?.cashLeftUntilPayday
            ?? data.paydayBreakdown?.estimatedRemainingDiscretionary
            ?? payday.left
        let leftLabel = data.liveCash != nil ? "bank cash left after unpaid bills" : "estimated left after bills"
        var parts = [
            "\(Money.yen(leftAmount)) \(leftLabel), \(FinanceFormat.daysLabel(payday.daysToPayday)) until payday"
        ]
        if let breakdown = data.paydayBreakdown, breakdown.dayToDaySpentSincePayday > 0 {
            parts.append("day-to-day spent \(Money.yen(breakdown.dayToDaySpentSincePayday))")
        }
        if let nextBill = payday.outs.first(where: { $0.done != true && $0.amount > 0 }) {
            parts.append("next bill \(nextBill.item) \(Money.yen(nextBill.amount)) on \(DayText.short(nextBill.date))")
        }
        return .result(dialog: IntentDialog("\(parts.joined(separator: ". "))."))
    }
}

/// Exposes Finance actions in Apple Shortcuts with no setup.
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
        AppShortcut(
            intent: LogPaymentIntent(),
            phrases: [
                "Log a payment in \(.applicationName)",
                "Add cash payment in \(.applicationName)",
            ],
            shortTitle: "Log a payment",
            systemImageName: "plus.circle"
        )
        AppShortcut(
            intent: PaydaySummaryIntent(),
            phrases: [
                "Check payday budget in \(.applicationName)",
                "How much is left until payday in \(.applicationName)",
            ],
            shortTitle: "Payday budget",
            systemImageName: "calendar"
        )
    }
}
