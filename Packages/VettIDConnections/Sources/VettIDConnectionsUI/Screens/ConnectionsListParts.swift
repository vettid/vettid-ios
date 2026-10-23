#if os(iOS)
import SwiftUI
import VettIDConnections
import VettIDData
import VettIDUI

/// Dates and times as the connections screens show them, in the iPhone's zone and locale (vettid-android `Times`).
enum ConnectTimes {
    /// A full date and time (details, expiries), in [zone].
    static func full(_ d: Date, zone: TimeZone = .current) -> String {
        d.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: zone))
    }

    /// A calendar day as lists show it (vettid-android `Times.dayLabel`), in [zone].
    static func dayLabel(_ d: Date, zone: TimeZone = .current) -> String {
        d.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: zone))
    }

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
#endif
