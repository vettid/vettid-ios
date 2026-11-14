import Foundation
import os

/// A flag read from any thread: whether a call holds the app's background (``VaultManager/heldBackground``).
final class HeldFlag: Sendable {
    private let value = OSAllocatedUnfairLock(initialState: false)

    var on: Bool { value.withLock { $0 } }

    func set(_ on: Bool) { value.withLock { $0 = on } }
}
