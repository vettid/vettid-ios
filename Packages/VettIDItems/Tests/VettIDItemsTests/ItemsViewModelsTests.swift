import Foundation
import Testing
import VettIDData
import VettIDDataTesting
@testable import VettIDItems

// Fixtures stay on one line each.
// swiftlint:disable line_length

/// The Vault list and an item's detail (VAULT-MESSAGING §10.7): filters, reveal, the critical password path, delete and
/// protection. Mirrors vettid-android `ItemsViewModelsTest`.
@MainActor
@Suite struct ItemsViewModelsTests {
    let items = FakeItems()

    init() {
        items.add(FakeItems.item("01P", "Passport", tags: ["travel"], category: "identity_document"))
        items.add(FakeItems.item("01L", "Bank login", sensitivity: .secret, tags: ["money"], category: "login", fields: [("Password", "hunter2")]))
        items.add(FakeItems.item("01C", "Recovery phrase", sensitivity: .critical, category: "crypto_wallet", fields: [("Words", "abandon ability")]))
    }

    private func detail(_ id: String) async -> ItemDetailViewModel {
        let vm = ItemDetailViewModel(itemID: id, items: items)
        await vm.settle()
        return vm
    }

    private func stored(_ id: String) -> ItemDetail? { items.stored.first { $0.itemID == id } }

    /// Refused because the daily check was due: the Vault list reads again once the check passes.
    @Test func aListRefusedForTheDailyCheckReloadsWhenTheCheckPasses() async {
        let vault = FakeVaultRepository()
        vault.ownerCheck = OwnerCheckView(state: .due, deadline: nil)
        items.fail["refresh"] = VaultFailure(.ownerCheckRequired)
        let vm = ItemsViewModel(items: items, ownerChecks: vault)
        await vm.settle()
        #expect(vm.state.error == .ownerCheckRequired)
        vault.ownerCheck = OwnerCheckView(state: .ok, deadline: nil)
        #expect(await eventually { vm.state.error == nil && items.calls.count { $0 == "refresh" } == 2 })
    }

    @Test func theCategoryFilterIncludesTheMembersOwnCategories() async {
        // §10.7: any [a-z][a-z0-9_]{0,31} category; the recommended ones first, then the member's own.
        items.add(FakeItems.item("01K", "Coffee card", category: "loyalty_cards"))
        items.add(FakeItems.item("01G", "Gym card", category: "gym"))
        let vm = ItemsViewModel(items: items)
        await vm.settle()
        #expect(vm.state.categories == ["identity_document", "login", "crypto_wallet", "gym", "loyalty_cards"])
        vm.setCategory("loyalty_cards")
        #expect(vm.state.visible.map(\.name) == ["Coffee card"])
    }

    @Test func theListFiltersOnThePhone() async {
        let vm = ItemsViewModel(items: items)
        await vm.settle()
        #expect(items.calls.contains("refresh"))
        #expect(vm.state.visible.map(\.name) == ["Bank login", "Passport", "Recovery phrase"] && vm.state.tags == ["money", "travel"])
        vm.setTag("travel")
        #expect(vm.state.visible.map(\.name) == ["Passport"])
        vm.setTag("travel") // the selected tag again clears it
        #expect(vm.state.filter.tag == nil)
        vm.setSensitivity(.critical)
        #expect(vm.state.visible.map(\.itemID) == ["01C"])
        vm.setQuery("bank")
        #expect(vm.state.visible.isEmpty)
        vm.clearFilters()
        #expect(vm.state.visible.count == 3)
    }

    @Test func aFailedListShowsTheError() async {
        items.fail["refresh"] = VaultFailure(.network)
        let vm = ItemsViewModel(items: items)
        await vm.settle()
        #expect(vm.state.error == .network)
        vm.refresh()
        await vm.settle()
        #expect(vm.state.error == nil)
    }

    @Test func aDataItemShowsItsValues() async {
        let vm = await detail("01P")
        #expect(vm.state.revealed && vm.state.item?.fields.map(\.value) == [.text("123")])
    }

    @Test func aSecretItemIsHiddenUntilRevealedAndHiddenAgain() async {
        let vm = await detail("01L")
        #expect(!vm.state.revealed && vm.state.item?.fields.map(\.value) == [nil])
        vm.reveal()
        await vm.settle()
        #expect(items.calls.contains("reveal") && vm.state.item?.fields.map(\.value) == [.text("hunter2")])
        vm.toggleShown("f1")
        #expect(vm.state.shown == ["f1"])
        vm.hide()
        #expect(!vm.state.revealed && vm.state.item?.fields.map(\.value) == [nil] && vm.state.shown.isEmpty)
    }

    /// "Reveal" asks the iPhone's owner first, with the item's name; nothing is asked of the vault unless confirmed.
    @Test func aSecretItemIsRevealedOnlyOnceTheOwnerIsConfirmed() async {
        let vm = await detail("01L")
        let asked = Box<[String]>([])
        vm.askReveal { reason in
            asked.value.append(reason)
            return false
        }
        await vm.settle()
        #expect(asked.value == [ItemsStrings.revealPromptTitle + "\nBank login"])
        #expect(!items.calls.contains("reveal") && !vm.state.revealed)
        vm.askReveal { _ in true }
        await vm.settle()
        #expect(items.calls.contains("reveal") && vm.state.revealed)
        // A critical item is never revealed so: its password is asked for.
        let critical = await detail("01C")
        critical.askReveal { _ in true }
        await critical.settle()
        #expect(critical.state.prompt?.purpose == .open && !items.calls.contains("revealCritical"))
    }

    @Test func aCriticalItemOpensOnlyWithTheRightPassword() async throws {
        let vm = await detail("01C")
        vm.reveal() // a critical item is never revealed without the password
        #expect(vm.state.prompt?.purpose == .open && !items.calls.contains("revealCritical"))
        vm.setPassword("wrong")
        vm.submitPassword()
        await vm.settle()
        let p = try #require(vm.state.prompt)
        #expect(p.error == .badPassword && p.password == "" && !vm.state.revealed)
        vm.setPassword("correct horse")
        vm.submitPassword()
        await vm.settle()
        #expect(vm.state.prompt == nil && vm.state.item?.fields.map(\.value) == [.text("abandon ability")])
    }

    @Test func aBackoffKeepsTheSendButtonOff() async throws {
        let vm = await detail("01C")
        vm.open()
        items.fail["revealCritical"] = VaultFailure(.backoff, code: "backoff", retryAfterSeconds: 60)
        vm.setPassword("correct horse")
        vm.submitPassword()
        await vm.settle()
        var p = try #require(vm.state.prompt)
        #expect(p.retryUntil != nil && p.waiting(Date()) > 0)
        p.password = "x"
        #expect(!p.canSend(Date()))
    }

    @Test func revealedValuesAndATypedPasswordAreDroppedWhenTheItemsAreCleared() async {
        let vm = await detail("01L")
        vm.reveal()
        await vm.settle()
        #expect(vm.state.revealed)
        items.clear()
        #expect(await eventually { !vm.state.revealed })
        let critical = await detail("01C")
        critical.open()
        critical.setPassword("correct horse")
        items.clear()
        #expect(await eventually { critical.state.prompt == nil })
    }

    @Test func deletingAStandardItemNeedsOnlyTheConfirmation() async {
        let vm = await detail("01P")
        vm.askDelete()
        #expect(vm.state.dialog == .delete)
        vm.confirmDelete()
        await vm.settle()
        #expect(vm.state.deleted && stored("01P") == nil)
    }

    @Test func deletingACriticalItemNeedsThePassword() async {
        let vm = await detail("01C")
        vm.askDelete()
        vm.confirmDelete()
        #expect(vm.state.prompt?.purpose == .delete && !items.calls.contains("delete"))
        vm.setPassword("correct horse")
        vm.submitPassword()
        await vm.settle()
        #expect(vm.state.deleted)
    }

    @Test func standardAndSecretSwapWithoutThePassword() async {
        let vm = await detail("01P")
        vm.askProtection()
        vm.pickProtection(.secret)
        await vm.settle()
        #expect(stored("01P")?.sensitivity == .secret && vm.state.prompt == nil && vm.state.item?.sensitivity == .secret)
    }

    @Test func movingIntoTheCredentialNeedsThePassword() async {
        let vm = await detail("01P")
        vm.pickProtection(.critical)
        #expect(vm.state.prompt?.purpose == .protection)
        vm.setPassword("correct horse")
        vm.submitPassword()
        await vm.settle()
        #expect(stored("01P")?.sensitivity == .critical)
    }

    @Test func leavingTheCredentialWarnsFirst() async {
        let vm = await detail("01C")
        vm.pickProtection(.data)
        #expect(vm.state.dialog == .leaveCritical && vm.state.prompt == nil)
        vm.confirmLeaveCritical()
        #expect(vm.state.prompt?.purpose == .protection)
        vm.setPassword("correct horse")
        vm.submitPassword()
        await vm.settle()
        #expect(stored("01C")?.sensitivity == .data)
    }

    @Test func aDeletedItemIsMissing() async {
        let vm = await detail("01GONE")
        #expect(vm.state.missing && vm.state.error == nil)
    }

    @Test func theStatesNeverPrintTheirValues() async {
        let vm = await detail("01L")
        vm.reveal()
        await vm.settle()
        vm.open()
        vm.setPassword("correct horse")
        let printed = "\(vm.state) \(String(reflecting: vm.state)) \(vm.state.prompt.map { "\($0)" } ?? "")"
        #expect(!printed.contains("hunter2") && !printed.contains("correct horse"))
    }
}

/// TEST ONLY. A value a closure fills in.
@MainActor
final class Box<T> {
    var value: T
    init(_ value: T) { self.value = value }
}

// swiftlint:enable line_length
