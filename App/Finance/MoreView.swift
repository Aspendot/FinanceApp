import FinanceCore
import SwiftUI

struct MoreView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("faceIDLock") private var faceIDLock = true

    private var lastCheckedRun: SyncRunRecord? {
        model.runLog.first { $0.outcome == .updated }
    }

    private var checksTodayCount: Int {
        let today = JST.day(Date())
        return model.runLog.filter { JST.day($0.startedAt) == today }.count
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Data file") {
                    if let data = model.data {
                        LabeledContent("Statements through", value: DayText.long(data.bundle.asOf))
                        LabeledContent("File made", value: String(data.bundle.generatedAt.prefix(16)).replacingOccurrences(of: "T", with: " "))
                        LabeledContent("Payments from statements", value: data.bundle.items.count.formatted())
                        LabeledContent("Pending from bank emails", value: data.pendingCount.formatted())
                    } else {
                        Text("No data file yet").foregroundStyle(.secondary)
                    }
                    if let message = model.importMessage {
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                    }
                    Button(model.checkingInbox ? "Checking for a data file…" : "Check for a new data file") {
                        Task { await model.checkInbox() }
                    }
                    .disabled(model.checkingInbox)
                    Text("To update it: on your PC, open Apple Devices → your iPhone → Files → Finance, and drag in finance-bundle.json from Documents\\Finance\\data\\export.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Bank emails") {
                    if let last = lastCheckedRun {
                        Text("Last checked \(SyncStorage.formatCheckTime(last.startedAt)) (\(last.trigger.rawValue))")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Text("Not checked yet").font(.footnote).foregroundStyle(.secondary)
                    }
                    Text(checksTodayCount == 0
                        ? "No checks today"
                        : "\(checksTodayCount) \(checksTodayCount == 1 ? "check" : "checks") today")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let message = model.syncMessage {
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                    }
                    Button(model.syncing ? "Checking Gmail…" : "Check Gmail now") {
                        Task { await model.syncGmail(userInitiated: true) }
                    }
                    .disabled(model.syncing)
                    if let data = model.data, !data.unmatched.isEmpty {
                        Text("\(data.unmatched.count) older bank emails are before the statement cutoff and aren’t counted.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section("Privacy") {
                    Toggle("Lock with Face ID", isOn: $faceIDLock)
                }
                Section {
                    NavigationLink("Setup and tests") { SpikeView() }
                } footer: {
                    Text("Google sign-in, the widget, notifications and background refresh.")
                }
                Section("About") {
                    LabeledContent("Version", value: (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?")
                }
            }
            .navigationTitle("More")
            .onAppear { model.refreshRunLog() }
        }
    }
}
