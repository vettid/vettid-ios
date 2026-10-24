import CryptoKit
import Foundation
import Testing
@testable import VettIDAltChan
import VettIDCrypto
import VettIDRelay
import VettIDTesting

// Fixtures (JSON bodies of the fake member API) stay on one line each.
// swiftlint:disable line_length

/// Records values from @Sendable closures.
final class Box<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T

    init(_ v: T) { self.v = v }

    var value: T {
        get { lock.withLock { v } }
        set { lock.withLock { v = newValue } }
    }
}

/// The member API client against a fake API that checks every app-key signature (MEMBER-API "App request signing").
/// Mirrors the client-level cases of vettid-android `MemberApiTest`, `MemberApiFreshSignatureTest` and
/// `MemberApiRetryTest`; the flow-level ones come with enrollment (I1.6).
@Suite struct MemberApiClientTests {
    static let vid = "0123456789abcdef0123456789abcdef"
    let server = FakeHTTPServer()
    let appKey = SoftAppKey()
    let sleeps = Box<[TimeInterval]>([])

    func api(_ auth: MemberAuth, now: @escaping @Sendable () -> Date = { Date() }) -> MemberApiClient {
        let sleeps = sleeps
        return MemberApiClient(
            apiBase: server.baseURL, manifestURL: server.baseURL + MemberApiClient.manifestPath,
            transport: HTTPTransport(session: server.session, sleep: { _ in }), auth: auth,
            sleep: { sleeps.value.append($0) }, now: now
        )
    }

    func appAuth(_ vault: Box<String?>) -> MemberAuth { .appKey(appKey, vaultID: { vault.value }) }

    /// Verifies an `X-VettID-App` header as the API does; returns the header's `vault` and `nonce`.
    func verify(_ r: FakeHTTPServer.Request) throws -> (vault: String, nonce: String) {
        let h = try #require(r.header(AppRequestSigning.header))
        var f: [String: String] = [:]
        for part in h.components(separatedBy: "; ") {
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            f[kv[0]] = kv.count > 1 ? kv[1] : ""
        }
        let c = try #require(URLComponents(url: r.url, resolvingAgainstBaseURL: false))
        let msg = AppRequestSigning.signingString(
            method: r.method, path: c.percentEncodedPath, query: c.percentEncodedQuery ?? "", vaultID: f["vault"] ?? "",
            akid: AppRequestSigning.akid(try appKey.spki()), ts: UInt64(try #require(f["ts"]))!, nonce: try #require(f["nonce"]), body: r.body
        )
        #expect(f["kid"] == AppRequestSigning.akid(try appKey.spki()))
        #expect(appKey.verify(Array(msg.utf8), try Base64s.decodeRawUrl(try #require(f["sig"]))), "app signature")
        return (f["vault"] ?? "", f["nonce"] ?? "")
    }

    @Test func appKeySignedRedeemClaimAndStatus() async throws {
        let vault = Box<String?>("previous-vault")
        let a = api(appAuth(vault))
        // §11.12.1: the redeem names no vault (`vault=` empty) whatever the client's vault is.
        server.enqueue(.json(200, #"{"vault_id":"\#(Self.vid)","user_guid":"guid-1","email_hint":"s***@example.org"}"#))
        #expect(try await a.redeemSecret("AbCdEfGhIjKlMnOpQrStUv", appKey: try appKey.spki()) == Redeemed(vaultID: Self.vid, userGuid: "guid-1", emailHint: "s***@example.org"))
        #expect(try verify(server.requests[0]).vault == "")
        #expect(server.requests[0].path == "/api/vault/enroll/redeem")
        server.enqueue(.json(404, #"{"error":"invalid_code","message":"no"}"#))
        await #expect(throws: MemberApiError(status: 404, code: MemberApiError.invalidCode, message: "no")) {
            _ = try await a.redeemTyped(email: "sam@example.org", code: "K7QM4XRQ", appKey: try appKey.spki())
        }
        #expect(try StrictJson.parseObject(server.requests[1].body).string("code") == "K7QM4XRQ")
        // §11.11.7: the claim is signed with the QR's vault.
        server.enqueue(.json(200, #"{"user_guid":"guid-1","email_hint":"s***@example.org"}"#))
        #expect(try await a.recoveryClaim(vaultID: "qr-vault", recoveryID: "01JA0RECVERY0000000000001X", appKey: try appKey.spki()) == Claimed(userGuid: "guid-1", emailHint: "s***@example.org", vaultID: nil, recoveryID: nil))
        #expect(try verify(server.requests[2]).vault == "qr-vault")
        // Later calls name the client's vault.
        vault.value = Self.vid
        server.enqueue(.json(200, #"{"vault":null}"#))
        _ = try await a.vaultStatusAnswer()
        #expect(try verify(server.requests[3]).vault == Self.vid)
    }

    /// MEMBER-API 2.4.0: the claim by locator sends exactly `{locator, app_key}` with an empty `vault`.
    @Test func theClaimByLocator() async throws {
        let a = api(appAuth(Box("previous-vault")))
        server.enqueue(.json(200, #"{"user_guid":"guid-1","email_hint":"s***@example.org","vault_id":"\#(Self.vid)","recovery_id":"01JA0RECVERY0000000000001X"}"#))
        let c = try await a.recoveryClaim(locator: "7ZK3M9QX2HTD", appKey: try appKey.spki())
        #expect(c.vaultID == Self.vid && c.recoveryID == "01JA0RECVERY0000000000001X")
        let r = server.requests[0]
        #expect(try verify(r).vault == "")
        #expect(String(bytes: r.body, encoding: .utf8) == #"{"locator":"7ZK3M9QX2HTD","app_key":"\#(Base64s.encodeStd(try appKey.spki()))"}"#)
        await #expect(throws: CryptoError.self) { _ = try await a.recoveryClaim(locator: "7ZK3M9QX2HT", appKey: try appKey.spki()) }
        #expect(server.requestCount == 1)
    }

    /// A 401 is asked once more with a signature made now (a nonce the API saw is one cause); a second 401 is reported.
    /// Other refusals are not asked again.
    @Test func aRefusedSignatureIsAskedAgainOnceWithAFreshOne() async throws {
        let a = api(appAuth(Box(Self.vid)))
        server.enqueue(.json(401, #"{"error":"unauthorized"}"#), .json(200, #"{"vault":null}"#))
        #expect(try await a.vaultStatus() == nil)
        let n1 = try verify(server.requests[0]).nonce
        let n2 = try verify(server.requests[1]).nonce
        #expect(n1 != n2)
        server.enqueue(.json(401, #"{"error":"unauthorized"}"#), .json(401, #"{"error":"unauthorized"}"#))
        await #expect(throws: MemberApiError(status: 401, code: MemberApiError.unauthorized)) { _ = try await a.vaultStatus() }
        #expect(server.requestCount == 4)
        server.enqueue(.json(403, #"{"error":"forbidden"}"#))
        await #expect(throws: MemberApiError(status: 403, code: "forbidden")) { _ = try await a.vaultStatus() }
        #expect(server.requestCount == 5)
        // The dev stack's bearer auth is not signed per request: a 401 is reported at once.
        server.enqueue(.json(401, #"{"error":"unauthorized"}"#))
        await #expect(throws: MemberApiError(status: 401, code: MemberApiError.unauthorized)) { _ = try await api(.bearer("someone-else")).enclave() }
        #expect(server.requests.last?.header("Authorization") == "Bearer someone-else")
    }

    /// A 401 whose `Date` is more than 240 s from the phone's clock is reported as clock skew.
    @Test func aWrongClockIsReportedAsSuch() async throws {
        let date = "Sat, 17 Oct 2026 12:00:00 GMT"
        let apiTime = try #require(MemberApiClient.httpDate(date))
        let skewed = api(appAuth(Box(Self.vid)), now: { apiTime.addingTimeInterval(600) })
        for _ in 0..<2 { server.enqueue(.json(401, #"{"error":"unauthorized"}"#, headers: ["Date": date])) }
        await #expect(throws: MemberApiError(status: 401, code: MemberApiError.clockSkew)) { _ = try await skewed.vaultStatus() }
        let fine = api(appAuth(Box(Self.vid)), now: { apiTime.addingTimeInterval(60) })
        for _ in 0..<2 { server.enqueue(.json(401, #"{"error":"unauthorized"}"#, headers: ["Date": date])) }
        // A `Date` within the limit is noted: the phone's clock does not explain the refusal.
        await #expect(throws: MemberApiError(status: 401, code: MemberApiError.unauthorized, dateChecked: true)) { _ = try await fine.vaultStatus() }
        // Without a `Date` (a proxy may strip it) nothing is checked.
        for _ in 0..<2 { server.enqueue(.json(401, #"{"error":"unauthorized"}"#)) }
        await #expect(throws: MemberApiError(status: 401, code: MemberApiError.unauthorized, dateChecked: false)) { _ = try await fine.vaultStatus() }
    }

    /// "No vault" is only the API's explicit `"vault": null`; an empty body or a missing or odd `vault` is malformed.
    @Test func onlyAnExplicitNullIsNoVault() async throws {
        let a = api(appAuth(Box(Self.vid)))
        server.enqueue(.json(200, #"{"vault":null,"service":"available"}"#))
        #expect(try await a.vaultStatusAnswer() == VaultStatusAnswer(vault: nil, servicePaused: false))
        for body in ["", "{}", #"{"vault":"none"}"#, #"{"vault":{"state":"locked"}}"#] {
            server.enqueue(.bytes(200, Array(body.utf8)))
            await #expect(throws: MemberApiMalformed.self, "\(body)") { _ = try await a.vaultStatusAnswer() }
        }
    }

    /// MEMBER-API 2.1.0: `credential_backup` and a pending start-over in the status; the app's signed cancel.
    @Test func deletionInTheStatusAndTheAppsCancel() async throws {
        let a = api(appAuth(Box(Self.vid)))
        server.enqueue(.json(200, #"{"vault":{"vault_id":"\#(Self.vid)","state":"unlocked","leased":true,"credential_backup":false,"deletion":{"state":"pending","deletes_at":"2026-10-07T20:00:00Z","deletion_id":"01JDELETION0000000000000000"}},"service":"available"}"#))
        let v = try #require(try await a.vaultStatus())
        #expect(v.credentialBackup == false && v.leased)
        #expect(v.deletion == PendingDeletion(state: "pending", deletesAt: "2026-10-07T20:00:00Z", deletionID: "01JDELETION0000000000000000"))
        server.enqueue(.json(200, #"{"vault":{"vault_id":"\#(Self.vid)","state":"locked","deletion":{"state":"executing","deletes_at":"2026-10-07T20:00:00Z"}}}"#))
        #expect(try await a.vaultStatus()?.deletion == PendingDeletion(state: "executing", deletesAt: "2026-10-07T20:00:00Z", deletionID: nil))
        server.enqueue(.json(200, #"{"vault":{"vault_id":"\#(Self.vid)","state":"locked","deletion":null,"credential_backup":null}}"#))
        let cleared = try await a.vaultStatus()
        #expect(cleared?.deletion == nil && cleared?.credentialBackup == nil)
        server.enqueue(.json(200, #"{"cancelled":true}"#), .json(200, #"{"cancelled":false}"#))
        #expect(try await a.deletionCancel("01JDELETION0000000000000000"))
        let cancelVault = try verify(server.requests[3]).vault
        #expect(server.requests[3].path == "/api/vault/deletion/cancel" && cancelVault == Self.vid)
        #expect(try await a.deletionCancel("01JOTHER0000000000000000XX") == false)
    }

    @Test func statusReportsReleaseRecoveryAndTheServiceSwitch() async throws {
        let a = api(appAuth(Box(Self.vid)))
        server.enqueue(.json(200, #"{"vault":{"vault_id":"\#(Self.vid)","state":"locked","sealed_release":"aa","leased":false,"alarm":{"kind":"credential_clone","at":"x"},"release":{"number":13,"status":"deprecated","ends_at":"2026-12-01T00:00:00Z","newest_active":14,"notice":"update_available"},"recovery":{"state":"pending","available_at":"2026-10-20T00:00:00Z"}},"service":"paused"}"#))
        let s = try await a.vaultStatusAnswer()
        #expect(s.servicePaused)
        let v = try #require(s.vault)
        #expect(v.alarmKind == "credential_clone" && v.recoveryState == "pending" && v.recoveryAvailableAt == "2026-10-20T00:00:00Z")
        #expect(v.release == ReleaseInfo(number: 13, status: "deprecated", endsAt: "2026-12-01T00:00:00Z", newestActive: 14, notice: ReleaseInfo.noticeUpdateAvailable))
    }

    @Test func enrollUnlockLockAndTheSlot() async throws {
        let a = api(appAuth(Box(Self.vid)))
        let r = SealedRequest(requestID: "01JB2Z6V9K3M4N5P6Q7R8S9T30", etkKid: "40d6c2c8471844a9", envelope: [1, 2, 3], manifestSHA256: String(repeating: "ab", count: 32))
        server.enqueue(.json(202, #"{"vault_id":"\#(Self.vid)","request_id":"01JB2Z6V9K3M4N5P6Q7R8S9T30"}"#))
        #expect(try await a.enroll(vaultID: Self.vid, instanceID: "i-1", r) == Self.vid)
        #expect(String(bytes: server.requests[0].body, encoding: .utf8) == #"{"vault_id":"\#(Self.vid)","request_id":"01JB2Z6V9K3M4N5P6Q7R8S9T30","instance_id":"i-1","etk_kid":"40d6c2c8471844a9","envelope":"AQID","manifest_sha256":"\#(String(repeating: "ab", count: 32))"}"#)
        server.enqueue(.json(202, "{}"), .json(202, "{}"))
        try await a.unlock(vaultID: Self.vid, instanceID: "i-1", r)
        try await a.lock(vaultID: Self.vid, requestID: "01JB2Z6V9K3M4N5P6Q7R8S9T31")
        #expect(server.requests.map(\.path) == ["/api/vault/enroll", "/api/vault/unlock", "/api/vault/lock"])
        // The recovery register carries no manifest_sha256.
        server.enqueue(.json(202, "{}"))
        try await a.recoveryRegister(vaultID: Self.vid, instanceID: "i-1", SealedRequest(requestID: "01JB2Z6V9K3M4N5P6Q7R8S9T32", etkKid: "40d6c2c8471844a9", envelope: [1], manifestSHA256: nil))
        #expect(String(bytes: server.requests[3].body, encoding: .utf8) == #"{"vault_id":"\#(Self.vid)","instance_id":"i-1","request_id":"01JB2Z6V9K3M4N5P6Q7R8S9T32","etk_kid":"40d6c2c8471844a9","envelope":"AQ=="}"#)
        for req in server.requests { _ = try verify(req) }
    }

    @Test func slotPollingAndABoundedPoll() async throws {
        let a = api(appAuth(Box(Self.vid)))
        server.enqueue(.json(200, #"{"status":"queued"}"#), .json(200, #"{"status":"queued"}"#), .json(200, #"{"status":"done","envelope":"AQID","code":"recovery_registered"}"#))
        let s = try await a.poll("01JB2Z6V9K3M4N5P6Q7R8S9T30")
        #expect(s.status == Slot.done && s.envelope == [1, 2, 3] && s.code == Slot.recoveryRegistered)
        #expect(sleeps.value == [0.6, 0.6])
        #expect(server.requests[0].path == "/api/vault/requests/01JB2Z6V9K3M4N5P6Q7R8S9T30")
        sleeps.value = []
        server.handle { _ in .json(200, #"{"status":"queued"}"#) }
        let q = try await a.poll("01JB2Z6V9K3M4N5P6Q7R8S9T30", atMost: 1.5)
        #expect(q.status == Slot.queued && sleeps.value.count == 3)
        server.enqueue(.json(200, #"{"status":"done","envelope":"!!"}"#))
        await #expect(throws: MemberApiMalformed.self) { _ = try await a.slot("x") }
    }

    /// `release_starting` is waited for (at most 2 s a time, 10 minutes in all); `vault_unavailable` (also paused) is
    /// thrown at once with its retry_after.
    @Test func releaseStartingIsWaitedForBoundedlyAndPausedIsNot() async throws {
        let a = api(appAuth(Box(Self.vid)))
        let starts = Box<[Int]>([])
        server.enqueue(.json(503, #"{"error":"release_starting","release":"aa","retry_after":30}"#))
        server.enqueue(.json(200, #"{"instance_id":"i-1","release":"aa","descriptor":"AQ==","attestation":"Ag=="}"#))
        let e = try await a.enclaveWait { s in starts.value.append(s) }
        #expect(e.instanceID == "i-1" && e.descriptor == [1] && e.attestation == [2])
        #expect(starts.value == [30] && sleeps.value == [2])
        server.handle { _ in .json(503, #"{"error":"release_starting","retry_after":1}"#) }
        await #expect(throws: MemberApiError.self) { _ = try await a.enclaveWait() }
        #expect(abs(sleeps.value.reduce(0, +) - 2 - MemberApiClient.maxStartTotal) < 0.001)
        let fresh = FakeHTTPServer()
        let paused = MemberApiClient(apiBase: fresh.baseURL, manifestURL: fresh.baseURL, transport: HTTPTransport(session: fresh.session, sleep: { _ in }), auth: .bearer("g"))
        fresh.enqueue(.json(503, #"{"error":"vault_unavailable","service":"paused","retry_after":120,"reason":"maintenance"}"#))
        do {
            _ = try await paused.enclaveWait()
            Issue.record("not thrown")
        } catch let e as MemberApiError {
            #expect(e.servicePaused && e.retryAfterSeconds == 120)
        }
        #expect(fresh.requestCount == 1)
    }

    @Test func retryAfterFromTheHeaderAndItsBounds() async throws {
        let a = api(.bearer("g"))
        server.enqueue(.json(429, #"{"error":"rate_limited"}"#, headers: ["Retry-After": "7"]))
        await #expect(throws: MemberApiError(status: 429, code: MemberApiError.rateLimited, retryAfterSeconds: 7)) { _ = try await a.vaultStatus() }
        server.enqueue(.json(429, #"{"error":"rate_limited","retry_after":999999}"#))
        await #expect(throws: MemberApiError(status: 429, code: MemberApiError.rateLimited, retryAfterSeconds: 86_400)) { _ = try await a.vaultStatus() }
        #expect(MemberApiClient.retryAfterHeader("Wed, 21 Oct 2015 07:28:00 GMT") == 0)
        #expect(MemberApiClient.retryAfterHeader("-1") == 0)
        server.enqueue(.bytes(502, Array("<html>bad gateway</html>".utf8)))
        await #expect(throws: MemberApiError(status: 502, code: "http_502")) { _ = try await a.vaultStatus() }
    }

    /// A GET whose connection dropped is retried by the transport; a sealed POST that may have arrived is not resent; an
    /// API refusal is never retried.
    @Test func transportRetries() async throws {
        let a = api(appAuth(Box(Self.vid)))
        server.enqueue(.failure(.networkConnectionLost), .json(200, #"{"vault":null}"#))
        #expect(try await a.vaultStatus() == nil)
        let first = try verify(server.requests[0]).nonce
        #expect(first != (try verify(server.requests[1]).nonce))
        server.enqueue(.failure(.networkConnectionLost), .json(202, "{}"))
        await #expect(throws: URLError.self) {
            try await a.unlock(vaultID: Self.vid, instanceID: "i-1", SealedRequest(requestID: "01JB2Z6V9K3M4N5P6Q7R8S9T30", etkKid: "k", envelope: [1], manifestSHA256: nil))
        }
        #expect(server.requestCount == 3)
    }

    @Test func theManifestIsFetchedUnsigned() async throws {
        let a = api(appAuth(Box(Self.vid)))
        server.enqueue(.bytes(200, Array("{}".utf8)))
        #expect(try await a.manifest() == Array("{}".utf8))
        #expect(server.requests[0].header(AppRequestSigning.header) == nil && server.requests[0].path == MemberApiClient.manifestPath)
        server.enqueue(.empty(404))
        await #expect(throws: MemberApiError(status: 404, code: MemberApiError.manifestUnavailable)) { _ = try await a.manifest() }
    }

    @Test func theEnclaveReleaseQueryIsEncodedAndSigned() async throws {
        let a = api(appAuth(Box(Self.vid)))
        server.enqueue(.json(200, #"{"instance_id":"i-1","descriptor":"AQ==","attestation":"Ag=="}"#))
        _ = try await a.enclave(release: "ab/c d")
        let r = server.requests[0]
        #expect(r.query == "release=ab%2Fc+d")
        _ = try verify(r)
        server.enqueue(.json(200, #"{"instance_id":"i-1","descriptor":"not base64!","attestation":"Ag=="}"#))
        await #expect(throws: MemberApiMalformed.self) { _ = try await a.enclave() }
    }
}

// swiftlint:enable line_length
