import Foundation
import Testing
import VettIDData
import VettIDDataTesting
import VettIDKeys
@testable import VettIDSettings

/// Settings: the account read-only, the vault's lock, the app lock and its method and timeout. Mirrors vettid-android
/// `SettingsViewModelsTest` for the rows the iPhone app has.
@MainActor
@Suite struct SettingsViewModelTests {
    let repo = FakeVaultRepository(.unlocked)
    let lock = FakeAppLock()

    func model(_ can: DeviceAuthentication = DeviceAuthentication(biometrics: true, passcode: true)) -> SettingsViewModel {
        SettingsViewModel(account: repo, vault: repo, appLock: lock, promptReason: "Unlock VettID", deviceAuthentication: { can })
    }

    @Test func theAccountAndTheLockAreRead() {
        repo.account = AccountInfo(emailHint: "m***@example.com", state: "member", firstName: "Ada", lastName: "Lovelace")
        lock.state = .unlocked
        lock.method = .passcode
        lock.timeout = .oneHour
        let s = model().state
        #expect(s.account?.fullName == "Ada Lovelace")
        #expect(s.appLockOn && s.appLockMethod == .passcode && s.appLockTimeout == .oneHour)
        #expect(!s.busy && s.error == nil)
    }

    /// "Update available" while the vault has a release update to approve (RELEASE-UPDATES §2), and not otherwise.
    @Test func theUpdateRowFollowsTheOffer() {
        let offer = ReleaseUpdateOffer(current: FakeVaultRepository.release(4), target: FakeVaultRepository.release(5))
        let updates = FakeReleaseUpdates(offer: offer)
        let m = SettingsViewModel(account: repo, vault: repo, appLock: lock, promptReason: "Unlock VettID", updates: updates)
        #expect(m.state.update == offer)
        updates.offer = nil
        #expect(m.state.update == nil)
        #expect(model().state.update == nil)
    }

    /// vettid-android `themeIsPersistedAndLockWorks`: the lock goes to the vault; this phone is locked.
    @Test func lockVaultLocks() async {
        let m = model()
        m.lockVault()
        #expect(m.state.busy)
        await m.settle()
        #expect(repo.calls.contains("lock") && repo.phase == .locked)
        #expect(!m.state.busy && m.state.error == nil)
    }

    @Test func aFailedLockIsShownAndDismissed() async {
        repo.fail["lock"] = VaultFailure(.network)
        let m = model()
        m.lockVault()
        await m.settle()
        #expect(m.state.error == .network)
        m.dismissError()
        #expect(m.state.error == nil)
    }

    /// The switch on asks at once with the chosen method; off needs no prompt.
    @Test func theSwitchTurnsTheLockOnAndOff() async {
        lock.method = .passcode
        let m = model()
        m.setAppLock(true)
        await m.settle()
        #expect(lock.calls == ["enable(passcode, Unlock VettID)"])
        #expect(m.state.appLockOn)
        m.setAppLock(false)
        #expect(lock.calls.last == "disable" && !m.state.appLockOn)
    }

    /// A cancelled prompt leaves the lock off and says nothing; a key that cannot be made says the lock cannot be used.
    @Test func aLockThatCannotBeMadeIsSaid() async {
        lock.enableAnswer = false
        let m = model()
        m.setAppLock(true)
        await m.settle()
        #expect(!m.state.appLockOn && !m.state.appLockUnavailable)
        lock.enableError = KeysError.noSecureHardware
        m.setAppLock(true)
        await m.settle()
        #expect(!m.state.appLockOn && m.state.appLockUnavailable)
        m.dismissAppLockUnavailable()
        #expect(!m.state.appLockUnavailable)
    }

    /// vettid-android `theAppLockMethodIsChosenWhileOff`: off, only the choice; on, a new key with one prompt; the same
    /// method again, nothing.
    @Test func theMethodIsChosenWhileOffAndRemadeWhileOn() async {
        let m = model()
        m.setAppLockMethod(.passcode)
        #expect(lock.calls == ["chooseMethod(passcode)"] && m.state.appLockMethod == .passcode)
        m.setAppLockMethod(.passcode)
        #expect(lock.calls.count == 1)
        lock.state = .unlocked
        m.setAppLockMethod(.biometrics)
        await m.settle()
        #expect(lock.calls.last == "enable(biometrics, Unlock VettID)" && m.state.appLockMethod == .biometrics)
    }

    @Test func theTimeoutAndTheInvalidatedNotice() {
        lock.invalidated = true
        let m = model()
        m.setAppLockTimeout(.immediately)
        #expect(m.state.appLockTimeout == .immediately)
        #expect(m.state.appLockInvalidated)
        m.acknowledgeInvalidated()
        #expect(!m.state.appLockInvalidated)
    }

    /// A settings file that cannot be written is the screen's failure (`localState`).
    @Test func aChangeThatCannotBeWrittenIsShown() {
        lock.state = .unlocked
        lock.writeError = KeysError.unavailable("app lock")
        let m = model()
        m.setAppLockTimeout(.oneHour)
        #expect(m.state.error == .localState && m.state.appLockTimeout == .standard)
        m.dismissError()
        m.setAppLock(false)
        #expect(m.state.error == .localState && m.state.appLockOn)
    }

    /// Face ID and Touch ID only, never the passcode in their place: an iPhone without them is not asked; it is told to
    /// choose the passcode, or, without a passcode either, that the lock cannot be used.
    @Test func withoutFaceIDThePasscodeIsSuggested() async {
        let m = model(DeviceAuthentication(biometrics: false, passcode: true))
        m.setAppLock(true)
        await m.settle()
        #expect(lock.calls.isEmpty && m.state.appLockSuggestPasscode && !m.state.appLockUnavailable)
        m.dismissAppLockUnavailable()
        #expect(!m.state.appLockSuggestPasscode)
        m.setAppLockMethod(.passcode)
        m.setAppLock(true)
        await m.settle()
        #expect(lock.calls.last == "enable(passcode, Unlock VettID)" && m.state.appLockOn)
        let none = model(DeviceAuthentication(biometrics: false, passcode: false))
        lock.state = .disabled
        lock.method = .biometrics
        none.setAppLock(true)
        #expect(none.state.appLockUnavailable && !none.state.appLockSuggestPasscode)
    }

    // MARK: - Allow screenshots (IOS-PLAN §4)

    /// vettid-android `allowScreenshotsIsOffUntilTurnedOnAndNeverStoredOrSentToTheVault`: off at start, on from the switch,
    /// off again when the vault closes or the member turns it off; nothing is asked of the vault.
    @Test func allowScreenshotsIsOffUntilTurnedOnAndNeverSentToTheVault() {
        let allowance = ScreenshotAllowance(onByDefault: false, now: { 0 })
        let m = SettingsViewModel(account: repo, vault: repo, appLock: lock, promptReason: "Unlock VettID", screenshots: allowance)
        #expect(!m.state.screenshotsAllowed && !m.state.screenshotsStayOn)
        m.setScreenshotsAllowed(true)
        #expect(m.state.screenshotsAllowed && allowance.allowed)
        #expect(repo.calls.isEmpty, "nothing asked of the vault: \(repo.calls)")
        allowance.vaultClosed()
        #expect(!m.state.screenshotsAllowed)
        m.setScreenshotsAllowed(true)
        m.setScreenshotsAllowed(false)
        #expect(!allowance.allowed)
    }

    /// vettid-android `aDevelopmentBuildShowsTheSwitchOn`.
    @Test func aDevelopmentBuildShowsTheSwitchOn() {
        let m = SettingsViewModel(
            account: repo, vault: repo, appLock: lock, promptReason: "Unlock VettID", screenshots: ScreenshotAllowance(onByDefault: true)
        )
        #expect(m.state.screenshotsAllowed && m.state.screenshotsStayOn)
    }

    /// New phone secret is offered only on a phone that holds a phone secret (release R).
    @Test func newPhoneSecretFollowsThePhoneSecret() {
        #expect(!model().state.phoneSecret)
        repo.phoneSecret = true
        #expect(model().state.phoneSecret)
    }
}
