#if DEBUG
import Foundation
import VettIDData
import VettIDKeys
import VettIDKeysTesting

/// TEST ONLY. What a test phone's wipe erases: its data directory and its software keys. [failingErase] makes the next
/// erases leave a file behind (a wipe that does not finish).
public final class TestWipeTargets: WipeTargets, @unchecked Sendable {
    public let directory: URL
    private let appKeys: SoftwareAppKeyStore
    private let seedWrap: SoftwareSeedWrapKeySource
    private let wrapped: InMemoryWrappedKeyStore
    private let phoneKeys: SoftwarePhoneSecretSource
    private let fileKeys: InMemoryFileKeyHolder
    private let lock = NSLock()
    private var stuck = false
    private var notificationsCancelled = 0

    init(
        directory: URL, appKeys: SoftwareAppKeyStore, seedWrap: SoftwareSeedWrapKeySource, wrapped: InMemoryWrappedKeyStore,
        phoneKeys: SoftwarePhoneSecretSource, fileKeys: InMemoryFileKeyHolder
    ) {
        self.directory = directory
        self.appKeys = appKeys
        self.seedWrap = seedWrap
        self.wrapped = wrapped
        self.phoneKeys = phoneKeys
        self.fileKeys = fileKeys
    }

    /// A key that cannot be deleted for now (the next erases fail until it is set back).
    public var keyStuck: Bool {
        get { lock.withLock { stuck } }
        set { lock.withLock { stuck = newValue } }
    }

    public var cancelledNotifications: Int { lock.withLock { notificationsCancelled } }

    public var marker: URL { directory.appendingPathComponent(LocalWipe.marker) }
    public var dirs: [URL] { [directory] }
    public var kept: [URL] { [] }
    public var erasers: [any KeyEraser] { [StuckEraser(targets: self), appKeys, seedWrap, wrapped, phoneKeys, fileKeys] }

    public func keysLeft() throws -> Bool {
        keyStuck || appKeys.current != nil || seedWrap.exists || !wrapped.all.isEmpty || phoneKeys.count > 0 || fileKeys.holdsKey
    }

    public func cancelNotifications() { lock.withLock { notificationsCancelled += 1 } }

    private struct StuckEraser: KeyEraser {
        let targets: TestWipeTargets

        func deleteAll() throws {
            if targets.keyStuck { throw KeysError.unavailable("test key") }
        }
    }
}
#endif
