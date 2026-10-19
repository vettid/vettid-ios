import Foundation
@testable import VettIDVault

/// The request a change or a renew was fixed as, handed to its `onMarker` once the checks of step 1 passed
/// (VAULT-MESSAGING 0.46.0 §11.14.9); nil while none was.
final class Marked: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ChangeRequest?

    var change: ChangeRequest? { lock.withLock { value } }
    func set(_ c: ChangeRequest) { lock.withLock { value = c } }
}

// The tests' shorthand for the calls whose request is fixed after the checks: [marked] records it.
extension VaultApi {
    func pinChange(pin: String, newPin: String, password: String, newUnlockSecret: [UInt8], marked: Marked) async throws -> Bool {
        try await pinChange(pin: pin, newPin: newPin, password: password) { change in
            marked.set(change)
            return newUnlockSecret
        }
    }

    func credentialChangePassword(password: String, newPassword: String, pin: String? = nil, marked: Marked) async throws {
        try await credentialChangePassword(password: password, newPassword: newPassword, pin: pin) { marked.set($0) }
    }

    func secretRenew(pin: String, password: String, newUnlockSecret: [UInt8], marked: Marked) async throws {
        try await secretRenew(pin: pin, password: password, onMarker: { change in
            marked.set(change)
            return newUnlockSecret
        }, onAnswered: {})
    }
}
