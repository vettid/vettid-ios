import Foundation
import Testing
import VettIDData
import VettIDDataTesting
@testable import VettIDMessages

/// Samples for the view-model tests.
enum Samples {
    static func connection(
        _ id: String, first: String? = "Ada", state: ConnectionState = .active, favorite: Bool = false
    ) -> ConnectionInfo {
        var c = ConnectionInfo(id: id, name: "", state: state)
        c.firstName = first
        c.lastName = first == nil ? nil : "Lovelace"
        c.favorite = favorite
        return c
    }

    static func message(
        _ id: String, in conn: String = "c1", outgoing: Bool = false, text: String = "Hello", at: TimeInterval = 1_791_115_200,
        read: Bool = false
    ) -> MessageInfo {
        MessageInfo(
            connectionID: conn, messageID: id, outgoing: outgoing, text: text, sentAt: Date(timeIntervalSince1970: at), read: read
        )
    }
}

/// The Messages screen (ANDROID-PLAN §4): loading, the rows newest first, the Unread chip, the search, the empty states'
/// inputs and the failures. Mirrors vettid-android `MessagesViewModelTest`.
@MainActor
@Suite struct MessagesViewModelTests {
    let fake = FakeMessages()

    func model() async -> MessagesViewModel {
        let m = MessagesViewModel(messages: fake)
        await m.settle()
        return m
    }

    @Test func itLoadsTheConversationsNewestFirst() async {
        fake.connections = [Samples.connection("c1"), Samples.connection("c2", first: "Grace")]
        fake.byConnection = ["c1": [Samples.message("m1", at: 100)], "c2": [Samples.message("m2", in: "c2", at: 200)]]
        let m = MessagesViewModel(messages: fake)
        #expect(m.state.loading)
        await m.settle()
        #expect(!m.state.loading && m.state.error == nil)
        #expect(m.state.conversations.map(\.connection.id) == ["c2", "c1"])
        #expect(!m.state.noConnections && m.state.searchable)
        #expect(fake.calls == ["refreshConversations:"])
    }

    @Test func withoutConnectionsTheButtonInvites() async {
        let m = await model()
        #expect(m.state.conversations.isEmpty && m.state.noConnections && !m.state.searchable)
    }

    @Test func theUnreadChipFilters() async {
        fake.connections = [Samples.connection("c1"), Samples.connection("c2")]
        fake.byConnection = ["c1": [Samples.message("m1")], "c2": [Samples.message("m2", in: "c2", read: true)]]
        let m = await model()
        m.setUnreadOnly(true)
        #expect(m.state.unreadOnly && m.state.conversations.map(\.connection.id) == ["c1"])
        #expect(m.state.conversations.first?.unread == 1)
        m.setUnreadOnly(false)
        #expect(m.state.conversations.count == 2)
    }

    /// The search: the connection's names and the latest message, ignoring case.
    @Test func theSearchMatchesNamesAndTheLatestMessage() async {
        fake.connections = [Samples.connection("c1"), Samples.connection("c2", first: "Grace")]
        fake.byConnection = ["c2": [Samples.message("m2", in: "c2", text: "See you at the harbour")]]
        let m = await model()
        m.setQuery("grace")
        #expect(m.state.conversations.map(\.connection.id) == ["c2"] && m.state.searching)
        m.setQuery("HARBOUR")
        #expect(m.state.conversations.map(\.connection.id) == ["c2"])
        m.setQuery("nobody")
        #expect(m.state.conversations.isEmpty && m.state.searchable)
        m.setQuery("  ")
        #expect(m.state.conversations.count == 2 && !m.state.searching)
    }

    @Test func aFailureIsShownAndRetried() async {
        fake.fail["refreshConversations"] = VaultFailure(.network)
        let m = await model()
        #expect(m.state.error == .network && !m.state.loading)
        m.refresh()
        #expect(m.state.error == nil)
        await m.settle()
        #expect(m.state.error == nil && fake.calls.count == 2)
        fake.fail["refreshConversations"] = VaultFailure(.busy)
        m.refresh()
        await m.settle()
        m.dismissError()
        #expect(m.state.error == nil)
    }

    /// A list refused because the daily check was due reads again by itself once a check passes; another failure does not.
    @Test func aPassedCheckReadsARefusedListAgain() async {
        let vault = FakeVaultRepository(.unlocked)
        vault.ownerCheck = OwnerCheckView(state: .due, deadline: nil, hold: false)
        fake.fail["refreshConversations"] = VaultFailure(.ownerCheckRequired)
        let m = MessagesViewModel(messages: fake, ownerChecks: vault)
        await m.settle()
        #expect(m.state.error == .ownerCheckRequired)
        vault.ownerCheck = OwnerCheckView(state: .ok, deadline: Date(), hold: false)
        // The view model follows the check on a later turn of the main actor.
        #expect(await eventually { m.state.error == nil && fake.calls.count == 2 })
        await m.settle()
        fake.fail["refreshConversations"] = VaultFailure(.network)
        m.refresh()
        await m.settle()
        vault.ownerCheck = OwnerCheckView(state: .ok, deadline: Date().addingTimeInterval(60), hold: false)
        await m.settle()
        #expect(m.state.error == .network && fake.calls.count == 3)
    }

    /// Nothing of the members' own (names, text) is in the state's descriptions.
    @Test func theStateDescribesNoContent() async {
        fake.connections = [Samples.connection("c1")]
        fake.byConnection = ["c1": [Samples.message("m1", text: "secret plans")]]
        let m = await model()
        m.setQuery("Ada")
        for text in [String(describing: m.state), String(reflecting: m.state), "\(Mirror(reflecting: m.state).children.count)"] {
            #expect(!text.contains("Ada") && !text.contains("secret") && !text.contains("Lovelace"))
        }
    }
}

/// The new-message picker: the active connections, favourites first, then by name.
@MainActor
@Suite struct NewMessageViewModelTests {
    let fake = FakeConnections()

    @Test func itListsTheActiveConnectionsFavouritesFirst() async {
        fake.connections = [
            Samples.connection("c1", first: "Grace"), Samples.connection("c2", first: "ada"),
            Samples.connection("c3", first: "Zoe", favorite: true), Samples.connection("c4", state: .blocked),
        ]
        let m = NewMessageViewModel(connections: fake)
        #expect(m.state.loading)
        await m.settle()
        #expect(!m.state.loading && m.state.error == nil && fake.calls == ["refresh"])
        #expect(m.state.connections.map(\.id) == ["c3", "c2", "c1"])
    }

    @Test func aFailedRefreshStillLists() async {
        fake.connections = [Samples.connection("c1")]
        fake.fail["refresh"] = VaultFailure(.network)
        let m = NewMessageViewModel(connections: fake)
        await m.settle()
        #expect(!m.state.loading && m.state.error == .network && m.state.connections.count == 1)
        #expect(!String(describing: m.state).contains("Ada"))
    }
}
