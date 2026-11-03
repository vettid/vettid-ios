import Foundation
import Testing
import VettIDData
import VettIDDataTesting
@testable import VettIDItems

/// The sharing screens' reads that overlap: only the latest one's answer is shown, so that an older answer never replaces
/// a newer one.
@MainActor
@Suite struct SharingReadOrderTests {
    let sharing = FakeSharing()
    let social = FakeConnections()
    let items = FakeItems()

    func connectionVM() async -> ConnectionSharingViewModel {
        let vm = ConnectionSharingViewModel(connectionID: "c1", sharing: sharing, items: items, connections: social)
        await vm.settle()
        return vm
    }

    func sharedVM() async -> SharedWithYouViewModel {
        let vm = SharedWithYouViewModel(connectionID: "c1", ask: false, sharing: sharing, items: items, connections: social)
        await vm.settle()
        return vm
    }

    /// Reads of what a connection can see, and of what it shares, that overlap: only the latest one's answer is shown.
    @Test func onlyTheLatestReadOfSharingIsShown() async {
        let vm = await connectionVM()
        let first = TestHold()
        sharing.holds["rules"] = first
        sharing.fail["rules"] = VaultFailure(.network)
        vm.load()
        vm.load()
        await waitFor { first.count == 2 }
        first.release(1)
        await waitFor { !vm.state.loading }
        first.release(0)
        await vm.settle()
        #expect(vm.state.loadFailure == nil && !vm.state.loading, "an older failure does not hide a newer success")
        sharing.holds["rules"] = nil
        let shared = await sharedVM()
        let second = TestHold()
        sharing.holds["grants"] = second
        shared.load()
        await waitFor { second.count == 1 }
        sharing.fail["grants"] = VaultFailure(.noResponse)
        shared.load()
        await waitFor { second.count == 2 }
        second.release(1)
        await waitFor { !shared.state.loading }
        second.release(0)
        await shared.settle()
        #expect(shared.state.loadFailure?.kind == .noResponse, "an older success does not clear a newer failure")
    }

    private func waitFor(_ condition: () -> Bool) async {
        for _ in 0..<5000 where !condition() { await Task.yield() }
        #expect(condition())
    }
}
