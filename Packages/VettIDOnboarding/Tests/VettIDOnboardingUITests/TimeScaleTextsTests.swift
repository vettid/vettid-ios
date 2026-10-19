#if os(iOS)
import Foundation
import Testing
import VettIDData
import VettIDOnboarding
@testable import VettIDOnboardingUI

/// The texts that name a wait the staging time scale divides (STAGING-TIME-SCALE §5.2): at scale 1 the approved words
/// verbatim (ANDROID-PLAN §4 "Recovery and unlock from release R", "Owner check and status", "Staging time scale"),
/// on a scaled vault the computed duration (the owner's decision of 2026-10-19).
@MainActor
@Suite struct TimeScaleTextsTests {
    @Test func thePresenceNotice() {
        let real = OwnerCheckScreenState(timeScale: 1)
        #expect(PresenceNotice.body(real.scaledQuietText) == """
            If this stays for three days, your vault is no longer protected against a recovery started by someone else. \
            Try again later. If it does not go away, contact VettID.
            """)
        let staging = OwnerCheckScreenState(timeScale: 24)
        #expect(PresenceNotice.body(staging.scaledQuietText) == """
            If this stays for 3 hours, your vault is no longer protected against a recovery started by someone else. \
            Try again later. If it does not go away, contact VettID.
            """)
    }

    @Test func theRecoveryDelay() {
        var s = UnlockState()
        let help = """
            First update VettID from where you installed it and try again: your PIN was not counted as wrong.

            If that does not help, recover your vault. Start a recovery on the account site, install a current version of \
            VettID (on this phone after removing this one, or on another phone) and choose "I lost my phone: recover my \
            vault" on its first screen, then scan or type the recovery code. A recovery takes 24 hours and needs your PIN \
            and your credential password.

            Moving your vault to a new phone directly is not possible while this phone cannot open it.
            """
        #expect(OnboardingStrings.unlockSignerRefusedHelpBody(s.recoveryText) == help)
        let erase = """
            Everything VettID keeps on this phone is erased, including its keys for your vault, and VettID goes back to \
            the start. Your vault itself is not changed.

            To get back into it you then need a recovery from the account site (it takes 24 hours and needs your PIN and \
            credential password, and the credential backup must be on), or a move from another phone that still holds \
            your vault.
            """
        #expect(UnreachableScreen.erasePhoneBody(timeScale: 1) == erase)
        s.timeScale = 24
        let scaledHelp = help.replacingOccurrences(of: "takes 24 hours", with: "takes 1 hour")
        #expect(scaledHelp != help && OnboardingStrings.unlockSignerRefusedHelpBody(s.recoveryText) == scaledHelp)
        let scaledErase = erase.replacingOccurrences(of: "takes 24 hours", with: "takes 1 hour") + "\n\nStaging: 1 day = 1 hour"
        #expect(UnreachableScreen.erasePhoneBody(timeScale: 24) == scaledErase)
    }

    @Test func theOldPhoneAndTheLongUnreachable() {
        var s = UnlockState()
        let kept = """
            Finish the move on your new phone. This phone keeps your vault's keys until your new phone has finished the \
            move, for at most 7 days. Before you give this phone away, remove VettID from it or reset it.
            """
        #expect(OnboardingStrings.keptTransfer(s.keptTransferText) == kept)
        s.timeScale = 24
        #expect(OnboardingStrings.keptTransfer(s.keptTransferText) == kept.replacingOccurrences(of: "7 days", with: "7 hours"))
        let wait = { (scale: UInt64) in TimeScales.text(TimeInterval(TimeScales.longUnreachableMs / 1_000), by: scale) }
        #expect(OnboardingStrings.rootLongUnreachable(wait(1)) == "VettID has not reached your vault for 7 days or more.")
        #expect(OnboardingStrings.rootLongUnreachable(wait(24)) == "VettID has not reached your vault for 7 hours or more.")
    }

    /// Texts kept in real time on purpose: the "recover elsewhere" screen has no vault, so no scale; "within a day" of a
    /// failed move is the data bucket's version retention (STAGING-TIME-SCALE N4), which is never scaled.
    @Test func theTextsThatStayInRealTime() {
        #expect(OnboardingStrings.elsewhereRecoveryBody.hasPrefix("Start a recovery on the account site. After 24 hours it shows"))
        #expect(OnboardingStrings.moveBackFailed
            == "Your vault could not be opened from this phone. Contact VettID within a day of the failed move: it may be repairable.")
    }
}
#endif
