import Observation
import SwiftUI
import Testing
import UIKit
@testable import VettIDUI

/// What is spoken to VoiceOver by itself (I4 audit, accessibility: results and step changes were silent): a live text when
/// it appears and when it changes, a notice only when asked, a countdown once, a step change as a new screen.
@MainActor
@Suite(.serialized) struct AnnouncementsTests {
    @Test func aLiveTextIsSpokenWhenItAppearsAndWhenItChanges() async {
        let model = Live(text: "Wrong PIN")
        let events = await recording {
            let window = host(LiveText(model: model))
            #expect(await eventually { $0.contains(.announcement("Wrong PIN", .assertive)) })
            model.text = "2 checks left"
            #expect(await eventually { $0.contains(.announcement("2 checks left", .assertive)) })
            model.text = nil
            window.isHidden = true
        }
        #expect(events.filter { $0 == .announcement("Wrong PIN", .assertive) }.count == 1)
    }

    @Test func aNoticeIsSpokenOnlyWhenItAsksToBe() async {
        let events = await recording {
            let window = host(VStack {
                NoticeCard(.urgent, title: "Unlock failed", message: "Check your connection.", announce: .assertive)
                NoticeCard(.info, title: "Quiet notice", message: "Not spoken.")
                NoticeCard(.success, title: "Locked", message: "", announce: .polite)
            })
            #expect(await eventually { $0.contains(.announcement("Locked", .polite)) })
            window.isHidden = true
        }
        #expect(events.contains(.announcement("Unlock failed. Check your connection.", .assertive)))
        #expect(!events.contains { if case .announcement(let t, _) = $0 { t.contains("Quiet notice") } else { false } })
    }

    @Test func aNoticeWhoseMessageCountsDownIsSpokenOnce() async {
        let model = Live(text: "Try again in 0:30")
        let events = await recording {
            let window = host(Countdown(model: model))
            #expect(await eventually { $0.contains(.announcement("Failed. Too many tries.", .assertive)) })
            model.text = "Try again in 0:29"
            try? await Task.sleep(for: .milliseconds(200))
            window.isHidden = true
        }
        #expect(events.filter { $0 == .announcement("Failed. Too many tries.", .assertive) }.count == 1)
    }

    @Test func aCountdownIsSpokenOnce() async {
        let model = Live(text: "Try again in 30 s")
        let events = await recording {
            let window = host(Once(model: model))
            #expect(await eventually { $0.contains(.announcement("Try again in 30 s", .polite)) })
            model.text = "Try again in 29 s"
            try? await Task.sleep(for: .milliseconds(200))
            window.isHidden = true
        }
        #expect(!events.contains(.announcement("Try again in 29 s", .polite)))
    }

    @Test func aStepChangeIsANewScreenAndTheFirstStepIsNot() async {
        let model = Live(text: "one")
        let events = await recording {
            let window = host(Steps(model: model))
            try? await Task.sleep(for: .milliseconds(200))
            #expect(!Self.recorded.contains(.screenChanged))
            model.text = "two"
            #expect(await eventually { $0.contains(.screenChanged) })
            window.isHidden = true
        }
        #expect(events.filter { $0 == .screenChanged }.count == 1)
    }

    @Test func anEmptyTextIsNotSpoken() async {
        let events = await recording { Announcer.announce("") }
        #expect(events.isEmpty)
    }

    // MARK: - Helpers

    private static var recorded: [Announcer.Event] = []

    /// What was posted while [body] ran (other suites' screens may post too: the checks look for their own texts).
    private func recording(_ body: () async -> Void) async -> [Announcer.Event] {
        let saved = Announcer.sink
        Self.recorded = []
        Announcer.sink = { Self.recorded.append($0) }
        await body()
        Announcer.sink = saved
        return Self.recorded
    }

    private func eventually(_ condition: @MainActor ([Announcer.Event]) -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let end = clock.now.advanced(by: .seconds(5))
        while clock.now < end {
            if condition(Self.recorded) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition(Self.recorded)
    }

    private func host(_ view: some View) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIHostingController(rootView: view.vettIDTheme())
        window.isHidden = false
        window.layoutIfNeeded()
        return window
    }
}

@MainActor @Observable
private final class Live {
    var text: String?
    init(text: String?) { self.text = text }
}

private struct LiveText: View {
    let model: Live
    var body: some View { Text(model.text ?? "").announced(model.text, .assertive) }
}

private struct Once: View {
    let model: Live
    var body: some View { Text(model.text ?? "").announcedOnce(model.text ?? "") }
}

private struct Countdown: View {
    let model: Live
    var body: some View {
        NoticeCard(
            .urgent, title: "Failed", message: model.text ?? "", announce: .assertive, announcement: "Failed. Too many tries."
        )
    }
}

private struct Steps: View {
    let model: Live
    var body: some View { Text(model.text ?? "").announcesStepChanges(of: model.text) }
}
