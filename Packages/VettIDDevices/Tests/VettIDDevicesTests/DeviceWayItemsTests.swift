import Foundation
import Testing
@testable import VettIDData
import VettIDDataTesting
@testable import VettIDDevices

/// AA7 on the agent's page: "Items it may use" is read with the page. Mirrors vettid-android `WayItemsPageViewModelTest`.
@MainActor
@Suite struct DeviceWayItemsTests {
    let fake = Samples.fake()
    let ways = FakeItemWays()
    let items = FakeItems()

    @Test func theItemsAreReadWithThePageForAnAgent() async {
        ways.listAnswer = [#"{"agent_id":"a1","item_id":"i1","version":2,"ways":["use","reveal"]}"#]
        let m = DeviceViewModel(id: "a1", repo: fake, itemWays: ways, items: items)
        await m.settle()
        #expect(ways.lists == ["a1"])
        #expect(m.state.wayItemsAvailable && m.state.wayItemsLoaded && m.state.wayItems.map(\.itemID) == ["i1"])
        let desktop = DeviceViewModel(id: "d1", repo: fake, itemWays: ways, items: items)
        await desktop.settle()
        #expect(ways.lists == ["a1"], "a desktop has no items")
    }

    @Test func withoutItemWaysNothingIsRead() async {
        ways.listed = false
        let m = DeviceViewModel(id: "a1", repo: fake, itemWays: ways, items: items)
        await m.settle()
        #expect(ways.lists.isEmpty && !m.state.wayItemsAvailable)
    }

    /// A refresh that fails with the list already held still reads the items, which have their own failure and Retry.
    @Test func theItemsAreReadAlthoughTheDeviceListFailedToRefresh() async {
        fake.fail["refresh"] = VaultFailure(.network)
        ways.failList = VaultFailure(.network)
        let m = DeviceViewModel(id: "a1", repo: fake, itemWays: ways, items: items)
        await m.settle()
        #expect(m.state.loadError == .network)
        #expect(ways.lists == ["a1"] && m.state.wayItemsError == .network)
        ways.listAnswer = []
        m.refreshWayItems()
        await m.settle()
        #expect(m.state.wayItemsError == nil && m.state.wayItemsLoaded)
    }

    /// A pair the vault lists twice is two rows with two ids.
    @Test func everyRowHasItsOwnId() async {
        ways.listAnswer = [
            #"{"agent_id":"a1","item_id":"i1","version":2,"ways":["use"]}"#,
            #"{"agent_id":"a1","item_id":"i1","version":2,"ways":["use"]}"#,
        ]
        let m = DeviceViewModel(id: "a1", repo: fake, itemWays: ways, items: items)
        await m.settle()
        #expect(m.state.wayItems.count == 2 && Set(m.state.wayItems.map(\.id)).count == 2)
    }
}
