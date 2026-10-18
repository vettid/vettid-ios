import Foundation
import Testing
@testable import VettIDKeys
import VettIDKeysTesting

/// The encrypted file store (IOS-PLAN §6.1) with an in-memory key: vettid-android `KeystoreFileStoreTest`, and the
/// iPhone's rules: atomic replace, backup exclusion, and "no such file" told apart from everything else (§6.3).
@Suite struct EncryptedFileStoreTests {
    let keys = InMemoryFileKeyHolder()
    let available = ProtectedDataFlag(available: true)

    func store(_ url: URL, _ purpose: String = "a", protectedData: (any ProtectedData)? = nil) -> EncryptedFileStore {
        EncryptedFileStore(url: url, purpose: purpose, keys: keys, protectedData: protectedData ?? available)
    }

    @Test func roundTripTamperAndPurpose() throws {
        let file = try scratchDirectory().appendingPathComponent("data/store-test.bin")
        let s = store(file)
        #expect(try s.load() == nil)
        try s.save(Array("secret state".utf8))
        #expect(try s.load() == Array("secret state".utf8))
        try s.save(Array("newer".utf8))
        #expect(try s.load() == Array("newer".utf8))
        // Another purpose (AAD) cannot read it; a flipped byte fails.
        #expect(throws: KeysError.corrupt("store-test.bin")) { try store(file, "b").load() }
        var b = try Array(Data(contentsOf: file))
        b[b.count - 1] ^= 1
        try Data(b).write(to: file)
        #expect(throws: KeysError.corrupt("store-test.bin")) { try s.load() }
        try s.clear()
        #expect(try s.load() == nil)
        try s.clear()
    }

    /// Android's format: `0x01 || iv (12) || ciphertext || tag (16)`, nothing else in the file.
    @Test func theFileFormat() throws {
        let file = try scratchDirectory().appendingPathComponent("f.bin")
        try store(file).save([1, 2, 3])
        let raw = try Array(Data(contentsOf: file))
        #expect(raw.count == 1 + 12 + 3 + 16)
        #expect(raw[0] == 0x01)
        #expect(!raw.contains([1, 2, 3]))
    }

    /// A write replaces the file atomically: no temporary file is left, and the directory is excluded from backups.
    @Test func writesReplaceAtomicallyInABackupExcludedDirectory() throws {
        let dir = try scratchDirectory().appendingPathComponent("VettID", isDirectory: true)
        let file = dir.appendingPathComponent("records")
        let s = store(file)
        for i in 0 ..< 5 { try s.save([UInt8(i)]) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["records"])
        #expect(AppDirectories.isExcludedFromBackup(dir))
        #expect(try s.load() == [4])
    }

    /// "Missing" only when protected data is available before and after, and the lookup answers "no such file".
    @Test func missingIsDecidedOnlyWithProtectedData() throws {
        let file = try scratchDirectory().appendingPathComponent("absent")
        #expect(try store(file).lookup() == .missing)
        // Locked before the lookup: not missing.
        #expect(try store(file, protectedData: ProtectedDataFlag(available: false)).lookup() == .unavailable)
        #expect(throws: KeysError.unavailable("absent")) { try store(file, protectedData: ProtectedDataFlag()).load() }
        // Protected data that goes away during the lookup: not missing.
        #expect(try store(file, protectedData: FadingProtectedData(availableReads: 1)).lookup() == .unavailable)
    }

    /// A file that exists but cannot be read (as on a locked iPhone, a file-protection refusal) is not missing.
    @Test func anUnreadableFileIsNotMissing() throws {
        let file = try scratchDirectory().appendingPathComponent("locked")
        let s = store(file)
        try s.save([9])
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        #expect(try s.lookup() == .unavailable)
        #expect(throws: KeysError.unavailable("locked")) { try s.load() }
    }

    /// A file whose format byte this app does not know is its own error, never "damaged" and never "missing".
    @Test func anUnknownFormatByteIsItsOwnError() throws {
        let file = try scratchDirectory().appendingPathComponent("newer")
        try store(file).save([1])
        var raw = try Array(Data(contentsOf: file))
        raw[0] = 0x07
        try Data(raw).write(to: file)
        #expect(throws: KeysError.unknownFormat("newer")) { try store(file).load() }
    }

    /// Two stores over the same file share one process-wide lock: read-modify-writes from both never lose an update.
    @Test func twoStoresOverOneFileShareALock() throws {
        let file = try scratchDirectory().appendingPathComponent("counter")
        let a = store(file)
        let b = store(file)
        try a.save([0])
        DispatchQueue.concurrentPerform(iterations: 50) { i in
            let s = i.isMultiple(of: 2) ? a : b
            s.exclusive {
                let n = (try? s.load())??.first ?? 0
                try? s.save([n &+ 1])
            }
        }
        #expect(try a.load() == [50])
    }

    /// A file key that cannot be read now refuses for now; it never reads as a missing file or a damaged one.
    @Test func aLockedFileKeyIsRefusedForNow() throws {
        let file = try scratchDirectory().appendingPathComponent("k")
        let s = store(file)
        try s.save([1])
        keys.state.behaviour = .locked
        #expect(throws: KeysError.unavailable("file key")) { try s.load() }
        #expect(throws: KeysError.unavailable("file key")) { try s.save([2]) }
        keys.state.behaviour = .normal
        #expect(try s.load() == [1])
    }
}

@Suite struct ProtectedLookupTests {
    @Test func theRuleOfTheThreeAnswers() {
        let on = ProtectedDataFlag(available: true)
        let off = ProtectedDataFlag()
        #expect(ProtectedLookup.run(on) { RawLookup.found(1) } == .found(1))
        #expect(ProtectedLookup.run(off) { RawLookup.found(1) } == .found(1))
        #expect(ProtectedLookup.run(on) { RawLookup<Int>.noSuchItem } == .missing)
        #expect(ProtectedLookup.run(off) { RawLookup<Int>.noSuchItem } == .unavailable)
        #expect(ProtectedLookup.run(on) { RawLookup<Int>.failed } == .unavailable)
        // Available before the lookup only, or after it only.
        #expect(ProtectedLookup.run(FadingProtectedData(availableReads: 1)) { RawLookup<Int>.noSuchItem } == .unavailable)
        let late = ProtectedDataFlag()
        #expect(ProtectedLookup.run(late) { () -> RawLookup<Int> in
            late.set(true)
            return .noSuchItem
        } == .unavailable)
    }

    @Test func theFlagStartsUnavailable() {
        let f = ProtectedDataFlag()
        #expect(!f.isAvailable)
        f.set(true)
        #expect(f.isAvailable)
    }
}
