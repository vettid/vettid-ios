#if os(iOS)
import SwiftUI
import VettIDData
import VettIDUI

/// The shell's release notice (owner decision 2026-10-09, RELEASE-UPDATES §2): "A new vault release is available
/// (release N)", or the end-date warning for a `retired` release or a `deprecated` one with an `ends_at`; "Update now" and
/// a close button that hides it for 24 h at most (``ReleaseNotices``), re-read as time passes. The "Vault updates"
/// notification comes with phase P (IOS-PLAN §6.7). Mirrors vettid-android `ReleaseUpdateBanner`.
struct ReleaseUpdateBanner: View {
    let updates: any ReleaseUpdateRepository
    let onUpdate: @MainActor () -> Void

    /// How often the dismissal's 24 h are compared with the clock (vettid-android: a minute).
    static var tick: TimeInterval { 60 }

    var body: some View {
        TimelineView(.periodic(from: .now, by: Self.tick)) { context in
            if let o = updates.offer, ReleaseNotices.bannerVisible(o, updates.dismissal, now: context.date) {
                Self.banner(o, onUpdate: onUpdate) { updates.dismissBanner(at: Date()) }
            }
        }
    }

    @ViewBuilder static func banner(
        _ o: ReleaseUpdateOffer, onUpdate: @escaping @MainActor () -> Void, onDismiss: @escaping @MainActor () -> Void
    ) -> some View {
        switch o.kind {
        case .available:
            InfoBanner(
                ShellStrings.releaseBannerAvailable(Int(o.target.number)), actionLabel: ShellStrings.releaseBannerUpdate,
                onAction: onUpdate, onDismiss: onDismiss
            )
            .accessibilityIdentifier("release_banner")
        case .ending, .ended:
            UrgentBanner(text(o), actionLabel: ShellStrings.releaseBannerUpdate, onDismiss: onDismiss, action: onUpdate)
                .accessibilityIdentifier("release_banner_ending")
        }
    }

    static func text(_ o: ReleaseUpdateOffer) -> String {
        if o.kind == .ended { return ShellStrings.releaseBannerEnded }
        return o.endsAt.map { ShellStrings.releaseBannerEnding($0.formatted(date: .abbreviated, time: .omitted)) }
            ?? ShellStrings.releaseBannerEndingSoon
    }
}
#endif
