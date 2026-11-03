import Foundation
import Testing
import VettIDData
import VettIDDataTesting
@testable import VettIDItems

// Fixtures stay on one line each.
// swiftlint:disable line_length

/// Waits until [condition] holds, at most [within] (20 s by default), as the other packages' tests do.
@MainActor
func eventually(within: Duration = .seconds(20), _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + within
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

/// The tags screen's view model against ``FakeSharing``. Mirrors the tag tests of vettid-android's
/// `SharingViewModelsTest`.
@MainActor
@Suite struct TagsViewModelTests {
    let sharing = FakeSharing()

    init() {
        sharing.registry = TagRegistry(version: 3, tags: [TagView(tag: "@profile", items: 1), TagView(tag: "medical", items: 2, rules: ["r1"]), TagView(tag: "travel", items: 1)])
    }

    func loaded() async -> TagsViewModel {
        let vm = TagsViewModel(sharing: sharing)
        await vm.settle()
        return vm
    }

    @Test func tagsAreListedProfileFirst() async {
        let vm = await loaded()
        #expect(vm.state.tags.map(\.tag) == ["@profile", "medical", "travel"] && !vm.state.loading)
        vm.edit(vm.state.tags[0])
        #expect(vm.state.dialog == nil, "@profile is reserved")
    }

    @Test func aNewTagIsNormalised() async {
        let vm = await loaded()
        vm.askCreate()
        vm.setName("  Home  Office ")
        vm.setDescription("Desk things")
        vm.save()
        await vm.settle()
        #expect(sharing.calls.contains("setTag:home office") && vm.state.dialog == nil)
        #expect(vm.state.tags.contains { $0.tag == "home office" && $0.description == "Desk things" })
        // A name that is not a tag is not sent.
        vm.askCreate()
        vm.setName("!nope")
        vm.save()
        await vm.settle()
        #expect(!sharing.calls.contains { $0.hasPrefix("setTag:!") } && vm.state.dialog == .create(name: "!nope", description: ""))
    }

    @Test func aDescriptionStopsAt256Characters() async {
        let vm = await loaded()
        vm.askCreate()
        vm.setDescription(String(repeating: "x", count: 300))
        #expect(vm.state.dialog == .create(name: "", description: String(repeating: "x", count: 256)))
    }

    @Test func aRenameIsPreviewedThenDone() async throws {
        sharing.change = TagChange(version: 3, items: 1, sharesTotal: 1)
        let vm = await loaded()
        vm.edit(try #require(vm.state.tags.first { $0.tag == "travel" }))
        vm.setName("trips")
        vm.save()
        await vm.settle()
        #expect(sharing.calls.contains("renameDry:travel>trips"))
        guard case .confirmRename(let tag, let into, let change)? = vm.state.dialog else { Issue.record("no preview"); return }
        #expect(tag == "travel" && into == "trips" && change.items == 1)
        vm.confirmRename()
        await vm.settle()
        #expect(sharing.calls.contains("rename:travel>trips") && vm.state.dialog == nil)
        #expect(vm.state.tags.map(\.tag).contains("trips"))
    }

    @Test func aDescriptionEditKeepsTheColourAndAnUnchangedFormJustCloses() async throws {
        sharing.registry.tags[2].color = "#59bbfb"
        let vm = await loaded()
        let travel = try #require(vm.state.tags.first { $0.tag == "travel" })
        vm.edit(travel)
        vm.save()
        #expect(vm.state.dialog == nil && !sharing.calls.contains { $0.hasPrefix("setTag") })
        vm.edit(travel)
        vm.setDescription("Trips")
        vm.save()
        await vm.settle()
        #expect(sharing.calls.contains("setTag:travel") && sharing.registry.tags.first { $0.tag == "travel" }?.color == "#59bbfb")
    }

    @Test func aTagARuleUsesCannotBeDeleted() async throws {
        let vm = await loaded()
        vm.edit(try #require(vm.state.tags.first { $0.tag == "medical" }))
        vm.askDelete()
        await vm.settle()
        #expect(vm.state.error == .inUse && vm.state.dialog == nil)
        vm.dismissError()
        #expect(vm.state.error == nil)
    }

    @Test func aDeleteIsPreviewedThenDone() async throws {
        sharing.change = TagChange(version: 3, items: 4)
        let vm = await loaded()
        vm.edit(try #require(vm.state.tags.first { $0.tag == "travel" }))
        vm.askDelete()
        await vm.settle()
        #expect(vm.state.dialog == .confirmDelete(tag: "travel", change: TagChange(version: 3, items: 4)))
        vm.confirmDelete()
        await vm.settle()
        #expect(sharing.calls.contains("delete:travel") && vm.state.dialog == nil && !vm.state.tags.contains { $0.tag == "travel" })
    }

    @Test func theColourPickerStoresTheChosenPaletteColour() async throws {
        sharing.registry.tags[2].color = "#99d079"
        sharing.registry.tags[2].description = "Trips"
        let vm = await loaded()
        let travel = try #require(vm.state.tags.first { $0.tag == "travel" })
        vm.askColour(travel)
        #expect(vm.state.dialog == .colour(travel))
        // The current colour again: nothing to store.
        vm.pickColour("#99d079", shown: true)
        #expect(vm.state.dialog == nil && !sharing.calls.contains { $0.hasPrefix("setTagColor") })
        vm.askColour(travel)
        vm.pickColour("#59bbfb", shown: false)
        await vm.settle()
        #expect(sharing.calls.contains("setTagColor:travel:#59bbfb") && vm.state.dialog == nil)
        let stored = try #require(vm.state.tags.first { $0.tag == "travel" })
        #expect(stored.color == "#59bbfb" && stored.description == "Trips")
    }

    @Test func theSharedProfileSaysWhyItHasNoColourToPick() async {
        let vm = await loaded()
        vm.askColour(vm.state.tags[0])
        #expect(vm.state.dialog == .profileColour)
        vm.pickColour("#59bbfb", shown: false)
        #expect(!sharing.calls.contains { $0.hasPrefix("setTagColor") })
    }

    @Test func aRefusedColourKeepsThePickerAndSaysWhy() async throws {
        sharing.fail["setTagColor:travel:#fea669"] = VaultFailure(.ownerCheckRequired, code: "owner_check_required")
        let vm = await loaded()
        vm.askColour(try #require(vm.state.tags.first { $0.tag == "travel" }))
        vm.pickColour("#fea669", shown: false)
        await vm.settle()
        #expect(vm.state.error == .ownerCheckRequired)
        if case .colour? = vm.state.dialog {} else { Issue.record("the picker stays") }
    }

    /// Refused while the vault was on hold: the failure is kept, and "Try again" (the screen's refresh) reads again.
    @Test func aHeldReadIsReadAgainOnTryAgain() async {
        sharing.fail["refreshTags"] = VaultFailure(.ownerCheckRequired)
        let vm = await loaded()
        #expect(vm.state.loadFailure?.kind == .ownerCheckRequired)
        vm.refresh()
        await vm.settle()
        #expect(vm.state.loadFailure == nil && vm.state.registry != nil)
    }

    /// Reads that overlap: only the latest one's answer is shown.
    @Test func onlyTheLatestReadIsShown() async {
        let vm = await loaded()
        let first = TestHold()
        sharing.holds["refreshTags"] = first
        sharing.fail["refreshTags"] = VaultFailure(.network)
        vm.refresh()
        vm.refresh()
        await waitFor { first.count == 2 }
        first.release(1)
        await waitFor { !vm.state.loading }
        first.release(0)
        await vm.settle()
        #expect(vm.state.loadFailure == nil, "an older failure does not hide a newer success")
        let second = TestHold()
        sharing.holds["refreshTags"] = second
        vm.refresh()
        await waitFor { second.count == 1 }
        sharing.fail["refreshTags"] = VaultFailure(.noResponse)
        vm.refresh()
        await waitFor { second.count == 2 }
        second.release(1)
        await waitFor { !vm.state.loading }
        second.release(0)
        await vm.settle()
        #expect(vm.state.loadFailure?.kind == .noResponse, "an older success does not clear a newer failure")
    }

    /// A read already on its way when a change brings the new registry does not take the change back: the tag just made
    /// stays shown.
    @Test func aReadOnItsWayDoesNotDropATagJustMade() async {
        let vm = await loaded()
        let read = TestHold()
        sharing.holds["refreshTags"] = read
        vm.refresh()
        await waitFor { read.count == 1 }
        vm.askCreate()
        vm.setName("trips")
        vm.save()
        await waitFor { !vm.state.busy && vm.state.dialog == nil }
        #expect(vm.state.tags.contains { $0.tag == "trips" } && !vm.state.loading)
        read.release(0)
        await vm.settle()
        #expect(vm.state.tags.contains { $0.tag == "trips" }, "the older read is not applied")
        #expect(sharing.tags?.tags.contains { $0.tag == "trips" } == true, "nor published over the newer registry")
    }

    /// After a change refused as `conflict`, the next read is applied whatever its version (the vault's may have gone down,
    /// a restore).
    @Test func afterAConflictALowerVersionReadIsApplied() async {
        let vm = await loaded()
        #expect(vm.state.registry?.version == 3)
        sharing.fail["setTag:trips"] = VaultFailure(.conflict, code: "conflict")
        vm.askCreate()
        vm.setName("trips")
        vm.save()
        await vm.settle()
        #expect(vm.state.error == .conflict)
        sharing.registry = TagRegistry(version: 1, tags: [TagView(tag: "garden", items: 1)])
        vm.refresh()
        await vm.settle()
        #expect(vm.state.registry?.version == 1 && vm.state.tags.map(\.tag) == ["garden"])
        // Without a conflict, an older read does not replace a newer registry.
        sharing.registry = TagRegistry(version: 0, tags: [])
        vm.refresh()
        await vm.settle()
        #expect(vm.state.registry?.version == 1)
    }

    /// A read that ends while a change is on its way leaves the change busy: it cannot be sent twice.
    @Test func aReadEndingDuringACreateKeepsItBusy() async {
        let vm = await loaded()
        let create = TestHold()
        sharing.holds["setTag:trips"] = create
        vm.askCreate()
        vm.setName("trips")
        vm.save()
        await waitFor { create.count == 1 }
        #expect(vm.state.busy)
        vm.refresh()
        await waitFor { !vm.state.loading }
        #expect(vm.state.busy, "the create is still on its way")
        create.release(0)
        await vm.settle()
        #expect(!vm.state.busy && sharing.calls.count { $0 == "setTag:trips" } == 1)
    }

    /// Yields until [condition] holds (at most a few thousand turns of the main actor).
    private func waitFor(_ condition: () -> Bool) async {
        for _ in 0..<5000 where !condition() { await Task.yield() }
        #expect(condition())
    }

    @Test func aFailedListSaysWhyAndALimitIsNamed() async {
        sharing.fail["refreshTags"] = VaultFailure(.network)
        let vm = await loaded()
        // A read that failed is its own failure, with "Try again": not "No tags yet", not an action's failure.
        #expect(vm.state.loadFailure == LoadFailure(.network) && vm.state.error == nil && !vm.state.loading && vm.state.registry == nil)
        vm.refresh()
        #expect(vm.state.loadFailure == nil && vm.state.loading)
        await vm.settle()
        #expect(vm.state.registry != nil && vm.state.loadFailure == nil)
        // A refresh that fails with tags listed keeps them.
        sharing.fail["refreshTags"] = VaultFailure(.noResponse)
        vm.refresh()
        await vm.settle()
        #expect(vm.state.loadFailure?.kind == .noResponse && vm.state.registry != nil)
        // A change that brings the tags back clears the failed read.
        vm.askCreate()
        vm.setName("trips")
        vm.save()
        await vm.settle()
        #expect(vm.state.loadFailure == nil && vm.state.dialog == nil)
        sharing.fail["setTag:new"] = VaultFailure(.limit, code: "limit", limit: VaultLimit("tag_registry", max: 512))
        vm.askCreate()
        vm.setName("new")
        vm.save()
        await vm.settle()
        #expect(vm.state.error == .limit && vm.state.limit?.name == "tag_registry" && vm.state.dialog != nil)
    }

    /// A dry run answered after the member closed its form opens nothing.
    @Test func aLatePreviewOpensNothing() async throws {
        let vm = await loaded()
        let gate = TestDeferred<Void>()
        sharing.dryRunGate = gate
        vm.edit(try #require(vm.state.tags.first { $0.tag == "travel" }))
        vm.setName("trips")
        vm.save()
        vm.dismiss()
        gate.complete(())
        await vm.settle()
        #expect(vm.state.dialog == nil, "closed stays closed")
        vm.edit(try #require(vm.state.tags.first { $0.tag == "travel" }))
        let gate2 = TestDeferred<Void>()
        sharing.dryRunGate = gate2
        vm.askDelete()
        vm.askCreate()
        gate2.complete(())
        await vm.settle()
        #expect(vm.state.dialog == .create(), "another dialog is not replaced")
    }

    /// A description saved after the keeper stored a colour keeps that colour, not the one the form opened with.
    @Test func aDescriptionKeepsTheColourStoredMeanwhile() async throws {
        let vm = await loaded()
        let travel = try #require(vm.state.tags.first { $0.tag == "travel" })
        vm.edit(travel)
        _ = try await sharing.assignColors { tags in tags.first { $0.tag == "travel" && $0.color == nil }.map { ($0.tag, "#59bbfb") } }
        vm.setDescription("Trips")
        vm.save()
        await vm.settle()
        #expect(sharing.registry.tags.first { $0.tag == "travel" }?.color == "#59bbfb")
    }
}

// swiftlint:enable line_length
