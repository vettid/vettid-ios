#if os(iOS)
import Foundation
import SwiftUI
import Testing
import UIKit
import VettIDData
import VettIDOnboarding
@testable import VettIDOnboardingUI
import VettIDUI

/// The unlock screen's release offer (RELEASE-UPDATES §2 step 2; ANDROID-PLAN "What's new"): the PIN first, a compact
/// notice under it, What's new one tap away, approval never gated on the notes.
@MainActor
@Suite struct UnlockOfferTests {
    func release(_ n: UInt64) -> ReleaseView {
        ReleaseView(
            number: n, pcr0: String(repeating: "ab", count: 48), status: "active", endsAt: nil,
            notes: "https://vettid.org/security/releases/\(n)/"
        )
    }

    func state(offer: Bool = true, rollback: Bool = false, notes: ReleaseNotes? = nil) -> UnlockState {
        var s = UnlockState(loading: false)
        s.preflight = PreflightInfo(
            routed: release(4), lastNumber: 4, softwareUpdated: false, rollback: rollback, offer: offer ? release(5) : nil
        )
        s.notes = notes
        return s
    }

    func entry(_ security: ReleaseSecurity) -> ReleaseNotes {
        .available(
            host: "vettid.org",
            entry: ReleaseLogEntry(
                release: 5, summary: "Faster unlocks.", changes: ["One round trip."], security: security,
                securityText: security == .none ? nil : "Fixes a flaw in the PIN check."
            ),
            earlier: [EarlierRelease(release: 4, summary: "Smaller.")]
        )
    }

    @Test func theKeypadComesBeforeTheOffer() {
        let blocks = UnlockBlock.blocks(for: state())
        let pin = blocks.firstIndex(of: .pin)
        let offer = blocks.firstIndex(of: .offer)
        #expect(pin != nil && offer != nil && pin! < offer!)
        // The other notices (the release check, locks, owner check) stay above the keypad, the results of the unlock
        // (the refusals, the way forward) between the keypad and the offer: the offer is last.
        #expect(blocks.first == .notices && blocks.firstIndex(of: .notices)! < pin!)
        #expect(blocks.last == .offer)
        var stuck = state()
        stuck.signerRefused = true
        let order = UnlockBlock.blocks(for: stuck)
        #expect(order == [.notices, .pin, .signerRefused, .wayForward, .offer])
        // No offer, no notice; an older release (rollback) offers nothing.
        #expect(!UnlockBlock.blocks(for: state(offer: false)).contains(.offer))
        #expect(!UnlockBlock.blocks(for: state(rollback: true)).contains(.offer))
    }

    /// The line is said politely when it arrives (not the progress line), and it is the one line announced.
    @Test func theLineIsAnnouncedWhenItArrives() {
        #expect(OfferSecurityLine(nil).spoken == nil)
        #expect(OfferSecurityLine(.unavailable).spoken == "Release notes unavailable")
        #expect(OfferSecurityLine(entry(.urgent)).spoken == "Security fix: update urgently")
        #expect(OfferSecurityLine(entry(.none)).spoken == "No security fix")
    }

    /// The reserved line height: the notice is as tall while loading as with the longest line.
    @Test func theNoticeDoesNotMoveWhenTheNotesArrive() {
        func notice(_ n: ReleaseNotes?) -> CGFloat {
            let s = state(notes: n)
            return height(ReleaseOfferNotice(preflight: s.preflight!, offer: release(5), state: s, actions: NoUnlockActions()))
        }
        let heights = [nil, .unavailable, entry(.none), entry(.recommended), entry(.urgent)].map { notice($0 as ReleaseNotes?) }
        #expect(Set(heights.map { Int($0.rounded()) }).count == 1)
        // And at an accessibility size, where the lines wrap.
        func big(_ n: ReleaseNotes?) -> CGFloat {
            let s = state(notes: n)
            let view = ReleaseOfferNotice(preflight: s.preflight!, offer: release(5), state: s, actions: NoUnlockActions())
                .environment(\.dynamicTypeSize, .accessibility3)
            return height(view)
        }
        let bigHeights = [nil, .unavailable, entry(.none), entry(.recommended), entry(.urgent)].map { big($0 as ReleaseNotes?) }
        #expect(Set(bigHeights.map { Int($0.rounded()) }).count == 1)
    }

    @Test func theSecurityLineFollowsTheNotes() {
        #expect(OfferSecurityLine(nil) == .loading)
        #expect(OfferSecurityLine(.unavailable) == .unavailable)
        #expect(OfferSecurityLine(entry(.none)) == .line("No security fix", urgent: false))
        #expect(OfferSecurityLine(entry(.recommended)) == .line("Security fix: update recommended", urgent: false))
        #expect(OfferSecurityLine(entry(.urgent)) == .line("Security fix: update urgently", urgent: true))
    }

    @Test func theNoticeAndItsLinkUseTheExistingTexts() {
        #expect(OnboardingStrings.unlockOfferTitle(5) == "Update available: release 5")
        #expect(OnboardingStrings.unlockOfferApprove == "Approve the update with this unlock")
        #expect(OnboardingStrings.releaseNotesTitle(5) == "What's new in release 5")
        #expect(OnboardingStrings.releaseNotesUnavailable == "Release notes unavailable")
        #expect(OnboardingStrings.releaseNotesFull == "Full release notes")
    }

    /// Every notes state renders the notice with the approval, and the whole screen without a keyboard for the PIN.
    @Test func theNoticeRendersWithTheApprovalForEveryNotesState() {
        for notes in [nil, .unavailable, entry(.none), entry(.recommended), entry(.urgent)] as [ReleaseNotes?] {
            let s = state(notes: notes)
            let notice = ReleaseOfferNotice(preflight: s.preflight!, offer: release(5), state: s, actions: NoUnlockActions())
            #expect(height(notice) > 0)
            let screen = host(UnlockScreen(state: s, actions: NoUnlockActions()))
            #expect(views(in: screen).compactMap { $0 as? UITextField }.isEmpty)
            screen.isHidden = true
        }
    }

    /// The sheet holds the full notes, the earlier releases, the fingerprint and "Full release notes"; unavailable or
    /// loading, it still renders (with the manifest's notes link). It scrolls, so its height is the screen's, not its content's.
    @Test func theSheetRendersEveryNotesState() {
        for notes in [nil, .unavailable, entry(.urgent)] as [ReleaseNotes?] {
            #expect(height(WhatsNewSheet(offer: release(5), routed: 4, notes: notes, onClose: {})) > 0)
        }
    }

    /// The sheet is open only for the offer it was opened on: another release or PCR0 never shows its notes.
    @Test func theSheetIsKeyedToItsOffer() {
        let five = release(5)
        var other = release(5)
        other.pcr0 = String(repeating: "cd", count: 48)
        #expect(ReleaseOfferNotice.isOpen(five, offer: five))
        #expect(!ReleaseOfferNotice.isOpen(nil, offer: five))
        #expect(!ReleaseOfferNotice.isOpen(five, offer: other) && !ReleaseOfferNotice.isOpen(five, offer: release(6)))
        #expect(ReleaseOfferNotice.stillOpen(five, offer: five) == five)
        #expect(ReleaseOfferNotice.stillOpen(five, offer: other) == nil)
        #expect(ReleaseOfferNotice.stillOpen(five, offer: release(6)) == nil)
        #expect(ReleaseOfferNotice.stillOpen(nil, offer: five) == nil)
    }

    /// The approval is on the screen and enabled in every notes state (it never waits for the notes).
    @Test func theApprovalIsOnTheScreenAndEnabledInEveryNotesState() {
        for notes in [nil, .unavailable, entry(.none), entry(.recommended), entry(.urgent)] as [ReleaseNotes?] {
            let window = host(UnlockScreen(state: state(notes: notes), actions: NoUnlockActions()))
            let toggles = views(in: window).compactMap { $0 as? UISwitch }
            #expect(toggles.count == 1 && toggles[0].isEnabled, "\(String(describing: notes))")
            window.isHidden = true
        }
    }

    /// The compact notice is shorter than the sheet's contents: the screen no longer opens with the long card.
    @Test func theNoticeIsCompact() {
        let s = state(notes: entry(.urgent))
        let notice = height(ReleaseOfferNotice(preflight: s.preflight!, offer: release(5), state: s, actions: NoUnlockActions()))
        let sheet = height(WhatsNewSheet(offer: release(5), routed: 4, notes: s.notes, onClose: {}))
        #expect(notice < sheet)
    }

    /// Held for an undecided PIN or password change (§11.14.9): no approval toggle, the notice stays.
    @Test func aHeldUpdateKeepsTheNoticeWithoutTheToggle() {
        var s = state(notes: .unavailable)
        s.updateHeld = true
        #expect(UnlockBlock.blocks(for: s).contains(.offer))
        #expect(height(ReleaseOfferNotice(preflight: s.preflight!, offer: release(5), state: s, actions: NoUnlockActions())) > 0)
    }

    private func height(_ view: some View) -> CGFloat {
        UIHostingController(rootView: view.vettIDTheme()).sizeThatFits(in: CGSize(width: 390, height: 4_000)).height
    }

    private func host(_ view: some View) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIHostingController(rootView: view.vettIDTheme())
        window.isHidden = false
        window.layoutIfNeeded()
        return window
    }

    private func views(in view: UIView) -> [UIView] { [view] + view.subviews.flatMap { views(in: $0) } }
}
#endif
