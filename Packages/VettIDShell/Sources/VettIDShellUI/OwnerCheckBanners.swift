#if os(iOS)
import SwiftUI
import VettIDData
import VettIDOnboarding
import VettIDShell
import VettIDUI

/// The owner check's banners above the shell's screens: the `owner_check.*` feed items (a failed check, the ten-failure
/// lock, a hold change; the feed comes with I2.3), the early warning (VAULT-MESSAGING §3.6.5, from 1 h before the deadline, "Check now"),
/// the persistent "hold is off" indicator (VAULT-MESSAGING §3.6.7, "Turn on") and the presence notice (release R, VAULT-MESSAGING §11.14.5). Mirrors
/// vettid-android `OwnerCheckBanners`.
public struct OwnerCheckBanners: View {
    let gate: OwnerCheckGate
    let now: Date
    let onCheckNow: @MainActor () -> Void
    let onHoldOn: @MainActor () -> Void
    let onDismissNotices: @MainActor () -> Void

    public init(
        gate: OwnerCheckGate,
        now: Date = Date(),
        onCheckNow: @escaping @MainActor () -> Void,
        onHoldOn: @escaping @MainActor () -> Void,
        onDismissNotices: @escaping @MainActor () -> Void
    ) {
        self.gate = gate
        self.now = now
        self.onCheckNow = onCheckNow
        self.onHoldOn = onHoldOn
        self.onDismissNotices = onDismissNotices
    }

    public var body: some View {
        VStack(spacing: 0) {
            if let notice = gate.notices.first {
                let text = Self.noticeText(notice, count: gate.notices.count, now: now)
                if notice.urgent {
                    UrgentBanner(text, actionLabel: ShellStrings.ownerCheckNoticeOk, action: onDismissNotices)
                        .accessibilityIdentifier("owner_check_notice")
                } else {
                    InfoBanner(text, actionLabel: ShellStrings.ownerCheckNoticeOk, onAction: onDismissNotices)
                        .accessibilityIdentifier("owner_check_notice")
                }
            }
            if gate.warningShown {
                InfoBanner(
                    Self.warningText(gate.deadline, scaledAhead: gate.scaledWarningText),
                    actionLabel: ShellStrings.ownerCheckNow,
                    onAction: onCheckNow
                )
                    .accessibilityIdentifier("owner_check_warning")
            }
            if gate.holdOff {
                InfoBanner(Self.holdOffText(gate.holdOffUntil), actionLabel: ShellStrings.ownerCheckHoldOn, onAction: onHoldOn)
                    .accessibilityIdentifier("owner_check_hold_off")
            }
            // Release R (VAULT-MESSAGING §11.14.5): until a later answer or vault.status says the presence was recorded; the member cannot
            // act on it, so it has no action.
            if gate.presenceUnrecorded {
                let note = gate.stagingNote.map { " " + $0 } ?? ""
                InfoBanner(ShellStrings.ownercheckPresenceTitle + " " + Self.presenceBody(gate.scaledQuietText) + note)
                    .accessibilityIdentifier("owner_check_presence_banner")
            }
        }
    }

    /// The early warning: the deadline's time; without one, "within the hour", or on a scaled vault [scaledAhead]
    /// (``OwnerCheckGate/scaledWarningText``).
    static func warningText(_ deadline: Date?, scaledAhead: String? = nil) -> String {
        if let deadline { return ShellStrings.ownerCheckWarning(ShellTimes.time(deadline)) }
        return scaledAhead.map(ShellStrings.ownerCheckWarningSoonScaled) ?? ShellStrings.ownerCheckWarningSoon
    }

    /// The presence notice: the approved "three days" in real time, or on a scaled vault [scaledQuiet]
    /// (``OwnerCheckGate/scaledQuietText``).
    static func presenceBody(_ scaledQuiet: String?) -> String {
        scaledQuiet.map(ShellStrings.ownercheckPresenceBodyScaled) ?? ShellStrings.ownercheckPresenceBody
    }

    static func holdOffText(_ until: Date?) -> String {
        until.map { ShellStrings.ownerCheckHoldOffUntil(ShellTimes.full($0)) } ?? ShellStrings.ownerCheckHoldOff
    }

    static func noticeText(_ n: OwnerCheckNotice, count: Int, now: Date) -> String {
        let main = switch OwnerCheckNoticeText.of(n) {
        case .locked: ShellStrings.ownerCheckNoticeLocked
        case .failedPin: ShellStrings.ownerCheckNoticeFailedPin
        case .failedPassword: ShellStrings.ownerCheckNoticeFailedPassword
        case .holdOff: ShellStrings.ownerCheckNoticeHoldOff
        case .holdOffUntil(let until): ShellStrings.ownerCheckNoticeHoldOffUntil(ShellTimes.full(until))
        case .holdOn: ShellStrings.ownerCheckNoticeHoldOn
        case .holdExpired: ShellStrings.ownerCheckNoticeHoldExpired
        }
        let withTime = n.at.map { ShellStrings.ownerCheckNoticeAt(main, ShellTimes.short($0, now: now)) } ?? main
        return count > 1 ? ShellStrings.ownerCheckNoticeMore(withTime, count - 1) : withTime
    }
}

/// Dates and times as the shell shows them, in the iPhone's zone and locale. Mirrors vettid-android `Times`.
enum ShellTimes {
    /// The time of day only.
    static func time(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }

    /// A full date and time (details, expiries).
    static func full(_ d: Date) -> String { d.formatted(date: .abbreviated, time: .shortened) }

    /// A list row's date (Proton): the time today, the weekday this week, else the date.
    static func short(_ d: Date, now: Date, calendar: Calendar = .current) -> String {
        let day = calendar.startOfDay(for: d)
        let today = calendar.startOfDay(for: now)
        if day == today { return time(d) }
        if let weekAgo = calendar.date(byAdding: .day, value: -6, to: today), day >= weekAgo, day <= today {
            return d.formatted(.dateTime.weekday(.abbreviated))
        }
        return d.formatted(date: .abbreviated, time: .omitted)
    }
}
#endif
