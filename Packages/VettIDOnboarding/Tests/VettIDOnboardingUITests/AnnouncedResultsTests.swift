#if os(iOS)
import Foundation
import Observation
import SwiftUI
import Testing
import UIKit
import VettIDData
import VettIDOnboarding
@testable import VettIDOnboardingUI
@testable import VettIDUI

/// The result of an unlock or an owner check is spoken to VoiceOver wherever its cursor is (I4 audit, accessibility: a
/// wrong PIN, a wrong password, a failure or "may have counted" used to be silent). Mirrors the live regions of
/// vettid-android `UnlockScreen` and `OwnerCheckScreen`.
@MainActor
@Suite(.serialized) struct AnnouncedResultsTests {
    let now = Date(timeIntervalSince1970: 1_791_384_000)

    var unlock: UnlockState {
        var s = UnlockState(loading: false)
        let release = ReleaseView(number: 3, pcr0: String(repeating: "aa", count: 48), status: "active", endsAt: nil, notes: "")
        s.preflight = PreflightInfo(routed: release, lastNumber: 3, softwareUpdated: false, rollback: false, offer: nil)
        return s
    }

    var check: OwnerCheckScreenState {
        OwnerCheckScreenState(
            mode: .gated, view: OwnerCheckView(state: .held, deadline: now.addingTimeInterval(-60), failures: 2)
        )
    }

    @Test func aWrongPinIsSpokenAtOnce() async {
        var s = unlock
        s.message = .badPin
        #expect(await spoken(UnlockScreen(state: s, actions: NoUnlockActions()), OnboardingStrings.unlockBadPin, .assertive))
    }

    /// The failure is cleared when the next attempt starts (`setPin`), so a second wrong PIN is said again.
    @Test func aSecondWrongPinIsSpokenAgain() async {
        var bad = unlock
        bad.message = .badPin
        let holder = UnlockHolder(bad)
        let saved = Announcer.sink
        Self.recorded = []
        Announcer.sink = { Self.recorded.append($0) }
        defer { Announcer.sink = saved }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIHostingController(rootView: HeldUnlock(holder: holder).vettIDTheme())
        window.isHidden = false
        window.layoutIfNeeded()
        defer { window.isHidden = true }
        let wrong = Announcer.Event.announcement(OnboardingStrings.unlockBadPin, .assertive)
        #expect(await eventually { Self.recorded.filter { $0 == wrong }.count == 1 })
        holder.state = unlock
        try? await Task.sleep(for: .milliseconds(100))
        holder.state = bad
        #expect(await eventually { Self.recorded.filter { $0 == wrong }.count == 2 })
    }

    @Test func aFailedUnlockIsSpokenAtOnce() async {
        var s = unlock
        s.message = .failed(.network, code: nil)
        let text = "\(OnboardingStrings.unlockTitle). \(FailureKind.network.message(timeScale: 1))"
        #expect(await spoken(UnlockScreen(state: s, actions: NoUnlockActions()), text, .assertive))
    }

    @Test func theOwnerCheckResultsAreSpokenAtOnce() async {
        var wrong = check
        wrong.pinKept = true
        wrong.unlockedWrong = 7
        let screen = OwnerCheckScreen(state: wrong, actions: NoOwnerCheckActions(), now: now)
        #expect(await spoken(screen, OnboardingStrings.unlockCheckPasswordWrong(7), .assertive))
        var maybe = check
        maybe.message = .maybeCounted(atLeast: 1)
        let maybeScreen = OwnerCheckScreen(state: maybe, actions: NoOwnerCheckActions(), now: now)
        #expect(await spoken(maybeScreen, OnboardingStrings.unlockCheckMaybeCounted(1), .assertive))
    }

    // MARK: - Helpers

    private static var recorded: [Announcer.Event] = []

    /// Whether [view], once shown, speaks [text] at [priority].
    private func spoken(_ view: some View, _ text: String, _ priority: Announce) async -> Bool {
        let saved = Announcer.sink
        Self.recorded = []
        Announcer.sink = { Self.recorded.append($0) }
        defer { Announcer.sink = saved }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIHostingController(rootView: view.vettIDTheme())
        window.isHidden = false
        window.layoutIfNeeded()
        defer { window.isHidden = true }
        return await eventually { Self.recorded.contains(.announcement(text, priority)) }
    }

    private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let end = clock.now.advanced(by: .seconds(5))
        while clock.now < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

@MainActor @Observable
private final class UnlockHolder {
    var state: UnlockState
    init(_ state: UnlockState) { self.state = state }
}

private struct HeldUnlock: View {
    let holder: UnlockHolder
    var body: some View { UnlockScreen(state: holder.state, actions: NoUnlockActions()) }
}
#endif
