import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Whether the iPhone's protected data is available now (`UIApplication.isProtectedDataAvailable`), readable from any
/// thread. IOS-PLAN §6.3 decides "missing" with it: true before the lookup, "no such item" from the lookup itself, and
/// true after it.
public protocol ProtectedData: Sendable {
    var isAvailable: Bool { get }
}

/// A flag set from outside: the app's ``ProtectedDataMonitor`` on the iPhone, a test elsewhere. Starts unavailable
/// unless told otherwise, so that nothing is ever judged missing before the app has read the real state.
public final class ProtectedDataFlag: ProtectedData, @unchecked Sendable {
    private let lock = NSLock()
    private var available: Bool

    public init(available: Bool = false) {
        self.available = available
    }

    public var isAvailable: Bool { lock.withLock { available } }

    public func set(_ available: Bool) {
        lock.withLock { self.available = available }
    }
}

#if canImport(UIKit)
/// The iPhone's protected-data state for nonisolated code: read once on the main actor, then kept current by
/// `protectedDataWillBecomeUnavailableNotification` (sent before the files lock, so the flag errs towards "locked")
/// and `protectedDataDidBecomeAvailableNotification`.
public final class ProtectedDataMonitor: ProtectedData, @unchecked Sendable {
    private let flag = ProtectedDataFlag()
    private let lock = NSLock()
    private var observers: [NSObjectProtocol] = []

    public init() {}

    public var isAvailable: Bool { flag.isAvailable }

    /// Reads the current state and starts following it. Call once, at launch.
    @MainActor
    public func start(_ application: UIApplication = .shared) {
        flag.set(application.isProtectedDataAvailable)
        let center = NotificationCenter.default
        let flag = flag
        let added = [
            center.addObserver(forName: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil, queue: nil) { _ in
                flag.set(false)
            },
            center.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: nil) { _ in
                flag.set(true)
            },
        ]
        lock.withLock { observers += added }
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }
}
#endif

/// The answer of a lookup for one item (a keychain item, a file, a key), as IOS-PLAN §6.3 classifies it.
public enum ItemLookup<Value> {
    case found(Value)
    /// Genuinely absent: see ``ProtectedLookup``.
    case missing
    /// Refused for now (locked, or any other error): keep everything and retry.
    case unavailable

    /// The value, or the failure the caller reports for [what].
    public func get(_ what: String) throws -> Value {
        switch self {
        case .found(let v): return v
        case .missing: throw KeysError.missing(what)
        case .unavailable: throw KeysError.unavailable(what)
        }
    }

    public func map<T>(_ f: (Value) throws -> T) rethrows -> ItemLookup<T> {
        switch self {
        case .found(let v): .found(try f(v))
        case .missing: .missing
        case .unavailable: .unavailable
        }
    }
}

extension ItemLookup: Sendable where Value: Sendable {}
extension ItemLookup: Equatable where Value: Equatable {}

/// What a lookup itself answered, before the protected-data rule is applied.
public enum RawLookup<Value> {
    case found(Value)
    /// `errSecItemNotFound` (keychain), `ENOENT` / `NSFileReadNoSuchFileError` (files), "no such key".
    case noSuchItem
    /// Any other answer: `errSecInteractionNotAllowed`, a file-protection refusal, an I/O error.
    case failed
}

/// The rule of IOS-PLAN §6.3: an item is **missing** only when protected data is available before the lookup, the
/// lookup itself answers "no such item", and protected data is still available after it. Any other error, or protected
/// data that went away in between, is the locked case. Never replaced by a separate "is storage readable" probe.
public enum ProtectedLookup {
    public static func run<Value>(_ protectedData: ProtectedData, _ lookup: () -> RawLookup<Value>) -> ItemLookup<Value> {
        let before = protectedData.isAvailable
        let answer = lookup()
        let after = protectedData.isAvailable
        switch answer {
        case .found(let v): return .found(v)
        case .noSuchItem: return before && after ? .missing : .unavailable
        case .failed: return .unavailable
        }
    }
}
