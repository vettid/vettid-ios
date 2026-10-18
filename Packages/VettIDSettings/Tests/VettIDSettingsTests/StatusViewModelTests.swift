import Foundation
import LocalAuthentication
import Testing
import VettIDData
import VettIDDataTesting
@testable import VettIDSettings

/// Vault status and Attestation load their value once, and say why they could not.
@MainActor
@Suite struct StatusViewModelTests {
    let repo = FakeVaultRepository(.unlocked)

    @Test func theVaultsStatusLoadsAndLoadsAgain() async {
        repo.fail["overview"] = VaultFailure(.network)
        let m = VaultStatusViewModel(vault: repo)
        #expect(m.state.loading)
        await m.settle()
        #expect(m.state == LoadState(loading: false, error: .network))
        m.load()
        #expect(m.state.loading)
        await m.settle()
        #expect(m.state == LoadState(loading: false, value: repo.overviewValue))
    }

    @Test func theAttestationLoads() async {
        repo.attestationValue = .iPhone(
            environment: "staging", appAttest: AppAttestInfo(accepted: true), lastRelease: 3, lastReleaseFingerprint: "a3a3 a3a3"
        )
        let m = AttestationViewModel(vault: repo)
        await m.settle()
        #expect(m.state.value?.appAttest?.accepted == true && m.state.value?.environment == "staging")
        repo.fail["attestationInfo"] = VaultFailure(.other)
        let failed = AttestationViewModel(vault: repo)
        await failed.settle()
        #expect(failed.state == LoadState(loading: false, error: .other))
    }

    /// ANDROID-PLAN §4 "Recovery and unlock from release R": the Recovery line, never "0 of 10" when the counter could not be read. Mirrors vettid-android
    /// `RecoveryStatusTextTest`.
    @Test func everyRecoveryState() {
        #expect(RecoveryLine.of(RecoveryStatusView(state: "armed", used: 0, counterUnavailable: false)) == .armed(used: 0))
        #expect(RecoveryLine.of(RecoveryStatusView(state: "armed", used: 3, counterUnavailable: false)) == .used(3))
        #expect(RecoveryLine.of(RecoveryStatusView(state: "armed", used: 10, counterUnavailable: false)) == .exhausted)
        #expect(RecoveryLine.of(RecoveryStatusView(state: "change_required", used: 10, counterUnavailable: false)) == .exhausted)
        #expect(RecoveryLine.of(RecoveryStatusView(state: "change_required", used: 2, counterUnavailable: false)) == .changeRequired)
        #expect(RecoveryLine.of(RecoveryStatusView(state: "needs_check", used: nil, counterUnavailable: false)) == .needsCheck)
        #expect(RecoveryLine.of(RecoveryStatusView(state: "off", used: nil, counterUnavailable: false)) == .off)
        #expect(RecoveryLine.of(RecoveryStatusView(state: "unknown", used: 0, counterUnavailable: true)) == .unknown)
        #expect(RecoveryLine.of(RecoveryStatusView(state: "armed", used: nil, counterUnavailable: true)) == .unknown)
    }
}

/// A screen that goes away releases its view model at once, its work cancelled; turning the app lock on is not cancelled
/// with it (the app lock owns that prompt).
@MainActor
@Suite struct ViewModelLifetimeTests {
    @Test func aStatusScreenThatGoesAwayIsReleased() async {
        let repo = FakeVaultRepository(.unlocked)
        repo.overviewGate = TestDeferred()
        weak var gone: VaultStatusViewModel?
        do {
            let m = VaultStatusViewModel(vault: repo)
            gone = m
            for _ in 0..<5 { await Task.yield() }
            #expect(repo.calls == ["overview"])
        }
        #expect(gone == nil, "the read under way does not keep the model")
        repo.overviewGate?.complete(())
    }

    @Test func turningTheLockOnOutlivesTheScreen() async {
        let repo = FakeVaultRepository(.unlocked)
        let lock = FakeAppLock()
        lock.promptGate = TestDeferred()
        weak var gone: SettingsViewModel?
        do {
            let m = SettingsViewModel(
                account: repo, vault: repo, appLock: lock, promptReason: "r",
                deviceAuthentication: { DeviceAuthentication(biometrics: true, passcode: true) }
            )
            gone = m
            m.setAppLock(true)
            for _ in 0..<5 { await Task.yield() }
        }
        #expect(gone == nil)
        lock.promptGate?.complete(())
        for _ in 0..<20 { await Task.yield() }
        #expect(lock.state == .unlocked, "the prompt was not cut short by the screen going away")
    }
}

/// What the iPhone can ask for, from LocalAuthentication's answers.
@Suite struct DeviceAuthenticationTests {
    /// A Face ID or Touch ID lockout is not "not set up": the member is not told to switch to the passcode.
    @Test func aLockoutIsStillSetUp() {
        #expect(DeviceAuthentication.of(biometrics: false, biometricsError: .biometryLockout, passcode: true).biometrics)
        #expect(!DeviceAuthentication.of(biometrics: false, biometricsError: .biometryNotEnrolled, passcode: true).biometrics)
        #expect(!DeviceAuthentication.of(biometrics: false, biometricsError: .biometryNotAvailable, passcode: false).biometrics)
        #expect(DeviceAuthentication.of(biometrics: true, biometricsError: nil, passcode: true)
            == DeviceAuthentication(biometrics: true, passcode: true))
    }
}
