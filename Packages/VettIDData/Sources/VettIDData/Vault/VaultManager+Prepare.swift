import Foundation

// The start's reads of the encrypted files (IOS-PLAN §6.1).
extension VaultManager {
    /// What the start read off the main actor (``preparedOffMain()``).
    struct LocalFileReads: Sendable {
        var record: FileRead?
        var canary: FileRead?
    }

    /// ``prepared(reads:)`` with the first-run cleanup and the reads of the account record and the canary manifest done off
    /// the main actor: the keychain lookup of the file key and the decryption of each file no longer hold up the first frame.
    /// The order of IOS-PLAN §6.1 stays: the cleanup first, a pending wipe finished before any file is read, and nothing is
    /// read while the record is shut. Anything that cannot be read ahead is left to ``prepared(reads:)``, which then reads (and
    /// fails) as it always did; the owner check's file and the lock's are still read there (chosen; not in the spec).
    func preparedOffMain() async throws {
        let c = config
        let cleaned = await Task.detached { (try? c.prepare()) != nil }.value
        guard cleaned else { return try prepared() }
        resumePendingWipe()
        guard !record.closed else { return try prepared() }
        let recordFile = record.needsLoad ? record.file : nil
        let canaryStore = canary.needsLoad ? canary.store : nil
        let recordGeneration = record.generation, canaryWipes = canary.wipes
        var reads = await Task.detached {
            LocalFileReads(
                record: recordFile.map { f in FileRead { try f.load() } },
                canary: canaryStore.map { s in FileRead { try s.load() } }
            )
        }.value
        #if DEBUG
        await record.afterOffMainRead?()
        #endif
        // A reset of the record or a wipe meanwhile (the files were replaced or erased): what was read is stale and dropped.
        if record.generation != recordGeneration { reads.record = nil }
        if canary.wipes != canaryWipes || record.generation != recordGeneration { reads.canary = nil }
        try prepared(reads: reads)
    }
}
