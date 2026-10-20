import Foundation
import Testing
import VettIDData
import VettIDDataTesting
@testable import VettIDConnections

/// A connection's detail (ANDROID-PLAN §4; VAULT-MESSAGING §10.4, §10.4.1): loading, an unknown connection, the
/// favourite, removing once confirmed, muting and resuming the asks, and the failures. Mirrors vettid-android
/// `ConnectionsViewModelsTest`'s detail part.
@MainActor
@Suite struct ConnectionDetailViewModelTests {
    let fake = FakeConnections()

    func model(_ id: String = "c1") async -> ConnectionDetailViewModel {
        let m = ConnectionDetailViewModel(connectionID: id, connections: fake)
        await m.settle()
        return m
    }

    @Test func itLoadsTheConnection() async {
        fake.connections = [Samples.active("c1")]
        let m = ConnectionDetailViewModel(connectionID: "c1", connections: fake)
        #expect(m.state.loading)
        await m.settle()
        #expect(!m.state.loading && m.state.connection?.displayName == "Ada Lovelace" && !m.state.gone)
        #expect(fake.calls == ["connection"])
    }

    /// The vault does not know it (removed on another device): the screen closes.
    @Test func anUnknownConnectionCloses() async {
        let m = await model("nope")
        #expect(m.state.gone && m.state.error == .notFound && m.state.connection == nil)
    }

    /// A failed read keeps the screen, saying why.
    @Test func aFailedReadSaysWhyAndTriesAgain() async {
        fake.connections = [Samples.active("c1")]
        fake.fail["connection"] = VaultFailure(.network)
        let m = ConnectionDetailViewModel(connectionID: "c1", connections: fake)
        await m.settle()
        #expect(!m.state.gone && m.state.error == .network && !m.state.loading)
        m.load()
        #expect(m.state.loading && m.state.error == nil)
        await m.settle()
        #expect(!m.state.loading && m.state.error == nil && m.state.connection?.id == "c1")
    }

    /// The list's copy wins: a change made elsewhere shows at once.
    @Test func theFavouriteToggles() async {
        fake.connections = [Samples.active("c1")]
        let m = await model()
        m.toggleFavorite()
        #expect(m.state.busy)
        await m.settle()
        #expect(m.state.connection?.favorite == true && !m.state.busy && fake.calls.last == "setFavorite")
        m.toggleFavorite()
        await m.settle()
        #expect(m.state.connection?.favorite == false)
        // Another device changed it first and the retry failed too (`conflict`, §10.4): said, nothing changed.
        fake.fail["setFavorite"] = VaultFailure(.conflict)
        m.toggleFavorite()
        await m.settle()
        #expect(m.state.error == .conflict && m.state.connection?.favorite == false && !m.state.busy)
        m.dismissNotice()
        #expect(m.state.error == nil)
    }

    @Test func removingIsConfirmedFirst() async {
        fake.connections = [Samples.active("c1")]
        let m = await model()
        m.confirm()
        await m.settle()
        #expect(!fake.calls.contains("remove"))
        m.ask(.remove)
        #expect(m.state.confirm == .remove)
        m.ask(nil)
        #expect(m.state.confirm == nil)
        m.ask(.remove)
        fake.fail["remove"] = VaultFailure(.network)
        m.confirm()
        await m.settle()
        #expect(m.state.error == .network && !m.state.gone && m.state.confirm == nil)
        m.ask(.remove)
        m.confirm()
        await m.settle()
        // Closed, and nothing of it stays on screen.
        #expect(m.state.gone && fake.connections.isEmpty && m.state.connection == nil)
    }

    /// Removed on another device, or the vault locked and the lists were emptied: the screen closes and drops the names
    /// and the profile it showed.
    @Test func aConnectionThatLeavesTheListCloses() async {
        fake.connections = [Samples.active("c1"), Samples.active("c2")]
        let m = await model()
        fake.connections.removeAll { $0.id == "c2" }
        await m.settle()
        #expect(!m.state.gone && m.state.connection != nil)
        fake.connections = []
        await m.settle()
        #expect(m.state.gone && m.state.connection == nil)
        // It does not come back with the list.
        fake.connections = [Samples.active("c1")]
        await m.settle()
        #expect(m.state.connection == nil)
    }

    /// Mute and unmute; resume a pause or the cooldowns (0.23.0 §10.4.1). Unmuting does not resume, resuming does not
    /// unmute.
    @Test func theAsksAreMutedAndResumed() async {
        var c = Samples.active("c1")
        c.asks = AskState(muted: false, paused: true, pausedAt: Date(), cooldowns: 2)
        fake.connections = [c]
        let m = await model()
        #expect(AsksView.of(m.state.connection?.asks)?.actions == [.resume, .mute])
        m.muteAsks(true)
        await m.settle()
        #expect(fake.calls.last == "asksMute:c1:true")
        #expect(AsksView.of(m.state.connection?.asks)?.actions == [.resume, .unmute])
        m.resumeAsks()
        await m.settle()
        #expect(fake.calls.last == "asksResume:c1" && m.state.connection?.asks == AskState(muted: true))
        #expect(AsksView.of(m.state.connection?.asks)?.actions == [.unmute])
        fake.fail["asksMute:c1:false"] = VaultFailure(.network)
        m.muteAsks(false)
        await m.settle()
        #expect(m.state.error == .network && m.state.connection?.asks?.muted == true)
    }

    /// vettid-android `AsksView`: nothing from an older vault; allow-again for cooldowns without a pause; prominent when
    /// muted or paused.
    @Test func theAsksView() {
        #expect(AsksView.of(nil) == nil)
        let normal = AsksView.of(AskState())
        #expect(normal?.actions == [.mute] && normal?.prominent == false)
        let cooled = AsksView.of(AskState(cooldowns: 1))
        #expect(cooled?.actions == [.allowAgain, .mute] && cooled?.prominent == false)
        #expect(AsksView.of(AskState(muted: true))?.prominent == true)
        #expect(AsksView.of(AskState(paused: true))?.prominent == true)
    }

    @Test func theSharingName() {
        #expect(Samples.active("c", first: " Ada ", last: "Lovelace").sharingName == "Ada")
        #expect(Samples.active("c", first: nil, last: nil).sharingName == nil)
    }

    @Test func theStateDoesNotPrintNames() async {
        fake.connections = [Samples.active("c1")]
        let m = await model()
        #expect(!"\(m.state)".contains("Ada") && !String(reflecting: m.state).contains("Ada"))
    }
}
