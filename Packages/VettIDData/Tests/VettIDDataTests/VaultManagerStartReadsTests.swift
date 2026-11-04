import Foundation
import Testing
@testable import VettIDData
import VettIDDataTesting

/// The start's reads of the encrypted files, made off the main actor (IOS-PLAN §6.1), and what a change meanwhile does to them.
@MainActor
@Suite(.serialized) struct VaultManagerStartReadsTests {
    func account(_ guid: String) throws -> [UInt8] {
        var a = LocalAccount()
        a.userGuid = guid
        return Array(try JSONEncoder().encode(a))
    }

    #if DEBUG
    /// The record is read ahead; a read that a change of the record overtook (the generation moved while the read waited, as at
    /// a lock or a wipe) is not taken in: the file is read again, and its newer content is the one used.
    @Test func aReadMadeAheadThatTheRecordOvertookIsDropped() async throws {
        let phone = try TestVaultPhone(service: try FakeVaultService())
        defer { phone.close() }
        let m = phone.manager
        try m.record.file.save(try account("old"))
        let reached = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        m.record.afterOffMainRead = {
            reached.continuation.yield()
            for await _ in release.stream { return }
        }
        let start = Task { try await m.preparedOffMain() }
        for await _ in reached.stream { break } // the file was read; the result waits
        try m.record.file.save(try account("new"))
        m.record.bumpGeneration()
        release.continuation.yield()
        try await start.value
        #expect(m.record.value.userGuid == "new", "the stale bytes were not taken in")
    }
    #endif

    /// Without a change meanwhile, the bytes read ahead are the ones used.
    @Test func aReadMadeAheadIsUsedWhenNothingMoved() async throws {
        let phone = try TestVaultPhone(service: try FakeVaultService())
        defer { phone.close() }
        let m = phone.manager
        try m.record.file.save(try account("kept"))
        try await m.preparedOffMain()
        #expect(m.record.value.userGuid == "kept")
    }
}
