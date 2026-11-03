import Foundation
@testable import VettIDData
import VettIDKeys
import VettIDKeysTesting

/// The software app-lock key whose open waits (the prompt on screen) until a test releases it.
final class HeldAppLockKeys: AppLockKeys, @unchecked Sendable {
    let inner = SoftwareAppLockKeys()
    private let lock = NSLock()
    private var holdValue = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var openCount = 0

    /// How many prompts were opened.
    var opens: Int { lock.withLock { openCount } }

    var hold: Bool {
        get { lock.withLock { holdValue } }
        set { lock.withLock { holdValue = newValue } }
    }

    /// An open is waiting for ``release()``.
    var waiting: Bool { lock.withLock { continuation != nil } }

    func release() {
        let c = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { continuation = nil }
            return continuation
        }
        c?.resume()
    }

    func create(_ method: AppLockMethod) throws { try inner.create(method) }
    func exists() throws -> Bool { try inner.exists() }
    func seal(_ plaintext: [UInt8]) throws -> [UInt8] { try inner.seal(plaintext) }

    func open(_ sealed: [UInt8], reason: String) async throws -> [UInt8] {
        lock.withLock { openCount += 1 }
        if hold { await withCheckedContinuation { c in lock.withLock { continuation = c } } }
        return try await inner.open(sealed, reason: reason)
    }

    func delete() throws { try inner.delete() }
}
