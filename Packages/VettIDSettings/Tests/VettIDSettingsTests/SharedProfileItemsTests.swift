import Foundation
import Testing
import VettIDData
import VettIDDataTesting
@testable import VettIDSettings

/// The `@profile` items of the shared profile (VAULT-MESSAGING §10.8): listed from the Vault, a standard item added, one
/// taken out, a refusal (the limit) said. Mirrors the items part of vettid-android `ProfileViewModelsTest`.
@MainActor
@Suite struct SharedProfileItemsTests {
    let repo = FakeVaultRepository(.unlocked)
    let items = FakeItems()

    init() {
        items.add(FakeItems.item("01E", "email", tags: ["@profile"]))
        items.add(FakeItems.item("01P", "Phone"))
        items.add(FakeItems.item("01L", "Bank login", sensitivity: .secret))
        items.add(FakeItems.item("01A", "Address", tags: ["home"]))
    }

    @Test func theProfileItemsAndTheStandardOnesThatCouldJoin() async {
        let m = SharedProfileViewModel(profiles: repo, accounts: repo, items: items)
        await m.settle()
        #expect(items.calls.contains("refresh"))
        #expect(m.state.profileItems.map(\.itemID) == ["01E"])
        #expect(m.state.candidates.map(\.itemID) == ["01A", "01P"], "standard items only, by name")
    }

    @Test func anItemIsAddedAndTakenOut() async {
        let m = SharedProfileViewModel(profiles: repo, accounts: repo, items: items)
        await m.settle()
        m.pickItem(true)
        #expect(m.state.pickingItem)
        m.addToProfile(m.state.candidates[0])
        #expect(!m.state.pickingItem && m.state.itemsBusy)
        await m.settle()
        #expect(!m.state.itemsBusy && m.state.profileItems.map(\.itemID) == ["01A", "01E"])
        #expect(Set(items.stored.first { $0.itemID == "01A" }?.tags ?? []) == ["home", "@profile"])
        m.removeFromProfile(m.state.profileItems[1])
        await m.settle()
        #expect(m.state.profileItems.map(\.itemID) == ["01A"])
        // A secret item never joins.
        let sent = items.calls.count { $0 == "setTags" }
        m.addToProfile(ItemSummary(itemID: "01L", version: 1, name: "Bank login", category: "other", sensitivity: .secret))
        await m.settle()
        #expect(items.calls.count { $0 == "setTags" } == sent)
    }

    @Test func aRefusalIsSaidWithItsLimit() async {
        let m = SharedProfileViewModel(profiles: repo, accounts: repo, items: items)
        await m.settle()
        let limit = VaultLimit("profile_items", max: 32)
        items.fail["setTags"] = VaultFailure(.limit, code: "limit", limit: limit)
        m.addToProfile(m.state.candidates[0])
        await m.settle()
        #expect(m.state.error == .limit && m.state.limit == limit && !m.state.itemsBusy)
    }
}
