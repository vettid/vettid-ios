import Foundation
import Testing
import VettIDAttestation
@testable import VettIDData
import VettIDDataTesting
import VettIDKeys

/// The last enclave verification's record on the phone (IOS-PLAN §6.9, ANDROID-PLAN 0.1.124 §5 "What the phone keeps"): in
/// its encrypted file, read back only as a run of checks, replaced by the next verification and erased by the wipe, and
/// nothing written by a verification that began before a wipe. Mirrors vettid-android `EnclaveRecordStoreTest`.
@MainActor
@Suite(.serialized) struct EnclaveRecordStoreTests {
    let service: FakeVaultService
    let phone: TestVaultPhone
    let pin = "402817"

    init() throws {
        service = try FakeVaultService()
        phone = try TestVaultPhone(service: service)
    }

    var m: VaultManager { phone.manager }
    var url: URL { phone.directory.appendingPathComponent(VaultFiles.enclaveRecord) }
    var fileExists: Bool { FileManager.default.fileExists(atPath: url.path) }

    func file() -> EncryptedFileStore {
        EncryptedFileStore(url: url, purpose: VaultFiles.enclaveRecord, keys: phone.fileKeys, protectedData: phone.protectedData)
    }

    func sample() -> EnclaveRecord {
        var r = EnclaveRecord(at: Date(timeIntervalSince1970: 1_790_000_000.123), passed: 9, failed: false)
        r.manifestKeyID = "0123456789abcdef"
        r.manifestSerial = 7
        r.pcr0 = String(repeating: "a3", count: 48)
        r.pcr1 = String(repeating: "11", count: 48)
        r.pcr2 = String(repeating: "22", count: 48)
        r.attestedAt = Date(timeIntervalSince1970: 1_789_999_000.5)
        r.notAfter = Date(timeIntervalSince1970: 1_790_080_000)
        r.releaseNumber = 3
        r.releaseStatus = .deprecated
        r.releaseEndsAt = Date(timeIntervalSince1970: 1_791_000_000)
        r.refusal = .notActive
        return r
    }

    @Test func theStoredFormReadsBackAsItWasRecorded() throws {
        let r = sample()
        #expect(EnclaveRecordStore.decode(try #require(EnclaveRecordStore.encode(r))) == r)
        let failed = EnclaveRecord(at: Date(timeIntervalSince1970: 1_790_000_000), passed: 4, failed: true)
        #expect(EnclaveRecordStore.decode(try #require(EnclaveRecordStore.encode(failed))) == failed)
    }

    /// A stored record that does not read as a run, or names what this build does not know, is no record.
    @Test func aStoredRecordThatIsNotARunIsNoRecord() throws {
        func stored(_ change: (inout StoredEnclaveRecord) -> Void) throws -> [UInt8] {
            var s = try JSONDecoder().decode(StoredEnclaveRecord.self, from: Data(try #require(EnclaveRecordStore.encode(sample()))))
            change(&s)
            return Array(try JSONEncoder().encode(s))
        }
        let base = EnclaveRecord(at: Date(), passed: 3, failed: false)
        var gap = try JSONDecoder().decode(StoredEnclaveRecord.self, from: Data(try #require(EnclaveRecordStore.encode(base))))
        gap.results[AttestationCheck.match.rawValue] = CheckResult.passed.rawValue
        #expect(EnclaveRecordStore.decode(Array(try JSONEncoder().encode(gap))) == nil)
        #expect(EnclaveRecordStore.decode(try stored { $0.results["transparency"] = "passed" }) == nil)
        #expect(EnclaveRecordStore.decode(try stored { $0.results[AttestationCheck.recent.rawValue] = "maybe" }) == nil)
        #expect(EnclaveRecordStore.decode(try stored { $0.results[AttestationCheck.recent.rawValue] = nil }) == nil)
        #expect(EnclaveRecordStore.decode(try stored { $0.releaseStatus = "paused" }) == nil)
        #expect(EnclaveRecordStore.decode(try stored { $0.refusal = "unknown" }) == nil)
        #expect(EnclaveRecordStore.decode(Array("not json".utf8)) == nil)
        // Values of a step the run never reached are dropped: a refused list shows only the environment.
        let listFailed = try stored { s in
            let states = AttestationCheck.allCases.map { ($0.rawValue, $0 == .manifest ? "failed" : "notRun") }
            s.results = Dictionary(uniqueKeysWithValues: states)
        }
        let dropped = try #require(EnclaveRecordStore.decode(listFailed))
        #expect(dropped.pcr0 == nil && dropped.notAfter == nil && dropped.manifestKeyID == nil)
        #expect(dropped.releaseNumber == nil && dropped.releaseStatus == nil)
    }

    @Test func aRecordIsKeptInItsFileAndReadAtTheStart() throws {
        let store = EnclaveRecordStore(file: file())
        store.sink().record(sample())
        #expect(store.record == sample())
        #expect(fileExists)
        let again = EnclaveRecordStore(file: file())
        #expect(again.needsLoad)
        again.load()
        #expect(again.record == sample())
        #expect(!again.needsLoad)
    }

    /// A file that does not decrypt or read is no record; a record made before the read wins over what the file held.
    @Test func anUnreadableFileIsNoRecordAndALaterRecordWins() throws {
        try file().save(Array("{}".utf8))
        let store = EnclaveRecordStore(file: file())
        store.load()
        #expect(store.record == nil)
        try file().save(try #require(EnclaveRecordStore.encode(sample())))
        let early = EnclaveRecordStore(file: file())
        let newer = EnclaveRecord.manifestFailed(at: Date())
        early.sink().record(newer)
        early.load()
        #expect(early.record == newer)
    }

    /// The wipe: the record goes from memory and disk, and a sink made before it writes nothing after it.
    @Test func aSinkMadeBeforeTheWipeWritesNothingAfterIt() throws {
        let store = EnclaveRecordStore(file: file())
        let before = store.sink()
        before.record(sample())
        store.forget()
        #expect(store.record == nil && !fileExists)
        before.record(sample())
        #expect(store.record == nil && !fileExists)
        let after = store.sink()
        after.record(sample())
        #expect(store.record == sample())
    }

    /// End to end: the enrollment's verification is the manager's record, kept across a restart, erased by the wipe.
    @Test func theManagerKeepsTheEnrollmentsVerificationUntilTheWipe() async throws {
        defer { phone.close() }
        #expect(m.enclaveRecord == nil)
        _ = try await m.redeemSetupCode(.secret(service.secret))
        try await m.enroll(pin: pin) { _ in }
        #expect(await eventually { m.enclaveRecord?.allPassed == true })
        #expect(m.enclaveRecord?.releaseNumber == 3)
        #expect(fileExists)
        let kept = m.enclaveRecord
        try await phone.restart()
        try await m.refresh()
        // Read back from the file, whose times are in milliseconds.
        #expect(await eventually { m.enclaveRecord?.releaseNumber == 3 })
        #expect(m.enclaveRecord?.allPassed == true)
        #expect(abs((m.enclaveRecord?.at ?? .distantPast).timeIntervalSince(kept?.at ?? .distantFuture)) < 0.001)
        try await m.createCredential(password: "correct horse battery", backup: true, pin: pin) { _ in }
        try await m.finishSetup()
        try await m.eraseThisPhone()
        #expect(m.phase == .signedOut)
        #expect(await eventually { m.enclaveRecord == nil })
        #expect(!fileExists)
    }
}
