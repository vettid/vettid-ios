import CryptoKit
import Foundation
import VettIDCrypto
import VettIDKeys

// TEST ONLY: software keys behind the protocols of the Secure Enclave keys (IOS-PLAN §6.1, §6.3), for unit tests and the
// simulator, which has no Secure Enclave. Never linked by a Release or Staging app: the release check fails on this
// module's name and on ``SoftwareKeys/testOnlyMarker``. Each key can be made to behave like a locked iPhone
// (``SoftwareKeyBehaviour/locked``) or a key iOS reports invalid (``SoftwareKeyBehaviour/invalid``).

/// The marker the release check looks for.
public enum SoftwareKeys {
    public static let testOnlyMarker = "VETTID TEST ONLY: software keys instead of the Secure Enclave"
}

/// How a software key answers: normally, like a locked iPhone (refused for now), or like a key iOS reports invalid.
public enum SoftwareKeyBehaviour: Sendable {
    case normal
    case locked
    case invalid
}

/// A behaviour switch shared by a key and its source.
public final class SoftwareKeyState: @unchecked Sendable, CustomStringConvertible {
    private let lock = NSLock()
    private var value: SoftwareKeyBehaviour = .normal

    public init() {}

    public var behaviour: SoftwareKeyBehaviour {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }

    func check(_ what: String) throws {
        switch behaviour {
        case .normal: return
        case .locked: throw KeysError.unavailable(what)
        case .invalid: throw KeysError.invalid(what)
        }
    }

    public var description: String { SoftwareKeys.testOnlyMarker }
}

/// A software P-256 key-agreement key: the phone key's or the seed-wrapping key's stand-in.
public final class SoftwareKeyAgreementKey: KeyAgreementKey, @unchecked Sendable {
    private let agreement: P256.KeyAgreement.PrivateKey
    public let state: SoftwareKeyState
    /// How many ECDH computations this key made (tests count the Secure Enclave's work).
    public private(set) var agreements = 0
    private let lock = NSLock()

    public init(_ agreement: P256.KeyAgreement.PrivateKey = P256.KeyAgreement.PrivateKey(), state: SoftwareKeyState = SoftwareKeyState()) {
        self.agreement = agreement
        self.state = state
    }

    /// A key from its raw 32-byte scalar (the vectors' fixed keys).
    public convenience init(raw: [UInt8]) throws {
        self.init(try P256.KeyAgreement.PrivateKey(rawRepresentation: raw))
    }

    public func publicKey() throws -> [UInt8] {
        try state.check("key agreement key")
        return Array(agreement.publicKey.x963Representation)
    }

    public func agree(_ peer: [UInt8]) throws -> [UInt8] {
        try state.check("key agreement key")
        lock.withLock { agreements += 1 }
        return try SoftwareECDH.agree(agreement, peer)
    }
}

/// The software ``PhoneSecretSource``: one key per `key_vault`, in memory. [make] makes new keys (random by default;
/// the vectors pass their fixed key). A [source] state set to `locked` refuses lookups like a locked iPhone.
public final class SoftwarePhoneSecretSource: PhoneSecretSource, @unchecked Sendable {
    private struct Entry {
        let keyVault: String
        let keyID: String
        let key: SoftwareKeyAgreementKey
    }

    private let lock = NSLock()
    /// By label, in creation order.
    private var entries: [Entry] = []
    private let make: @Sendable () throws -> SoftwareKeyAgreementKey
    public let source = SoftwareKeyState()
    /// How many keys were made.
    public private(set) var created = 0
    /// Each software source holds its own keys in memory: its own identity.
    public let sourceID = "software-phone-keys-" + UUID().uuidString

    public init(make: @escaping @Sendable () throws -> SoftwareKeyAgreementKey = { SoftwareKeyAgreementKey() }) {
        self.make = make
    }

    public func create(keyVault: String) throws -> (keyID: String, key: any KeyAgreementKey) {
        try source.check("phone key")
        let k = try make()
        let id = PhoneKeyLabel.newKeyID()
        lock.withLock {
            entries.append(Entry(keyVault: keyVault, keyID: id, key: k))
            created += 1
        }
        return (id, k)
    }

    public func lookup(keyVault: String, keyID: String) -> ItemLookup<any KeyAgreementKey> {
        if source.behaviour == .locked { return .unavailable }
        return lock.withLock {
            entries.first { $0.keyVault == keyVault && $0.keyID == keyID }.map { .found($0.key) } ?? .missing
        }
    }

    /// The newest key of [keyVault], to change its behaviour.
    public func key(_ keyVault: String) -> SoftwareKeyAgreementKey? {
        lock.withLock { entries.last { $0.keyVault == keyVault }?.key }
    }

    /// The `key_vault`s that have at least one key, sorted.
    public var keyVaults: [String] { lock.withLock { Array(Set(entries.map(\.keyVault))).sorted() } }

    /// How many keys exist.
    public var count: Int { lock.withLock { entries.count } }

    /// Deletes every key of [keyVault] (a test's "the key is gone").
    public func deleteKeys(of keyVault: String) {
        lock.withLock { entries.removeAll { $0.keyVault == keyVault } }
    }

    public func delete(keyVault: String, keyID: String) throws {
        try source.check("phone key")
        lock.withLock { entries.removeAll { $0.keyVault == keyVault && $0.keyID == keyID } }
    }

    public func deleteAll() throws {
        try source.check("phone key")
        lock.withLock { entries.removeAll() }
    }

    public func keyNames() throws -> [PhoneKeyName] {
        try source.check("phone key")
        return lock.withLock { entries.map { PhoneKeyName(keyVault: $0.keyVault, keyID: $0.keyID) } }
    }
}

/// The software seed-wrapping key source.
public final class SoftwareSeedWrapKeySource: SeedWrapKeySource, @unchecked Sendable {
    private let lock = NSLock()
    private var key: SoftwareKeyAgreementKey?

    public init() {}

    public func getOrCreate() throws -> any KeyAgreementKey {
        lock.withLock {
            if let k = key { return k }
            let k = SoftwareKeyAgreementKey()
            key = k
            return k
        }
    }

    public var exists: Bool { lock.withLock { key != nil } }

    public func deleteAll() throws { lock.withLock { key = nil } }
}

/// A software app key (P-256 ECDSA, DER signatures).
public final class SoftwareAppSigningKey: AppSigningKey, @unchecked Sendable {
    private let signer: P256.Signing.PrivateKey
    public let state: SoftwareKeyState

    public init(_ signer: P256.Signing.PrivateKey = P256.Signing.PrivateKey(), state: SoftwareKeyState = SoftwareKeyState()) {
        self.signer = signer
        self.state = state
    }

    public func spki() throws -> [UInt8] {
        try state.check("app key")
        return Array(signer.publicKey.derRepresentation)
    }

    public func sign(_ message: [UInt8]) throws -> [UInt8] {
        try state.check("app key")
        return Array(try signer.signature(for: message).derRepresentation)
    }
}

/// The software ``AppKeyStore``.
public final class SoftwareAppKeyStore: AppKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: SoftwareAppSigningKey?
    public let source = SoftwareKeyState()

    public init() {}

    public func getOrCreate() throws -> any AppSigningKey {
        try source.check("app key")
        return lock.withLock {
            if let k = key { return k }
            let k = SoftwareAppSigningKey()
            key = k
            return k
        }
    }

    public func regenerate() throws -> any AppSigningKey {
        try source.check("app key")
        let k = SoftwareAppSigningKey()
        lock.withLock { key = k }
        return k
    }

    public func lookup() -> ItemLookup<any AppSigningKey> {
        if source.behaviour == .locked { return .unavailable }
        return lock.withLock { key.map { .found($0) } ?? .missing }
    }

    /// The stored key itself, to change its behaviour.
    public var current: SoftwareAppSigningKey? { lock.withLock { key } }

    public func deleteAll() throws { lock.withLock { key = nil } }
}

/// An in-memory file key (the keychain's stand-in where `swift test` has no keychain).
public final class InMemoryFileKeyHolder: FileKeyHolder, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: SymmetricKey?
    public let state = SoftwareKeyState()

    public init() {}

    public func key() throws -> SymmetricKey {
        try state.check("file key")
        return lock.withLock {
            if let k = stored { return k }
            let k = SymmetricKey(size: .bits256)
            stored = k
            return k
        }
    }

    public func deleteAll() throws { lock.withLock { stored = nil } }

    /// Whether a key is held.
    public var holdsKey: Bool { lock.withLock { stored != nil } }
}

/// Wrapped seeds in memory.
public final class InMemoryWrappedKeyStore: WrappedKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var blobs: [KeySlot: [UInt8]] = [:]

    public init() {}

    public func get(_ slot: KeySlot) throws -> [UInt8]? { lock.withLock { blobs[slot] } }

    public func put(_ slot: KeySlot, _ blob: [UInt8]) throws { lock.withLock { blobs[slot] = blob } }

    public func remove(_ slot: KeySlot) throws { _ = lock.withLock { blobs.removeValue(forKey: slot) } }

    public var all: [[UInt8]] { lock.withLock { Array(blobs.values) } }
}

/// An eraser that records that it ran (the first-run cleanup's tests).
public final class RecordingEraser: KeyEraser, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    public var fails = false

    public init() {}

    public var runs: Int { lock.withLock { count } }

    public func deleteAll() throws {
        if fails { throw KeysError.unavailable("eraser") }
        lock.withLock { count += 1 }
    }
}

/// TEST ONLY. The app-lock key's software stand-in (the simulator has no Secure Enclave): an AES-GCM key in memory. Each
/// prompt answers as ``nextPrompts`` says (success by default); ``invalidate()`` is a new face or finger enrolled.
public final class SoftwareAppLockKeys: AppLockKeys, @unchecked Sendable, CustomStringConvertible {
    /// How one prompt ends.
    public enum Prompt: Sendable {
        case succeed
        case cancel
        case fail
        /// Face ID or Touch ID locked after too many attempts.
        case lockout
        /// Face ID or Touch ID turned off for the app (or the passcode turned off): the key can no longer be used.
        case unavailable
    }

    private let lock = NSLock()
    private var key: SymmetricKey?
    private var promptsValue: [Prompt] = []
    private var createdValue: [AppLockMethod] = []
    private var opensValue = 0

    public init() {}

    public var description: String { SoftwareKeys.testOnlyMarker }

    /// The next prompts' answers, in order; then success.
    public func nextPrompts(_ p: Prompt...) { lock.withLock { promptsValue += p } }

    /// The methods of the keys made, in order.
    public var created: [AppLockMethod] { lock.withLock { createdValue } }

    /// How many prompts were shown.
    public var opens: Int { lock.withLock { opensValue } }

    /// The key no longer opens (a new face or finger, the passcode turned off).
    public func invalidate() { lock.withLock { key = nil } }

    public func create(_ method: AppLockMethod) throws {
        lock.withLock {
            createdValue.append(method)
            key = SymmetricKey(size: .bits256)
        }
    }

    private var lookupFailsValue = false

    /// The key's lookup answers neither "found" nor "no such item" (the iPhone not ready, say).
    public var lookupFails: Bool {
        get { lock.withLock { lookupFailsValue } }
        set { lock.withLock { lookupFailsValue = newValue } }
    }

    public func exists() throws -> Bool {
        if lookupFails { throw KeysError.unavailable("app lock key") }
        return lock.withLock { key != nil }
    }

    public func seal(_ plaintext: [UInt8]) throws -> [UInt8] {
        guard let key = lock.withLock({ key }) else { throw KeysError.missing("app lock key") }
        guard let combined = try AES.GCM.seal(plaintext, using: key).combined else { throw KeysError.invalid("app lock key") }
        return Array(combined)
    }

    public func open(_ sealed: [UInt8], reason: String) async throws -> [UInt8] {
        lock.lock()
        opensValue += 1
        let held = key
        let prompt: Prompt = promptsValue.first ?? .succeed
        if !promptsValue.isEmpty { promptsValue.removeFirst() }
        lock.unlock()
        guard let key = held else { throw AppLockKeyError.invalidated }
        switch prompt {
        case .cancel: throw AppLockKeyError.cancelled
        case .fail: throw AppLockKeyError.failed
        case .lockout: throw AppLockKeyError.lockedOut
        case .unavailable: throw AppLockKeyError.invalidated
        case .succeed: break
        }
        do {
            return Array(try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key))
        } catch {
            throw AppLockKeyError.invalidated
        }
    }

    public func delete() throws { lock.withLock { key = nil } }
}
