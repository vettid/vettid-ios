import Foundation
import VettIDData

// TEST ONLY. The end of a test phone's app process, before ``TestVaultPhone/restart()`` starts the next one.
extension TestVaultPhone {
    /// A restart as a real process death with the relay's long poll still open: the old collects are not waited for, and
    /// one of them may take what the vault sends next (with ``FakeVaultService/leasesCollected``, the relay's lease).
    public func restartLeavingCollects() async throws {
        waitsForOldCollects = false
        defer { waitsForOldCollects = true }
        try await restart()
    }

    /// The manager halted (``VaultManager/halt()``), and the process's requests gone with it: a long poll its device left
    /// waiting at the fake relay ends before the next process starts, so that it takes nothing the vault sends from then on
    /// (a halt cancels the task, not the fake's answer to it). Only the collects in flight at the halt are waited for, at
    /// most a second: another phone's later ones are not. What it found is kept (``FakeVaultService/lastRestartCollects``).
    func haltProcess() async throws {
        await manager.halt()
        let left = service.collectsInFlight
        if !waitsForOldCollects { return service.noteRestart(left: left.count, outlived: !left.isEmpty) }
        for _ in 0..<200 where !service.collectsInFlight.isDisjoint(with: left) {
            try await Task.sleep(for: .milliseconds(5))
        }
        service.noteRestart(left: left.count, outlived: !service.collectsInFlight.isDisjoint(with: left))
    }

    /// A window heartbeat's tick: 10 ms, or a pause the test releases while it holds [beat].
    static func heartbeatSleep(_ beat: TestPauses) -> LockSleep {
        { _ in
            if beat.holding { try await beat.sleep(1) } else { try await Task.sleep(for: .milliseconds(10)) }
        }
    }
}
