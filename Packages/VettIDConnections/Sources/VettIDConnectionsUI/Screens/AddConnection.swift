#if os(iOS)
import SwiftUI
import VettIDConnections
import VettIDUI

/// Connections' add button (ANDROID-PLAN 0.1.11) and its sheet, at the bottom of the screen: [onOpen] opens the chosen
/// screen of the connect flow once the sheet has closed. The Connections list hosts it. Mirrors vettid-android
/// `ConnectionsScreen`'s floating button and `AddSheet`.
public struct AddConnectionControls: View {
    @Environment(\.vettIDColors) private var colors
    let onOpen: @MainActor (ConnectDestination) -> Void
    @State private var showing = false
    @Environment(\.vettIDCovered) private var covered
    @State private var chosen: ConnectDestination?

    public init(onOpen: @escaping @MainActor (ConnectDestination) -> Void) { self.onOpen = onOpen }

    public var body: some View {
        BottomFloatingControls {
            EmptyView()
        } trailing: {
            // ANDROID-PLAN 0.1.11: the button invites (QR or link, or scan the other's QR).
            VettIDFab(.personAdd, label: ConnectStrings.inviteTitle) { showing = true }
                .accessibilityIdentifier("add_connection")
        }
        .sheet(isPresented: uncovered($showing, covered: covered), onDismiss: {
            if let chosen { onOpen(chosen) }
            chosen = nil
        }) {
            AddConnectionSheet(
                onInvite: { choose(.invite) }, onScan: { choose(.scan) }, onPaste: { choose(.accept(AcceptInput())) }
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
            .presentationBackground(colors.surfaceContainerLow.color)
            .environment(\.vettIDColors, colors)
        }
        .closesWhenCovered {
            chosen = nil
            showing = false
        }
    }

    private func choose(_ d: ConnectDestination) {
        chosen = d
        showing = false
    }
}

/// What the Connections screen's add button offers (ANDROID-PLAN 0.1.11): invite with a QR code or a link, scan the
/// other member's code, or paste a link they sent. Mirrors vettid-android `AddSheet`.
public struct AddConnectionSheet: View {
    @Environment(\.vettIDColors) private var colors
    let onInvite: @MainActor () -> Void
    let onScan: @MainActor () -> Void
    let onPaste: @MainActor () -> Void

    public init(
        onInvite: @escaping @MainActor () -> Void, onScan: @escaping @MainActor () -> Void, onPaste: @escaping @MainActor () -> Void
    ) {
        self.onInvite = onInvite
        self.onScan = onScan
        self.onPaste = onPaste
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(ConnectStrings.inviteTitle)
                .vettIDFont(.titleMedium)
                .padding(.horizontal, Spacing.xl)
                .padding(.vertical, Spacing.s)
                .accessibilityAddTraits(.isHeader)
            option(.qrCode, ConnectStrings.addInvite, ConnectStrings.addInviteBody, "add_invite", onInvite)
            option(.qrCodeScanner, ConnectStrings.addScan, ConnectStrings.addScanBody, "add_scan", onScan)
            option(.contentPaste, ConnectStrings.addPaste, ConnectStrings.addPasteBody, "add_paste", onPaste)
        }
        .padding(.vertical, Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("add_connection_sheet")
    }

    private func option(
        _ symbol: VettIDSymbol, _ title: String, _ body: String, _ identifier: String, _ action: @escaping @MainActor () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: Spacing.l) {
                symbol.image.font(.system(size: 22)).foregroundStyle(colors.primary).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).vettIDFont(.bodyLarge).fontWeight(.semibold).foregroundStyle(colors.onSurface)
                    Text(body).vettIDFont(.bodyMedium).foregroundStyle(colors.onSurfaceVariant)
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: 64)
            .padding(.horizontal, Spacing.xl)
            .padding(.vertical, Spacing.m)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }
}
#endif
