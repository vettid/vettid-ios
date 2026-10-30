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

    /// A long form whose only problem is the last field's value.
    private var refused: ItemEditState {
        var s = ItemEditState()
        s.loading = false
        var fields = (0..<14).map { DraftField(label: "Line \($0)", kind: FieldKinds.text, text: "Value \($0)") }
        fields.append(DraftField(label: "Expires", kind: FieldKinds.date, text: "1st of May"))
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
        Announcer.sink = { Self.recorded.append($0) }
        defer { Announcer.sink = saved }
        let holder = EditHolder(refused)
        #expect(holder.state.firstProblem == .field(14) && holder.state.problemCount == 1)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIHostingController(rootView: HeldEdit(holder: holder).vettIDTheme())
        window.isHidden = false
        window.layoutIfNeeded()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(200))
        #expect(!Self.recorded.contains { if case .announcement(let t, _) = $0 { t.hasPrefix("Check the item:") } else { false } })
        holder.state.refusedSaves += 1
        #expect(await eventually { Self.recorded.contains(.announcement("Check the item: 1 problem", .queued)) } != nil)
        // Said again at the next refusal.
        holder.state.refusedSaves += 1
        #expect(await eventually { Self.recorded.filter { $0 == .announcement("Check the item: 1 problem", .queued) }.count == 2 } != nil)
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
