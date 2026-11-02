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

    /// `forbidden` to a message sent to a service: the text, once, in place of the composer; nothing more can be sent.
    @Test func forbiddenRemovesTheComposer() async {
        let messages = FakeMessages()
        let connections = FakeConnections()
        connections.connections = [Self.service("s1")]
        messages.connections = connections.connections
        let m = ConversationViewModel(connectionID: "s1", messages: messages, connections: connections)
        await m.settle()
        messages.fail["send"] = VaultFailure(.vaultCode("forbidden"))
        m.setDraft("Hello")
        m.send()
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
