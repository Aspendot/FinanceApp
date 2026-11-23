import SwiftUI

/// Lists Gmail, Money Forward and Google Drive connections with one-line status
/// and links to each connection's settings screen.
struct ConnectionsSection: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var footerText: String? = nil

    var body: some View {
        Section {
            NavigationLink(value: MoreDestination.gmail) {
                connectionRow(
                    title: "Gmail",
                    status: model.gmailStatusLine,
                    warning: model.runLog.first?.outcome == .signInRequired
                )
            }

            NavigationLink(value: MoreDestination.moneyForward) {
                connectionRow(
                    title: "Money Forward",
                    status: model.moneyForwardStatusLine,
                    warning: model.moneyForwardState.reconnectRequired
                        || model.moneyForwardState.accessRefusedMessage != nil
                )
            }

            NavigationLink(value: MoreDestination.drive) {
                connectionRow(
                    title: "Google Drive",
                    status: model.driveStatusLine,
                    warning: model.driveState.needsDriveConsent
                )
            }
        } header: {
            SectionLabel("Connections")
        } footer: {
            if let footerText, !footerText.isEmpty {
                Text(footerText)
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
            }
        }
        .listRowBackground(Theme.surface)
        .onAppear {
            model.refreshConnectionStates()
        }
    }

    private func connectionRow(title: String, status: String, warning: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.ink)
            Text(status)
                .font(.footnote)
                .foregroundStyle(warning ? Theme.bad : Theme.muted)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
        }
        .padding(.vertical, 2)
    }
}
