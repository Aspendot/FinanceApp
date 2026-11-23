import SwiftUI

struct MoreView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("faceIDLock") private var faceIDLock = true

    var body: some View {
        NavigationStack {
            List {
                Section("Data file") {
                    if let data = model.data {
                        LabeledContent("Statements through", value: DayText.long(data.bundle.asOf))
                        LabeledContent("File made", value: String(data.bundle.generatedAt.prefix(16)).replacingOccurrences(of: "T", with: " "))
                        LabeledContent("Payments from statements", value: data.bundle.items.count.formatted())
                        LabeledContent("Pending from bank emails", value: data.pending.count.formatted())
                    } else {
                        Text("No data file yet").foregroundStyle(.secondary)
                    }
                    if let message = model.importMessage {
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                    }
                    Button("Check for a new data file") { model.checkInbox() }
                    Text("To update it: on your PC, open Apple Devices → your iPhone → Files → Finance, and drag in finance-bundle.json from Documents\\Finance\\data\\export.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Bank emails") {
                    if let message = model.syncMessage {
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                    }
                    Button(model.syncing ? "Checking Gmail…" : "Check Gmail now") {
                        Task { await model.syncGmail() }
                    }
                    .disabled(model.syncing)
                    if let data = model.data, !data.unmatched.isEmpty {
                        Text("\(data.unmatched.count) bank emails fall inside the statements' period without a matching row. They aren't counted.")
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
        }
    }
}
