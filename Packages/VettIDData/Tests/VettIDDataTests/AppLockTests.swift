import Foundation
import Testing
@testable import VettIDData
import VettIDKeys
import VettIDKeysTesting

/// The app lock's preferences in memory, with the sealed data key an earlier build may have left ([retired]);
/// [unavailable] answers like a locked iPhone, [corrupt] like a damaged file.
final class MemoryAppLockStore: AppLockStore, @unchecked Sendable {
    private let lock = NSLock()
    private var prefs = AppLockPreferences()
    private var retiredValue: [UInt8]?
    private var unavailableValue = false
    private var corruptValue = false

    var current: AppLockPreferences {
        get { lock.withLock { prefs } }
        set { lock.withLock { prefs = newValue } }
    }

    var retired: [UInt8]? {
        get { lock.withLock { retiredValue } }
        set { lock.withLock { retiredValue = newValue } }
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

    func deleteRetired() throws { retired = nil }
}

/// The app lock (ANDROID-PLAN D6; IOS-PLAN ID17) with a software stand-in for the Secure Enclave key. Mirrors
/// vettid-android `AppLockTest`, test for test, with the prompt inside the key's use as on iOS.
/// The software app-lock key with two faults: a seal that throws [sealError], and an open that answers other bytes than
/// were sealed ([otherBytes]).
final class FaultyAppLockKeys: AppLockKeys, @unchecked Sendable {
    let inner: SoftwareAppLockKeys
    private let lock = NSLock()
    private var sealErrorValue: (any Error)?
    private var otherBytesValue = false

    init(_ inner: SoftwareAppLockKeys) { self.inner = inner }

    var sealError: (any Error)? {
        get { lock.withLock { sealErrorValue } }
        set { lock.withLock { sealErrorValue = newValue } }
    }

    var otherBytes: Bool {
        get { lock.withLock { otherBytesValue } }
        set { lock.withLock { otherBytesValue = newValue } }
    }

    func create(_ method: AppLockMethod) throws { try inner.create(method) }
    func exists() throws -> Bool { try inner.exists() }

    func seal(_ plaintext: [UInt8]) throws -> [UInt8] {
        if let e = sealError { throw e }
        return try inner.seal(plaintext)
    }

    func open(_ sealed: [UInt8], reason: String) async throws -> [UInt8] {
        let b = try await inner.open(sealed, reason: reason)
        return otherBytes ? b.map { $0 ^ 0x01 } : b
    }

    func delete() throws { try inner.delete() }
}

@MainActor
@Suite struct AppLockTests {
    final class Clock: @unchecked Sendable {
        var t = Date(timeIntervalSince1970: 1_791_000_000)
    }

    let store = MemoryAppLockStore()
    let keys = SoftwareAppLockKeys()
    let clock = Clock()

    func lock(_ keys: (any AppLockKeys)? = nil) -> AppLock {
        let clock = clock
        return AppLock(store: store, keys: keys ?? self.keys) { clock.t }
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
        #expect(l.state == .disabled)
    }

    /// A UI gate only: each prompt opens a fresh challenge sealed to the key; no data key is made or kept.
    @Test func enableThenRestartStartsLockedAndUnlocks() async throws {
        let l = try await enabled()
        #expect(l.state == .unlocked && store.current.enabled && keys.opens == 1)
        #expect(store.retired == nil)

        let again = lock()
        again.start()
        #expect(again.state == .locked)
        #expect(await again.unlock(reason: "Unlock VettID"))
        #expect(again.state == .unlocked && keys.opens == 2)
    }

    /// The sealed data key an earlier build left is deleted at the start, unread, and the lock that was on stays on (its
    /// key is the gate); a start with nothing left changes nothing.
    @Test func anEarlierBuildsSealedDataKeyIsDeletedAtTheStart() async throws {
        _ = try await enabled()
        store.retired = [0x01, 1, 2, 3]
        let l = lock()
        l.start()
        #expect(store.retired == nil && l.state == .locked && store.current.enabled)
        #expect(await l.unlock(reason: "Unlock VettID"))
        let again = lock()
        again.start()
        #expect(store.retired == nil && again.state == .locked)
    }

    /// The file of the sealed data key an earlier build left, and the temporary file of an interrupted write of it, are
    /// deleted by the file store, and a second deletion is no error.
    @Test func theFileStoreDeletesTheRetiredFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent(FileAppLockStore.sealedFile)
        try Data([1, 2, 3]).write(to: file)
        // An interrupted write of it by an earlier build; the settings' own temporary file is not its.
        let tmp = dir.appendingPathComponent(".\(FileAppLockStore.sealedFile).\(UUID().uuidString).tmp")
        let settingsTmp = dir.appendingPathComponent(".\(FileAppLockStore.settingsFile).\(UUID().uuidString).tmp")
        try Data([4]).write(to: tmp)
        try Data([5]).write(to: settingsTmp)
        let s = FileAppLockStore(directory: dir, keys: InMemoryFileKeyHolder(), protectedData: ProtectedDataFlag(available: true))
        try s.deleteRetired()
        #expect(!FileManager.default.fileExists(atPath: file.path) && !FileManager.default.fileExists(atPath: tmp.path))
        #expect(FileManager.default.fileExists(atPath: settingsTmp.path))
        try s.deleteRetired()
    }

    /// Whatever fails at the start, the lock leaves "pending": settings that cannot be read are a lock that cannot open,
    /// off, with the notice. A locked iPhone (no protected data yet) stays pending until the next start.
    @Test func settingsThatCannotBeReadTurnTheLockOffInsteadOfLeavingItPending() async throws {
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
        #expect(l.state == .locked)
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

    /// A key that opens to other bytes than the challenge sealed to it no longer opens: the lock turns itself off, with
    /// the notice, and the key goes.
    @Test func aKeyThatOpensToOtherBytesTurnsTheLockOff() async throws {
        let faulty = FaultyAppLockKeys(keys)
        let l = lock(faulty)
        l.start()
        #expect(try await l.enable(.biometrics, reason: "Unlock VettID"))
        l.lockNow()
        faulty.otherBytes = true
        #expect(await !l.unlock(reason: "Unlock VettID"))
        #expect(try l.state == .disabled && l.invalidated && !store.current.enabled && !keys.exists())
    }

    /// A seal that fails because the key cannot be read now (`unavailable`) is no lock that cannot open: the lock stays
    /// on, without the notice and without a prompt, and opens at the next try.
    @Test func aSealThatIsUnavailableKeepsTheLockOn() async throws {
        let faulty = FaultyAppLockKeys(keys)
        let l = lock(faulty)
        l.start()
        #expect(try await l.enable(.biometrics, reason: "Unlock VettID"))
        l.lockNow()
        faulty.sealError = KeysError.unavailable("app lock key")
        #expect(await !l.unlock(reason: "Unlock VettID"))
        #expect(try l.state == .locked && !l.invalidated && store.current.enabled && keys.exists() && keys.opens == 1)
        faulty.sealError = nil
        #expect(await l.unlock(reason: "Unlock VettID"))
        #expect(l.state == .unlocked)
    }

    /// The key gone (deleted outside the app lock): the lock cannot open and turns itself off, with the notice.
    @Test func aMissingKeyTurnsTheLockOff() async throws {
        let l = try await enabled()
        l.lockNow()
        try keys.delete()
        #expect(await !l.unlock(reason: "Unlock VettID"))
        #expect(l.state == .disabled && l.invalidated && keys.opens == 1, "no prompt for a key that is gone")
    }

    @Test func disableForgetsEverything() async throws {
        let l = try await enabled()
        try l.disable()
        #expect(try l.state == .disabled && !keys.exists() && store.retired == nil)
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

    /// No Secure Enclave (the app's placeholder on the simulator): the lock cannot be turned on, and stays off.
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
        #expect(try l.state == .disabled && l.method == .biometrics && l.timeout == .standard && !keys.exists() && store.retired == nil)
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
