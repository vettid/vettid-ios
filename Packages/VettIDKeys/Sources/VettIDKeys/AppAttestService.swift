import Foundation
#if canImport(DeviceCheck)
import DeviceCheck
#endif

/// What App Attest answered, as ``AppAttestService`` reports it (`DCError.Code`).
public enum AppAttestServiceError: Error, Equatable, Sendable {
    case featureUnsupported
    /// Bad input, also App Attest's answer for a key id it does not know (seen on iOS 27). A second attestation of one
    /// key is not refused on iOS 27.0.1 (`AppAttestDeviceTests.testAKeyAttestedAgain`).
    case invalidInput
    /// The key is gone or unusable (a reinstall, a restore).
    case invalidKey
    case serverUnavailable
    /// No answer in time.
    case timedOut
    case other(Int)
}

/// App Attest as ``AppAttestKey`` uses it: `DCAppAttestService` on the iPhone (``DeviceCheckAppAttestService``), a
/// fake in tests. Key ids are App Attest's base64 strings. Errors are ``AppAttestServiceError``s.
public protocol AppAttestService: Sendable {
    var isSupported: Bool { get }
    func generateKey() throws -> String
    func attestKey(_ keyID: String, clientDataHash: [UInt8]) throws -> [UInt8]
    func generateAssertion(_ keyID: String, clientDataHash: [UInt8]) throws -> [UInt8]
}

/// The kept key ids: the current one (the vault accepted its attestation) and the pending ones (sent, not yet
/// confirmed), oldest first. Stored as JSON; a bare key id (an earlier format) reads as the current one.
///
/// (IOS-PLAN 0.1.33 §4.9) A phone that could not tell whether an open recovered the vault holds two device identities for a
/// while, and the vault bound each identity's own App Attest key at its register: `current` and `pending` are those of the
/// identity in use ([active]), and the other identity's are [parked] under its number, untouched, until it is used again or
/// forgotten.
struct KeyIDRecord: Equatable {
    /// The keys of an identity that is not in use.
    struct Parked: Equatable {
        var current: String?
        var pending: [String]
    }

    var current: String?
    var pending: [String]
    var active = 0
    var parked: [Int: Parked] = [:]

    /// The key an assertion uses.
    var inUse: String? { current ?? pending.last }

    init(current: String?, pending: [String]) {
        self.current = current
        self.pending = pending
    }

    init?(_ bytes: [UInt8]) {
        if let object = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any] {
            guard object["v"] as? Int == 1, let pending = object["pending"] as? [String] else { return nil }
            let current = object["current"] as? String
            guard Self.valid(pending, current) else { return nil }
            self.init(current: current, pending: pending)
            if let a = object["active"] as? Int { active = a }
            if let others = object["parked"] as? [String: [String: Any]] {
                for (key, value) in others {
                    guard let n = Int(key), let p = value["pending"] as? [String] else { return nil }
                    let c = value["current"] as? String
                    guard Self.valid(p, c) else { return nil }
                    parked[n] = Parked(current: c, pending: p)
                }
            }
            return
        }
        guard let id = String(bytes: bytes, encoding: .utf8), AppAttestKey.raw(id)?.isEmpty == false else { return nil }
        self.init(current: id, pending: [])
    }

    private static func valid(_ pending: [String], _ current: String?) -> Bool {
        (pending + [current].compactMap { $0 }).allSatisfy { AppAttestKey.raw($0)?.isEmpty == false }
    }

    /// The keys of identity [n] in use from now on; the ones in use are parked under their number. Nothing for the identity in use.
    mutating func use(_ n: Int) {
        guard n != active else { return }
        parked[active] = Parked(current: current, pending: pending)
        let next = parked.removeValue(forKey: n)
        current = next?.current
        pending = next?.pending ?? []
        active = n
    }

    func encoded() throws -> [UInt8] {
        var object: [String: Any] = ["v": 1, "pending": pending]
        if let current { object["current"] = current }
        if active != 0 { object["active"] = active }
        let others = parked.filter { $0.value.current != nil || !$0.value.pending.isEmpty }
        if !others.isEmpty {
            var map: [String: Any] = [:]
            for (n, p) in others {
                var entry: [String: Any] = ["pending": p.pending]
                if let c = p.current { entry["current"] = c }
                map[String(n)] = entry
            }
            object["parked"] = map
        }
        return Array(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
    }
}

/// Where the App Attest key id is kept: the keychain on the iPhone (``KeychainKeyIDStore``), memory in tests.
public protocol KeyIDStore: Sendable {
    func lookup() -> ItemLookup<[UInt8]>
    func write(_ value: [UInt8]) throws
    func delete() throws
}

/// The App Attest key id in the keychain: `AfterFirstUnlockThisDeviceOnly`, never synchronizable, never logged.
public struct KeychainKeyIDStore: KeyIDStore {
    private let item: KeychainItem
    private let protectedData: any ProtectedData

    /// [account] names the item; tests pass their own (`vettid.test.…`).
    public init(account: String = AppAttestKey.account, protectedData: any ProtectedData) {
        item = KeychainItem(account: account, accessible: .afterFirstUnlockThisDeviceOnly)
        self.protectedData = protectedData
    }

    public func lookup() -> ItemLookup<[UInt8]> { item.lookup(protectedData) }
    public func write(_ value: [UInt8]) throws { try item.write(value) }
    public func delete() throws { try item.delete() }
}

#if canImport(DeviceCheck)
/// `DCAppAttestService.shared`, waited for: each call blocks its thread until App Attest answers or ``timeout`` passes.
public struct DeviceCheckAppAttestService: AppAttestService {
    /// How long one call may wait for Apple (chosen; not in the spec).
    public static let timeout: Double = 60

    public init() {}

    public var isSupported: Bool { DCAppAttestService.shared.isSupported }

    public func generateKey() throws -> String {
        try Self.wait { done in DCAppAttestService.shared.generateKey { id, error in done(id, error) } }
    }

    public func attestKey(_ keyID: String, clientDataHash: [UInt8]) throws -> [UInt8] {
        Array(try Self.wait { done in
            DCAppAttestService.shared.attestKey(keyID, clientDataHash: Data(clientDataHash)) { data, error in done(data, error) }
        })
    }

    public func generateAssertion(_ keyID: String, clientDataHash: [UInt8]) throws -> [UInt8] {
        Array(try Self.wait { done in
            DCAppAttestService.shared.generateAssertion(keyID, clientDataHash: Data(clientDataHash)) { data, error in done(data, error) }
        })
    }

    private static func wait<T: Sendable>(_ start: (@escaping @Sendable (T?, (any Error)?) -> Void) -> Void) throws -> T {
        let answer = Answer<T>()
        start { value, error in answer.set(value, error) }
        guard answer.done.wait(timeout: .now() + timeout) == .success else { throw AppAttestServiceError.timedOut }
        let (value, error) = answer.get()
        if let value { return value }
        throw classify(error)
    }

    static func classify(_ error: (any Error)?) -> AppAttestServiceError {
        guard let error = error as NSError?, error.domain == DCErrorDomain else { return .other(-1) }
        switch DCError.Code(rawValue: error.code) {
        case .featureUnsupported: return .featureUnsupported
        case .invalidInput: return .invalidInput
        case .invalidKey: return .invalidKey
        case .serverUnavailable: return .serverUnavailable
        default: return .other(error.code)
        }
    }
}

/// One answer of App Attest, handed from its completion handler to the waiting thread.
private final class Answer<T: Sendable>: @unchecked Sendable {
    let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var value: T?
    private var error: (any Error)?

    func set(_ value: T?, _ error: (any Error)?) {
        lock.lock()
        self.value = value
        self.error = error
        lock.unlock()
        done.signal()
    }

    func get() -> (T?, (any Error)?) {
        lock.lock()
        defer { lock.unlock() }
        return (value, error)
    }
}
#endif

/// Whether an App Attest key record that does not parse may be replaced by a fresh one (``AppAttestKey``): only while
/// no vault made or being made on this phone can hold one of its keys. The vault manager keeps it current from its
/// account record; until it has read the record it says no.
public final class AttestStartOver: @unchecked Sendable {
    private let lock = NSLock()
    private var allowed = false
    private var recovering = false

    public init() {}

    /// The account record allows it, and this phone is not registered for a recovery.
    public var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return allowed && !recovering
    }

    /// Whether this phone is registered for a recovery (its key bound at the register).
    public func set(recovering: Bool) {
        lock.lock()
        self.recovering = recovering
        lock.unlock()
    }

    public func set(_ allowed: Bool) {
        lock.lock()
        self.allowed = allowed
        lock.unlock()
    }
}
