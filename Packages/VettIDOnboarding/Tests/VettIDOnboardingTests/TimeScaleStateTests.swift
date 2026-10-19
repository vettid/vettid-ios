import Foundation
import Testing
import VettIDData
import VettIDDataTesting
@testable import VettIDOnboarding

/// The staging time scale on the onboarding and unlock screens (STAGING-TIME-SCALE §5.2): the scaled waits and the
/// "Staging: 1 day = 1 hour" note, from the vault's scale.
@MainActor
@Suite struct TimeScaleStateTests {
    let ticker = ManualTicker()

    @Test func theOwnerCheckScreenShowsTheScaledInterval() {
        let view = OwnerCheckView(state: .ok, deadline: nil)
        let real = OwnerCheckScreenState(view: view)
        #expect(real.intervalText == "24 hours" && real.quietText == "3 days" && real.stagingNote == nil)
        let staging = OwnerCheckScreenState(view: view, timeScale: 24)
        #expect(staging.intervalText == "1 hour" && staging.quietText == "3 hours")
        #expect(staging.stagingNote == "Staging: 1 day = 1 hour")
    }

    @Test func theOwnerCheckModelTakesTheVaultsScale() {
        let repo = FakeVaultRepository(.unlocked)
        repo.ownerCheck = OwnerCheckView(state: .ok, deadline: Date().addingTimeInterval(3_600))
        repo.timeScale = 24
        let m = OwnerCheckViewModel(repo: repo, vault: repo, tick: ticker.tick)
        #expect(m.state.timeScale == 24)
        m.start(.voluntary)
        #expect(m.state.timeScale == 24 && m.state.intervalText == "1 hour")
    }

    @Test func theUnlockScreenShowsTheScaledWaits() {
        var s = UnlockState()
        #expect(s.recoveryText == "24 hours" && s.keptTransferText == "7 days" && s.stagingNote == nil)
        s.timeScale = 24
        #expect(s.recoveryText == "1 hour" && s.keptTransferText == "7 hours")
        #expect(s.stagingNote == "Staging: 1 day = 1 hour")
    }

    @Test func theUnlockModelFollowsTheVaultsScale() async {
        let vault = FakeVaultRepository(.locked)
        vault.timeScale = 24
        let m = UnlockViewModel(vault: vault, account: vault, tick: ticker.tick)
        await m.settle()
        #expect(m.state.timeScale == 24)
    }

    @Test func theShellsPresenceNoticeIsScaled() {
        let view = OwnerCheckView(state: .ok, deadline: Date().addingTimeInterval(3_600))
        let real = OwnerCheckGate.of(view, now: Date())
        #expect(real.quietText == "3 days" && real.stagingNote == nil)
        // The vault's current scale, whatever the deadline's.
        let g = OwnerCheckGate.of(view, now: Date(), timeScale: 24)
        #expect(g.timeScale == 24 && g.quietText == "3 hours" && g.stagingNote == "Staging: 1 day = 1 hour")
    }
}
