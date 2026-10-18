import Foundation
import Observation
import VettIDData
import VettIDKeys
import VettIDDataTesting
@testable import VettIDSettings

/// The app lock as Settings sees it, in memory: [enableAnswer] is how the next prompt ends (or [enableError] the key that
/// cannot be made); every call is recorded.
@MainActor
@Observable
final class FakeAppLock: AppLockSettings {
    var state: AppLockState = .disabled
    var invalidated = false
    var method: AppLockMethod = .biometrics
    var timeout: AppLockTimeout = .standard
    var enableAnswer = true
    var enableError: (any Error)?
    /// What disable, chooseMethod and setTimeout throw (the settings file cannot be written).
    var writeError: (any Error)?
    /// Set: the prompt waits for it, and a prompt cancelled meanwhile fails as iOS's does.
    var promptGate: TestDeferred<Void>?
    var calls: [String] = []

    func enable(_ m: AppLockMethod, reason: String) async throws -> Bool {
        calls.append("enable(\(m.rawValue), \(reason))")
        if let enableError { throw enableError }
        if let promptGate {
            try await promptGate.value()
            try Task.checkCancellation()
        }
        guard enableAnswer else {
            state = .disabled
            return false
        }
        method = m
        state = .unlocked
        return true
    }

    func disable() throws {
        if let writeError { throw writeError }
        calls.append("disable")
        state = .disabled
    }

    func chooseMethod(_ m: AppLockMethod) throws {
        if let writeError { throw writeError }
        calls.append("chooseMethod(\(m.rawValue))")
        method = m
    }

    func setTimeout(_ t: AppLockTimeout) throws {
        if let writeError { throw writeError }
        calls.append("setTimeout(\(t.rawValue))")
        timeout = t
    }

    func acknowledgeInvalidated() { invalidated = false }
}
