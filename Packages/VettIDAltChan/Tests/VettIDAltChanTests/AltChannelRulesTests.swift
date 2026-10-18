import Foundation
import Testing
@testable import VettIDAltChan
import VettIDAttestation
import VettIDCrypto
import VettIDRelay
import VettIDTesting

// Fixtures stay on one line each.
// swiftlint:disable line_length

/// An attester with a chain (an Android key), to check when the chain travels.
struct ChainAttester: Attester {
    func attest(_ challenge: [UInt8]) throws -> DeviceAttest { try DeviceAttest.androidChain([[1, 2, 3]]) }
    func assert(_ message: [UInt8]) throws -> DeviceAssertion { try DeviceAssertion.androidSignature([4, 5, 6]) }
    func chain() -> [[UInt8]]? { [[7, 7, 7], [8, 8]] }
}

/// The retry, secret and chain rules of the alternate channel (§11.7.1, §11.9, §11.10, §11.14.1). Mirrors the matching
/// cases of vettid-android `AltRequestsTest`, `CanaryManifestTest` and `MemberApiTest`.
@Suite struct AltChannelRulesTests {
    func setUp(_ enclaves: [FakeEnclave]? = nil) throws -> (FakeAltAPI, TestParty, AltChannelFlow) { // swiftlint:disable:this large_tuple
        try AltChannelFlowTests().setUp(enclaves)
    }

    func enroll(_ f: AltChannelFlow, _ p: TestParty) async throws -> EnrollOutcome {
        try await f.enroll(party: p, vaultID: "0123456789abcdef0123456789abcdef", userGuid: "guid-1", pin: "246802", attester: SoftAttester())
    }

    /// An expired slot and `etk_unknown` re-seal with a fresh descriptor (§11.9), at most 4 attempts in all.
    @Test func expiredSlotsAndAnUnknownETKAreResealedFourTimesAtMost() async throws {
        let (api, p, f) = try setUp()
        api.slotOverrides = ["expired", "etk"]
        #expect(try await enroll(f, p).ok)
        #expect(api.requests.filter { $0.path == "/api/vault/enroll" }.count == 3)
        api.slotOverrides = ["expired", "expired", "etk", "expired"]
        await #expect(throws: AltChannelFailure.self) { _ = try await enroll(f, p) }
        #expect(api.requests.filter { $0.path == "/api/vault/enroll" }.count == 7)
    }

    /// The sealed result decides whatever clear code the host adds beside it (`recovery_registered`, §11.11.3).
    @Test func theSealedResultDecidesWhateverTheSlotsCode() async throws {
        let (api, p, f) = try setUp()
        api.slotCode = Slot.recoveryRegistered
        #expect(try await enroll(f, p).ok)
    }

    /// (Release R) With a callback, its nil means the earlier shape: no unlock secret, whatever the options carried.
    /// Without one, the caller's secret goes; the caller's copy is left as it was.
    @Test func theUnlockSecretGoesOnlyWhereTheShapeAsksForIt() async throws {
        let (api, p, f) = try setUp()
        p.vaultID = "0123456789abcdef0123456789abcdef"
        let mine = [UInt8](repeating: 0x42, count: 32)
        _ = try await f.unlock(party: p, userGuid: "guid-1", pin: "246802", attester: SoftAttester(), options: UnlockOptions(unlockSecret: mine), unlockSecretFor: { _ in nil })
        _ = try await f.unlock(party: p, userGuid: "guid-1", pin: "246802", attester: SoftAttester(), options: UnlockOptions(unlockSecret: mine))
        let bodies = try api.openedBodies("/api/vault/unlock")
        #expect(bodies.count == 2)
        #expect(!bodies[0].has("unlock_secret"))
        #expect(try bodies[1].base64("unlock_secret") == mine)
        #expect(mine == [UInt8](repeating: 0x42, count: 32))
    }

    /// A canary manifest is used only while nothing is published (404) or it is newer; a server error is not "nothing
    /// published".
    @Test func onlyA404FallsBackToTheCanary() async throws {
        final class Canary: CanaryManifestSource, @unchecked Sendable {
            let lock = NSLock()
            var doc: [UInt8]?
            var retired = 0
            init(_ d: [UInt8]) { doc = d }
            func served() -> [UInt8]? { lock.withLock { doc } }
            func retire(_ served: [UInt8]) { lock.withLock { retired += 1; doc = nil } }
        }
        let (api, _, _) = try setUp()
        let canary = Canary(try api.served())
        let client = MemberApiClient(apiBase: api.server.baseURL, manifestURL: api.server.baseURL + MemberApiClient.manifestPath, transport: HTTPTransport(session: api.server.session, sleep: { _ in }), auth: .bearer("guid-1"), sleep: { _ in })
        let f = AltChannelFlow(api: client, trust: AltTrust(nitroRoots: [], manifestKeys: [try api.manifestKey]), canary: canary)
        api.manifestStatus = 404
        #expect(try await f.manifest(seen: 0).serial == 7)
        api.manifestStatus = 503
        await #expect(throws: MemberApiError.self) { _ = try await f.manifest(seen: 0) }
        api.manifestStatus = nil // published at the same serial: the canary is retired
        #expect(try await f.manifest(seen: 0).serial == 7)
        #expect(canary.retired == 1 && canary.served() == nil)
    }

    /// The device key's chain goes with an unlock only when asked (§11.7.1), never on the release approval, and an
    /// abandon is accepted only towards the previous release (§11.10.4).
    @Test func theChainAndTheReleaseRules() throws {
        let e = try FakeEnclave("inst-a")
        let api = FakeAltAPI([e])
        let m = try ManifestVerifier(pinned: [try api.manifestKey]).verify(try api.served())
        let enclave = try e.verified(m)
        let ik = Ed25519PrivateKey.generate()
        func body(_ options: UnlockOptions, _ state: AltState = AltState()) throws -> JsonObject {
            let b = try AltRequests.buildUnlock(userGuid: "guid-1", vaultID: "0123456789abcdef0123456789abcdef", pin: "246802", enclave: enclave, manifest: m, attester: ChainAttester(), ik: ik, token: "v4.public.t", state: state, options: options, now: Date())
            return try StrictJson.parseObject(try e.open(b.request.envelope).body)
        }
        #expect(try body(UnlockOptions(sendChain: true)).obj("device_assertion").has("chain"))
        #expect(try !body(UnlockOptions()).obj("device_assertion").has("chain"))
        let approved = try body(UnlockOptions(approve: Approval(toPcr0: String(repeating: "c5", count: 48), toRelease: 4), sendChain: true))
        #expect(try !approved.obj("release_update").obj("approval").has("chain"))
        // Abandon: only towards the release this device moved from.
        var moved = AltState()
        moved.release = String(repeating: "c5", count: 48)
        moved.releaseNumber = 4
        #expect(throws: AltRefused.rollbackRelease) { _ = try body(UnlockOptions(abandon: true), moved) }
        moved.previousRelease = FakeEnclave.pcr0
        moved.previousReleaseNumber = 3
        #expect(try body(UnlockOptions(abandon: true), moved).obj("release_update").string("to") == FakeEnclave.pcr0)
        let abandoned = try AltRequests.applyUnlock(moved, PendingUnlock(requestID: "r", release: FakeEnclave.pcr0, number: 3, serial: 7, toNumber: 3), {
            var r = UnlockResult(ok: true)
            r.release = FakeEnclave.pcr0
            r.releaseNumber = 3
            r.update = UnlockResult.Update(to: FakeEnclave.pcr0, result: "abandoned", code: nil)
            return r
        }())
        #expect(abandoned.previousRelease == "" && abandoned.releaseNumber == 3 && abandoned.release == FakeEnclave.pcr0)
    }

    @Test func theUniversalLinksPortHostAndPath() {
        let secret = "AbCdEfGhIjKlMnOpQrStUv"
        #expect(SetupCodes.parseLink("https://account.example.org:443/vault/enroll/#s=\(secret)", api: "https://account.example.org") == nil)
        #expect(SetupCodes.parseLink("https://ACCOUNT.example.org/vault/enroll/#s=\(secret)", api: "https://account.example.org") == nil)
        #expect(SetupCodes.parseLink("https://account.example.org/vault/enroll/x#s=\(secret)", api: "https://account.example.org") == nil)
    }
}

// swiftlint:enable line_length
