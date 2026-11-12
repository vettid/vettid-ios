import Foundation
import Testing
@testable import VettIDAltChan
import VettIDAttestation
import VettIDCrypto
import VettIDRelay

// Calls stay on one line each.
// swiftlint:disable line_length

extension FakeEnclave {
    /// [verified] as the verifier reports it: every check passed with the entry's values (the fake checks nothing).
    func verification(_ m: ReleaseManifest) -> EnclaveVerification {
        FakeEnclave.verification { try verified(m) }
    }

    /// [body]'s enclave with every check passed, or its failure with the chain failed.
    static func verification(_ body: () throws -> VerifiedEnclave) -> EnclaveVerification {
        do {
            let e = try body()
            var r = EnclaveRecord(at: Date(), passed: AttestationCheck.allCases.count, failed: false)
            r.pcr0 = e.measurements.pcr0
            r.releaseNumber = e.release.number
            r.releaseStatus = e.release.status
            return EnclaveVerification(e, record: r)
        } catch {
            return EnclaveVerification(failure: error as? AttestationError ?? .chain, record: EnclaveRecord(at: Date(), passed: 1, failed: true))
        }
    }
}

/// TEST-ONLY: the records a flow reported, in order.
final class RecordSink: EnclaveRecords, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [EnclaveRecord] = []

    func record(_ r: EnclaveRecord) { lock.withLock { items.append(r) } }
    var all: [EnclaveRecord] { lock.withLock { items } }
    var last: EnclaveRecord? { all.last }
}

/// Which verifications the flows record (ANDROID-PLAN 0.1.124 §4 "Attestation in detail"): the enclave a request goes to,
/// a refused release list, a failed check, and a refusal after every check passed; never the update check's list, nor a
/// route that still names the release an unconfirmed move left. Mirrors the record part of vettid-android `MemberApiTest`.
@Suite struct AltChannelRecordTests {
    let vaultID = "0123456789abcdef0123456789abcdef"

    @Test func anEnrollmentAndAnUnlockRecordTheEnclaveTheyGoTo() async throws {
        let sink = RecordSink()
        let (_, p, f) = try AltChannelFlowTests().setUp(records: sink)
        _ = try await f.enroll(party: p, vaultID: vaultID, userGuid: "guid-1", pin: "246802", attester: SoftAttester())
        #expect(sink.all.count == 1)
        #expect(sink.last?.allPassed == true && sink.last?.refusal == nil && sink.last?.releaseNumber == 3)
        p.vaultID = vaultID
        _ = try await f.unlock(party: p, userGuid: "guid-1", pin: "246802", attester: SoftAttester())
        #expect(sink.all.count == 2)
        #expect(sink.last?.allPassed == true)
    }

    /// The phone's own step before the build fails: the route is not classified yet, so nothing is recorded.
    @Test func nothingIsRecordedWhenTheUnlockSecretFails() async throws {
        struct NoSecret: Error {}
        let sink = RecordSink()
        let (_, p, f) = try AltChannelFlowTests().setUp(records: sink)
        p.vaultID = vaultID
        await #expect(throws: NoSecret.self) { _ = try await f.unlock(party: p, userGuid: "guid-1", pin: "246802", attester: SoftAttester(), unlockSecretFor: { _ in throw NoSecret() }) }
        #expect(sink.all.isEmpty)
    }

    @Test func aFailedCheckIsRecordedAndNothingIsSent() async throws {
        let sink = RecordSink()
        let api = FakeAltAPI([try FakeEnclave("inst-a")])
        let p = try TestParty()
        api.party = p
        api.start()
        let client = MemberApiClient(apiBase: api.server.baseURL, manifestURL: api.server.baseURL + MemberApiClient.manifestPath, transport: HTTPTransport(session: api.server.session, sleep: { _ in }), auth: .bearer("guid-1"), sleep: { _ in })
        let f = AltChannelFlow(api: client, trust: AltTrust(nitroRoots: [], manifestKeys: [try api.manifestKey]), verifyEnclave: { _, _, _, _, _ in FakeEnclave.verification { throw AttestationError.chain } }, records: sink)
        await #expect(throws: AttestationError.chain) { _ = try await f.enroll(party: p, vaultID: vaultID, userGuid: "guid-1", pin: "246802", attester: SoftAttester()) }
        #expect(sink.all.count == 1)
        #expect(sink.last?.failed == .chain)
        #expect(!api.requests.contains { $0.path == "/api/vault/enroll" })
    }

    @Test func anOlderListIsLineOneFailedAndTheUpdateChecksListIsNotRecorded() async throws {
        let sink = RecordSink()
        let (_, p, f) = try AltChannelFlowTests().setUp(records: sink)
        p.state.manifestSerial = 9
        await #expect(throws: AltRefused.manifestOlder) { _ = try await f.enroll(party: p, vaultID: vaultID, userGuid: "guid-1", pin: "246802", attester: SoftAttester()) }
        #expect(sink.all.count == 1)
        #expect(sink.last?.failed == .manifest && sink.last?.pcr0 == nil)
        // The update check (and any other caller that does not ask): nothing recorded.
        await #expect(throws: AltRefused.manifestOlder) { _ = try await f.manifest(seen: 9) }
        _ = try await f.manifest(seen: 0)
        #expect(sink.all.count == 1)
    }

    @Test func anotherInstanceIsARefusalAfterEveryCheckPassed() async throws {
        let sink = RecordSink()
        let (api, p, _) = try AltChannelFlowTests().setUp()
        let client = MemberApiClient(apiBase: api.server.baseURL, manifestURL: api.server.baseURL + MemberApiClient.manifestPath, transport: HTTPTransport(session: api.server.session, sleep: { _ in }), auth: .bearer("guid-1"), sleep: { _ in })
        let other = try FakeEnclave("inst-z")
        let f = AltChannelFlow(api: client, trust: AltTrust(nitroRoots: [], manifestKeys: [try api.manifestKey]), verifyEnclave: { _, _, m, _, _ in other.verification(m) }, records: sink)
        await #expect(throws: AltChannelFailure.self) { _ = try await f.enroll(party: p, vaultID: vaultID, userGuid: "guid-1", pin: "246802", attester: SoftAttester()) }
        #expect(sink.all.count == 1)
        #expect(sink.last?.allPassed == true && sink.last?.refusal == .otherInstance)
    }

    @Test func aTimeScaleThisBuildRefusesIsARefusalAfterEveryCheckPassed() async throws {
        let sink = RecordSink()
        let (_, p, f) = try AltChannelFlowTests().setUp([try FakeEnclave("inst-a", timeScale: 24)], records: sink)
        await #expect(throws: TimeScaleRefused(scale: 24)) { _ = try await f.preflight(p.state) }
        #expect(sink.all.count == 1)
        #expect(sink.last?.allPassed == true && sink.last?.refusal == .timeScale)
    }

    @Test func anOlderReleaseIsARefusalAfterEveryCheckPassed() async throws {
        let sink = RecordSink()
        let (_, p, f) = try AltChannelFlowTests().setUp(records: sink)
        p.vaultID = vaultID
        p.state.release = String(repeating: "b4", count: 48)
        p.state.releaseNumber = 4
        await #expect(throws: AltRefused.rollbackRelease) { _ = try await f.unlock(party: p, userGuid: "guid-1", pin: "246802", attester: SoftAttester()) }
        #expect(sink.all.count == 1)
        #expect(sink.last?.allPassed == true && sink.last?.refusal == .olderRelease)
        #expect(try await f.preflight(p.state).rollback)
        #expect(sink.all.count == 2)
        #expect(sink.last?.refusal == .olderRelease)
    }

    /// A route that still names the release an unconfirmed move left: nothing is sealed to it, and nothing recorded.
    @Test func aRouteToTheReleaseAMoveLeftIsNotRecorded() async throws {
        let sink = RecordSink()
        let (_, p, f) = try AltChannelFlowTests().setUp(records: sink)
        p.vaultID = vaultID
        // Moved from release 3 (the fake enclave's) to 4, not confirmed yet.
        p.state.release = String(repeating: "b4", count: 48)
        p.state.releaseNumber = 4
        p.state.previousRelease = FakeEnclave.pcr0
        p.state.previousReleaseNumber = 3
        await #expect(throws: AltRefused.notYetRouted) { _ = try await f.unlock(party: p, userGuid: "guid-1", pin: "246802", attester: SoftAttester()) }
        #expect(try await f.preflight(p.state).rollback)
        #expect(sink.all.isEmpty)
        // The way back, asked for that release by its PCR0, is recorded.
        _ = try await f.preflight(p.state, release: FakeEnclave.pcr0)
        #expect(sink.all.count == 1)
        #expect(sink.last?.refusal == nil)
    }
}

// swiftlint:enable line_length
