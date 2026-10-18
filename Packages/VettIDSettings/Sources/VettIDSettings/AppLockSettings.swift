import Foundation
import Observation
import VettIDData
import VettIDKeys

/// What Settings changes of the app lock (ANDROID-PLAN D6; IOS-PLAN ID17): ``AppLock``, or a fake in the tests.
@MainActor
public protocol AppLockSettings: AnyObject, Observable {
    var state: AppLockState { get }
    /// The key no longer opened and the lock turned itself off (Face ID or Touch ID changed).
    var invalidated: Bool { get }
    var method: AppLockMethod { get }
    var timeout: AppLockTimeout { get }

    /// Turns the lock on with [m], or changes the method of a lock that is on: a fresh key and one prompt. False when the
    /// prompt was cancelled; throws when the key cannot be made.
    func enable(_ m: AppLockMethod, reason: String) async throws -> Bool
    func disable() throws
    func chooseMethod(_ m: AppLockMethod) throws
    func setTimeout(_ t: AppLockTimeout) throws
    func acknowledgeInvalidated()
}

extension AppLock: AppLockSettings {}

public extension AppLockState {
    /// The lock is on (whether or not the member has authenticated since).
    var isOn: Bool { self == .locked || self == .unlocked }
}
