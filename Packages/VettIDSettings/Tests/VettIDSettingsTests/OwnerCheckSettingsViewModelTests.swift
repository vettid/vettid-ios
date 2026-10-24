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
        #expect(repo.calls == ["refreshOwnerCheck", "refreshIdleLockSetting"])
        #expect(m.state.view == repo.ownerCheck && m.state.intervalHours == 24)
    }

    /// STAGING-TIME-SCALE §3 rule 3: the interval keeps its real units with the scaled value beside it, and the staging
    /// note, on a staging vault only.
    @Test func aStagingVaultShowsBothUnitsAndTheNote() async {
        let real = OwnerCheckSettingsViewModel(repo: repo)
        #expect(real.state.interval("Every 24 hours", hours: 24) == "Every 24 hours" && real.state.stagingNote == nil)
        repo.timeScale = 24
        let m = OwnerCheckSettingsViewModel(repo: repo)
        await m.settle()
        #expect(m.state.timeScale == 24)
        #expect(m.state.interval("Every 24 hours", hours: 24) == "Every 24 hours (staging: 1 hour)")
        #expect(m.state.interval("Every hour", hours: 1) == "Every hour (staging: 150 seconds)")
        #expect(m.state.stagingNote == "Staging: 1 day = 1 hour")
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

    /// Release L (§3.6.8): no row for a vault before L; a longer value is said to take effect after the next check.
    @Test func theIdleLockSettingSaysWhenALongerValueTakesEffect() async {
        let m = OwnerCheckSettingsViewModel(repo: repo)
        await m.settle()
        // A vault before L: no row.
        #expect(m.state.idleLock == nil)
        repo.idleLockSetting = IdleLockSetting(seconds: 604_800)
        m.setIdleLock(86_400)
        await m.settle()
        #expect(m.state.idleLock == IdleLockSetting(seconds: 86_400))
        // Shorter: at once, nothing to say.
        #expect(!m.state.idleLongerNote)
        m.setIdleLock(2_592_000)
        await m.settle()
        #expect(m.state.idleLongerNote)
        #expect(m.state.idleLock?.afterNextCheck == true)
        m.dismissIdleNote()
        #expect(!m.state.idleLongerNote)
        // The same value sends nothing.
        let sent = repo.calls.filter { $0 == "setIdleLockAfter" }.count
        m.setIdleLock(2_592_000)
        await m.settle()
        #expect(repo.calls.filter { $0 == "setIdleLockAfter" }.count == sent)
    }

    /// The choices on a staging vault show the scaled value beside the real one.
    @Test func aStagingVaultShowsTheIdleLockAsItRuns() {
        repo.timeScale = 24
        let m = OwnerCheckSettingsViewModel(repo: repo)
        #expect(m.state.idleLockText("7 days", seconds: 604_800) == "7 days (staging: 7 hours)")
        #expect(OwnerCheckSettingsState().idleLockText("7 days", seconds: 604_800) == "7 days")
    }
}
