import FinanceCore
import SwiftUI

struct MoreView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var session: AppSession
    @AppStorage("faceIDLock") private var faceIDLock = true

    private var activeData: FinanceData? {
        session.resolvedData(from: model)
    }

    private var activeRunLog: [SyncRunRecord] {
        session.resolvedRunLog(from: model)
    }

    private var lastCheckedRun: SyncRunRecord? {
        activeRunLog.first { $0.outcome == .updated }
    }

    private var checksTodayCount: Int {
        let today = JST.day(Date())
        return activeRunLog.filter { JST.day($0.startedAt) == today }.count
    }

    private var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?"
    }

    var body: some View {
        NavigationStack {
            List {
                ConnectionsSection()

                Section {
                    if let data = activeData {
                        dataMetricRow("Statements through", value: DayText.long(data.bundle.asOf))
                        dataMetricRow("File made", value: FinanceFormat.bundleTimestamp(data.bundle.generatedAt))
                        dataMetricRow("Payments from statements", value: data.bundle.items.count.formatted())
                        dataMetricRow("Pending from bank emails", value: data.pendingCount.formatted())
                    } else {
                        Text("No data file yet")
                            .foregroundStyle(Theme.muted)
                    }
                    if let message = model.importMessage, !session.isDemo {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(message.hasPrefix("Not imported:") ? Theme.bad : Theme.muted)
                    }
                    Button {
                        Task { await model.checkInbox() }
                    } label: {
                        Text(model.checkingInbox ? "Checking for a data file…" : "Check for a new data file")
                            .foregroundStyle(session.isDemo || model.checkingInbox ? Theme.muted : Theme.accent)
                    }
                    .disabled(session.isDemo || model.checkingInbox)
                } header: {
                    SectionLabel("Data file")
                } footer: {
                    Text("On your PC, open Apple Devices, choose your iPhone, then Files → Finance, and copy in finance-bundle.json.")
                        .foregroundStyle(Theme.muted)
                }
                .listRowBackground(Theme.surface)

                Section {
                    if let last = lastCheckedRun {
                        Text("Last checked \(SyncStorage.formatCheckTime(last.startedAt)) (\(last.trigger.rawValue))")
                            .font(.subheadline)
                            .foregroundStyle(Theme.ink2)
                    } else {
                        Text("Not checked yet")
                            .font(.subheadline)
                            .foregroundStyle(Theme.muted)
                    }
                    Text(checksTodayCount == 0
                        ? "No checks today"
                        : "\(checksTodayCount) \(checksTodayCount == 1 ? "check" : "checks") today")
                        .font(.footnote)
                        .foregroundStyle(Theme.muted)
                    if let message = model.syncMessage, !session.isDemo {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(Theme.muted)
                    }
                    Button {
                        Task { await model.syncGmail(userInitiated: true) }
                    } label: {
                        Text(model.syncing ? "Checking Gmail…" : "Check Gmail now")
                            .foregroundStyle(session.isDemo || model.syncing ? Theme.muted : Theme.accent)
                    }
                    .disabled(session.isDemo || model.syncing)
                    if let data = activeData, !data.unmatched.isEmpty {
                        Text("\(data.unmatched.count) older bank emails are before the statement cutoff and are not counted.")
                            .font(.footnote)
                            .foregroundStyle(Theme.muted)
                    }
                } header: {
                    SectionLabel("Bank emails")
                }
                .listRowBackground(Theme.surface)

                Section {
                    Toggle("Lock with Face ID", isOn: $faceIDLock)
                        .tint(Theme.accent)
                } header: {
                    SectionLabel("Privacy")
                }
                .listRowBackground(Theme.surface)

                Section {
                    NavigationLink("Setup and tests") {
                        SpikeView()
                    }
                } header: {
                    SectionLabel("Diagnostics")
                } footer: {
                    Text("Google sign-in, widget, notifications and background refresh.")
                        .foregroundStyle(Theme.muted)
                }
                .listRowBackground(Theme.surface)

                Section {
                    dataMetricRow("Version", value: appVersion)
                    if session.isDemo {
                        dataMetricRow("Mode", value: "Demo data")
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
            .onAppear {
                if !session.isDemo {
                    model.refreshRunLog()
                }
            }
        }
    }

    private func dataMetricRow(_ label: String, value: String) -> some View {
        LabeledContent {
            Text(value)
                .monospacedDigit()
                .foregroundStyle(Theme.ink2)
        } label: {
            Text(label)
                .foregroundStyle(Theme.ink)
        }
    }
}
