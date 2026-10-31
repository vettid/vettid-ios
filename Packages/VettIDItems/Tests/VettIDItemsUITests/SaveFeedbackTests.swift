#if os(iOS)
import Foundation
import Observation
import SwiftUI
import Testing
import UIKit
import VettIDData
@testable import VettIDItems
@testable import VettIDItemsUI
@testable import VettIDUI

/// A refused save takes the member to the first problem, wherever "Save item" was pressed, and says how many problems
/// there are (I4 audit, accessibility).
@MainActor
@Suite(.serialized) struct SaveFeedbackTests {
    private static var recorded: [Announcer.Event] = []

    /// This test's announcements only: the sink is shared by the suites running in parallel, whose screens say other
    /// things meanwhile, and by this suite's earlier forms, which may still be going away. Each test's form has its own
    /// number of problems.
    private static func ours(_ text: String) -> (Announcer.Event) -> Bool {
        { if case .announcement(let t, _) = $0 { t == text } else { false } }
    }

    /// A long form whose problems are its last fields' values.
    private func refused(problems: Int) -> ItemEditState {
        var s = ItemEditState()
        s.loading = false
        var fields = (0..<14).map { DraftField(label: "Line \($0)", kind: FieldKinds.text, text: "Value \($0)") }
        fields += (0..<problems).map { DraftField(label: "Expires \($0)", kind: FieldKinds.date, text: "1st of May") }
        s.draft = ItemDraft(name: "Card", fields: fields)
        s.check = ItemChecks.check(s.draft)
        s.showErrors = true
        return s
    }

    /// A refused save renders with its errors and tells VoiceOver how many problems there are, queued behind the problem it
    /// moves to. The scroll to the first problem (``ScrollViewReader`` on an anchor in the scroll view's layout) is not
    /// observable in a hosted test; it is checked on the iPhone.
    @Test func aRefusedSaveSaysHowManyProblems() async throws {
        let saved = Announcer.sink
        Self.recorded = []
        let ours = Self.ours("Check the item: 1 problem")
        Announcer.sink = { if ours($0) { Self.recorded.append($0) } }
        defer { Announcer.sink = saved }
        let holder = EditHolder(refused(problems: 1))
        #expect(holder.state.firstProblem == .field(14) && holder.state.problemCount == 1)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIHostingController(rootView: HeldEdit(holder: holder).vettIDTheme())
        window.isHidden = false
        window.layoutIfNeeded()
        defer { window.rootViewController = nil; window.isHidden = true }
        try await Task.sleep(for: .milliseconds(200))
        #expect(Self.recorded.isEmpty)
        holder.state.refusedSaves += 1
        #expect(await eventually { Self.recorded.contains(.announcement("Check the item: 1 problem", .queued)) } != nil)
        // Said again at the next refusal.
        holder.state.refusedSaves += 1
        #expect(await eventually { Self.recorded.filter { $0 == .announcement("Check the item: 1 problem", .queued) }.count == 2 } != nil)
        try await Task.sleep(for: .milliseconds(1_000))
        #expect(Self.recorded.count == 2, "\(Self.recorded)")
    }

    /// A refusal already counted when the screen appears, or the form coming back after the password step, says nothing
    /// and moves nothing: only a new refusal is acted on.
    @Test func onlyANewRefusalIsActedOn() async throws {
        let saved = Announcer.sink
        Self.recorded = []
        let ours = Self.ours("Check the item: 2 problems")
        Announcer.sink = { if ours($0) { Self.recorded.append($0) } }
        defer { Announcer.sink = saved }
        var already = refused(problems: 2)
        already.refusedSaves = 1
        let holder = EditHolder(already)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIHostingController(rootView: HeldEdit(holder: holder).vettIDTheme())
        window.isHidden = false
        window.layoutIfNeeded()
        defer { window.rootViewController = nil; window.isHidden = true }
        try await Task.sleep(for: .milliseconds(800))
        #expect(Self.recorded.isEmpty)
        holder.state.refusedSaves += 1
        #expect(await eventually { Self.recorded.count == 1 } != nil)
        // The password step takes the form away and gives it back: nothing is said again.
        holder.state.prompt = PasswordPrompt(.save)
        try await Task.sleep(for: .milliseconds(300))
        holder.state.prompt = nil
        try await Task.sleep(for: .milliseconds(800))
        #expect(Self.recorded.count == 1)
    }

    /// The scroll waits for the first problem's place: the list of the others appears with the refusal, so its place is
    /// known only after the form's next layout. Then it is taken once.
    @Test func theScrollWaitsForTheProblemsPlace() {
        var scroll = ProblemScroll(pending: .summary)
        #expect(scroll.take([.name: .zero]) == nil && scroll.pending == .summary)
        #expect(scroll.take([.name: .zero, .summary: CGRect(x: 0, y: 900, width: 300, height: 80)]) == .summary)
        #expect(scroll.pending == nil && scroll.take([.summary: .zero]) == nil)
        var none = ProblemScroll()
        #expect(none.take([.name: .zero]) == nil)
    }

    private func eventually<T>(_ value: @MainActor () -> T?) async -> T? {
        let clock = ContinuousClock()
        let end = clock.now.advanced(by: .seconds(5))
        while clock.now < end {
            if let v = value() { return v }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return value()
    }

    private func eventually(_ condition: @MainActor () -> Bool) async -> Bool? {
        await eventually { condition() ? true : nil }
    }
}

@MainActor @Observable
private final class EditHolder {
    var state: ItemEditState
    init(_ state: ItemEditState) { self.state = state }
}

private struct HeldEdit: View {
    let holder: EditHolder
    var body: some View { ItemEditScreen(state: holder.state, actions: ItemEditActions()) }
}
#endif
