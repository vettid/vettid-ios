#if os(iOS)
import Foundation
import Observation
import SwiftUI
import Testing
import UIKit
import VettIDData
import VettIDMessages
@testable import VettIDMessagesUI
@testable import VettIDUI

/// A message that arrives in the open conversation is told to VoiceOver; the member's own, the opening load and a page of
/// older messages are not (I4 audit, accessibility).
@MainActor
@Suite(.serialized) struct ArrivalsTests {
    private static var recorded: [Announcer.Event] = []

    private func message(_ id: String, outgoing: Bool = false, text: String = "Hello") -> MessageInfo {
        MessagesScreensTests.message(id, outgoing: outgoing, text: text)
    }

    private func key(_ ids: [String], loading: Bool = false) -> AnnouncesArrivals.Key {
        AnnouncesArrivals.Key(loading: loading, ids: ids)
    }

    @Test func onlyNewIncomingMessagesAtTheEndArrive() {
        let old = [message("m1"), message("m2")]
        // A new incoming message and the member's own after it: only the incoming one.
        let new = old + [message("m3"), message("m4", outgoing: true)]
        #expect(AnnouncesArrivals.arrivals(after: key(["m1", "m2"]), in: new).map(\.messageID) == ["m3"])
        // A page of older messages above: nothing.
        let older = [message("m0"), message("m00")] + old
        #expect(AnnouncesArrivals.arrivals(after: key(["m1", "m2"]), in: older).isEmpty)
        // The opening load: nothing, whatever it brings.
        #expect(AnnouncesArrivals.arrivals(after: key([], loading: true), in: old).isEmpty)
        #expect(AnnouncesArrivals.arrivals(after: key(["m1"], loading: true), in: old).isEmpty)
        // The first message of a loaded, empty conversation arrives.
        #expect(AnnouncesArrivals.arrivals(after: key([]), in: [message("m1")]).map(\.messageID) == ["m1"])
        // The last message deleted: what follows cannot be told, so nothing.
        #expect(AnnouncesArrivals.arrivals(after: key(["m1", "m2"]), in: [message("m1")]).isEmpty)
        // A change of state (read, delivered) of the same messages: nothing.
        #expect(AnnouncesArrivals.arrivals(after: key(["m1", "m2"]), in: old).isEmpty)
    }

    @Test func anArrivalIsTheSenderAndTheText() {
        #expect(AnnouncesArrivals.spoken(message("m1", text: "See you at 6"), "Ada") == "Ada: See you at 6")
        var photo = message("m2", text: "")
        photo.attachment = AttachmentInfo(attID: "a1", state: .stored)
        #expect(AnnouncesArrivals.spoken(photo, "Ada") == "Photo from Ada")
        photo.text = "The beach"
        #expect(AnnouncesArrivals.spoken(photo, "Ada") == "Photo from Ada. The beach")
    }

    /// On screen: a new incoming message is announced, politely; the member's own and an older page are not.
    @Test func theOpenConversationAnnouncesAnArrival() async throws {
        let saved = Announcer.sink
        Self.recorded = []
        Announcer.sink = { Self.recorded.append($0) }
        defer { Announcer.sink = saved }
        var s = ConversationState(connectionID: "c1")
        s.connection = MessagesScreensTests.connection("c1")
        s.loading = false
        s.messages = [message("m1")]
        let holder = ConversationHolder(s)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIHostingController(rootView: HeldConversation(holder: holder).vettIDTheme())
        window.isHidden = false
        window.layoutIfNeeded()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(300))
        #expect(Self.recorded.isEmpty)
        holder.state.messages.append(message("m2", outgoing: true, text: "Mine"))
        holder.state.messages.insert(message("m0", text: "Older"), at: 0)
        try await Task.sleep(for: .milliseconds(300))
        #expect(Self.recorded.isEmpty)
        holder.state.messages.append(message("m3", text: "Theirs"))
        #expect(await eventually { !Self.recorded.isEmpty })
        #expect(Self.recorded.count == 1)
        guard case .announcement(let text, let priority) = Self.recorded.first else { Issue.record("no announcement"); return }
        #expect(text.hasSuffix(": Theirs") && priority == .polite)
    }

    private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let end = clock.now.advanced(by: .seconds(5))
        while clock.now < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}

@MainActor @Observable
private final class ConversationHolder {
    var state: ConversationState
    init(_ state: ConversationState) { self.state = state }
}

private struct HeldConversation: View {
    let holder: ConversationHolder
    var body: some View { ConversationScreen(state: holder.state, actions: ConversationActions()) }
}
#endif
