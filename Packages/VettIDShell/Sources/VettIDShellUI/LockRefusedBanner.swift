#if os(iOS)
import SwiftUI
import VettIDOnboardingUI
import VettIDUI

/// "Lock and unlock now" was refused on a phone without a usable `user_guid` (VAULT-MESSAGING §6.7.1): nothing was locked,
/// and the unlock screen's recover-or-erase words say why, until "OK".
struct LockRefusedBanner: View {
    let onOk: @MainActor () -> Void

    static var text: String { UnlockStuckTexts.title + "\n" + UnlockStuckTexts.body }

    var body: some View {
        UrgentBanner(Self.text, actionLabel: ShellStrings.ownerCheckNoticeOk, action: onOk)
            .accessibilityIdentifier("change_check_no_user_guid")
    }
}
#endif
