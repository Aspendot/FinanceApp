import FinanceCore
import SwiftUI

struct MoreView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var session: AppSession
    @AppStorage("faceIDLock") private var faceIDLock = true

    private var activeData: FinanceData? {
        session.resolvedData(from: model)
    }

    private var dataSummaryLine: String? {
        guard let data = activeData else { return nil }
        var parts = [
            "Statements through \(DayText.long(data.bundle.asOf))",
            "\(data.allItems.count.formatted()) items"
        ]
        if data.pendingCount > 0 {
            parts.append("\(data.pendingCount) pending")
        }
        return parts.joined(separator: " · ")
    }

    private var localDataSummary: String {
        let mods = model.localModifications
        let total = mods.manualEntries.count + mods.importedEntries.count
        var parts: [String] = []
        if total > 0 { parts.append("\(total) local") }
        if !mods.categoryOverrides.isEmpty { parts.append("\(mods.categoryOverrides.count) rules") }
        return parts.isEmpty ? "PayPay CSV, overrides, backup" : parts.joined(separator: " · ")
    }

    private var notificationsSummary: String {
        let p = model.notificationPreferences
        var enabled: [String] = []
        if p.paymentAlertsEnabled { enabled.append("Payments") }
        if p.declineAlertsEnabled { enabled.append("Declines") }
        if p.billRemindersEnabled { enabled.append("Bills") }
        return enabled.isEmpty ? "All off" : enabled.joined(separator: " · ")
    }

    private var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?"
    }

    var body: some View {
        NavigationStack(path: $session.morePath) {
            List {
                ConnectionsSection(footerText: dataSummaryLine)

                Section {
                    NavigationLink(value: MoreDestination.notifications) {
                        moreRow(title: "Notifications & bill reminders", subtitle: notificationsSummary)
                    }
                    NavigationLink(value: MoreDestination.localData) {
                        moreRow(title: "Imports, rules & backup", subtitle: localDataSummary)
                    }
                    NavigationLink(value: MoreDestination.syncHealth) {
                        moreRow(title: "Sync health & coverage", subtitle: "Statement cutoffs and recent sync log")
                    }
                } header: {
                    SectionLabel("App & Data")
                }
                .listRowBackground(Theme.surface)

                Section {
                    Toggle("Lock with Face ID", isOn: $faceIDLock)
                        .font(.subheadline)
                        .foregroundStyle(Theme.ink)
                        .tint(Theme.accent)
                } header: {
                    SectionLabel("Privacy")
                }
                .listRowBackground(Theme.surface)

                Section {
                    NavigationLink(value: MoreDestination.diagnostics) {
                        Text("Setup and tests")
                            .font(.subheadline)
                            .foregroundStyle(Theme.ink)
                    }
                } header: {
                    SectionLabel("Diagnostics")
                } footer: {
                    Text("Google sign-in, widget, notifications and background refresh.")
                        .font(.footnote)
                        .foregroundStyle(Theme.muted)
                }
                .listRowBackground(Theme.surface)

                Section {
                    SettingsValueRow(label: "Version", value: appVersion)
                    if session.isDemo {
                        SettingsValueRow(label: "Mode", value: "Demo data")
                    }
                } header: {
                    SectionLabel("About")
                }
                .listRowBackground(Theme.surface)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.page)
            .navigationTitle("More")
            .navigationDestination(for: MoreDestination.self) { destination in
                switch destination {
                case .gmail:
                    GmailSettingsView()
                case .moneyForward:
                    MoneyForwardSettingsView()
                case .drive:
                    DriveSyncSettingsView()
                case .notifications:
                    NotificationSettingsView()
                case .localData:
                    LocalDataSettingsView()
                case .syncHealth:
                    SyncHealthView()
                case .diagnostics:
                    SpikeView()
                }
            }
            .onAppear {
                if !session.isDemo {
                    model.refreshRunLog()
                }
            }
        }
    }

    private func moreRow(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.ink)
            Text(subtitle)
                .font(.footnote)
                .foregroundStyle(Theme.muted)
        }
        .padding(.vertical, 2)
    }
}
