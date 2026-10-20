import Foundation
import Testing
import VettIDData
import VettIDDataTesting
@testable import VettIDMessages

/// A conversation (ANDROID-PLAN §4; VAULT-MESSAGING §10.5, §10.5.2): loading, read marking while open, the draft and its
/// limit, sending, older pages, deleting once confirmed, and the link question. Mirrors vettid-android
/// `ConversationViewModelTest` without its photos.
@MainActor
@Suite struct ConversationViewModelTests {
    let messages = FakeMessages()
    let connections = FakeConnections()

    init() {
        connections.connections = [Samples.connection("c1")]
        messages.connections = connections.connections
    }

    func model(_ id: String = "c1") async -> ConversationViewModel {
        let m = ConversationViewModel(connectionID: id, messages: messages, connections: connections)
        await m.settle()
        return m
    }

    @Test func itLoadsTheConversation() async {
        messages.byConnection = ["c1": [Samples.message("m1", read: true), Samples.message("m2", outgoing: true)]]
        let m = ConversationViewModel(connectionID: "c1", messages: messages, connections: connections)
        #expect(m.state.loading)
        await m.settle()
        #expect(!m.state.loading && m.state.error == nil && m.state.active)
        #expect(m.state.messages.map(\.messageID) == ["m1", "m2"] && m.state.connection?.id == "c1")
        // The list had the connection: it is not read again.
        #expect(messages.calls == ["load:c1"] && connections.calls.isEmpty)
    }

    /// A connection not in the list (opened from elsewhere) is read once.
    @Test func aConnectionNotListedIsRead() async {
        connections.connections = []
        let m = ConversationViewModel(connectionID: "c1", messages: messages, connections: connections)
        await m.settle()
        #expect(m.state.error == .notFound && m.state.connection == nil && !m.state.loading)
        #expect(connections.calls == ["connection"] && messages.calls.isEmpty)
    }

    @Test func aFailedLoadSaysWhy() async {
        messages.fail["load"] = VaultFailure(.network)
        let m = await model()
        #expect(m.state.error == .network && !m.state.loading)
        m.dismissError()
        #expect(m.state.error == nil)
    }

    /// Incoming messages are marked read while the conversation is open: those there on opening, and each new one; a
    /// failure is left for the next arrival.
    @Test func incomingMessagesAreMarkedReadWhileOpen() async {
        messages.byConnection = ["c1": [Samples.message("m1")]]
        let m = await model()
        #expect(messages.calls == ["load:c1", "markRead:c1"] && m.state.messages.allSatisfy(\.read))
        messages.fail["markRead"] = VaultFailure(.network)
        messages.byConnection["c1", default: []].append(Samples.message("m2"))
        await m.settle()
        #expect(messages.calls.filter { $0 == "markRead:c1" }.count == 2 && m.state.error == nil)
        #expect(m.state.messages.last?.read == false)
        messages.byConnection["c1", default: []].append(Samples.message("m3"))
        await m.settle()
        #expect(messages.calls.filter { $0 == "markRead:c1" }.count == 3 && m.state.messages.allSatisfy(\.read))
        // An outgoing message is nothing to mark.
        messages.byConnection["c1", default: []].append(Samples.message("m4", outgoing: true))
        await m.settle()
        #expect(messages.calls.filter { $0 == "markRead:c1" }.count == 3)
    }

    @Test func sendingClearsTheDraft() async {
        let m = await model()
        #expect(!m.state.canSend)
        m.setDraft("  Hello there \n")
        #expect(m.state.canSend)
        m.send()
        #expect(m.state.sending && !m.state.canSend)
        await m.settle()
        #expect(!m.state.sending && m.state.draft.isEmpty && m.state.error == nil)
        #expect(m.state.messages.last?.text == "Hello there" && m.state.messages.last?.outgoing == true)
    }

    /// A failed send keeps the draft for another try.
    @Test func aFailedSendKeepsTheDraft() async {
        let m = await model()
        messages.fail["send"] = VaultFailure(.limit)
        m.setDraft("Hello")
        m.send()
        await m.settle()
        #expect(m.state.error == .limit && m.state.draft == "Hello" && !m.state.sending && m.state.canSend)
        m.send()
        await m.settle()
        #expect(m.state.error == nil && m.state.draft.isEmpty)
    }

    /// 16 KiB in UTF-8 at most (§10.5): over it the composer says so and nothing is sent; blank text is not sent either.
    @Test func theDraftHasItsLimit() async {
        let m = await model()
        m.setDraft(String(repeating: "a", count: MessageLimits.maxTextBytes))
        #expect(!m.state.tooLong && m.state.canSend)
        m.setDraft(String(repeating: "é", count: MessageLimits.maxTextBytes / 2 + 1))
        #expect(m.state.tooLong && !m.state.canSend)
        m.send()
        m.setDraft("   \n ")
        #expect(!m.state.tooLong && !m.state.canSend)
        m.send()
        await m.settle()
        #expect(!messages.calls.contains("send:c1"))
    }

    /// A connection that is not active cannot be written to.
    @Test func anInactiveConnectionCannotBeWrittenTo() async {
        connections.connections[0].state = .blocked
        let m = await model()
        m.setDraft("Hello")
        #expect(!m.state.active && !m.state.canSend)
        m.send()
        await m.settle()
        #expect(!messages.calls.contains("send:c1"))
    }

    /// Older pages one at a time (§10.5.2), put before what is loaded; a failure is shown and the next try reads again.
    @Test func olderPagesLoadOneAtATime() async {
        messages.byConnection = ["c1": [Samples.message("m3", read: true)]]
        messages.olderPages = ["c1": [[Samples.message("m1", read: true)], [Samples.message("m2", read: true)]]]
        let m = await model()
        #expect(m.state.olderAvailable)
        m.loadOlder()
        m.loadOlder()
        #expect(m.state.loadingOlder)
        await m.settle()
        #expect(!m.state.loadingOlder && m.state.messages.map(\.messageID) == ["m2", "m3"] && m.state.olderAvailable)
        #expect(messages.calls.filter { $0 == "loadOlder:c1" }.count == 1)
        messages.fail["loadOlder"] = VaultFailure(.responseTooLarge)
        m.loadOlder()
        await m.settle()
        #expect(m.state.error == .responseTooLarge && !m.state.loadingOlder && m.state.messages.count == 2)
        m.loadOlder()
        await m.settle()
        #expect(m.state.messages.map(\.messageID) == ["m1", "m2", "m3"] && !m.state.olderAvailable)
        m.loadOlder()
        await m.settle()
        #expect(messages.calls.filter { $0 == "loadOlder:c1" }.count == 3)
    }

    /// Deleting is confirmed first, and removes the message from this vault only.
    @Test func deletingIsConfirmed() async {
        let msg = Samples.message("m1", outgoing: true)
        messages.byConnection = ["c1": [msg]]
        let m = await model()
        m.confirmDelete()
        m.askDelete(msg)
        #expect(m.state.deleting == msg)
        m.askDelete(nil)
        #expect(m.state.deleting == nil)
        m.askDelete(msg)
        m.confirmDelete()
        #expect(m.state.deleting == nil)
        await m.settle()
        #expect(m.state.messages.isEmpty && messages.calls.filter { $0 == "delete:c1" }.count == 1)
        messages.byConnection = ["c1": [msg]]
        messages.fail["delete"] = VaultFailure(.network)
        m.askDelete(msg)
        m.confirmDelete()
        await m.settle()
        #expect(m.state.error == .network && m.state.messages.count == 1)
    }

    /// A tapped link is asked about by its host, and handed on only once confirmed and checked again (§10.5 "Links").
    @Test func aLinkIsAskedAboutFirst() async throws {
        let m = await model()
        m.askOpen(try #require(URL(string: "https://Example.org/a?b=1#c")))
        #expect(m.state.link?.host == "example.org")
        m.dismissLink()
        #expect(m.state.link == nil && m.confirmLink() == nil)
        m.askOpen(try #require(URL(string: "https://example.org/a")))
        let url = m.confirmLink()
        #expect(url?.absoluteString == "https://example.org/a" && m.state.link == nil)
        #expect(m.confirmLink() == nil)
    }

    /// What the link rule does not make tappable is never asked about.
    @Test func otherLinksAreIgnored() async throws {
        let m = await model()
        for s in ["http://example.org", "vettid://connect#x", "someapp://open", "https://bank.example@other.example/", "https://"] {
            if let url = URL(string: s) { m.askOpen(url) }
            #expect(m.state.link == nil, "\(s)")
        }
    }

    /// The question names an internationalized host in its ASCII form, so that a look-alike shows as what it is.
    @Test func theHostIsShownInASCII() async throws {
        let m = await model()
        let link = try #require(MessageLinks.links(in: "see https://bücher.example/x").first)
        m.askOpen(link.url)
        #expect(m.state.link?.host == "xn--bcher-kva.example")
    }

    @Test func theStateDescribesNoContent() async {
        messages.byConnection = ["c1": [Samples.message("m1", text: "secret plans", read: true)]]
        let m = await model()
        m.setDraft("my draft")
        for text in [String(describing: m.state), String(reflecting: m.state)] {
            #expect(!text.contains("secret") && !text.contains("draft") && !text.contains("Ada"))
        }
        #expect(Mirror(reflecting: m.state).children.isEmpty)
    }
}
