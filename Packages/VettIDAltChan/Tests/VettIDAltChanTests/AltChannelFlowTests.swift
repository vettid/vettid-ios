import CryptoKit
import Foundation
import Testing
@testable import VettIDAltChan
import VettIDAttestation
import VettIDCrypto
import VettIDRelay
import VettIDTesting

// Fixtures (JSON bodies of the fake member API and enclave) stay on one line each.
// swiftlint:disable line_length

/// TEST-ONLY enclave: its ETK, descriptor and manifest entry; opens sealed requests and seals results.
struct FakeEnclave {
    static let pcr0 = String(repeating: "a3", count: 48)
    let instanceID: String
    let etk: KemPrivateKey
    let descriptor: [UInt8]
    let capabilities: [String]?

    init(_ instanceID: String, capabilities: [String]? = nil, timeScale: UInt64? = nil) throws {
        self.instanceID = instanceID
        etk = try KemPrivateKey.generate()
        self.capabilities = capabilities
        descriptor = Descriptor.marshal(instanceID: instanceID, etk: etk.publicKey, release: Self.pcr0, notAfter: Date().addingTimeInterval(3600), capabilities: capabilities, timeScale: timeScale)
    }

    func open(_ env: [UInt8]) throws -> Inner {
        let (padded, _) = try Envelope.openSealed(try Envelope.parse(env), key: etk)
        return try Inner.parse(try Padding.unpadFixed(padded, Padding.altChannelRequest), .sealed)
    }

    func verified(_ m: ReleaseManifest) throws -> VerifiedEnclave {
        let r = try #require(m.byPcr0(Self.pcr0))
        return VerifiedEnclave(descriptor: try Descriptor.parse(descriptor), measurements: r.measurements, release: r)
    }

    /// A sealed result of [type] answering [requestID], addressed to [kem] (§11.3, §11.4).
    static func sealResult(_ kem: KemPublicKey, _ type: String, _ requestID: String, _ body: String) throws -> [UInt8] {
        let inner = Inner(id: Ulid.new(), type: type, ts: Date(), re: requestID, status: Inner.statusOK, body: Array(body.utf8))
        return try Envelope.sealSealed(kem, senderKid: Kid.anonymous, padded: try Padding.padFixed(try inner.marshal(.sealed), Padding.altChannel)).0
    }
}

/// TEST-ONLY attester with Android-shaped answers (the fake enclave does not check them).
struct SoftAttester: Attester {
    func attest(_ challenge: [UInt8]) throws -> DeviceAttest { try DeviceAttest.androidChain([[1, 2, 3]]) }
    func assert(_ signed: AttestSigned) throws -> DeviceAssertion { try DeviceAssertion.androidSignature([4, 5, 6]) }
}

struct TestWriteFailure: Error {}

/// A thread-safe counter: the number of calls before this one.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        n += 1
        return n - 1
    }
}

/// An iOS-shaped attester that records what the flow confirms and discards: key n is [n].
final class RecordingIOSAttester: Attester, @unchecked Sendable {
    private let lock = NSLock()
    private var made: UInt8 = 0
    private var entries: [String] = []

    var log: [String] { lock.withLock { entries } }

    func attest(_ challenge: [UInt8]) throws -> DeviceAttest {
        lock.lock()
        made += 1
        let n = made
        lock.unlock()
        return try DeviceAttest.iosAttestation(keyID: [n], attestation: [0xA1])
    }

    func assert(_ signed: AttestSigned) throws -> DeviceAssertion { try DeviceAssertion.iosAssertion([1]) }
    /// How many other keys ``nextCandidate()`` offers.
    var candidates = 0
    /// Confirmations fail to be recorded.
    var failConfirm = false

    func confirm(keyID: [UInt8]) throws {
        if failConfirm { throw TestWriteFailure() }
        lock.withLock { entries.append("confirm \(keyID[0])") }
    }
    func discard(keyID: [UInt8]) { lock.withLock { entries.append("discard \(keyID[0])") } }
    func confirmInUse() throws {
        if failConfirm { throw TestWriteFailure() }
        lock.withLock { entries.append("confirm in use") }
    }

    func nextCandidate() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        entries.append("next")
        guard candidates > 0 else { return false }
        candidates -= 1
        return true
    }
}

/// A minimal device: what VettIDVault's VaultDevice does for the alternate channel.
final class TestParty: AltParty, @unchecked Sendable {
    let lock = NSLock()
    var state = AltState()
    var vaultID: String?
    var pending: PendingUnlock?
    let kem: KemPrivateKey
    let ik = Ed25519PrivateKey.generate()
    let app: AppIdentity

    init() throws {
        kem = try KemPrivateKey.generate()
        let relayKey = Ed25519PrivateKey.generate()
        app = AppIdentity(ik: ik.publicKey, kem: kem.publicKey, relay: RelayAddr(url: "https://relay.example.org", mailbox: Mailbox.id(relayKey.publicKey), pk: relayKey.publicKey), name: "phone")
    }

    func manifestSerialSeen() -> UInt64 { lock.withLock { state.manifestSerial } }
    func vaultIDForUnlock() -> String? { lock.withLock { vaultID } }

    func prepareEnroll(userGuid: String, pin: String, enclave: VerifiedEnclave, manifest: ReleaseManifest, attester: Attester, unlockSecret: [UInt8]?, vaultID: String) async throws -> SealedRequest { // swiftlint:disable:this function_parameter_count
        let b = try AltRequests.buildEnroll(userGuid: userGuid, pin: pin, enclave: enclave, manifest: manifest, attester: attester, app: app, openToken: "v4.public.open", state: lock.withLock { state }, now: Date(), unlockSecret: unlockSecret, vaultID: vaultID)
        lock.withLock { state = b.state }
        return b.request
    }

    func openEnrollResult(_ raw: [UInt8], requestID: String) async throws -> EnrollResult {
        try EnrollResult.parse(try AltResults.open(raw, kem: kem, type: AltResults.typeEnrollResult, requestID: requestID))
    }

    func prepareUnlock(userGuid: String, pin: String, enclave: VerifiedEnclave, manifest: ReleaseManifest, attester: Attester, options: UnlockOptions) async throws -> BuiltUnlock { // swiftlint:disable:this function_parameter_count
        let (vid, s) = lock.withLock { (vaultID, state) }
        let b = try AltRequests.buildUnlock(userGuid: userGuid, vaultID: try #require(vid), pin: pin, enclave: enclave, manifest: manifest, attester: attester, ik: ik, token: "v4.public.tok", state: s, options: options, now: Date())
        lock.withLock { pending = b.pending }
        return b
    }

    func openUnlockResult(_ raw: [UInt8]) async throws -> UnlockResult {
        let p = try #require(lock.withLock { pending })
        let r = try UnlockResult.parse(try AltResults.open(raw, kem: kem, type: AltResults.typeUnlockResult, requestID: p.requestID))
        let next = try AltRequests.applyUnlock(lock.withLock { state }, p, r)
        lock.withLock { state = next }
        return r
    }
}

/// The fake member API and its enclaves, with the switches the flow tests use.
final class FakeAltAPI: @unchecked Sendable {
    let server = FakeHTTPServer()
    let signer = P256.Signing.PrivateKey()
    let lock = NSLock()
    var enclaves: [FakeEnclave]
    var manifestSerial: UInt64 = 7
    var instanceMovedFirst = false
    var manifestFailFirst = false
    var enrolledVaultIDs: [String] = []
    var requests: [(path: String, body: [UInt8])] = []
    var slots: [String: String] = [:]
    var polled: Set<String> = []
    var resultFor: ((String, Inner) -> String?)?
    /// The next slots, in order, answer this instead of the sealed result: "expired", or "etk" (done, `etk_unknown`).
    var slotOverrides: [String] = []
    /// A clear code the host adds beside the sealed result (`recovery_registered`).
    var slotCode: String?
    /// The manifest route answers this status instead of the manifest.
    var manifestStatus: Int?
    weak var party: TestParty?

    init(_ enclaves: [FakeEnclave]) { self.enclaves = enclaves }

    var manifestKey: ManifestKey { get throws { try ManifestKey(spki: Array(signer.publicKey.derRepresentation)) } }

    func served() throws -> [UInt8] {
        let entry = JsonBuilder().uint("release", 3).string("pcr0", FakeEnclave.pcr0).string("pcr1", String(repeating: "11", count: 48)).string("pcr2", String(repeating: "22", count: 48)).string("seal_key", "arn:aws:kms:us-east-1:000000000000:key/test").string("status", "active").string("published_at", "2026-09-01T00:00:00Z").string("notes", "https://vettid.org/releases/3").build()
        let m = JsonBuilder().uint("v", 1).uint("serial", manifestSerial).string("issued_at", "2026-10-02T12:00:00Z").raw("releases", JsonBuilder.array([entry])).bytes()
        let sig = try signer.signature(for: Array(ReleaseManifest.label.utf8) + [0] + m).rawRepresentation
        return JsonBuilder().base64("manifest", m).base64("sig", Array(sig)).string("key_id", try manifestKey.keyID).bytes()
    }

    func start() {
        server.handle { [weak self] r in self?.answer(r) ?? .empty(500) }
    }

    private func answer(_ r: FakeHTTPServer.Request) -> FakeHTTPServer.Answer {
        lock.withLock {
            requests.append((r.path, r.body))
            if r.path == MemberApiClient.manifestPath {
                if let s = manifestStatus { return .json(s, #"{"error":"x"}"#) }
                return (try? served()).map { .bytes(200, $0) } ?? .empty(500)
            }
            guard let e = enclaves.first else { return .json(503, #"{"error":"vault_unavailable"}"#) }
            switch r.path {
            case "/api/vault/enclave":
                return .json(200, #"{"instance_id":"\#(e.instanceID)","release":"\#(FakeEnclave.pcr0)","descriptor":"\#(Base64s.encodeStd(e.descriptor))","attestation":"AA=="}"#)
            case "/api/vault/enroll", "/api/vault/unlock":
                return sealed(r, e, enroll: r.path.hasSuffix("enroll"))
            case "/api/vault/recovery/register":
                return sealed(r, e, enroll: false, type: AltResults.typeRecoveryResult)
            case "/api/vault/lock":
                let rid = (try? StrictJson.parseObject(r.body).string("request_id")) ?? ""
                slots[rid] = #"{"status":"done"}"#
                return .json(202, "{}")
            case let p where p.hasPrefix("/api/vault/requests/"):
                // The first poll of each slot is still queued (the enclave has not answered yet).
                let rid = String(p.split(separator: "/").last ?? "")
                if polled.insert(rid).inserted { return .json(200, #"{"status":"queued"}"#) }
                return .json(200, slots.removeValue(forKey: rid) ?? #"{"status":"expired"}"#)
            default:
                return .json(404, #"{"error":"not_found"}"#)
            }
        }
    }

    private func sealed(_ r: FakeHTTPServer.Request, _ e: FakeEnclave, enroll: Bool, type recovery: String? = nil) -> FakeHTTPServer.Answer {
        guard let o = try? StrictJson.parseObject(r.body), let iid = try? o.string("instance_id"), let rid = try? o.string("request_id"),
              let env = try? Base64s.decodeStd(try o.string("envelope")), let kem = party?.kem.publicKey
        else { return .json(400, #"{"error":"bad_request"}"#) }
        guard iid == e.instanceID else { return .json(409, #"{"error":"instance_moved","code":"instance_moved"}"#) }
        if instanceMovedFirst {
            instanceMovedFirst = false
            enclaves.removeFirst()
            return .json(409, #"{"error":"instance_moved","code":"instance_moved"}"#)
        }
        guard env.count == AltChannel.requestEnvelopeSize, let inner = try? e.open(env), inner.id == rid else { return .json(400, #"{"error":"bad_request"}"#) }
        if enroll, let vid = try? o.string("vault_id") { enrolledVaultIDs.append(vid) }
        let result = answer(r.path, inner, enroll: enroll, recovery: recovery != nil)
        let type = recovery ?? (enroll ? AltResults.typeEnrollResult : AltResults.typeUnlockResult)
        guard let sealed = try? FakeEnclave.sealResult(kem, type, rid, result) else { return .empty(500) }
        if !slotOverrides.isEmpty {
            slots[rid] = slotOverrides.removeFirst() == "expired" ? #"{"status":"expired"}"# : #"{"status":"done","code":"etk_unknown"}"#
        } else {
            let code = slotCode.map { #","code":"\#($0)""# } ?? ""
            slots[rid] = #"{"status":"done","envelope":"\#(Base64s.encodeStd(sealed))"\#(code)}"#
        }
        return .json(202, #"{"vault_id":"0123456789abcdef0123456789abcdef","request_id":"\#(rid)"}"#)
    }

    /// The sealed result of one request.
    private func answer(_ path: String, _ inner: Inner, enroll: Bool, recovery: Bool) -> String {
        if manifestFailFirst {
            manifestFailFirst = false
            return enroll ? #"{"ok":false,"code":"manifest"}"# : #"{"ok":false,"code":"manifest","header_seq":0,"retry_after":0}"#
        }
        if let custom = resultFor?(path, inner) { return custom }
        if recovery { return #"{"ok":true}"# }
        if enroll { return #"{"ok":true,"vault_id":"0123456789abcdef0123456789abcdef"}"# }
        return #"{"ok":true,"state_seq":5,"header_seq":3,"token":"v4.public.t","release":"\#(FakeEnclave.pcr0)","release_number":3,"release_status":"active","manifest_serial":\#(manifestSerial)}"#
    }

    /// The request bodies the enclave opened, by path.
    func openedBodies(_ path: String) throws -> [JsonObject] {
        let (reqs, e) = lock.withLock { (requests.filter { $0.path == path }, enclaves) }
        return try reqs.compactMap { req in
            let o = try StrictJson.parseObject(req.body)
            let env = try Base64s.decodeStd(try o.string("envelope"))
            for enc in e { if let inner = try? enc.open(env) { return try StrictJson.parseObject(inner.body) } }
            return nil
        }
    }
}

/// The alternate-channel flows (VAULT-MESSAGING §11.3, §11.4, §11.9) against a fake member API and enclave. Mirrors the
/// flow-level cases of vettid-android `MemberApiTest`.
@Suite struct AltChannelFlowTests {
    func setUp(_ enclaves: [FakeEnclave]? = nil, timeScales: TimeScalePolicy = .production) throws -> (FakeAltAPI, TestParty, AltChannelFlow) { // swiftlint:disable:this large_tuple
        let api = FakeAltAPI(try enclaves ?? [FakeEnclave("inst-a")])
        let party = try TestParty()
        api.party = party
        api.start()
        let client = MemberApiClient(
            apiBase: api.server.baseURL, manifestURL: api.server.baseURL + MemberApiClient.manifestPath,
            transport: HTTPTransport(session: api.server.session, sleep: { _ in }), auth: .bearer("guid-1"), sleep: { _ in }
        )
        let flow = AltChannelFlow(api: client, trust: AltTrust(nitroRoots: [], manifestKeys: [try api.manifestKey], timeScales: timeScales), verifyEnclave: { d, _, m, _, _ in
            guard let e = api.lock.withLock({ api.enclaves.first }), d == e.descriptor else { throw AttestationError.userData }
            return try e.verified(m)
        })
        return (api, party, flow)
    }

    @Test func enrollUnlockLock() async throws {
        let (api, p, f) = try setUp()
        let out = try await f.enroll(party: p, vaultID: "0123456789abcdef0123456789abcdef", userGuid: "guid-1", pin: "246802", attester: SoftAttester())
        #expect(out.ok && out.vaultID == "0123456789abcdef0123456789abcdef" && out.instanceID == "inst-a")
        #expect(api.enrolledVaultIDs == ["0123456789abcdef0123456789abcdef"]) // MEMBER-API 2.0.0: the enroll names the redeemed vault
        #expect(p.state.enrollNonce?.count == 32 && p.state.enrollNumber == 3)
        let body = try #require(try api.openedBodies("/api/vault/enroll").first)
        #expect(try body.string("pin") == "246802" && body.has("nonce") && (try body.string("manifest_sha256")).count == 64)
        p.vaultID = out.vaultID
        p.state = p.state.applyingEnrolled(stateSeq: 1)
        let u = try await f.unlock(party: p, userGuid: "guid-1", pin: "246802", attester: SoftAttester())
        #expect(u.ok)
        #expect(p.state.stateSeq == 5 && p.state.headerSeq[FakeEnclave.pcr0] == 3 && p.state.manifestSerial == 7)
        #expect(try await f.lock(vaultID: out.vaultID).status == Slot.done)
    }

    /// `instance_moved`: re-sealed to the next instance's descriptor (§11.9).
    @Test func reSealsAfterInstanceMoved() async throws {
        let (api, p, f) = try setUp([try FakeEnclave("inst-a"), try FakeEnclave("inst-b")])
        api.instanceMovedFirst = true
        let out = try await f.enroll(party: p, vaultID: "0123456789abcdef0123456789abcdef", userGuid: "guid-1", pin: "246802", attester: SoftAttester())
        #expect(out.ok && out.instanceID == "inst-b")
    }

    /// A `manifest` result: the manifest is fetched again once and the request re-sealed (§11.9).
    @Test func refetchesTheManifestOnceAfterAManifestResult() async throws {
        let (api, p, f) = try setUp()
        api.manifestFailFirst = true
        let out = try await f.enroll(party: p, vaultID: "0123456789abcdef0123456789abcdef", userGuid: "guid-1", pin: "246802", attester: SoftAttester())
        #expect(out.ok)
        #expect(api.requests.filter { $0.path == MemberApiClient.manifestPath }.count == 2)
    }

    /// IOS-PLAN §6.2: the vault's answer to each enrollment request confirms or discards the App Attest key it attested
    /// (a `manifest` refusal discards the first, the accepted retry confirms the second).
    @Test func theEnrollmentAnswerConfirmsOrDiscardsTheAttestedKey() async throws {
        let (api, p, f) = try setUp()
        api.manifestFailFirst = true
        let attester = RecordingIOSAttester()
        let out = try await f.enroll(party: p, vaultID: "0123456789abcdef0123456789abcdef", userGuid: "guid-1", pin: "246802", attester: attester)
        #expect(out.ok)
        #expect(attester.log == ["discard 1", "confirm 2"])
    }

    /// IOS-PLAN §6.2: A expires (it may have made the vault), B never reaches the vault (`etk_unknown`), C is refused
    /// (`vault_exists`): B and C are discarded, A is kept.
    @Test func aRequestThatNeverReachedTheVaultDiscardsItsKey() async throws {
        let (api, p, f) = try setUp()
        api.slotOverrides = ["expired", "etk"]
        api.resultFor = { path, _ in path.hasSuffix("enroll") ? #"{"ok":false,"code":"vault_exists"}"# : nil }
        let attester = RecordingIOSAttester()
        let out = try await f.enroll(party: p, vaultID: "0123456789abcdef0123456789abcdef", userGuid: "guid-1", pin: "246802", attester: attester)
        #expect(!out.ok && out.code == "vault_exists")
        #expect(attester.log == ["discard 2", "discard 3"])
        // Each kept request names its key: vault.enrolled for A's names key 1.
        #expect(p.state.enrollAttempts.map(\.attestKeyID) == [[3], [2], [1]])
        #expect(p.state.applyingEnrolled(stateSeq: 1, attempt: p.state.enrollAttempts.last).enrolledAttestKeyID == [1])
    }

    /// IOS-PLAN §6.2: a request dropped from the kept ones can never be confirmed: its key is discarded. Two tries of
    /// four expired requests: the state keeps the five newest, so keys 1 to 3 go.
    @Test func aRequestNoLongerKeptDiscardsItsKey() async throws {
        let (api, p, f) = try setUp()
        api.slotOverrides = Array(repeating: "expired", count: 8)
        let attester = RecordingIOSAttester()
        for _ in 0 ..< 2 {
            _ = try? await f.enroll(party: p, vaultID: "0123456789abcdef0123456789abcdef", userGuid: "guid-1", pin: "246802", attester: attester)
        }
        #expect(attester.log == ["discard 1", "discard 2", "discard 3"])
        #expect(p.state.enrollAttempts.map(\.attestKeyID) == [[8], [7], [6], [5], [4]])
    }

    /// A confirmation that cannot be recorded never turns what the vault did into a failure (the unlock's fallback and
    /// vault.enrolled confirm the key later).
    @Test func aFailedConfirmationIsNotAFailure() async throws {
        let (_, p, f) = try setUp()
        let attester = RecordingIOSAttester()
        attester.failConfirm = true
        let out = try await f.enroll(party: p, vaultID: "0123456789abcdef0123456789abcdef", userGuid: "guid-1", pin: "246802", attester: attester)
        #expect(out.ok)
        p.vaultID = out.vaultID
        p.state = p.state.applyingEnrolled(stateSeq: 1)
        #expect(try await f.unlock(party: p, userGuid: "guid-1", pin: "246802", attester: attester).ok)
    }

    /// An unlock refused for its assertion while no key is confirmed tries the next unconfirmed key; the accepted one is
    /// confirmed.
    @Test func anUnlockRefusedForItsAssertionTriesTheNextKey() async throws {
        let (api, p, f) = try setUp()
        p.vaultID = "0123456789abcdef0123456789abcdef"
        let refused = Counter()
        api.resultFor = { path, _ in
            guard path.hasSuffix("unlock"), refused.next() == 0 else { return nil }
            return #"{"ok":false,"code":"attestation","header_seq":0,"retry_after":0}"#
        }
        let attester = RecordingIOSAttester()
        attester.candidates = 1
        let u = try await f.unlock(party: p, userGuid: "guid-1", pin: "246802", attester: attester)
        #expect(u.ok)
        #expect(attester.log == ["next", "confirm in use"])
        // No other key: the refusal is the answer.
        let again = Counter()
        api.resultFor = { path, _ in
            guard path.hasSuffix("unlock"), again.next() < 9 else { return nil }
            return #"{"ok":false,"code":"attestation","header_seq":0,"retry_after":0}"#
        }
        let none = RecordingIOSAttester()
        let r = try await f.unlock(party: p, userGuid: "guid-1", pin: "246802", attester: none)
        #expect(!r.ok && r.result.code == "attestation" && none.log == ["next"])
    }

    /// IOS-PLAN §6.2: a recovery's register confirms the key it attested on `ok` and discards it on a sealed refusal or
    /// when it never reached the vault.
    @Test func aRecoveryRegisterConfirmsOrDiscardsItsKey() async throws {
        let (api, p, f) = try setUp()
        let attester = RecordingIOSAttester()
        let code = RecoveryCode(vaultID: "0123456789abcdef0123456789abcdef", recoveryID: "01JA0RECVERY0000000000001X", code: "AbCdEfGhIjKlMnOpQrStUv")
        let app = p.app
        func register() async throws -> RecoveryResult {
            try await f.recoveryRegister(vaultID: code.vaultID, attester: attester, build: { e in
                try AltRequests.buildRecoveryRegister(userGuid: "guid-1", code: code, enclave: e, attester: attester, app: app, now: Date())
            }, open: { raw, rid in
                try RecoveryResult.parse(try AltResults.open(raw, kem: p.kem, type: AltResults.typeRecoveryResult, requestID: rid))
            })
        }
        #expect(try await register().ok)
        api.slotOverrides = ["etk"]
        api.resultFor = { path, _ in path.hasSuffix("register") ? #"{"ok":false,"code":"recovery_unknown"}"# : nil }
        #expect(try await !register().ok)
        #expect(attester.log == ["confirm 1", "discard 2", "discard 3"])
    }

    /// A served manifest older than one already seen is refused before anything is sealed (§11.10.1).
    @Test func refusesAnOlderManifest() async throws {
        let (api, p, f) = try setUp()
        p.state.manifestSerial = 9
        await #expect(throws: AltRefused.manifestOlder) { _ = try await f.enroll(party: p, vaultID: "v", userGuid: "guid-1", pin: "246802", attester: SoftAttester()) }
        #expect(!api.requests.contains { $0.path == "/api/vault/enroll" })
    }

    /// No PIN is sealed or sent to an enclave that did not verify.
    @Test func noPinGoesToAnEnclaveThatDidNotVerify() async throws {
        let api = FakeAltAPI([try FakeEnclave("inst-a")])
        let p = try TestParty()
        api.party = p
        api.start()
        let client = MemberApiClient(apiBase: api.server.baseURL, manifestURL: api.server.baseURL + MemberApiClient.manifestPath, transport: HTTPTransport(session: api.server.session, sleep: { _ in }), auth: .bearer("guid-1"), sleep: { _ in })
        let f = AltChannelFlow(api: client, trust: AltTrust(nitroRoots: [], manifestKeys: [try api.manifestKey]), verifyEnclave: { _, _, _, _, _ in throw AttestationError.chain })
        await #expect(throws: AttestationError.chain) { _ = try await f.enroll(party: p, vaultID: "v", userGuid: "guid-1", pin: "246802", attester: SoftAttester()) }
        #expect(!api.requests.contains { $0.path == "/api/vault/enroll" })
    }

    /// A descriptor that names another instance than the route's is refused.
    @Test func aDescriptorForAnotherInstanceIsRefused() async throws {
        let (api, p, _) = try setUp()
        let client = MemberApiClient(apiBase: api.server.baseURL, manifestURL: api.server.baseURL + MemberApiClient.manifestPath, transport: HTTPTransport(session: api.server.session, sleep: { _ in }), auth: .bearer("guid-1"), sleep: { _ in })
        let other = try FakeEnclave("inst-z")
        let f = AltChannelFlow(api: client, trust: AltTrust(nitroRoots: [], manifestKeys: [try api.manifestKey]), verifyEnclave: { _, _, m, _, _ in try other.verified(m) })
        await #expect(throws: AltChannelFailure.self) { _ = try await f.enroll(party: p, vaultID: "v", userGuid: "guid-1", pin: "246802", attester: SoftAttester()) }
    }

    /// (0.34.0, release R) The instance's capabilities choose the request's shape: the unlock secret goes only to a
    /// release that offers `recovery_r`; a refusal from the callback sends nothing.
    @Test func theInstancesCapabilitiesChooseTheShape() async throws {
        let (api, p, f) = try setUp([try FakeEnclave("inst-a", capabilities: [Capabilities.recoveryR])])
        let seen = Recorder<[String]>()
        _ = try await f.enroll(party: p, vaultID: "v", userGuid: "guid-1", pin: "246802", attester: SoftAttester()) { caps in
            seen.add(caps)
            return caps.contains(Capabilities.recoveryR) ? [UInt8](repeating: 0x42, count: 32) : nil
        }
        #expect(seen.all == [[Capabilities.recoveryR]])
        #expect(try api.openedBodies("/api/vault/enroll").first?.has("unlock_secret") == true)
        struct NoSecret: Error {}
        await #expect(throws: NoSecret.self) {
            _ = try await f.enroll(party: p, vaultID: "v", userGuid: "guid-1", pin: "246802", attester: SoftAttester()) { _ in throw NoSecret() }
        }
        #expect(api.requests.filter { $0.path == "/api/vault/enroll" }.count == 1)
    }

    @Test func preflightOffersTheNewestActiveRelease() async throws {
        let (_, p, f) = try setUp()
        let pre = try await f.preflight(p.state)
        #expect(pre.routed.number == 3 && pre.offer == nil && !pre.rollback && !pre.softwareUpdated && pre.manifestSerial == 7)
        p.state.releaseNumber = 4
        #expect(try await f.preflight(p.state).rollback)
    }

    /// Never a PIN to an older release than the last one unlocked into (§11.10.6).
    @Test func anUnlockToAnOlderReleaseIsRefused() async throws {
        let (api, p, f) = try setUp()
        p.vaultID = "0123456789abcdef0123456789abcdef"
        p.state.release = String(repeating: "b4", count: 48)
        p.state.releaseNumber = 4
        await #expect(throws: AltRefused.rollbackRelease) { _ = try await f.unlock(party: p, userGuid: "guid-1", pin: "246802", attester: SoftAttester()) }
        #expect(!api.requests.contains { $0.path == "/api/vault/unlock" })
        p.vaultID = nil
        await #expect(throws: AltRefused.notPaired) { _ = try await f.unlock(party: p, userGuid: "guid-1", pin: "246802", attester: SoftAttester()) }
    }
}

/// Records values from @Sendable closures.
final class Recorder<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []

    func add(_ v: T) { lock.withLock { items.append(v) } }
    var all: [T] { lock.withLock { items } }
}

/// Setup codes (VAULT-MESSAGING §11.12.1): the QR, the Universal Link and the typed code. Mirrors vettid-android
/// `SetupCodeTest`.
@Suite struct SetupCodesTests {
    let api = "https://account.example.org"
    let secret = "AbCdEfGhIjKlMnOpQrStUv"

    @Test func aScannedQR() {
        #expect(SetupCodes.parseScanned(#"{"v":1,"t":"e","api":"https://account.example.org","s":"\#(secret)"}"#, api: api) == .secret(secret))
        #expect(SetupCodes.parseScanned(#"{"v":1,"t":"e","api":"https://account.other.org","s":"\#(secret)"}"#, api: api) == .otherEnvironment("https://account.other.org"))
        for bad in ["", "hello", #"{"v":2,"t":"e","api":"\#(api)","s":"\#(secret)"}"#, #"{"v":1,"t":"r","api":"\#(api)","s":"\#(secret)"}"#, #"{"v":1,"t":"e","api":"\#(api)","s":"short"}"#] {
            #expect(SetupCodes.parseScanned(bad, api: api) == .notACode, "\(bad)")
        }
        #expect(SetupCodes.Scanned.secret(secret).description == "Secret(…)")
    }

    @Test func theUniversalLink() {
        #expect(SetupCodes.parseLink("https://account.example.org/vault/enroll/#s=\(secret)", api: api) == secret)
        #expect(SetupCodes.parseLink("https://account.example.org/vault/enroll/#x=1&s=\(secret)", api: api) == secret)
        #expect(SetupCodes.parseLink("https://evil.example.org/vault/enroll/#s=\(secret)", api: api) == nil)
        #expect(SetupCodes.parseLink("https://account.example.org/vault/other/#s=\(secret)", api: api) == nil)
        #expect(SetupCodes.parseLink("https://account.example.org/vault/enroll/#s=short", api: api) == nil)
        #expect(SetupCodes.isSetupLink("https://anything.example/vault/enroll/"))
    }

    @Test func theTypedCode() {
        #expect(SetupCodes.normalize("k7qm 4xrp") == "K7QM4XRP")
        #expect(SetupCodes.normalize("K7QM-4XRP") == "K7QM4XRP")
        #expect(SetupCodes.normalize("K7QM4XR") == nil)
        #expect(SetupCodes.normalize("K7QM4XRPP") == nil)
        #expect(SetupCodes.normalize("K7QM4XR0") == nil) // 0 is never in a code
        #expect(SetupCodes.hasForeignCharacter("K7QM-4XRO"))
        #expect(!SetupCodes.hasForeignCharacter("k7qm 4xrp"))
        #expect(SetupCodes.grouped("K7QM4XRP") == "K7QM-4XRP")
        #expect(SetupCodes.normalizeEmail("  Sam@Example.ORG ") == "sam@example.org")
        #expect(SetupCodes.origin("https://account.example.org/") == "https://account.example.org")
    }
}

/// The sealed results (§11.3, §11.4) and the unlock state rules (§11.10.4).
@Suite struct AltResultsTests {
    @Test func resultsAreOpenedOnlyForTheirRequest() throws {
        let kem = try KemPrivateKey.generate()
        let raw = try FakeEnclave.sealResult(kem.publicKey, AltResults.typeEnrollResult, "01JB2Z6V9K3M4N5P6Q7R8S9T30", #"{"ok":true,"vault_id":"v1"}"#)
        #expect(raw.count == AltChannel.resultEnvelopeSize)
        #expect(try EnrollResult.parse(try AltResults.open(raw, kem: kem, type: AltResults.typeEnrollResult, requestID: "01JB2Z6V9K3M4N5P6Q7R8S9T30")) == EnrollResult(ok: true, code: nil, vaultID: "v1"))
        #expect(throws: AltResultFailure(what: "result does not answer the request")) { _ = try AltResults.open(raw, kem: kem, type: AltResults.typeEnrollResult, requestID: "01JB2Z6V9K3M4N5P6Q7R8S9T31") }
        #expect(throws: AltResultFailure(what: "result does not answer the request")) { _ = try AltResults.open(raw, kem: kem, type: AltResults.typeUnlockResult, requestID: "01JB2Z6V9K3M4N5P6Q7R8S9T30") }
        #expect(throws: AltResultFailure(what: "result unreadable")) { _ = try AltResults.open(raw, kem: try KemPrivateKey.generate(), type: AltResults.typeEnrollResult, requestID: "01JB2Z6V9K3M4N5P6Q7R8S9T30") }
        #expect(throws: AltResultFailure(what: "result size")) { _ = try AltResults.open(Array(raw.dropLast()), kem: kem, type: AltResults.typeEnrollResult, requestID: "x") }
    }

    @Test func unlockResultsAndTheirState() throws {
        let pcr = FakeEnclave.pcr0
        let next = String(repeating: "c5", count: 48)
        let ok = try UnlockResult.parse(Array(#"{"ok":true,"state_seq":9,"header_seq":4,"release":"\#(pcr)","release_number":3,"release_status":"active","manifest_serial":8,"update":{"to":"\#(next)","result":"moved"},"credential_backup":true}"#.utf8))
        #expect(ok.ok && ok.update?.result == "moved" && ok.credentialBackup == true && ok.recoveryCancelled == false)
        let p = PendingUnlock(requestID: "r", release: pcr, number: 3, serial: 8, toNumber: 4)
        var s = AltState()
        s.stateSeq = 2
        let after = try AltRequests.applyUnlock(s, p, ok)
        #expect(after.release == next && after.releaseNumber == 4 && after.previousRelease == pcr && after.previousReleaseNumber == 3)
        #expect(after.stateSeq == 9 && after.manifestSerial == 8 && after.headerSeq[next] == 4)
        let refused = try UnlockResult.parse(Array(#"{"ok":false,"code":"bad_pin","header_seq":6,"retry_after":30}"#.utf8))
        #expect(!refused.ok && refused.code == "bad_pin" && refused.retryAfterSeconds == 30)
        #expect(try AltRequests.applyUnlock(s, p, refused).headerSeq[pcr] == 6)
        var other = ok
        other.releaseNumber = 2
        #expect(throws: AltResultFailure.self) { _ = try AltRequests.applyUnlock(s, p, other) }
        #expect(throws: AltResultFailure.self) { _ = try UnlockResult.parse(Array(#"{"ok":true,"state_seq":1,"header_seq":1,"release":"nope","release_number":3,"release_status":"active","manifest_serial":1}"#.utf8)) }
    }

    @Test func aRecoveryOpenMovesTheFloors() {
        var s = AltState()
        s.stateSeq = 5
        let r = AltRequests.applyRecoveryOpen(s, stateSeq: 7, headerSeq: 3, release: FakeEnclave.pcr0, releaseNumber: 3)
        #expect(r.stateSeq == 7 && r.release == FakeEnclave.pcr0 && r.releaseNumber == 3 && r.headerSeq[FakeEnclave.pcr0] == 3)
        #expect(AltRequests.applyRecoveryOpen(s, stateSeq: 1, headerSeq: 3, release: "bad", releaseNumber: 3).stateSeq == 5)
    }
}

// swiftlint:enable line_length
