#if os(iOS)
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import VettIDData
import VettIDUI
@testable import VettIDDevices
@testable import VettIDDevicesUI

/// The pairing screens (ANDROID-PLAN 0.1.53 AA2; vettid-android #291) rendered: every stage for an agent and for a desktop, the
/// countdown, the digits, the pasteboard and the floating button's rule. What the screens say is checked, as text, in `DeviceStringsTests`
/// and `DeviceTextsTests` (the hosted tree gives no text without an assistive technology). Mirrors vettid-android `PairScreenTest`,
/// `PairingClipboardTest` and the pairing part of `DevicesScreenTest`.
@MainActor
@Suite(.serialized) struct PairScreensTests {
    let exp = Samples.now.addingTimeInterval(600)
    let code = PairingCode(pairingID: "p1", link: "bGluayBvZiB0aGUgcGFpcmluZw", exp: Samples.now.addingTimeInterval(600))

    private func host(_ view: some View) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIHostingController(rootView: view.vettIDTheme())
        window.isHidden = false
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        return window
    }

    private func height(_ view: some View) -> CGFloat {
        UIHostingController(rootView: view.vettIDTheme(.light)).sizeThatFits(in: CGSize(width: 390, height: 844)).height
    }

    private func state(
        _ stage: PairingStage, role: PairRole = .agent, change: (inout PairState) -> Void = { _ in }
    ) -> PairState {
        var s = PairState()
        s.pairing = PairingState(stage: stage, role: role)
        change(&s)
        return s
    }

    private func screen(_ s: PairState, _ actions: PairActions = PairActions()) -> PairScreen { PairScreen(state: s, actions: actions) }

    private func pending(_ sas: String? = "123456") -> PendingPairing {
        PendingPairing(pairingID: "p1", name: "Claude on laptop", sas: sas, ends: exp)
    }

    /// Every stage of the flow, for the role.
    private func states(_ role: PairRole) -> [PairState] {
        let c = PairingStage.code(code)
        return [
            state(.creating, role: role), state(.idle, role: role),
            state(c, role: role), state(c, role: role) { $0.copied = true },
            state(.codeExpired(pairingID: "p1", exp: exp), role: role),
            state(.compare(pending()), role: role), state(.compare(pending()), role: role) { $0.pairing.busy = true },
            state(.compare(pending(nil)), role: role),
            state(.compare(pending()), role: role) { $0.sheet = true },
            state(.compare(pending()), role: role) { $0.sheet = true; $0.session = .none; $0.pairing.error = .ownerCheckRequired },
            state(.compare(pending()), role: role) { $0.sheet = true; $0.pairing.busy = true },
            state(.rejected(told: true), role: role), state(.rejected(told: false), role: role),
            state(.paired(name: "Claude on laptop", deviceID: "a1"), role: role), state(.paired(name: "", deviceID: nil), role: role),
            state(.ended, role: role),
            state(.ended, role: role) { $0.pairing.unknownOutcome = true; $0.pairing.agentName = "Claude on laptop" },
            state(.ended, role: role) { $0.pairing.unknownOutcome = true; $0.pairing.agentName = "" },
            state(.idle, role: role) { $0.interrupted = true },
            state(.idle, role: role) { $0.pairing.error = .network }, state(.idle, role: role) { $0.pairing.error = .ownerCheckRequired },
            state(.idle, role: role) { $0.held = true },
        ]
    }

    @Test func everyStageRendersForAnAgentAndForADesktop() {
        for role in [PairRole.agent, .desktop] {
            for s in states(role) { #expect(height(screen(s)) > 0, "\(role) \(s.stage)") }
        }
    }

    /// The flow has no field to type or paste into (the code is shown, never entered here), so there is nothing for AutoFill, a
    /// password manager or a third-party keyboard to reach.
    @Test func noStageOffersATextInput() {
        func inputs(_ v: UIView) -> Int {
            let own = (v is UITextField || v is UITextView || v is UISearchBar) ? 1 : 0
            return own + v.subviews.map(inputs).reduce(0, +)
        }
        for role in [PairRole.agent, .desktop] {
            for s in states(role) {
                let window = host(screen(s))
                #expect(inputs(window) == 0, "\(role) \(s.stage)")
            }
        }
    }

    // MARK: The countdown and the digits

    @Test func theCountdownIsMinutesAndTwoDigitSecondsAndNeverBelowZero() {
        #expect(Countdown.clock(581) == "9:41" && Countdown.clock(600) == "10:00" && Countdown.clock(59.9) == "0:59")
        #expect(Countdown.clock(0) == "0:00" && Countdown.clock(5) == "0:05")
        // A minute is announced when it starts: 600 s is 10 minutes left, 541 s is 10 (not yet 9), 540 s is 9.
        #expect(Countdown.minutes(600) == 10 && Countdown.minutes(541) == 10 && Countdown.minutes(540) == 9)
        #expect(Countdown.minutes(1) == 1 && Countdown.minutes(0) == 0 && Countdown.minutes(-5) == 0)
    }

    @Test func theDigitsAreTwoGroupsOfThreeAndReadOneByOne() {
        let agent = SasSentence(sas: "123456", desktop: false)
        #expect(agent.grouped == "123 456")
        #expect(agent.text == "Does the agent show 123 456? Approve only if the codes match.")
        #expect(agent.spoken == "Does the agent show 1 2 3 4 5 6? Approve only if the codes match.")
        let desktop = SasSentence(sas: "012345", desktop: true)
        #expect(desktop.text == "Does the desktop show 012 345? Approve only if the codes match.")
        #expect(desktop.spoken == "Does the desktop show 0 1 2 3 4 5? Approve only if the codes match.")
    }

    // MARK: The pairing code on the pasteboard

    private func board() throws -> UIPasteboard {
        try #require(UIPasteboard(name: UIPasteboard.Name("vettid.test.\(UUID().uuidString)"), create: true))
    }

    /// The code is copied through `SecurePasteboard` (local to this iPhone, expiring at the code's end): on the pasteboard while the code is
    /// live, gone once it expired, and the app clears it when the pairing ends.
    @Test func theCodeIsCopiedAndExpiresAtItsEnd() throws {
        let b = try board()
        defer { UIPasteboard.remove(withName: b.name) }
        PairingClipboard.copy("THECODE", exp: exp, now: Samples.now, pasteboard: b)
        #expect(b.string == "THECODE")
        // A code whose end has passed is not left on the pasteboard at all (the system's expiry date is already past).
        PairingClipboard.copy("OLDCODE", exp: Samples.now, now: Samples.now.addingTimeInterval(5), pasteboard: b)
        #expect(b.string == nil)
    }

    @Test func whenThePairingEndsTheClipIsClearedIfItIsStillTheCode() throws {
        let b = try board()
        defer { UIPasteboard.remove(withName: b.name) }
        PairingClipboard.copy("THECODE", exp: exp, now: Samples.now, pasteboard: b)
        PairingClipboard.ended(pasteboard: b)
        #expect(b.string == nil)
    }

    /// Other text the member copied meanwhile is left alone: the app moves nothing it did not copy.
    @Test func otherTextTheMemberCopiedMeanwhileIsLeftAlone() throws {
        let b = try board()
        defer { UIPasteboard.remove(withName: b.name) }
        PairingClipboard.copy("THECODE", exp: exp, now: Samples.now, pasteboard: b)
        b.string = "the member's own"
        PairingClipboard.ended(pasteboard: b)
        #expect(b.string == "the member's own")
        // And one more pairing end finds nothing of ours to clear.
        b.string = "still theirs"
        PairingClipboard.ended(pasteboard: b)
        #expect(b.string == "still theirs")
    }

    /// A secret the app copied since (an item's value, which goes through `SecurePasteboard` too) is not the pairing code: it stays when
    /// the pairing ends, though it is the app's own latest copy.
    @Test func anotherCopyOfTheAppSinceIsNotClearedWhenThePairingEnds() throws {
        let b = try board()
        defer { UIPasteboard.remove(withName: b.name) }
        PairingClipboard.copy("THECODE", exp: exp, now: Samples.now, pasteboard: b)
        SecurePasteboard.copy("AN ITEM VALUE", clearAtLock: true, pasteboard: b)
        PairingClipboard.ended(pasteboard: b)
        #expect(b.string == "AN ITEM VALUE")
        SecurePasteboard.clearIfOwn(pasteboard: b)
    }

    @Test func nothingIsClearedThatWasNeverCopiedHere() throws {
        let b = try board()
        defer { UIPasteboard.remove(withName: b.name) }
        b.string = "not ours"
        PairingClipboard.ended(pasteboard: b)
        #expect(b.string == "not ours")
    }

    /// The vault's lock takes the code with it, as it takes any secret the app copied (IOS-PLAN §6.5, §6.9).
    @Test func theVaultsLockClearsTheCodeToo() throws {
        let b = try board()
        defer { UIPasteboard.remove(withName: b.name) }
        PairingClipboard.copy("THECODE", exp: exp, now: Samples.now, pasteboard: b)
        SecurePasteboard.clearIfOwn(pasteboard: b)
        #expect(b.string == nil)
        PairingClipboard.ended(pasteboard: b)
    }

    // MARK: The floating button

    @Test func thePairButtonIsThereWithOnlyThisPhoneAndWithAgentsButNotWhileLoadingOrUnread() {
        func offered(_ s: DevicesState) -> Bool { DevicesScreen.offersPairing(s) }
        #expect(offered(Samples.list(Samples.phone)))
        #expect(offered(Samples.list(Samples.phone, Samples.agent, Samples.desktop)))
        // A list that could not be read says so above what was read before, and the button stays.
        #expect(offered(Samples.list(Samples.phone, Samples.agent) { $0.error = .network }))
        var loading = DevicesState()
        loading.load = .loading
        #expect(!offered(loading))
        var unread = DevicesState()
        unread.error = .network
        unread.load = .failed
        #expect(!offered(unread))
    }

    /// With nothing paired the list renders its empty state with the button, and with devices the list with it.
    @Test func theListRendersWithTheButtonAndTheEmptyStateForAgentsAndDesktopsAlike() {
        let chrome = ShellChrome(accountName: "Ada Lovelace", onMenu: {}, onAvatar: {})
        for s in [Samples.list(Samples.phone), Samples.list(Samples.phone, Samples.agent, Samples.desktop)] {
            let view = DevicesScreen(state: s, chrome: chrome, now: Samples.now, calendar: Samples.calendar(), actions: DevicesActions())
            #expect(height(view) > 0)
        }
    }
}
#endif
