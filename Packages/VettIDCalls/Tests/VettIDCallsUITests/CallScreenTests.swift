#if os(iOS)
import SwiftUI
import Testing
import UIKit
import VettIDCalls
@testable import VettIDCallsUI
import VettIDUI

/// The call screen in each of its states, hosted: every state renders, the screen is full height, the clock ticks from the time
/// media first flowed, and the window of the calls goes up and down.
@MainActor
@Suite struct CallScreenTests {
    static let since = Date(timeIntervalSince1970: 1_791_384_000)

    static func live(_ phase: CallPhase, muted: Bool = false, reconnecting: Bool = false) -> CallUiState {
        CallUiState(
            call: .live(CallState.Live(
                connectionId: "c1", direction: phase == .incoming ? .incoming : .outgoing, phase: phase, muted: muted,
                activeSince: phase == .active ? since : nil, reconnecting: reconnecting
            )),
            name: "Ada Lovelace", firstName: "Ada", speaker: false, canSpeaker: true
        )
    }

    static func ended(_ reason: CallEnd) -> CallUiState {
        CallUiState(
            call: .ended(CallState.Ended(connectionId: "c1", direction: .outgoing, reason: reason)), name: "Ada Lovelace", firstName: "Ada"
        )
    }

    func host(_ state: CallUiState) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let screen = CallScreen(state, actions: CallActions(), now: { Self.since.addingTimeInterval(252) })
        window.rootViewController = UIHostingController(rootView: screen.vettIDTheme(.light))
        window.isHidden = false
        window.layoutIfNeeded()
        return window
    }

    private func views(in view: UIView) -> [UIView] { [view] + view.subviews.flatMap { views(in: $0) } }

    @Test func everyLiveStateRendersFullScreen() {
        let phases: [CallPhase] = [.starting, .calling, .ringing, .incoming, .connecting, .active]
        for phase in phases {
            let w = host(Self.live(phase))
            #expect(w.rootViewController?.view.bounds.height == 844, "\(phase)")
            w.isHidden = true
        }
        host(Self.live(.active, muted: true, reconnecting: true)).isHidden = true
    }

    @Test func everyEndingRenders() {
        for reason in CallEnd.allCases {
            let w = host(Self.ended(reason))
            #expect(w.rootViewController?.view.bounds.height == 844, "\(reason)")
            w.isHidden = true
        }
    }

    @Test func theTimeIsCountedFromTheFirstMedia() {
        #expect(CallElapsed.text(since: Self.since, now: Self.since.addingTimeInterval(252)) == "4:12")
        #expect(CallElapsed.text(since: Self.since, now: Self.since.addingTimeInterval(3852)) == "1:04:12")
        #expect(CallElapsed.text(since: nil, now: Self.since) == "0:00")
        // A clock set back never shows a negative time.
        #expect(CallElapsed.text(since: Self.since, now: Self.since.addingTimeInterval(-5)) == "0:00")
    }

    /// Above sheets and alerts of the app, below the app lock's window (alert + 0.5) and the privacy shield's (alert + 1): the app
    /// lock covers a call without ending it.
    @Test func theCallsWindowIsAboveTheAppAndBelowTheLock() {
        #expect(CallsWindow.level == .alert)
        #expect(CallsWindow.level > .normal && CallsWindow.level < UIWindow.Level.alert + 0.5)
    }
}
#endif
