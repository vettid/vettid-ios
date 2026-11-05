import Foundation

// TEST ONLY. The end of a test phone's app process, before ``TestVaultPhone/restart()`` starts the next one.
extension TestVaultPhone {
    /// The manager halted (``VaultManager/halt()``), and the process's requests gone with it: a long poll its device left
    /// waiting at the fake relay ends before the next process starts, so that it takes nothing the vault sends from then on
    /// (a halt cancels the task, not the fake's answer to it). Only the collects in flight at the halt are waited for, at
    /// most a second: another phone's later ones are not.
    func haltProcess() async throws {
        await manager.halt()
        let left = service.collectsInFlight
        for _ in 0..<200 where !service.collectsInFlight.isDisjoint(with: left) {
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
