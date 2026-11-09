#if DEBUG
import Foundation

/// TEST ONLY. A switch the device state's writes consult (``TestVaultPhone/deviceSaveFails``).
public final class SaveSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    public init() {}

    public var on: Bool {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
#endif
