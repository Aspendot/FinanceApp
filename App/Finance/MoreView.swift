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
            "\(data.bundle.items.count.formatted()) payments"
        ]
        if data.pendingCount > 0 {
            parts.append("\(data.pendingCount) pending")
        }
        return parts.joined(separator: " · ")
    }

    private var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?"
    }

    var body: some View {
        NavigationStack(path: $session.morePath) {
            List {
                ConnectionsSection(footerText: dataSummaryLine)

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
}
