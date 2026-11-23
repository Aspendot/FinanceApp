import SwiftUI

/// Lists Gmail, Money Forward and Google Drive connections with one-line status
/// and links to each connection's settings screen.
struct ConnectionsSection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Section("Connections") {
            NavigationLink {
                GmailSettingsView()
            } label: {
                connectionRow(title: "Gmail", status: model.gmailStatusLine)
            }

            NavigationLink {
                MoneyForwardSettingsView()
            } label: {
                connectionRow(
                    title: "Money Forward",
                    status: model.moneyForwardStatusLine,
                    warning: model.moneyForwardState.reconnectRequired
                        || model.moneyForwardState.accessRefusedMessage != nil
                )
            }

            NavigationLink {
                DriveSyncSettingsView()
            } label: {
                connectionRow(
                    title: "Google Drive",
                    status: model.driveStatusLine,
                    warning: model.driveState.needsDriveConsent
                )
            }
        }
        .onAppear {
            model.refreshConnectionStates()
        }
    }

    private func connectionRow(title: String, status: String, warning: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(status)
                .font(.footnote)
                .foregroundStyle(warning ? Color.orange : Color.secondary)
                .lineLimit(1)
        }
    }
}
