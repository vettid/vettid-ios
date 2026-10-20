#if os(iOS)
import SwiftUI
import VettIDConnections
import VettIDUI

/// "Requests from <First>" (VAULT-MESSAGING 0.23.0 §10.4.1): paused after several declines (with Resume; removing is in
/// the pill), muted (with Unmute), or the usual state (with Mute), and how many declined asks are refused for 7 days. The
/// connection never learns which: it sees "not accepted". Mirrors vettid-android `AsksCard`.
struct AsksCard: View {
    @Environment(\.vettIDColors) private var colors
    let view: AsksView
    /// The connection's first name, bidi-isolated; nil before the names arrived.
    let name: String?
    let busy: Bool
    let onMute: @MainActor (Bool) -> Void
    let onResume: @MainActor () -> Void

    private var who: String { name ?? ConnectStrings.theirsUnnamed }

    var body: some View {
        DetailCard {
            CardTitle(text: name.map(ConnectStrings.asksTitle) ?? ConnectStrings.asksTitleUnnamed)
            VStack(alignment: .leading, spacing: Spacing.xs) { states }
            ForEach(view.actions, id: \.self) { a in
                SecondaryButton(Self.label(a)) { run(a) }
                    .disabled(busy)
                    .padding(.top, Spacing.s)
                    .accessibilityIdentifier("asks_\(Self.identifier(a))")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("asks_card")
    }

    /// Paused (since when), muted, or the usual state; the cooldowns; and that the connection is never told which.
    @ViewBuilder private var states: some View {
        if view.paused {
            Text(ConnectStrings.asksPausedTitle).fontWeight(.semibold).foregroundStyle(colors.error)
                .accessibilityIdentifier("asks_paused")
            Text(ConnectStrings.asksPaused(who))
            if let at = view.pausedAt {
                Text(ConnectStrings.asksPausedSince(ConnectTimes.full(at))).vettIDFont(.bodySmall).foregroundStyle(colors.onSurfaceVariant)
            }
        }
        if view.muted {
            Text(ConnectStrings.asksMutedTitle).fontWeight(.semibold).foregroundStyle(colors.primary)
                .accessibilityIdentifier("asks_muted")
            Text(ConnectStrings.asksMuted(who))
        }
        if !view.paused && !view.muted {
            Text(ConnectStrings.asksNormal(who)).accessibilityIdentifier("asks_normal")
        }
        if view.cooldowns > 0 && !view.paused {
            Text(ConnectStrings.asksCooldowns(view.cooldowns)).vettIDFont(.bodySmall).accessibilityIdentifier("asks_cooldowns")
        }
        Text(ConnectStrings.asksNeutral(who)).vettIDFont(.bodySmall).foregroundStyle(colors.onSurfaceVariant)
    }

    private func run(_ a: AsksAction) {
        switch a {
        case .mute: onMute(true)
        case .unmute: onMute(false)
        case .resume, .allowAgain: onResume()
        }
    }

    static func label(_ a: AsksAction) -> String {
        switch a {
        case .mute: ConnectStrings.asksMute
        case .unmute: ConnectStrings.asksUnmute
        case .resume: ConnectStrings.asksResume
        case .allowAgain: ConnectStrings.asksAllowAgain
        }
    }

    /// vettid-android's test tags: `asks_mute`, `asks_unmute`, `asks_resume`, `asks_allow_again`.
    static func identifier(_ a: AsksAction) -> String {
        switch a {
        case .mute: "mute"
        case .unmute: "unmute"
        case .resume: "resume"
        case .allowAgain: "allow_again"
        }
    }
}
#endif
