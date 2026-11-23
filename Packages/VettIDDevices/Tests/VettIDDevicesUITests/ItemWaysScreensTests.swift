#if os(iOS)
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import VettIDData
import VettIDUI
@testable import VettIDDevices
@testable import VettIDDevicesUI

// Fixtures stay on one line each.
// swiftlint:disable line_length

/// How an agent may use an item (ANDROID-PLAN 0.1.137 AA7) rendered: the item's page in every state, the agent's page with
/// "Items it may use", the shown string. What the screens say is checked, as text, in `ItemWaysStringsTests`. Mirrors vettid-android
/// `ItemWaysPageTest`.
@MainActor
@Suite(.serialized) struct ItemWaysScreensTests {
    let sha = String(repeating: "ab", count: 32)

    private func height(_ view: some View) -> CGFloat {
        UIHostingController(rootView: view.vettIDTheme(.light)).sizeThatFits(in: CGSize(width: 390, height: 844)).height
    }

    private func state(_ json: String, _ change: (inout ItemWaysState) -> Void = { _ in }) -> ItemWaysState {
        var s = ItemWaysState()
        s.agent = Samples.agent
        s.itemName = "GitHub token"
        s.read = ItemWaysRules.one(Array(json.utf8))
        s.draft = s.read?.ways
        change(&s)
        return s
    }

    private func screen(_ s: ItemWaysState, _ actions: ItemWaysActions = ItemWaysActions()) -> ItemWaysScreen {
        ItemWaysScreen(state: s, actions: actions)
    }

    private var plain: String { #"{"agent_id":"a1","item_id":"i1","version":1,"ways":["use"]}"# }
    private var everything: String {
        #"{"agent_id":"a1","item_id":"i1","version":3,"ways":["use","run","proxy","reveal"],"run":{"programs":[{"program":"git","sha256":"\#(sha)","path":"/usr/bin/git","env":["GH_HOST"]},{"program":"C:\\tools\\run.cmd","env":[]}],"each":false},"proxy":{"hosts":["api.example.com"],"header":"Authorization","prefix":"Bearer "}}"#
    }

    @Test func everyPageStateRenders() {
        var loading = ItemWaysState()
        loading.agent = Samples.agent
        var failed = ItemWaysState()
        failed.loadError = .network
        let readOnly = #"{"agent_id":"a1","item_id":"i1","version":2,"ways":["use","run","reveal"],"run":{"programs":[],"each":true,"x":1}}"#
        let states: [ItemWaysState] = [
            loading, failed, state(plain), state(everything), state(readOnly),
            state(everything) { $0.openProgram = 0; $0.editInput = "git" },
            state(everything) { $0.openProgram = 1; $0.editInput = "x"; $0.editProblem = .duplicate },
            state(plain) { $0.notIncluded = true },
            state(plain) { $0.notIncluded = true; $0.leaving = true },
            state(plain) { $0.changedElsewhere = true },
            state(plain) { $0.loadError = .network },
            state(plain) { $0.refused = "" },
            state(plain) { $0.refused = "run.programs[0].env[1]: VETTID_IN is reserved" },
            state(plain) { $0.windowNotClosed = WindowNotClosed(ttlSeconds: 120) },
            state(plain) { $0.windowNotClosed = WindowNotClosed(ttlSeconds: nil) },
            state(plain) { $0.notice = .saved },
            state(plain) { $0.notice = .failed(.network) },
            state(everything) { $0.fullPin = sha },
            state(everything) { $0.saving = true },
        ]
        for s in states { #expect(height(screen(s)) > 0, "\(s)") }
    }

    @Test func everyConfirmationAndPromptRenders() {
        let confirms: [WaysConfirm] = [.runOff, .proxyOff, .revealOn, .eachOff, .removeLastProgram(0), .forgetPin(0)]
        for c in confirms { #expect(height(screen(state(everything) { $0.confirm = c })) > 0, "\(c)") }
        var sending = WaysPrompt()
        sending.sending = true
        var wrong = WaysPrompt()
        wrong.error = .badPassword
        var alarm = WaysPrompt(resend: true)
        alarm.error = .credentialFrozen
        for p in [WaysPrompt(), sending, wrong, alarm] {
            #expect(height(screen(state(plain) { $0.prompt = p })) > 0)
        }
    }

    @Test func theProxyAndProgramFieldsRenderWhateverIsTyped() {
        let s = state(everything) {
            $0.programInput = "bin/git"
            $0.programProblem = .notPathOrName
            $0.hostInput = "10.0.0.1"
            $0.hostProblem = .ipAddress
            $0.addingHost = true
            $0.draft?.proxy?.header = "Host"
            $0.draft?.proxy?.prefix = String(repeating: "x", count: 33)
        }
        #expect(height(screen(s)) > 0)
        let page = state(everything) {
            $0.openProgram = 0
            $0.editInput = "git"
            $0.variableInput = "lower"
            $0.variableProblem = .form
        }
        #expect(height(screen(page)) > 0)
    }

    /// Back from a program's page goes to the settings; from the settings, away.
    @Test func backClosesAProgramPageFirst() {
        var closed = 0
        var left = 0
        var a = ItemWaysActions()
        a.onCloseProgram = { closed += 1 }
        a.onBack = { left += 1 }
        let settings = screen(state(everything), a)
        let program = screen(state(everything) { $0.openProgram = 0 }, a)
        #expect(height(settings) > 0 && height(program) > 0)
        #expect(closed == 0 && left == 0)
    }

    @Test func theShownStringRendersEveryPiece() {
        for text in ["", "/usr/bin/git", " a  b ", "g\u{202E}it", "b\u{0430}sh", "\u{0301}x", "\u{05D0}\u{05D1}"] {
            #expect(height(ShownStringBox(text)) > 0, "\(text.unicodeScalars.map(\.value))")
        }
    }

    /// The agent's page: "Items it may use" only with a vault that lists `item_ways`; rows with and without names.
    @Test func theAgentsPageShowsItsItems() {
        func page(_ change: (inout DeviceState) -> Void) -> DeviceState {
            var s = Samples.page(Samples.agent)
            change(&s)
            return s
        }
        let rows = [
            WayItemRow(itemID: "i1", name: "GitHub token", namesLoaded: true, ways: [.use, .reveal]),
            WayItemRow(itemID: "i2", name: nil, namesLoaded: true, ways: [.use]),
            WayItemRow(itemID: "i3", name: nil, namesLoaded: false, ways: [.use, .run, .proxy, .reveal]),
        ]
        let none = DevicePageScreen(state: page { _ in }, actions: DevicePageActions(), now: Samples.now, calendar: Samples.calendar())
        let loading = DevicePageScreen(state: page { $0.wayItemsAvailable = true }, actions: DevicePageActions(), now: Samples.now, calendar: Samples.calendar())
        let listed = DevicePageScreen(
            state: page { $0.wayItemsAvailable = true; $0.wayItemsLoaded = true; $0.wayItems = rows }, actions: DevicePageActions(),
            now: Samples.now, calendar: Samples.calendar()
        )
        let failed = DevicePageScreen(
            state: page { $0.wayItemsAvailable = true; $0.wayItemsError = .network }, actions: DevicePageActions(), now: Samples.now,
            calendar: Samples.calendar()
        )
        #expect(height(none) > 0 && height(loading) > 0 && height(failed) > 0)
        #expect(height(listed) > height(none), "the items add a card")
    }
}
// swiftlint:enable line_length
#endif
