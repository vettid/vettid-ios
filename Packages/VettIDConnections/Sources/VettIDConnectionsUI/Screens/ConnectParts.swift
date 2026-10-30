#if os(iOS)
import SwiftUI
import VettIDData
import VettIDUI

/// [open] with [id], when both are there.
func opening(_ open: (@MainActor (String) -> Void)?, _ id: String?) -> (@MainActor () -> Void)? {
    guard let open, let id else { return nil }
    return { open(id) }
}

/// A failure line under a form (shared by the connect screens): the failure's member-facing text at the vault's time
/// scale. Mirrors vettid-android `FailureText` of `feature/connections`.
struct FailureLine: View {
    @Environment(\.vettIDColors) private var colors
    @Environment(\.vettIDTimeScale) private var timeScale
    let kind: FailureKind?

    var body: some View {
        if let kind {
            Text(kind.message(timeScale: timeScale))
                .vettIDFont(.bodyMedium)
                .foregroundStyle(colors.error)
                .padding(.top, Spacing.s)
                .announced(kind.message(timeScale: timeScale), .assertive)
                .accessibilityIdentifier("failure")
        }
    }
}

/// Kept out of screenshots and screen recordings (IOS-PLAN §6.4 protection 3) unless the member allowed screenshots
/// (Settings → App): the invitation's QR code and link, a pasted or opened link, and the safety code. vettid-android
/// keeps the whole app out of captures (`FLAG_SECURE`); on the iPhone these codes are what a capture must not carry, on
/// top of the app-switcher cover and capture hiding that are always on (chosen; not in the spec).
struct CaptureProtected<Content: View>: View {
    @Environment(ScreenshotAllowance.self) private var allowance: ScreenshotAllowance?
    @ViewBuilder let content: () -> Content

    var body: some View {
        SecureContainer(isSecure: !(allowance?.allowed ?? false)) { content() }
    }
}

/// The safety code, large, in a bordered box (VAULT-MESSAGING §6.3, §10.4), out of captures. Mirrors vettid-android
/// `SasBox`.
struct SasBox: View {
    @Environment(\.vettIDColors) private var colors
    let sas: String

    var body: some View {
        CaptureProtected {
            SafetyCode(sas)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.l)
                .overlay(VettIDShape.card.stroke(colors.outline, lineWidth: 1))
        }
        .accessibilityIdentifier("sas")
    }
}

/// The safety code under its label.
struct LabeledSas: View {
    let sas: String

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(ConnectStrings.safetyCode).vettIDFont(.labelLarge)
            SasBox(sas: sas)
        }
    }
}

/// A spinner and what is awaited, announced when it appears. Mirrors vettid-android `WaitingRow`.
struct WaitingRow: View {
    @Environment(\.vettIDColors) private var colors
    let text: String
    var identifier = "waiting_peer"

    var body: some View {
        HStack(spacing: Spacing.m) {
            ProgressView().controlSize(.small).tint(colors.primary.color)
            Text(text).vettIDFont(.bodyMedium)
        }
        .accessibilityElement(children: .combine)
        .announcedOnce(text)
        .accessibilityIdentifier(identifier)
    }
}

/// The member is told the other member declined (VAULT-MESSAGING 0.10.5, §6.4): the accepter "<name> declined your
/// connection request", the inviter "<name> declined the connection"; "Someone" without a name. Mirrors vettid-android
/// `peerDeclineText`.
enum PeerDeclineText {
    static func title(outgoing: Bool, name: String?) -> String {
        let who = AccountNames.isolateOrNull(name) ?? ConnectStrings.peerDeclinedSomeone
        return outgoing ? ConnectStrings.peerDeclinedOutgoing(who) : ConnectStrings.peerDeclinedIncoming(who)
    }
}

/// The connection is made. "Send a message" when the messages are there to open ([onMessage]); otherwise "Done" alone
/// (the iPhone's messages come with IOS-PLAN §8 I2.2; chosen; not in the spec). Mirrors vettid-android `Connected`.
struct ConnectedScreen: View {
    @Environment(\.vettIDColors) private var colors
    let name: String?
    let onMessage: (@MainActor () -> Void)?
    let onDone: @MainActor () -> Void

    var body: some View {
        FormScaffold(
            title: ConnectStrings.connectedTitle,
            message: Self.body(name),
            primaryLabel: onMessage == nil ? ConnectStrings.done : ConnectStrings.sendMessage,
            secondaryLabel: onMessage == nil ? nil : ConnectStrings.done,
            onPrimary: onMessage ?? onDone,
            onSecondary: onDone,
            header: {
                VettIDSymbol.checkCircle.image.font(.system(size: 56)).foregroundStyle(colors.success)
                    .accessibilityHidden(true)
            },
            content: { EmptyView() }
        )
        .accessibilityIdentifier("connected")
    }

    static func body(_ name: String?) -> String {
        AccountNames.isolateOrNull(name).map(ConnectStrings.connectedBody) ?? ConnectStrings.connectedBodyUnnamed
    }
}

/// What the request content can ask for.
struct RequestActions {
    var onApprove: @MainActor () -> Void = {}
    var onDecline: @MainActor () -> Void = {}
    var onBlock: @MainActor () -> Void = {}
    var onBack: @MainActor () -> Void = {}
}

/// A connection request at the inviter (VAULT-MESSAGING §6.4, 0.10.3): the requester's "First Last" from its `hs.init`
/// profile (the names on its VettID account, never called verified, 0.18.0 §6.2, §10.8) and its display name, if any
/// (self-asserted, labelled so), the safety code to compare with them, and approve / decline / block. After this
/// member's approval ([approved]) the code stays on screen while the other member approves on their phone. Mirrors
/// vettid-android `ConnectionRequestContent`.
struct ConnectionRequestContent: View {
    @Environment(\.vettIDColors) private var colors
    let request: ConnectionRequest
    var approved = false
    var autoApproved = false
    var busy = false
    var error: FailureKind?
    let actions: RequestActions

    private var who: String { AccountNames.isolateOrNull(request.name) ?? ConnectStrings.requestThem }

    /// The requester in the body sentence: cleaned and isolated, "Someone" when nothing visible is left of the name.
    static func named(_ name: String?) -> String { AccountNames.isolateOrNull(name) ?? ConnectStrings.requestSomeone }

    var body: some View {
        let named = Self.named(request.name)
        FormScaffold(
            title: ConnectStrings.requestTitle,
            message: request.remote ? ConnectStrings.requestBodyRemote(named) : ConnectStrings.requestBody(named),
            primaryLabel: approved ? nil : ConnectStrings.requestApprove,
            busy: busy,
            secondaryLabel: ConnectStrings.requestDecline,
            onPrimary: actions.onApprove,
            onSecondary: actions.onDecline,
            onBack: actions.onBack
        ) {
            names
            Spacer().frame(height: Spacing.xl)
            LabeledSas(sas: request.sas)
            Text(request.remote ? ConnectStrings.sasHintRemote : ConnectStrings.sasHint)
                .vettIDFont(.bodyMedium).foregroundStyle(colors.onSurfaceVariant).padding(.top, Spacing.s)
            if autoApproved {
                NoticeCard(.info, title: ConnectStrings.autoApprovedTitle, message: ConnectStrings.autoApproved(who))
                    .padding(.top, Spacing.m)
            }
            if approved { WaitingRow(text: ConnectStrings.waitingPeer(who)).padding(.top, Spacing.l) }
            Button(action: actions.onBlock) {
                Text(ConnectStrings.blockRequest).vettIDFont(.labelLarge).foregroundStyle(colors.error)
                    .frame(minHeight: Spacing.touchTarget)
            }
            .buttonStyle(.plain)
            .disabled(busy)
            .padding(.top, Spacing.l)
            .accessibilityIdentifier("block_request")
            FailureLine(kind: error)
        }
        .accessibilityIdentifier("connection_request")
    }

    @ViewBuilder private var names: some View {
        Text(ConnectStrings.requestNameLabel).vettIDFont(.labelLarge)
        Text(AccountNames.cleaned(request.name) ?? ConnectStrings.requestNoName)
            .vettIDFont(.titleLarge)
            .accessibilityIdentifier("request_name")
        if AccountNames.cleaned(request.name) != nil {
            Text(ConnectStrings.namesNote).vettIDFont(.bodySmall).foregroundStyle(colors.onSurfaceVariant)
        }
        if let display = AccountNames.isolateOrNull(request.displayName) {
            Text(ConnectStrings.requestDisplayName(display))
                .vettIDFont(.bodyMedium).padding(.top, Spacing.s)
            Text(ConnectStrings.selfAsserted).vettIDFont(.bodySmall).foregroundStyle(colors.onSurfaceVariant)
        }
    }
}
#endif
