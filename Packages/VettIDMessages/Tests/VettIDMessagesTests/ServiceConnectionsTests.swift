import Foundation
import Testing
import VettIDData
import VettIDDataTesting
@testable import VettIDMessages

/// A service (VAULT-MESSAGING §6.4 "Service connections", IOS-PLAN §4.13) is never in Messages: no conversation row, not
/// offered by the new-message picker; and a message the vault refuses `forbidden` because it went to a service says
/// "Services can't do that." and the composer goes.
@MainActor
@Suite struct ServiceConnectionsTests {
    static func service(_ id: String) -> ConnectionInfo {
        var c = Samples.connection(id, first: "Example")
        c.isService = true
        return c
    }

    @Test func aServiceIsNeverAConversation() async {
        let fake = FakeMessages()
        fake.connections = [Samples.connection("c1"), Self.service("s1")]
        fake.byConnection = ["c1": [Samples.message("m1", at: 100)], "s1": [Samples.message("m2", in: "s1", at: 200)]]
        let m = MessagesViewModel(messages: fake)
        await m.settle()
        #expect(m.state.conversations.map(\.connection.id) == ["c1"])
        m.setQuery("Example")
        #expect(m.state.conversations.isEmpty)
    }

    /// Services alone: Messages has no one to write to, and its empty state invites.
    @Test func withOnlyServicesThereIsNoConversationAtAll() async {
        let fake = FakeMessages()
        fake.connections = [Self.service("s1")]
        let m = MessagesViewModel(messages: fake)
        await m.settle()
        #expect(m.state.conversations.isEmpty && m.state.noConnections && !m.state.searchable)
    }

    @Test func thePickerNeverOffersAService() async {
        let fake = FakeConnections()
        var starred = Self.service("s2")
        starred.favorite = true
        fake.connections = [Samples.connection("c1", first: "Grace"), Self.service("s1"), starred]
        let m = NewMessageViewModel(connections: fake)
        await m.settle()
        #expect(m.state.connections.map(\.id) == ["c1"])
    }

    /// A service's conversation opened anyway (a notification, a link): nothing can be sent, before any refusal.
    @Test func aServicesConversationHasNoComposer() async {
        let messages = FakeMessages()
        let connections = FakeConnections()
        connections.connections = [Self.service("s1")]
        messages.connections = connections.connections
        let m = ConversationViewModel(connectionID: "s1", messages: messages, connections: connections)
        await m.settle()
        m.setDraft("Hello")
        #expect(m.state.noComposer && !m.state.serviceForbidden && !m.state.canSend)
        m.send()
        await m.settle()
        #expect(!messages.calls.contains("send:s1"))
        // A person's, with the same draft, can send.
        connections.connections = [Samples.connection("c1")]
        messages.connections = connections.connections
        let p = ConversationViewModel(connectionID: "c1", messages: messages, connections: connections)
        await p.settle()
        p.setDraft("Hello")
        #expect(!p.state.noComposer && p.state.canSend)
    }

    /// `forbidden` to a message sent to a connection that turns out to be a service (the list said so only once the send
    /// was on its way): the text, in place of the composer; nothing more is sent.
    @Test func forbiddenRemovesTheComposer() async {
        let messages = FakeMessages()
        let connections = FakeConnections()
        var s1 = Self.service("s1")
        s1.isService = false
        connections.connections = [s1]
        messages.connections = connections.connections
        let m = ConversationViewModel(connectionID: "s1", messages: messages, connections: connections)
        await m.settle()
        messages.fail["send"] = VaultFailure(.vaultCode("forbidden"))
        m.setDraft("Hello")
        m.send()
        connections.connections = [Self.service("s1")]
        await m.settle()
        #expect(m.state.serviceForbidden && m.state.error == nil && !m.state.canSend && !m.state.sending)
        m.send()
        await m.settle()
        #expect(messages.calls.filter { $0 == "send:s1" }.count == 1, "nothing more is sent")
    }

    /// The same refusal to a person is the vault's code as before, and another failure to a service is not "Services can't".
    @Test func onlyAServicesForbiddenIsSaidSo() async {
        #expect(ConversationViewModel.serviceForbade(VaultFailure(.vaultCode("forbidden")), Self.service("s1")))
        #expect(!ConversationViewModel.serviceForbade(VaultFailure(.vaultCode("forbidden")), Samples.connection("c1")))
        #expect(!ConversationViewModel.serviceForbade(VaultFailure(.network), Self.service("s1")))
        #expect(!ConversationViewModel.serviceForbade(VaultFailure(.vaultCode("forbidden")), nil))
    }
}
