import SwiftUI

/// Lists Gmail, Money Forward and Google Drive connections with icon medallions,
/// live status dots and links to each connection's settings screen.
struct ConnectionsSection: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var footerText: String? = nil

    var body: some View {
        Section {
            NavigationLink(value: MoreDestination.gmail) {
                connectionRow(
                    symbol: "envelope.fill",
                    tint: Color("LayerBills"),
                    title: "Gmail",
                    status: model.gmailStatusLine,
                    connected: !model.gmailStatusLine.localizedCaseInsensitiveContains("not connected"),
                    warning: model.runLog.first?.outcome == .signInRequired
                )
            }

            NavigationLink(value: MoreDestination.moneyForward) {
                connectionRow(
                    symbol: "building.columns.fill",
                    tint: Color("LayerRent"),
                    title: "Money Forward",
                    status: model.moneyForwardStatusLine,
                    connected: !model.moneyForwardStatusLine.localizedCaseInsensitiveContains("not connected"),
                    warning: model.moneyForwardState.reconnectRequired
                        || model.moneyForwardState.accessRefusedMessage != nil
                )
            }

            NavigationLink(value: MoreDestination.drive) {
                connectionRow(
                    symbol: "icloud.and.arrow.down.fill",
                    tint: Theme.accent,
                    title: "Google Drive",
                    status: model.driveStatusLine,
                    connected: !model.driveStatusLine.localizedCaseInsensitiveContains("not connected"),
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

    private func connectionRow(
        symbol: String,
        tint: Color,
        title: String,
        status: String,
        connected: Bool,
        warning: Bool = false
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            if !dynamicTypeSize.isAccessibilitySize {
                IconMedallion(symbol: symbol, tint: tint, size: 32)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.ink)
                HStack(spacing: 5) {
                    Circle()
                        .fill(warning ? Theme.bad : (connected ? Theme.good : Theme.muted.opacity(0.45)))
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(warning ? Theme.bad : Theme.muted)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
