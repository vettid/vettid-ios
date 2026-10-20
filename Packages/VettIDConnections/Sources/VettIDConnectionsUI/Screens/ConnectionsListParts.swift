#if os(iOS)
import SwiftUI
import VettIDConnections
import VettIDData
import VettIDUI

/// Dates and times as the connections screens show them, in the iPhone's zone and locale (vettid-android `Times`).
enum ConnectTimes {
    /// A full date and time (details, expiries).
    static func full(_ d: Date) -> String { d.formatted(date: .abbreviated, time: .shortened) }

    /// A list row's date (Proton): the time today, the weekday this week, else the date.
    static func short(_ d: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let day = calendar.startOfDay(for: d)
        let today = calendar.startOfDay(for: now)
        if day == today { return d.formatted(date: .omitted, time: .shortened) }
        if let weekAgo = calendar.date(byAdding: .day, value: -6, to: today), day >= weekAgo, day <= today {
            return d.formatted(.dateTime.weekday(.abbreviated))
        }
        return d.formatted(date: .abbreviated, time: .omitted)
    }
}

/// A notice's text action ("OK", "Try again").
struct ListNoticeAction: View {
    @Environment(\.vettIDColors) private var colors
    let label: String
    var identifier = ""
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            Text(label).vettIDFont(.labelLarge, weight: .semibold).foregroundStyle(colors.primary)
        }
        .buttonStyle(.plain)
        .frame(minHeight: Spacing.touchTarget)
        .accessibilityIdentifier(identifier)
    }
}

/// "Could not load connections" with the failure's text at the vault's time scale, and [actionLabel].
struct ConnectionsError: View {
    @Environment(\.vettIDTimeScale) private var timeScale
    let kind: FailureKind
    let actionLabel: String
    let action: @MainActor () -> Void

    var body: some View {
        NoticeCard(.warning, title: ConnectStrings.errorTitle, message: kind.message(timeScale: timeScale)) {
            ListNoticeAction(label: actionLabel, identifier: "connections_error_action", action: action)
        }
        .accessibilityIdentifier("connections_error")
    }
}

/// A request that ended before the member's decision reached the vault: "Already decided" when the vault no longer knew
/// it (``RequestEnd/gone``, vettid-android Approvals' text for the same case; chosen; not in the spec), otherwise why no
/// connection was made.
struct EndedRequestNotice: View {
    let ended: EndedRequest
    let onDismiss: @MainActor () -> Void

    var body: some View {
        NoticeCard(.info, title: Self.title(ended.end), message: Self.body(ended.end)) {
            ListNoticeAction(label: ConnectStrings.ok, identifier: "request_ended_ok", action: onDismiss)
        }
        .accessibilityIdentifier("request_ended")
    }

    static func title(_ end: RequestEnd) -> String {
        end == .gone ? ConnectStrings.goneTitle : ConnectStrings.endedTitle
    }

    static func body(_ end: RequestEnd) -> String {
        end == .gone ? ConnectStrings.goneBody : AcceptScreen.endedBody(end)
    }
}

/// A section's header ("Open invitations", "Connections").
struct SectionHeader: View {
    @Environment(\.vettIDColors) private var colors
    let text: String

    var body: some View {
        Text(text)
            .vettIDFont(.labelLarge)
            .foregroundStyle(colors.onSurfaceVariant)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, Spacing.gutter + Spacing.xs)
            .padding(.top, Spacing.l)
            .padding(.bottom, Spacing.xs)
            .accessibilityAddTraits(.isHeader)
    }
}

/// An outstanding invitation: in person or a link, when it expires, and ✕ to cancel it (confirmed).
struct InviteRow: View {
    @Environment(\.vettIDColors) private var colors
    let invite: OutstandingInvite
    let onCancel: @MainActor () -> Void

    var body: some View {
        HStack(spacing: Spacing.l) {
            VettIDSymbol.schedule.image.foregroundStyle(colors.primary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(invite.remote ? ConnectStrings.inviteRemote : ConnectStrings.inviteInPerson).vettIDFont(.bodyLarge)
                if let exp = invite.exp {
                    Text(ConnectStrings.inviteExpires(ConnectTimes.full(exp)))
                        .vettIDFont(.bodyMedium).foregroundStyle(colors.onSurfaceVariant)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            IconButton(.close, label: ConnectStrings.cancelInviteLabel, action: onCancel)
                .accessibilityIdentifier("cancel_invite_\(invite.inviteID)")
        }
        .frame(minHeight: 64)
        .padding(.leading, Spacing.gutter)
        .padding(.trailing, Spacing.xs)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("invite_\(invite.inviteID)")
    }
}

/// An open connection request of either side (VAULT-MESSAGING §6.4, 0.10.3): who (the names on their account, never
/// called verified), the safety code to compare (out of captures), and approve or decline; after this member's approval,
/// the wait for the other member; before the handshake, the wait for their vault. Texts of vettid-android's request
/// screens (`ConnectionRequestContent`, the accept screen).
struct RequestCard: View {
    @Environment(\.vettIDColors) private var colors
    let request: PendingConnection
    let deciding: Bool
    let actions: ConnectionsActions

    var body: some View {
        DetailCard {
            VStack(alignment: .leading, spacing: Spacing.s) {
                Text(Self.type(request)).vettIDFont(.labelLarge).foregroundStyle(colors.onSurfaceVariant)
                Text(request.name ?? ConnectStrings.requestNoName).vettIDFont(.titleMedium)
                    .accessibilityIdentifier("request_name")
                if request.name != nil {
                    Text(ConnectStrings.namesNote).vettIDFont(.bodySmall).foregroundStyle(colors.onSurfaceVariant)
                }
                decision
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("request_\(request.id)")
    }

    @ViewBuilder private var decision: some View {
        if let sas = request.sas {
            Text(Self.body(request)).vettIDFont(.bodyMedium)
            LabeledSas(sas: sas)
            if request.state == .approved {
                WaitingRow(text: ConnectStrings.waitingPeer(who))
            } else {
                PrimaryButton(Self.approveLabel(request), busy: deciding) { actions.onApprove(request) }
                    .accessibilityIdentifier("request_approve")
            }
        } else {
            WaitingRow(text: ConnectStrings.waitingHandshake, identifier: "waiting_handshake")
        }
        SecondaryButton(ConnectStrings.requestDecline) { actions.onDecline(request) }
            .disabled(deciding)
            .accessibilityIdentifier("request_decline")
    }

    private var who: String { request.name.map(AccountNames.isolate) ?? ConnectStrings.requestThem }

    static func remote(_ r: PendingConnection) -> Bool {
        switch r {
        case .incoming(let x): x.remote
        case .outgoing(let x): x.remote
        }
    }

    /// "Connection request", "Connection request (link)", or "Your connection request" (vettid-android Approvals).
    static func type(_ r: PendingConnection) -> String {
        if case .outgoing = r { return ConnectStrings.typeOutgoing }
        return remote(r) ? ConnectStrings.typeConnectionRemote : ConnectStrings.typeConnection
    }

    /// What to compare, as the invite screen (incoming) and the accept screen (outgoing) say it.
    static func body(_ r: PendingConnection) -> String {
        let named = r.name.map(AccountNames.isolate) ?? ConnectStrings.requestSomeone
        if case .outgoing = r {
            return remote(r) ? ConnectStrings.sasHintInviteeRemote(named) : ConnectStrings.sasHintInvitee(named)
        }
        return remote(r) ? ConnectStrings.requestBodyRemote(named) : ConnectStrings.requestBody(named)
    }

    static func approveLabel(_ r: PendingConnection) -> String {
        if case .outgoing = r { return ConnectStrings.compareApprove }
        return ConnectStrings.requestApprove
    }
}
#endif
