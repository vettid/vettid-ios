import Foundation
import Testing
@testable import VettIDData
import VettIDKeys
import VettIDKeysTesting

@MainActor
@Suite struct AppLockStartTests {
    let store = MemoryAppLockStore()
    let keys = SoftwareAppLockKeys()

    func lock() -> AppLock { AppLock(store: store, keys: keys, notifications: NotificationCenter()) }

    /// The start made off the main actor reads nothing on the main thread and ends as the start on it does: off by default;
    /// locked again after a restart with the lock on; still pending, and read later, while the iPhone has not been unlocked
    /// since it started.
    @Test func theStartOffTheMainActorEndsAsTheStartOnIt() async throws {
        let off = lock()
        await off.startOffMain()
        #expect(off.state == .disabled && store.readsOnMain == 0)
        #expect(try await off.enable(.biometrics, reason: "Unlock VettID"))
        let again = lock()
        store.unavailable = true
        await again.startOffMain()
        #expect(again.state == .pending, "not readable yet")
        store.unavailable = false
        await again.startOffMain()
        #expect(again.state == .locked && store.readsOnMain == 0)
        store.corrupt = true
        let damaged = lock()
        await damaged.startOffMain()
        #expect(damaged.state == .disabled && damaged.invalidated)
    }
}
