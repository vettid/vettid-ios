import Foundation
import Observation
import VettIDCrypto
import VettIDKeys

/// The app lock's state (ANDROID-PLAN D6). Mirrors vettid-android `AppLockState`.
public enum AppLockState: Equatable, Sendable {
    /// The preferences are not read yet (the iPhone has not been unlocked since it started).
    case pending
    /// The app lock is off.
    case disabled
    /// On, and the member has not authenticated since the app started or timed out.
    case locked
    /// On, and authenticated: the app's data key is in memory.
    case unlocked
}

/// How long the app may stay in the background before it locks again. Mirrors vettid-android `AppLockTimeout`.
public enum AppLockTimeout: Int, Codable, CaseIterable, Sendable {
    case immediately = 0
    case oneMinute = 60
    case fiveMinutes = 300
    case fifteenMinutes = 900
    case oneHour = 3600

    public static let standard = AppLockTimeout.fiveMinutes
}

/// The app lock's preferences. [method] nil: never chosen (Face ID or Touch ID then). Mirrors the app-lock fields of
/// vettid-android `AppPreferences`.
public struct AppLockPreferences: Codable, Equatable, Sendable {
    public var enabled = false
    public var method: AppLockMethod?
    public var timeout = AppLockTimeout.standard

    public init(enabled: Bool = false, method: AppLockMethod? = nil, timeout: AppLockTimeout = .standard) {
        self.enabled = enabled
        self.method = method
        self.timeout = timeout
    }
}

/// Where the app lock keeps its preferences and the sealed data key. Mirrors vettid-android `PreferencesRepository` (its
/// app-lock part) and `WrappedKeyFile`.
public protocol AppLockStore: Sendable {
    func preferences() throws -> AppLockPreferences
    func setPreferences(_ p: AppLockPreferences) throws
    func readSealed() throws -> [UInt8]?
    func writeSealed(_ b: [UInt8]) throws
    func deleteSealed() throws
}

/// ``AppLockStore`` in two encrypted files of the app's data directory (excluded from backups, IOS-PLAN §6.1).
public struct FileAppLockStore: AppLockStore {
    public static let settingsFile = "app-lock-settings"
    public static let sealedFile = "app-lock"

    private let settings: EncryptedFileStore
    private let sealed: EncryptedFileStore

    public init(directory: URL, keys: any FileKeyHolder, protectedData: any ProtectedData) {
        settings = EncryptedFileStore(
            url: directory.appendingPathComponent(Self.settingsFile), purpose: Self.settingsFile, keys: keys, protectedData: protectedData
        )
        sealed = EncryptedFileStore(
            url: directory.appendingPathComponent(Self.sealedFile), purpose: Self.sealedFile, keys: keys, protectedData: protectedData
        )
    }

    public func preferences() throws -> AppLockPreferences {
        guard let b = try settings.load() else { return AppLockPreferences() }
        do {
            return try JSONDecoder().decode(AppLockPreferences.self, from: Data(b))
        } catch {
            throw KeysError.corrupt("app lock settings")
        }
    }

    public func setPreferences(_ p: AppLockPreferences) throws { try settings.save(Array(try JSONEncoder().encode(p))) }
    public func readSealed() throws -> [UInt8]? { try sealed.load() }
    public func writeSealed(_ b: [UInt8]) throws { try sealed.save(b) }
    public func deleteSealed() throws { try sealed.clear() }
}

/// How an app-lock prompt ended. Mirrors vettid-android `PromptOutcome`.
public enum PromptOutcome: Sendable {
    case succeeded
    /// The member cancelled it, or it failed: the lock screen's "Unlock" asks again.
    case dismissed
}

/// One app-lock prompt at a time, and no automatic prompt after one that ended without success during the same lock: the
/// member presses "Unlock" (no loop of prompts). Mirrors vettid-android `UnlockPromptGate` (iOS has no activity that
/// could go away with its prompt).
@MainActor
public final class UnlockPromptGate {
    private var inFlight = false
    private var endedWithoutSuccess = false

    public init() {}

    public var prompting: Bool { inFlight }

    /// Whether a prompt may start; never while one is in flight, nor automatically after one that did not succeed.
    public func tryStart(auto: Bool) -> Bool {
        if inFlight || (auto && endedWithoutSuccess) { return false }
        inFlight = true
        return true
    }

    public func finished(_ outcome: PromptOutcome) {
        inFlight = false
        endedWithoutSuccess = outcome != .succeeded
    }

    /// A new lock (start, timeout): its first prompt is automatic again.
    public func newLock() { endedWithoutSuccess = false }
}

/// The app lock (ANDROID-PLAN D6; IOS-PLAN ID17). When on, opening the app, and returning to it after the timeout, asks
/// for Face ID or Touch ID, or for the iPhone passcode only (``AppLockMethod``), whose Secure Enclave key opens the app's
/// data key: a random 32-byte key that the app's local caches will be encrypted under (with the rows that bring them). A
/// convenience layer only: it never replaces the vault PIN or the credential password, and nothing of the vault depends
/// on it. A key that no longer opens (a new face or finger with Face ID or Touch ID) turns the lock off and says so
/// ([invalidated]); one that stops opening with the passcode method (the passcode turned off) turns it off without that
/// notice. Mirrors vettid-android `AppLock`, with the prompt inside the key's use (iOS shows it when the Secure Enclave
/// key is used).
@MainActor
@Observable
public final class AppLock {
    nonisolated static let keySize = 32
    nonisolated static let format: UInt8 = 0x01

    public private(set) var state: AppLockState = .pending
    /// The key no longer opened and the lock turned itself off (Face ID or Touch ID only).
    public private(set) var invalidated = false
    /// The last prompt found Face ID or Touch ID locked after too many attempts: the lock screen says to unlock the iPhone
    /// with its passcode, then try again. The lock is kept.
    public private(set) var lockedOut = false
    /// How the lock asks; the chosen one also while the lock is off.
    public private(set) var method: AppLockMethod = .biometrics
    public private(set) var timeout: AppLockTimeout = .standard
    /// One prompt at a time, and no automatic prompt after one the member dismissed.
    @ObservationIgnored public let prompts = UnlockPromptGate()
    /// Set while a prompt shows: iOS's prompt makes the app inactive, which is not leaving it.
    @ObservationIgnored public var authenticating = false

    @ObservationIgnored private let store: any AppLockStore
    @ObservationIgnored private let keys: any AppLockKeys
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var dataKey: [UInt8]?
    @ObservationIgnored private var backgroundAt: Date?

    public init(store: any AppLockStore, keys: any AppLockKeys, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.keys = keys
        self.now = now
    }

    /// Reads the preferences: an enabled lock starts locked. Leaves ``AppLockState/pending`` unless the iPhone has not been
    /// unlocked since it started (tried again by the next call). Anything else that fails is a lock that cannot open: off,
    /// with the notice, never pending for good.
    public func start() {
        guard state == .pending else { return }
        let p: AppLockPreferences
        do {
            p = try store.preferences()
        } catch KeysError.unavailable {
            return
        } catch {
            // Settings that cannot be read are replaced by the defaults: the lock is off.
            turnedOff(invalidated: true)
            try? store.setPreferences(AppLockPreferences())
            return
        }
        timeout = p.timeout
        method = p.method ?? .biometrics
        prompts.newLock()
        var usable = false
        if p.enabled {
            do {
                let sealed = try store.readSealed()
                usable = try keys.exists() && sealed != nil
            } catch KeysError.unavailable {
                return
            } catch {
                invalidated = true
            }
        }
        state = usable ? .locked : .disabled
        // Bookkeeping last: a preference that cannot be written must not keep the lock pending.
        var fixed = p
        if p.enabled && p.method == nil { fixed.method = .biometrics }
        if p.enabled && !usable { fixed.enabled = false }
        if fixed != p { try? store.setPreferences(fixed) }
    }

    /// The first-run cleanup failed for another reason than a locked iPhone: nothing can be read, and the lock never keeps
    /// the member from the screen that says so (and its way out).
    public func startFailed() {
        if state == .pending { state = .disabled }
    }

    /// Chooses the method while the lock is off (it applies when the lock is turned on).
    public func chooseMethod(_ m: AppLockMethod) throws {
        guard state != .locked, state != .unlocked else { return }
        var p = (try? store.preferences()) ?? AppLockPreferences()
        p.method = m
        try store.setPreferences(p)
        method = m
    }

    public func setTimeout(_ t: AppLockTimeout) throws {
        var p = (try? store.preferences()) ?? AppLockPreferences()
        p.timeout = t
        try store.setPreferences(p)
        timeout = t
    }

    /// Turns the lock on with [m] (also how the method of a lock that is on changes): a fresh key, the data key sealed to
    /// it, then one prompt that opens it, so that the member has shown they can. True once on; false when the prompt was
    /// cancelled or failed: the fresh key replaced any earlier one, so a lock that was on cannot open any more and is
    /// turned off, without the notice. Throws when the key cannot be made (``KeysError/noSecureHardware``).
    public func enable(_ m: AppLockMethod, reason: String) async throws -> Bool {
        guard prompts.tryStart(auto: false) else { return false }
        authenticating = true
        defer { authenticating = false }
        var fresh = Randomness.bytes(Self.keySize)
        defer { Bytes.wipe(&fresh) }
        do {
            try keys.create(m)
            try store.writeSealed([Self.format] + (try keys.seal(fresh)))
        } catch {
            prompts.finished(.dismissed)
            try? turnOff(invalidated: false)
            throw error
        }
        do {
            guard let sealed = try store.readSealed() else { throw AppLockKeyError.invalidated }
            var opened = try await keys.open(Array(sealed.dropFirst()), reason: reason)
            defer { Bytes.wipe(&opened) }
            guard opened == fresh else { throw AppLockKeyError.invalidated }
        } catch {
            prompts.finished(.dismissed)
            try? turnOff(invalidated: false)
            return false
        }
        prompts.finished(.succeeded)
        try store.setPreferences(AppLockPreferences(enabled: true, method: m, timeout: timeout))
        method = m
        keep(fresh)
        invalidated = false
        state = .unlocked
        return true
    }

    /// Opens the lock: one prompt, unless one is in flight or ([auto]) the last one of this lock did not succeed. True
    /// when the app is open. A key that cannot open any more turns the lock off.
    @discardableResult
    public func unlock(reason: String, auto: Bool = false) async -> Bool {
        guard state == .locked, prompts.tryStart(auto: auto) else { return false }
        lockedOut = false
        authenticating = true
        defer { authenticating = false }
        // The "new face or finger" notice is the biometric method's only.
        let notice = method == .biometrics
        let sealed: [UInt8]
        do {
            guard let s = try store.readSealed(), s.count > 1, s[0] == Self.format else {
                prompts.finished(.dismissed)
                try? turnOff(invalidated: notice)
                return false
            }
            sealed = s
        } catch {
            prompts.finished(.dismissed)
            return false
        }
        do {
            let k = try await keys.open(Array(sealed.dropFirst()), reason: reason)
            guard k.count == Self.keySize else { throw AppLockKeyError.invalidated }
            prompts.finished(.succeeded)
            keep(k)
            state = .unlocked
            return true
        } catch AppLockKeyError.invalidated {
            prompts.finished(.dismissed)
            try? turnOff(invalidated: notice)
            return false
        } catch AppLockKeyError.lockedOut {
            prompts.finished(.dismissed)
            lockedOut = true
            return false
        } catch {
            prompts.finished(.dismissed)
            return false
        }
    }

    /// Turns the lock off: the key and the sealed data key go.
    public func disable() throws { try turnOff(invalidated: false) }

    private func turnOff(invalidated notice: Bool) throws {
        try? keys.delete()
        try? store.deleteSealed()
        forgetKey()
        turnedOff(invalidated: notice)
        var p = (try? store.preferences()) ?? AppLockPreferences()
        p.enabled = false
        try store.setPreferences(p)
    }

    private func turnedOff(invalidated notice: Bool) {
        invalidated = notice
        state = .disabled
    }

    /// As on a fresh install (a wipe of this phone): off, no key, the default method and timeout.
    public func reset() {
        try? keys.delete()
        try? store.deleteSealed()
        forgetKey()
        invalidated = false
        lockedOut = false
        state = .disabled
        method = .biometrics
        timeout = .standard
        backgroundAt = nil
        authenticating = false
    }

    public func acknowledgeInvalidated() { invalidated = false }

    /// Locks now (the key leaves memory).
    public func lockNow() {
        guard state == .unlocked else { return }
        forgetKey()
        prompts.newLock()
        state = .locked
    }

    /// The app left the foreground (IOS-PLAN §6.6: the timeout counts from then, read on return). Not while a prompt
    /// shows.
    public func onBackground() {
        if authenticating { return }
        backgroundAt = now()
    }

    public func onForeground() {
        if authenticating { return }
        guard let at = backgroundAt else { return }
        backgroundAt = nil
        if state == .unlocked && now().timeIntervalSince(at) >= Double(timeout.rawValue) { lockNow() }
    }

    /// The app's data key while unlocked (a copy; the caller wipes it), else nil.
    public func appDataKey() -> [UInt8]? { dataKey }

    private func keep(_ k: [UInt8]) {
        forgetKey()
        dataKey = k
    }

    private func forgetKey() {
        if dataKey != nil { Bytes.wipe(&dataKey!) } // swiftlint:disable:this force_unwrapping
        dataKey = nil
    }
}
