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

/// A message that arrives in the open conversation is told to VoiceOver; the member's own, the opening load, a page of
/// older messages and what arrives under the app lock are not (I4 audit, accessibility).
@MainActor
@Suite(.serialized) struct ArrivalsTests {
    /// What this suite's messages said: every text here has [tag], so another suite's announcements (the sink is shared by
    /// the suites running in parallel) are not counted.
    private static var recorded: [String] = []
    private static let tag = "arrival-"

    private func message(_ id: String, outgoing: Bool = false, text: String? = nil) -> MessageInfo {
        MessagesScreensTests.message(id, outgoing: outgoing, text: text ?? "\(Self.tag)\(id)")
    }

    private func key(_ ids: [String], loading: Bool = false) -> AnnouncesArrivals.Key {
        AnnouncesArrivals.Key(loading: loading, ids: ids)
    }

    private func arrivals(_ old: [String], loading: Bool = false, _ new: [MessageInfo], had: Bool = false) -> [String] {
        AnnouncesArrivals.arrivals(after: key(old, loading: loading), in: new, hadMessages: had).map(\.messageID)
    }

    @Test func onlyNewIncomingMessagesAtTheEndArrive() {
        let old = [message("m1"), message("m2")]
        // A new incoming message and the member's own after it: only the incoming one.
        #expect(arrivals(["m1", "m2"], old + [message("m3"), message("m4", outgoing: true)], had: true) == ["m3"])
        // A page of older messages above: nothing.
        #expect(arrivals(["m1", "m2"], [message("m0"), message("m00")] + old, had: true).isEmpty)
        // The opening load: nothing, whatever it brings.
        #expect(arrivals([], loading: true, old).isEmpty && arrivals(["m1"], loading: true, old, had: true).isEmpty)
        // The first message of a loaded, empty conversation arrives; a page after a clear does not.
        #expect(arrivals([], [message("m1")]) == ["m1"])
        #expect(arrivals([], old, had: true).isEmpty)
        // The last message deleted: what follows cannot be told, so nothing.
        #expect(arrivals(["m1", "m2"], [message("m1")], had: true).isEmpty)
        // A change of state (read, delivered) of the same messages: nothing.
        #expect(arrivals(["m1", "m2"], old, had: true).isEmpty)
        // Many at once: the newest three.
        let many = (3...9).map { message("m\($0)") }
        #expect(arrivals(["m1", "m2"], old + many, had: true) == ["m7", "m8", "m9"])
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
        try await hosted(loaded([message("m1")])) { holder in
            holder.state.messages.append(message("m2", outgoing: true))
            holder.state.messages.insert(message("m0"), at: 0)
            try await Task.sleep(for: .milliseconds(300))
            #expect(Self.recorded.isEmpty)
            holder.state.messages.append(message("m3"))
            #expect(await eventually { !Self.recorded.isEmpty })
            #expect(Self.recorded.count == 1 && Self.recorded.first?.hasSuffix(": \(Self.tag)m3") == true)
        }
    }

    /// The opening load (the spinner, then the list) says nothing; a message after it does.
    @Test func afterTheLoadingAnArrivalIsAnnounced() async throws {
        var s = loaded([])
        s.loading = true
        try await hosted(s) { holder in
            holder.state.messages = [message("m1"), message("m2")]
            holder.state.loading = false
            try await Task.sleep(for: .milliseconds(300))
            #expect(Self.recorded.isEmpty)
            holder.state.messages.append(message("m3"))
            #expect(await eventually { Self.recorded.count == 1 })
        }
    }

    /// An empty conversation ("Say hello") announces its first message.
    @Test func theFirstMessageIsAnnounced() async throws {
        try await hosted(loaded([])) { holder in
            holder.state.messages = [message("m1")]
            #expect(await eventually { Self.recorded.count == 1 })
        }
    }

    /// Under the app lock or in the background nothing is said, and the messages cleared and brought back after the lock
    /// are not news.
    @Test func nothingIsAnnouncedUnderTheLock() async throws {
        try await hosted(loaded([message("m1")]), locked: true) { holder in
            holder.state.messages.append(message("m2"))
            try await Task.sleep(for: .milliseconds(300))
            #expect(Self.recorded.isEmpty)
            holder.locked = false
            holder.phase = .background
            holder.state.messages.append(message("m3"))
            try await Task.sleep(for: .milliseconds(300))
            #expect(Self.recorded.isEmpty)
            holder.phase = .active
            holder.state.messages = []
            try await Task.sleep(for: .milliseconds(100))
            holder.state.messages = [message("m1"), message("m2"), message("m3"), message("m4")]
            try await Task.sleep(for: .milliseconds(300))
            #expect(Self.recorded.isEmpty)
        }
    }

    private func loaded(_ messages: [MessageInfo]) -> ConversationState {
        var s = ConversationState(connectionID: "c1")
        s.connection = MessagesScreensTests.connection("c1")
        s.loading = false
        s.messages = messages
        return s
    }

    /// Runs [body] with the conversation on screen in an active scene (set here: a test window has no scene phase of its
    /// own), recording this suite's announcements.
    private func hosted(
        _ state: ConversationState, locked: Bool = false, _ body: (ConversationHolder) async throws -> Void
    ) async throws {
        let saved = Announcer.sink
        Self.recorded = []
        Announcer.sink = { event in
            if case .announcement(let text, .polite) = event, text.contains(Self.tag) { Self.recorded.append(text) }
        }
        defer { Announcer.sink = saved }
        let holder = ConversationHolder(state)
        holder.locked = locked
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIHostingController(rootView: HeldConversation(holder: holder).vettIDTheme())
        window.isHidden = false
        window.layoutIfNeeded()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(300))
        #expect(Self.recorded.isEmpty)
        try await body(holder)
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
    var locked = false
    var phase = ScenePhase.active
    init(_ state: ConversationState) { self.state = state }
}

private struct HeldConversation: View {
    let holder: ConversationHolder
    var body: some View {
        ConversationScreen(state: holder.state, actions: ConversationActions()).environment(\.vettIDLocked, holder.locked)
            .environment(\.scenePhase, holder.phase)
    }
}
#endif
