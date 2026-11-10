import Foundation
import Testing
@testable import VettIDData
import VettIDDataTesting
@testable import VettIDDevices

/// The Devices & agents list and a device's page (ANDROID-PLAN 0.1.53 AA1): what is read and when, the confirmations, the failures
/// said plainly, and that the page can never sign. Mirrors vettid-android `DevicesViewModelsTest`.
@MainActor
@Suite struct DevicesViewModelTests {
    let fake = Samples.fake()
    let now = Samples.now

    func list(_ owner: FakeVaultRepository? = nil) async -> DevicesViewModel {
        let m = DevicesViewModel(repo: fake, ownerChecks: owner)
        m.refresh()
        await m.settle()
        return m
    }

    func page(_ id: String) async -> DeviceViewModel {
        let m = DeviceViewModel(id: id, repo: fake)
        await m.settle()
        return m
    }

    // MARK: The list

    @Test func theListIsReadWhenItOpensAndShowsWhatTheRepositoryHolds() async {
        let m = await list()
        #expect(fake.calls.filter { $0 == "refresh" }.count == 1)
        #expect(m.state.devices.count == 3 && !m.state.onlyThisPhone && !m.state.loading)
    }

    /// "No agents yet" is said of a list that was read, never of one that was not.
    @Test func noAgentsYetNeedsAListThatWasRead() async {
        fake.devices = [Samples.phone]
        let m = DevicesViewModel(repo: fake)
        for load in [ListLoad.notLoaded, .loading, .failed] {
            fake.load = load
            #expect(!m.state.onlyThisPhone, "\(load)")
        }
        fake.load = .loaded
        #expect(m.state.onlyThisPhone)
    }

    @Test func aListThatFailedWithoutAnErrorOfItsOwnReadsAgainWhenTheCheckPasses() async {
        let owner = FakeVaultRepository()
        owner.ownerCheck = OwnerCheckView(state: .ok, deadline: Date(), hold: false)
        let m = await list(owner)
        let before = fake.calls.filter { $0 == "refresh" }.count
        owner.ownerCheck = OwnerCheckView(state: .held, deadline: nil, hold: true)
        fake.load = .failed
        await m.settle()
        owner.ownerCheck = OwnerCheckView(state: .ok, deadline: Date(), hold: true)
        await m.settle()
        #expect(await eventually { fake.calls.filter { $0 == "refresh" }.count == before + 1 })
    }

    @Test func thisPhoneAloneIsTheEmptyState() async {
        fake.devices = [Samples.phone]
        let m = DevicesViewModel(repo: fake)
        #expect(m.state.onlyThisPhone)
    }

    @Test func theListSpinsUntilReadAndNeverBeforeAFailureShows() async {
        fake.devices = []
        fake.load = .notLoaded
        let m = DevicesViewModel(repo: fake)
        #expect(m.state.loading)
        fake.load = .loading
        #expect(m.state.loading)
        fake.fail["refresh"] = VaultFailure(.network)
        m.refresh()
        await m.settle()
        #expect(!m.state.loading && m.state.error == .network)
    }

    /// A failed list with nothing held and no failure of this screen's own (another screen's read failed) shows the failure
    /// card with a generic failure, never a blank screen.
    @Test func aFailedListWithNothingHeldIsNeverBlank() {
        var s = DevicesState()
        s.load = .failed
        #expect(s.shownError == .other && !s.loading && !s.onlyThisPhone)
        s.error = .network
        #expect(s.shownError == .network)
        s.error = nil
        s.devices = [DeviceInfo(id: "me", kind: "app", name: "", thisPhone: true)]
        #expect(s.shownError == nil)
        s.load = .loaded
        s.devices = []
        #expect(s.shownError == nil)
    }

    @Test func aFailedReadIsShownAndReadsAgainWhenTheDailyCheckPasses() async {
        let owner = FakeVaultRepository()
        owner.ownerCheck = OwnerCheckView(state: .held, deadline: nil, hold: true)
        fake.fail["refresh"] = VaultFailure(.ownerCheckRequired)
        let m = await list(owner)
        #expect(m.state.error == .ownerCheckRequired)
        owner.ownerCheck = OwnerCheckView(state: .ok, deadline: Date(), hold: true)
        await m.settle()
        #expect(await eventually { m.state.error == nil && fake.calls.filter { $0 == "refresh" }.count == 2 })
    }

    /// A hold cleared the list while the screen was open (nothing failed): the end of the hold reads it again.
    @Test func aListTheHoldClearedReadsAgainWhenTheHoldEnds() async {
        let owner = FakeVaultRepository()
        owner.ownerCheck = OwnerCheckView(state: .ok, deadline: Date(), hold: false)
        let m = await list(owner)
        let before = fake.calls.filter { $0 == "refresh" }.count
        owner.ownerCheck = OwnerCheckView(state: .held, deadline: nil, hold: true)
        fake.load = .notLoaded // cleared by the hold
        await m.settle()
        owner.ownerCheck = OwnerCheckView(state: .ok, deadline: Date(), hold: true)
        await m.settle()
        #expect(await eventually { fake.calls.filter { $0 == "refresh" }.count == before + 1 })
    }

    @Test func aPassedCheckReadsNothingWhenTheListWasNotRefused() async {
        let owner = FakeVaultRepository()
        owner.ownerCheck = OwnerCheckView(state: .held, deadline: nil, hold: true)
        fake.fail["refresh"] = VaultFailure(.network)
        let m = await list(owner)
        owner.ownerCheck = OwnerCheckView(state: .ok, deadline: Date(), hold: true)
        await m.settle()
        #expect(m.state.error == .network && fake.calls.filter { $0 == "refresh" }.count == 1)
    }

    @Test func aFailedListKeepsWhatWasReadAndAReadClearsTheFailure() async {
        let m = await list()
        fake.fail["refresh"] = VaultFailure(.network)
        m.refresh()
        await m.settle()
        #expect(m.state.error == .network && m.state.devices.count == 3 && !m.state.loading)
        m.refresh()
        await m.settle()
        #expect(m.state.error == nil)
    }

    /// Work cut off by a lock or by the app leaving reaches the model as a cancellation: no error text, on the list or on a page.
    @Test func aReadCutOffByALockIsSilent() async {
        let m = DevicesViewModel(repo: fake)
        fake.failError["refresh"] = CancellationError()
        m.refresh()
        await m.settle()
        #expect(m.state.error == nil)
        let p = DeviceViewModel(id: "a1", repo: fake)
        fake.failError["endAccess:a1"] = CancellationError()
        p.askEndAccess()
        p.confirm()
        await p.settle()
        #expect(p.state.failure == nil && p.state.error == nil && !p.state.busy && !p.state.accessEnded)
    }

    @Test func theRemovedNameReachesTheListOnceUntilItIsShown() async {
        let m = await list()
        fake.removed = Samples.agent
        #expect(m.state.removedDevice?.name == "Claude")
        m.removedShown()
        #expect(m.state.removedDevice == nil && fake.calls.contains("dismissRemoved"))
    }

    // MARK: A device's page

    @Test func endingAccessAsksFirstThenSendsOnceAndSaysSo() async {
        let m = await page("a1")
        m.askEndAccess()
        #expect(m.state.confirm == .endAccess)
        #expect(!fake.calls.contains { $0.hasPrefix("endAccess") }, "nothing is sent before the confirmation")
        m.confirm()
        await m.settle()
        #expect(fake.calls.filter { $0.hasPrefix("endAccess") } == ["endAccess:a1"])
        #expect(m.state.accessEnded && m.state.device?.sessionExpiresAt == nil && !m.state.busy && m.state.confirm == nil)
        m.accessEndedShown()
        #expect(!m.state.accessEnded)
    }

    @Test func cancellingTheConfirmationSendsNothing() async {
        let m = await page("a1")
        m.askEndAccess()
        m.dismissConfirm()
        m.confirm()
        await m.settle()
        #expect(!fake.calls.contains { $0.hasPrefix("endAccess") || $0.hasPrefix("remove:") })
    }

    @Test func aFailedEndOfAccessSaysItDidNotHappenAndKeepsTheSession() async {
        let m = await page("a1")
        fake.fail["endAccess:a1"] = VaultFailure(.notFound)
        m.askEndAccess()
        m.confirm()
        await m.settle()
        #expect(m.state.failure == .endAccess && m.state.error == .notFound && !m.state.accessEnded && !m.state.busy)
        #expect(m.state.device?.sessionExpiresAt == Samples.agent.sessionExpiresAt)
        // What the vault says now settles whether it is still there: the list is read again.
        #expect(fake.calls.filter { $0 == "refresh" }.count == 2)
        m.dismissFailure()
        #expect(m.state.failure == nil && m.state.error == nil)
    }

    @Test func aRefusedDailyCheckKeepsItsKindForTheVaultsOwnText() async {
        let m = await page("d1")
        fake.fail["remove:d1"] = VaultFailure(.ownerCheckRequired, code: "owner_check_required")
        m.askRemove()
        await m.settle()
        m.confirm()
        await m.settle()
        #expect(m.state.failure == .remove && m.state.error == .ownerCheckRequired)
    }

    /// A hold clears the list while the request fails with the refused check: the page still shows the vault's refusal, naming
    /// the device, and never sits on a spinner.
    @Test func aRefusalDuringAHoldStaysOnThePage() async {
        let m = await page("a1")
        fake.fail["endAccess:a1"] = VaultFailure(.ownerCheckRequired, code: "owner_check_required")
        fake.fail["refresh"] = VaultFailure(.ownerCheckRequired, code: "owner_check_required")
        fake.clearsOnFailure = ["endAccess:a1"]
        m.askEndAccess()
        m.confirm()
        await m.settle()
        let s = m.state
        #expect(fake.devices.isEmpty && !s.loaded)
        #expect(s.failure == .endAccess && s.error == .ownerCheckRequired)
        #expect(s.device?.id == "a1" && !s.gone && !s.busy)
        #expect(s.loadError == .ownerCheckRequired)
        // Dismissed: no device and no list, and the page says why instead of spinning.
        m.dismissFailure()
        #expect(m.state.device == nil && m.state.loadError == .ownerCheckRequired && !m.state.gone)
    }

    /// A failed request whose list then reads without the device: the page is gone, it does not keep the copy.
    @Test func aFailedRequestOnADeviceThatIsGoneLeavesThePage() async {
        let m = await page("a1")
        m.askEndAccess()
        fake.fail["endAccess:a1"] = VaultFailure(.network)
        m.confirm()
        fake.devices = fake.devices.filter { $0.id != "a1" } // gone while the request is on its way
        await m.settle()
        #expect(m.state.failure == .endAccess && m.state.device == nil && m.state.gone)
    }

    /// While the notice of a removal shows, the device has no actions: nothing more is sent for it.
    @Test func aRemovedDeviceHasNoActionsWhileItsNoticeShows() async {
        let m = await page("a1")
        m.askRemove()
        await m.settle()
        m.confirm()
        await m.settle()
        #expect(m.state.removedDevice != nil)
        let calls = fake.calls.count
        m.askEndAccess()
        #expect(m.state.confirm == nil)
        m.askRemove()
        await m.settle()
        #expect(m.state.confirm == nil && !m.state.busy)
        // confirm() sends nothing either (no confirmation can be open now: the guard in confirm() is defence only).
        m.confirm()
        await m.settle()
        #expect(fake.calls.count == calls)
    }

    /// The end of the hold: a page the hold left without its device reads the list again, whoever opened it; a page that has
    /// its list does not.
    @Test func thePageReadsAgainWhenTheCheckPassesOnlyWithoutAList() async {
        let m = await page("a1")
        let before = fake.calls.filter { $0 == "refresh" }.count
        m.ownerCheckPassed()
        await m.settle()
        #expect(fake.calls.filter { $0 == "refresh" }.count == before)
        fake.load = .notLoaded
        m.ownerCheckPassed()
        await m.settle()
        #expect(fake.calls.filter { $0 == "refresh" }.count == before + 1)
        fake.load = .loaded
        fake.fail["refresh"] = VaultFailure(.network)
        m.refresh()
        await m.settle()
        #expect(m.state.loadError == .network)
        m.ownerCheckPassed()
        await m.settle()
        #expect(m.state.loadError == nil)
    }

    @Test func removingAnAgentNamesTheBoundFirstAndLeavesAfterwards() async {
        fake.bound = 960
        let m = await page("a1")
        m.askRemove()
        await m.settle()
        #expect(m.state.confirm == .remove && m.state.removalBoundSeconds == 960 && !m.state.busy)
        #expect(fake.calls.contains("removalBound:a1"))
        m.confirm()
        await m.settle()
        #expect(fake.calls.filter { $0.hasPrefix("remove:") } == ["remove:a1"])
        // The page tells it itself (opened from the feed it has no list under it), once, and leaves afterwards.
        #expect(m.state.removedDevice?.name == "Claude" && m.state.device?.id == "a1" && !m.state.gone && !m.state.removed)
        #expect(fake.removed == nil && fake.calls.contains("dismissRemoved"))
        m.removedShown()
        #expect(m.state.removed)
    }

    @Test func removingADesktopAsksNoBound() async {
        let m = await page("d1")
        m.askRemove()
        await m.settle()
        #expect(m.state.confirm == .remove && m.state.removalBoundSeconds == 0)
        #expect(!fake.calls.contains { $0.hasPrefix("removalBound") })
    }

    @Test func aFailedRemovalKeepsTheDeviceAndSaysSo() async {
        let m = await page("d1")
        fake.fail["remove:d1"] = VaultFailure(.other, code: "internal")
        m.askRemove()
        await m.settle()
        m.confirm()
        await m.settle()
        #expect(m.state.failure == .remove && !m.state.removed && m.state.device?.id == "d1" && !m.state.busy)
    }

    @Test func aSecondAskWhileBusyIsIgnored() async {
        let m = await page("d1")
        m.askRemove()
        // The bound is on its way: another ask or a confirm does nothing.
        m.askRemove()
        m.askEndAccess()
        m.confirm()
        await m.settle()
        #expect(fake.calls.filter { $0.hasPrefix("removalBound") }.isEmpty && !fake.calls.contains { $0.hasPrefix("remove:") })
        #expect(m.state.confirm == .remove)
    }

    @Test func thisPhoneHasNoPageAndNothingIsSentForIt() async {
        let m = await page("me")
        #expect(m.state.gone)
        m.askEndAccess()
        m.confirm()
        m.askRemove()
        await m.settle()
        #expect(!fake.calls.contains { $0.hasPrefix("endAccess") || $0.hasPrefix("remove") })
    }

    @Test func aDeviceThatIsNoLongerListedIsGoneOnceTheListWasRead() async {
        let m = await page("zzz")
        #expect(m.state.gone)
        fake.load = .notLoaded
        #expect(!m.state.gone, "not before the list was read")
    }

    @Test func aListThatCannotBeReadIsShownOnThePageWithRetry() async {
        fake.devices = []
        fake.fail["refresh"] = VaultFailure(.network)
        let m = DeviceViewModel(id: "a1", repo: fake)
        await m.settle()
        #expect(m.state.loadError == .network)
        m.refresh()
        await m.settle()
        #expect(m.state.loadError == nil && fake.calls.filter { $0 == "refresh" }.count == 2)
    }

    @Test func anotherAppEntryHasNoActions() async {
        fake.devices.append(DeviceInfo(id: "app2", kind: "app", name: "Old phone"))
        let m = await page("app2")
        m.askEndAccess()
        m.askRemove()
        await m.settle()
        m.confirm()
        await m.settle()
        #expect(m.state.confirm == nil && !fake.calls.contains { $0.hasPrefix("endAccess") || $0.hasPrefix("remove") })
    }

    /// The page's view model holds only the device's id and the devices repository: it has no way to sign anything, to ask for a
    /// password or to open the unlock window (the Android test reads the constructor's parameters).
    @Test func neverAsksForTheCredentialPasswordOrTheUnlockWindow() async {
        let m = await page("a1")
        let held = Mirror(reflecting: m).children.map(\.value).filter { Mirror(reflecting: $0).displayStyle == .class }
        let objects = held.compactMap { $0 as? AnyObject }
        let names = objects.map { String(describing: type(of: $0)) }
        // The repository, the work it started: nothing else is an object it could call.
        #expect(objects.contains { $0 === fake })
        #expect(objects.allSatisfy { $0 === fake || String(describing: type(of: $0)).hasSuffix("Work") }, "\(names)")
        #expect(!objects.contains { $0 is any OwnerCheckRepository || $0 is any VaultRepository })
        m.askEndAccess()
        m.confirm()
        await m.settle()
        m.askRemove()
        await m.settle()
        m.confirm()
        await m.settle()
        #expect(fake.calls.allSatisfy { ["refresh", "endAccess:a1", "removalBound:a1", "remove:a1", "dismissRemoved"].contains($0) })
    }

    @Test func theStatesNeverPrintANameOrADevice() async {
        let m = await page("a1")
        let l = await list()
        for text in ["\(m.state)", String(reflecting: m.state), "\(l.state)", String(reflecting: l.state), "\(Samples.agent)"] {
            #expect(!text.contains("Claude") && !text.contains("Laptop"), "\(text)")
        }
        #expect(Mirror(reflecting: m.state).children.isEmpty && Mirror(reflecting: l.state).children.isEmpty)
    }
}
