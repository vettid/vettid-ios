import Foundation
import Testing
import VettIDData
import VettIDDataTesting
@testable import VettIDSettings

/// The owner-check rows (VAULT-MESSAGING §3.6.2, §3.6.7). Mirrors vettid-android `OwnerCheckSettingsViewModelTest`.
@MainActor
@Suite struct OwnerCheckSettingsViewModelTests {
    let repo = FakeVaultRepository(.unlocked)

    init() {
        repo.ownerCheck = OwnerCheckView(state: .ok, deadline: Date().addingTimeInterval(3_600))
    }

    @Test func theVaultsCheckIsReadAtOnce() async {
        let m = OwnerCheckSettingsViewModel(repo: repo)
        await m.settle()
        #expect(repo.calls == ["refreshOwnerCheck"])
        #expect(m.state.view == repo.ownerCheck && m.state.intervalHours == 24)
    }

    /// A shorter interval offers a check (VAULT-MESSAGING §3.6.2); a longer one does not; the same one sends nothing.
    @Test func shorteningOffersACheck() async {
        let m = OwnerCheckSettingsViewModel(repo: repo)
        m.setIntervalHours(4)
        await m.settle()
        #expect(repo.lastInterval == 14_400 && m.state.offerCheck && m.state.intervalHours == 4)
        m.dismissOffer()
        m.setIntervalHours(8)
        await m.settle()
        #expect(repo.lastInterval == 28_800 && !m.state.offerCheck)
        let sent = repo.calls.filter { $0 == "setCheckInterval" }.count
        m.setIntervalHours(8)
        await m.settle()
        #expect(repo.calls.filter { $0 == "setCheckInterval" }.count == sent)
    }

    @Test func turningTheHoldOnNeedsNoCheck() async {
        repo.ownerCheck?.hold = false
        let m = OwnerCheckSettingsViewModel(repo: repo)
        m.turnHoldOn()
        await m.settle()
        #expect(repo.calls.contains("turnHoldOn") && !repo.calls.contains("check"))
        #expect(m.state.view?.hold == true && !m.state.busy)
    }

    @Test func aRefusalIsShown() async {
        repo.fail["setCheckInterval"] = VaultFailure(.ownerCheckRequired)
        let m = OwnerCheckSettingsViewModel(repo: repo)
        m.setIntervalHours(1)
        await m.settle()
        #expect(m.state.error == .ownerCheckRequired && !m.state.offerCheck)
        m.dismissError()
        #expect(m.state.error == nil)
    }
}
