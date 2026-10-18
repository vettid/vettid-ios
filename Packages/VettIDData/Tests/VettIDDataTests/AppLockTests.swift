import Foundation
import Testing
@testable import VettIDData
import VettIDKeys
import VettIDKeysTesting

/// The app lock's preferences and sealed data key in memory; [unavailable] answers like a locked iPhone, [corrupt] like a
/// damaged file.
final class MemoryAppLockStore: AppLockStore, @unchecked Sendable {
    private let lock = NSLock()
    private var prefs = AppLockPreferences()
    private var sealedValue: [UInt8]?
    private var unavailableValue = false
    private var corruptValue = false

    var current: AppLockPreferences {
        get { lock.withLock { prefs } }
        set { lock.withLock { prefs = newValue } }
    }

    var sealed: [UInt8]? {
        get { lock.withLock { sealedValue } }
        set { lock.withLock { sealedValue = newValue } }
    }

    var unavailable: Bool {
        get { lock.withLock { unavailableValue } }
        set { lock.withLock { unavailableValue = newValue } }
    }

    var corrupt: Bool {
        get { lock.withLock { corruptValue } }
        set { lock.withLock { corruptValue = newValue } }
    }

    private func check() throws {
        let (u, c) = lock.withLock { (unavailableValue, corruptValue) }
        if u { throw KeysError.unavailable("app lock") }
        if c { throw KeysError.corrupt("app lock") }
    }

    func preferences() throws -> AppLockPreferences {
        try check()
        return current
    }

    func setPreferences(_ p: AppLockPreferences) throws { current = p }

    func readSealed() throws -> [UInt8]? {
        try check()
        return sealed
    }

    func writeSealed(_ b: [UInt8]) throws { sealed = b }
    func deleteSealed() throws { sealed = nil }
}

/// The app lock (ANDROID-PLAN D6; IOS-PLAN ID17) with a software stand-in for the Secure Enclave key. Mirrors
/// vettid-android `AppLockTest`, test for test, with the prompt inside the key's use as on iOS.
@MainActor
@Suite struct AppLockTests {
    final class Clock: @unchecked Sendable {
        var t = Date(timeIntervalSince1970: 1_791_000_000)
    }

    let store = MemoryAppLockStore()
    let keys = SoftwareAppLockKeys()
    let clock = Clock()

    func lock() -> AppLock {
        let clock = clock
        return AppLock(store: store, keys: keys) { clock.t }
    }

    func enabled(_ m: AppLockMethod = .biometrics) async throws -> AppLock {
        let l = lock()
        l.start()
        #expect(try await l.enable(m, reason: "Unlock VettID"))
        return l
    }

    @Test func offByDefault() {
        let l = lock()
        l.start()
        #expect(l.state == .disabled && l.appDataKey() == nil)
    }

    @Test func enableThenRestartStartsLockedAndUnlocks() async throws {
        let l = try await enabled()
        #expect(l.state == .unlocked)
        let k = try #require(l.appDataKey())
        #expect(k.count == 32 && store.current.enabled)

        let again = lock()
        again.start()
        #expect(again.state == .locked && again.appDataKey() == nil)
        #expect(await again.unlock(reason: "Unlock VettID"))
        #expect(again.state == .unlocked && again.appDataKey() == k)
    }

    /// Whatever fails at the start, the lock leaves "pending": a sealed key that cannot be read is a lock that cannot open,
    /// off, with the notice. A locked iPhone (no protected data yet) stays pending until the next start.
    @Test func aKeyFileThatCannotBeReadTurnsTheLockOffInsteadOfLeavingItPending() async throws {
        store.current = AppLockPreferences(enabled: true, method: .biometrics)
        try keys.create(.biometrics)
        store.unavailable = true
        let l = lock()
        l.start()
        #expect(l.state == .pending)
        store.unavailable = false
        store.corrupt = true
        l.start()
        #expect(l.state == .disabled && l.invalidated)
        store.corrupt = false
        #expect(!store.current.enabled)
    }

    @Test func timeoutLocksOnlyAfterTheChosenTime() async throws {
        let l = try await enabled()
        try l.setTimeout(.oneMinute)
        l.onBackground()
        clock.t += 59
        l.onForeground()
        #expect(l.state == .unlocked)
        l.onBackground()
        clock.t += 60
        l.onForeground()
        #expect(l.state == .locked && l.appDataKey() == nil)
    }

    /// iOS's prompt makes the app inactive and, for the passcode, may send it to the background: not leaving the app.
    @Test func promptsDoNotCountAsLeavingTheApp() async throws {
        let l = try await enabled()
        try l.setTimeout(.immediately)
        l.authenticating = true
        l.onBackground()
        clock.t += 5
        l.onForeground()
        l.authenticating = false
        #expect(l.state == .unlocked)
        // Really leaving still locks.
        l.onBackground()
        l.onForeground()
        #expect(l.state == .locked)
    }

    @Test func invalidatedKeyTurnsTheLockOff() async throws {
        let l = try await enabled()
        l.lockNow()
        keys.invalidate() // a new face or finger
        #expect(await !l.unlock(reason: "Unlock VettID"))
        #expect(l.state == .disabled && l.invalidated && !store.current.enabled)
    }

    @Test func aMissingSealedKeyTurnsTheLockOff() async throws {
        let l = try await enabled()
        l.lockNow()
        store.sealed = nil
        #expect(await !l.unlock(reason: "Unlock VettID"))
        #expect(l.state == .disabled && l.invalidated)
    }

    @Test func disableForgetsEverything() async throws {
        let l = try await enabled()
        try l.disable()
        #expect(try l.state == .disabled && !keys.exists() && store.sealed == nil)
        // The chosen method stays for the next time the lock is turned on.
        #expect(store.current == AppLockPreferences(enabled: false, method: .biometrics))
    }

    // MARK: - The method (ANDROID-PLAN 0.1.19)

    @Test func biometricsIsTheDefault() {
        let l = lock()
        l.start()
        #expect(l.method == .biometrics && store.current.method == nil)
    }

    @Test func thePasscodeMakesAPasscodeKey() async throws {
        let l = try await enabled(.passcode)
        #expect(keys.created == [.passcode] && l.method == .passcode && store.current.method == .passcode)
        // Kept across a restart.
        let again = lock()
        again.start()
        #expect(again.method == .passcode && again.state == .locked)
    }

    @Test func aLockTurnedOnBeforeTheChoiceExistedIsBiometrics() async throws {
        _ = try await enabled()
        store.current = AppLockPreferences(enabled: true, method: nil)
        let l = lock()
        l.start()
        #expect(l.method == .biometrics && store.current.method == .biometrics && l.state == .locked)
    }

    @Test func theMethodIsChosenWhileOff() throws {
        let l = lock()
        l.start()
        try l.chooseMethod(.passcode)
        #expect(store.current.method == .passcode && l.method == .passcode)
    }

    /// The fresh key of a change of method replaced the earlier one: a prompt that is cancelled turns the lock off.
    @Test func aChangeOfMethodThatIsCancelledTurnsTheLockOff() async throws {
        let l = try await enabled(.biometrics)
        keys.nextPrompts(.cancel)
        #expect(try await !l.enable(.passcode, reason: "Unlock VettID"))
        #expect(l.state == .disabled && !l.invalidated && !store.current.enabled)
    }

    @Test func theFaceNoticeIsTheBiometricMethodsOnly() async throws {
        let l = try await enabled(.passcode)
        l.lockNow()
        keys.invalidate() // the passcode was turned off
        #expect(await !l.unlock(reason: "Unlock VettID"))
        #expect(l.state == .disabled && !l.invalidated)
    }

    /// A cancelled prompt leaves the lock as it was: locked, and no automatic prompt follows during the same lock.
    @Test func aCancelledPromptIsNotRepeatedByItself() async throws {
        let l = try await enabled()
        l.lockNow()
        keys.nextPrompts(.cancel)
        #expect(await !l.unlock(reason: "Unlock VettID", auto: true))
        #expect(l.state == .locked)
        #expect(await !l.unlock(reason: "Unlock VettID", auto: true))
        #expect(keys.opens == 2, "no second automatic prompt")
        #expect(await l.unlock(reason: "Unlock VettID"))
    }

    /// The lock never shuts the member out. Face ID locked after too many attempts: the lock stays and says to unlock the
    /// iPhone with its passcode; the next prompt is the member's, and it opens. Face ID turned off for the app: the key can
    /// no longer be used, and the lock turns itself off with the notice.
    @Test func aLockoutIsRetriedAndAnUnusableKeyTurnsTheLockOff() async throws {
        let l = try await enabled()
        l.lockNow()
        keys.nextPrompts(.lockout)
        #expect(await !l.unlock(reason: "Unlock VettID", auto: true))
        #expect(l.state == .locked && l.lockedOut && !l.invalidated)
        #expect(await l.unlock(reason: "Unlock VettID"))
        #expect(!l.lockedOut && l.state == .unlocked)
        l.lockNow()
        keys.nextPrompts(.unavailable)
        #expect(await !l.unlock(reason: "Unlock VettID"))
        #expect(l.state == .disabled && l.invalidated && !store.current.enabled)
    }

    /// A key lookup that answers neither "found" nor "no such item" keeps the lock: still pending, tried again.
    @Test func aLookupThatFailsKeepsTheLock() async throws {
        _ = try await enabled()
        keys.lookupFails = true
        let l = lock()
        l.start()
        #expect(l.state == .pending && store.current.enabled)
        keys.lookupFails = false
        l.start()
        #expect(l.state == .locked)
    }

    /// The first-run cleanup failed (not a locked iPhone): the lock gives way to the screen that says so.
    @Test func aFailedStartGivesWay() {
        let l = lock()
        l.startFailed()
        #expect(l.state == .disabled)
    }

    /// No Secure Enclave (the app's placeholder until I1.4b): the lock cannot be turned on, and stays off.
    @Test func withoutSecureHardwareTheLockCannotBeTurnedOn() async {
        let l = AppLock(store: store, keys: NoAppLockKeys())
        l.start()
        await #expect(throws: KeysError.noSecureHardware) { _ = try await l.enable(.biometrics, reason: "Unlock VettID") }
        #expect(l.state == .disabled && !store.current.enabled)
    }

    /// The wipe of a replaced phone: off, no key, the defaults.
    @Test func resetIsAFreshInstall() async throws {
        let l = try await enabled(.passcode)
        try l.setTimeout(.oneHour)
        l.reset()
        #expect(try l.state == .disabled && l.method == .biometrics && l.timeout == .standard && !keys.exists() && store.sealed == nil)
    }

    struct NoAppLockKeys: AppLockKeys {
        func create(_ method: AppLockMethod) throws { throw KeysError.noSecureHardware }
        func exists() -> Bool { false }
        func seal(_ plaintext: [UInt8]) throws -> [UInt8] { throw KeysError.noSecureHardware }
        func open(_ sealed: [UInt8], reason: String) async throws -> [UInt8] { throw AppLockKeyError.invalidated }
        func delete() throws {}
    }
}

/// One app-lock prompt at a time. Mirrors vettid-android `UnlockPromptGateTest` (iOS has no activity that goes away with
/// its prompt).
@MainActor
@Suite struct UnlockPromptGateTests {
    @Test func onePromptAtATime() {
        let g = UnlockPromptGate()
        #expect(g.tryStart(auto: true))
        // The lock screen drawn again, the app back in the foreground, "Unlock" pressed: no second prompt.
        #expect(!g.tryStart(auto: true))
        #expect(!g.tryStart(auto: false))
        #expect(g.prompting)
    }

    @Test func theSuccessUnlocksWithoutASecondPrompt() {
        let g = UnlockPromptGate()
        #expect(g.tryStart(auto: true))
        g.finished(.succeeded)
        #expect(!g.prompting)
        g.newLock()
        #expect(g.tryStart(auto: true))
    }

    @Test func aCancelledPromptIsNotRelaunchedByItself() {
        let g = UnlockPromptGate()
        #expect(g.tryStart(auto: true))
        g.finished(.dismissed)
        #expect(!g.tryStart(auto: true), "a return to the app: the Unlock button instead")
        #expect(g.tryStart(auto: false), "the member pressed Unlock")
    }

    @Test func aNewLockPromptsByItselfAgain() {
        let g = UnlockPromptGate()
        _ = g.tryStart(auto: true)
        g.finished(.dismissed)
        g.newLock()
        #expect(g.tryStart(auto: true))
    }
}
