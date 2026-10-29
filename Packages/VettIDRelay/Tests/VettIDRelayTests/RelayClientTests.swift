import Foundation
import Testing
@testable import VettIDRelay
import VettIDCrypto
import VettIDTesting

// Fixtures (JSON bodies of the fake relay) stay on one line each.
// swiftlint:disable line_length

/// Records values from @Sendable closures.
final class Recorder<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []

    func add(_ v: T) { lock.withLock { items.append(v) } }
    var all: [T] { lock.withLock { items } }
}

/// The relay client against a fake relay that checks every signature as the relay does (RELAY-PROTOCOL §4.1). Mirrors
/// vettid-android `RelayClientTest`, with one test per error of §7.1.
@Suite struct RelayClientTests {
    let server = FakeHTTPServer()
    let key = Ed25519PrivateKey.generate()
    let sleeps = Recorder<TimeInterval>()

    func client(maxAttempts: Int = RelayClient.defaultAttempts, transport: HTTPTransport? = nil) -> RelayClient {
        let sleeps = sleeps
        return RelayClient(
            baseURL: server.baseURL, key: key, transport: transport ?? HTTPTransport(session: server.session, sleep: { _ in }),
            maxAttempts: maxAttempts, sleep: { sleeps.add($0) }
        )
    }

    /// Verifies a request's signature as the relay does (§4.1) and returns its timestamp.
    @discardableResult
    func verifySigned(_ r: FakeHTTPServer.Request) throws -> String {
        let pub = try Base64s.decodeStd(try #require(r.header(RelayAuth.headerKey)))
        #expect(pub == key.publicKey)
        let ts = try #require(r.header(RelayAuth.headerTimestamp))
        let sig = try Base64s.decodeStd(try #require(r.header(RelayAuth.headerSig)))
        let d = RelayAuth.digest(method: r.method, path: r.path, timestamp: ts, bodyHash: RelayAuth.bodyHash(r.body))
        #expect(Ed25519.verifyRaw(pub, d, sig), "signature")
        let f = ISO8601DateFormatter()
        f.formatOptions = ts.contains(".") ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        let t = try #require(f.date(from: ts))
        #expect(abs(t.timeIntervalSinceNow) < 90)
        return ts
    }

    static let sender = RelayVectorsTests.senderPub
    static let limits = #"{"max_payload_bytes":262144,"message_ttl_seconds":1209600,"visibility_timeout_seconds":60,"max_token_lifetime_seconds":34560000,"open_token_max_lifetime_seconds":604800,"max_claim_bytes":16384,"claim_ttl_seconds":604800,"max_blob_bytes":8388608,"blob_ttl_seconds":604800}"#

    @Test func registerDepositCollectAck() async throws {
        let c = client()
        server.enqueue(.json(201, #"{"mailbox_id":"\#(c.mailboxID)","limits":\#(Self.limits)}"#))
        let reg = try await c.register()
        #expect(reg.created && reg.limits.maxBlobBytes == 8_388_608 && reg.mailboxID == c.mailboxID)
        let r1 = server.requests[0]
        try verifySigned(r1)
        #expect(r1.body == Array(#"{"pubkey":"\#(c.publicKeyB64)"}"#.utf8))

        server.enqueue(.json(201, #"{"msg_id":"01JXAMPLE0000000000000000A"}"#))
        #expect(try await c.deposit(mailboxID: "gr2q7gf5lh6pzfdnurnkvputhp", token: "tok", payload: [1, 2, 3]) == "01JXAMPLE0000000000000000A")
        let r2 = server.requests[1]
        try verifySigned(r2)
        #expect(r2.header("Authorization") == "VettID-Deposit tok")
        #expect(r2.path == "/v1/mailbox/gr2q7gf5lh6pzfdnurnkvputhp")
        #expect(r2.body == Array(#"{"payload":"AQID"}"#.utf8))

        server.enqueue(.json(200, #"{"messages":[{"msg_id":"01A","deposited_at":"2026-10-04T00:00:00Z","sender":"\#(Self.sender)","jti":"j1","payload":"AQID"},{"msg_id":"01B","deposited_at":"2026-10-04T00:00:01Z","sender":"\#(Self.sender)","payload":""}]}"#))
        let msgs = try await c.collect(wait: 25, max: 32)
        #expect(msgs.count == 2)
        #expect(msgs[0].jti == "j1" && msgs[1].jti == nil)
        #expect(msgs[0].payload == [1, 2, 3])
        #expect(msgs[0].senderKey == (try RelayVectorsTests.key(RelayVectorsTests.senderSeed)).publicKey)
        let r3 = server.requests[2]
        try verifySigned(r3)
        #expect(r3.query == "wait=25&max=32")

        server.enqueue(.empty(204))
        try await c.ack("01A")
        let r4 = server.requests[3]
        try verifySigned(r4)
        #expect(r4.method == "DELETE" && r4.path == "/v1/mailbox/01A")
    }

    /// Every request carries exactly `VettID-iOS` as its User-Agent, never the system's `CFNetwork/x Darwin/y`, and so does
    /// the WebSocket upgrade (VAULT-MESSAGING 0.75.0 §13.6).
    @Test func everyRequestSaysOnlyVettIDiOS() async throws {
        let c = client()
        server.enqueue(.json(201, #"{"mailbox_id":"\#(c.mailboxID)","limits":\#(Self.limits)}"#), .json(503, #"{"code":"internal","message":"x"}"#), .json(201, #"{"msg_id":"01M"}"#))
        _ = try await c.register()
        _ = try await c.deposit(mailboxID: "m1", token: "t", payload: [1])
        #expect(server.requests.count == 3)
        for r in server.requests { #expect(r.header("User-Agent") == "VettID-iOS" && r.header("Accept-Language") == "") }
        let transport = HTTPTransport(session: server.session)
        let upgrade = RelayClient.webSocket(transport.prepared(try c.streamRequest()))
        #expect(upgrade.value(forHTTPHeaderField: "User-Agent") == "VettID-iOS" && upgrade.value(forHTTPHeaderField: "Accept-Language") == "")
        var other = URLRequest(url: try #require(URL(string: server.baseURL)))
        other.setValue("CFNetwork/1 Darwin/2", forHTTPHeaderField: "User-Agent")
        #expect(ClientIdentity.identified(other).value(forHTTPHeaderField: "User-Agent") == "VettID-iOS")
    }

    @Test func retriesFiveHundredsResigningEachAttempt() async throws {
        server.enqueue(.json(503, #"{"code":"internal","message":"x"}"#), .json(201, #"{"msg_id":"01M"}"#))
        #expect(try await client().deposit(mailboxID: "mbx", token: "tok", payload: [1]) == "01M")
        #expect(server.requestCount == 2)
        for r in server.requests { try verifySigned(r) }
        #expect(sleeps.all.count == 1)
        #expect((0.25...0.5).contains(sleeps.all[0]))
    }

    @Test func honoursRetryAfter() async throws {
        server.enqueue(.json(429, #"{"code":"rate_limited","message":"slow","retry_after":3}"#), .empty(204))
        try await client().ack("x")
        #expect(sleeps.all.count == 1 && (3.0..<3.25).contains(sleeps.all[0]))
        // From the Retry-After header when the body has none.
        server.enqueue(.json(429, #"{"code":"rate_limited","message":""}"#, headers: ["Retry-After": "2"]), .empty(204))
        try await client().ack("y")
        #expect((2.0..<2.25).contains(sleeps.all[1]))
    }

    /// Every error of RELAY-PROTOCOL §7.1 is reported with its code; only `rate_limited`, `internal` (5xx) and the
    /// stale-signature codes are retried. `quota_exceeded` is not transient and is never retried unchanged.
    @Test(arguments: [
        (400, RelayError.badRequest, false), (401, RelayError.signatureInvalid, false), (401, RelayError.timestampStale, true),
        (401, RelayError.replayDetected, true), (401, RelayError.tokenInvalid, false), (401, RelayError.tokenExpired, false),
        (403, RelayError.tokenRevoked, false), (404, RelayError.mailboxUnknown, false), (404, RelayError.blobUnknown, false),
        (404, RelayError.claimUnknown, false), (404, RelayError.notFound, false), (409, RelayError.tokenUsed, false),
        (413, RelayError.payloadTooLarge, false), (429, RelayError.quotaExceeded, false), (429, RelayError.rateLimited, true),
        (500, RelayError.internalError, true),
    ])
    func everyErrorOfSection7(status: Int, code: String, retried: Bool) async throws {
        let quota = code == RelayError.quotaExceeded ? #","quota":"token""# : ""
        for _ in 0..<3 { server.enqueue(.json(status, #"{"code":"\#(code)","message":"m"\#(quota)}"#)) }
        do {
            _ = try await client().deposit(mailboxID: "mbx", token: "tok", payload: [1])
            Issue.record("\(code) not thrown")
        } catch let e as RelayError {
            #expect(e.status == status && e.code == code && e.message == "m")
            #expect(e.retryable == retried)
            if code == RelayError.quotaExceeded { #expect(e.quota == "token") }
        }
        #expect(server.requestCount == (retried ? 3 : 1))
        #expect(sleeps.all.count == (retried ? 2 : 0))
    }

    /// A certificate that does not match is not retried by the client either; a huge retry_after is capped at a day.
    @Test func fatalTransportErrorsAndHugeRetryAfter() async throws {
        server.enqueue(.failure(.serverCertificateUntrusted))
        await #expect(throws: URLError.self) { _ = try await client().deposit(mailboxID: "mbx", token: "tok", payload: [1]) }
        #expect(server.requestCount == 1 && sleeps.all.isEmpty)
        server.enqueue(.json(429, #"{"code":"rate_limited","message":"","retry_after":999999999}"#))
        await #expect(throws: RelayError(status: 429, code: RelayError.rateLimited, retryAfterSeconds: RelayError.maxRetryAfterSeconds)) {
            try await client(maxAttempts: 1).ack("x")
        }
    }

    /// A connection lost after a signed POST may have reached the relay: the transport does not resend it; the client
    /// retries it signed afresh, as vettid-android does (a deposit retried leaves a duplicate the E2E layer dedupes).
    @Test func aLostConnectionIsRetriedByTheClientSignedAfresh() async throws {
        server.enqueue(.failure(.networkConnectionLost), .json(201, #"{"msg_id":"01M"}"#))
        #expect(try await client().deposit(mailboxID: "mbx", token: "tok", payload: [1]) == "01M")
        #expect(server.requestCount == 2 && sleeps.all.count == 1)
    }

    @Test func theStreamRequestIsSignedMappedAndWebSocket() throws {
        let c = client()
        let r = try c.streamRequest()
        #expect(r.url?.absoluteString == server.baseURL + "/v1/mailbox/ws")
        #expect(r.value(forHTTPHeaderField: RelayAuth.headerSig) != nil)
        let t = HTTPTransport(session: server.session, originMap: [server.baseURL: "http://127.0.0.1:18080"])
        #expect(RelayClient.webSocket(t.mapped(r)).url?.absoluteString == "ws://127.0.0.1:18080/v1/mailbox/ws")
        #expect(RelayClient.webSocket(r).url?.absoluteString == "wss://\(server.host)/v1/mailbox/ws")
    }

    @Test func errorWithoutCodeBody() async throws {
        server.enqueue(.bytes(404, Array("not here".utf8)))
        await #expect(throws: RelayError(status: 404, code: "http_404", message: "not here")) { try await client().ack("x") }
    }

    @Test func givesUpAfterMaxAttempts() async throws {
        for _ in 0..<3 { server.enqueue(.json(500, #"{"code":"internal","message":""}"#)) }
        await #expect(throws: RelayError(status: 500, code: "internal")) { try await client().ack("x") }
        #expect(server.requestCount == 3 && sleeps.all.count == 2)
    }

    @Test func aBlobLargerThanTheBoundIsRefused() async throws {
        server.enqueue(.bytes(200, [UInt8](repeating: 1, count: 100)))
        await #expect(throws: RelayError(status: 200, code: RelayError.payloadTooLarge, message: "response")) {
            _ = try await client().getBlob("b1", maxBytes: 50)
        }
        server.enqueue(.bytes(200, [UInt8](repeating: 1, count: 50)))
        #expect(try await client().getBlob("b2", maxBytes: 50).count == 50)
    }

    @Test func claimGetIsUnsignedAndNeverRetried() async throws {
        server.enqueue(.json(500, #"{"code":"internal","message":""}"#))
        await #expect(throws: RelayError.self) { _ = try await client().getClaim("abc") }
        server.enqueue(.failure(.networkConnectionLost))
        await #expect(throws: URLError.self) { _ = try await client().getClaim("abc") }
        #expect(server.requestCount == 2)
        #expect(server.requests[0].header(RelayAuth.headerSig) == nil)
        #expect(server.requests[0].path == "/v1/claim/abc")
    }

    @Test func claimTTLTravelsInTheSignedPath() async throws {
        server.enqueue(.json(201, #"{"claim_id":"c1","expires_at":"2026-10-04T00:15:00Z"}"#))
        let ref = try await client().putClaim([9], ttl: 3600)
        #expect(ref.id == "c1" && ref.expiresAt == RelayClient.time("2026-10-04T00:15:00Z"))
        let r = server.requests[0]
        try verifySigned(r)
        #expect(r.path == "/v1/claim/ttl/3600")
        #expect(r.header("Content-Type") == "application/octet-stream")
    }

    @Test func blobsDenylistRotateAndDelete() async throws {
        let c = client()
        server.enqueue(.json(201, #"{"blob_id":"b1","expires_at":"2026-10-11T00:00:00Z"}"#))
        #expect(try await c.putBlob(mailboxID: "mbx", token: "tok", ciphertext: [UInt8](repeating: 0, count: 100)).id == "b1")
        server.enqueue(.bytes(200, Array("raw".utf8)))
        #expect(try await c.getBlob("b1") == Array("raw".utf8))
        server.enqueue(.empty(204))
        try await c.revoke([.jti("j1"), .sub(Self.sender)])
        #expect(server.requests[2].body == Array(#"{"revoke":[{"kind":"jti","value":"j1"},{"kind":"sub","value":"\#(Self.sender)"}]}"#.utf8))
        let next = Ed25519PrivateKey.generate()
        server.enqueue(.json(200, #"{"mailbox_id":"newbox"}"#))
        #expect(try await c.rotate(to: next) == "newbox")
        let proof = try StrictJson.parseObject(server.requests[3].body).base64("new_key_proof")
        #expect(Ed25519.verifyRaw(next.publicKey, Array(c.mailboxID.utf8), proof))
        server.enqueue(.empty(204))
        try await c.deleteMailbox()
        let del = server.requests[4]
        #expect(del.method == "DELETE" && del.path == "/v1/mailbox" && del.body.isEmpty)
        for r in server.requests { try verifySigned(r) }
    }

    @Test func twoRequestsInOneSecondCarryDifferentSignatures() async throws {
        server.enqueue(.json(200, #"{"messages":[]}"#), .json(200, #"{"messages":[]}"#))
        let c = client()
        _ = try await c.collect(wait: 0)
        try await Task.sleep(nanoseconds: 3_000_000)
        _ = try await c.collect(wait: 0)
        #expect(server.requests[0].header(RelayAuth.headerSig) != server.requests[1].header(RelayAuth.headerSig))
    }

    /// A stale or replayed signature (§4.1) is retried, signed afresh; the relay applied nothing.
    @Test func aStaleSignatureIsRetriedWithAFreshOne() async throws {
        server.enqueue(.json(401, #"{"code":"timestamp_stale","message":"stale"}"#), .json(401, #"{"code":"replay_detected","message":""}"#), .json(201, #"{"msg_id":"01M"}"#))
        let c = client()
        try await Task.sleep(nanoseconds: 2_000_000)
        #expect(try await c.deposit(mailboxID: "mbx", token: "tok", payload: [0, 0, 0, 0]) == "01M")
        for r in server.requests { try verifySigned(r) }
        #expect(Set(server.requests.compactMap { $0.header(RelayAuth.headerTimestamp) }).count >= 1)
        #expect(RelayError(status: 401, code: RelayError.replayDetected).staleSignature)
        #expect(!RelayError(status: 401, code: RelayError.signatureInvalid).retryable)
        #expect(!RelayError(status: 403, code: RelayError.tokenRevoked).retryable)
    }
}

/// The transport retry (vettid-android `TransportRetryTest`): transport failures while the network wakes, by policy;
/// a fresh signature on every attempt; an HTTP answer never retried by the transport.
@Suite struct TransportRetryTests {
    let server = FakeHTTPServer()

    func transport(gate: NetworkGate = .always, sleeps: Recorder<TimeInterval>? = nil) -> HTTPTransport {
        HTTPTransport(session: server.session, gate: gate, sleep: { sleeps?.add($0) })
    }

    func get(_ t: HTTPTransport, method: String = "GET", policy: HTTPTransport.Policy) async throws -> HTTPAnswer {
        try await t.send(policy: policy, maxBody: 1024) {
            var r = URLRequest(url: URL(string: server.baseURL + "/x")!)
            r.httpMethod = method
            return r
        }
    }

    @Test func aGetWhoseConnectionDroppedIsRetriedOnceAndSucceeds() async throws {
        server.enqueue(.failure(.networkConnectionLost), .json(200, "{}"))
        #expect(try await get(transport(), policy: .idempotent).status == 200)
        #expect(server.requestCount == 2)
    }

    @Test func aLookupThatFailsWhileTheNetworkWakesIsRetriedForAnyMethod() async throws {
        server.enqueue(.failure(.cannotFindHost), .json(200, "{}"))
        #expect(try await get(transport(), method: "POST", policy: .unsentOnly).status == 200)
    }

    @Test func aPersistentFailureSurfacesAfterTheRetries() async throws {
        for _ in 0..<3 { server.enqueue(.failure(.notConnectedToInternet)) }
        await #expect(throws: URLError.self) { _ = try await get(transport(), policy: .idempotent) }
        #expect(server.requestCount == 3)
    }

    @Test func aPostThatMayHaveReachedTheServerIsNotResent() async throws {
        server.enqueue(.failure(.networkConnectionLost), .json(200, "{}"))
        await #expect(throws: URLError.self) { _ = try await get(transport(), method: "POST", policy: .unsentOnly) }
        #expect(server.requestCount == 1)
    }

    @Test func anHTTPErrorIsNeverRetried() async throws {
        server.enqueue(.json(503, "{}"), .json(200, "{}"))
        #expect(try await get(transport(), policy: .idempotent).status == 503)
        #expect(server.requestCount == 1)
    }

    @Test func aClaimFetchIsNeverRetried() async throws {
        server.enqueue(.failure(.cannotFindHost))
        await #expect(throws: URLError.self) { _ = try await get(transport(), policy: .never) }
        #expect(server.requestCount == 1)
    }

    @Test func itWaitsForAUsableNetworkAndThenSignsAfresh() async throws {
        let calls = Recorder<Bool>()
        let gate = NetworkGate {
            calls.add(true)
            return calls.all.count > 3
        }
        let sleeps = Recorder<TimeInterval>()
        server.enqueue(.json(200, "{}"))
        let builds = Recorder<Int>()
        let a = try await transport(gate: gate, sleeps: sleeps).send(policy: .unsentOnly, maxBody: 64) {
            builds.add(1)
            return URLRequest(url: URL(string: server.baseURL + "/x")!)
        }
        #expect(a.status == 200)
        #expect(sleeps.all.count == 3)
        #expect(builds.all.count == 1) // built (and so signed) only once the network was there
    }

    @Test func aNetworkThatNeverComesStillGetsItsAttemptWithinTheBudget() async throws {
        server.enqueue(.json(200, "{}"))
        let sleeps = Recorder<TimeInterval>()
        #expect(try await get(transport(gate: NetworkGate { false }, sleeps: sleeps), policy: .idempotent).status == 200)
        #expect(abs(sleeps.all.reduce(0, +) - HTTPTransport.defaultNetworkWait) < 0.001)
    }

    @Test func theDecision() {
        #expect(HTTPTransport.retryable(URLError(.cannotConnectToHost), .unsentOnly))
        #expect(!HTTPTransport.retryable(URLError(.networkConnectionLost), .unsentOnly))
        #expect(HTTPTransport.retryable(URLError(.networkConnectionLost), .idempotent))
        #expect(!HTTPTransport.retryable(URLError(.timedOut), .idempotent))
        #expect(!HTTPTransport.retryable(URLError(.serverCertificateUntrusted), .idempotent))
        #expect(!HTTPTransport.retryable(URLError(.cannotFindHost), .never))
        // No internet can be reported after bytes went out (the interface dropped mid-transfer): idempotent only.
        #expect(!HTTPTransport.retryable(URLError(.notConnectedToInternet), .unsentOnly))
        #expect(HTTPTransport.retryable(URLError(.notConnectedToInternet), .idempotent))
    }

    @Test func theDevStackOriginMapKeepsPathAndQuery() async throws {
        let other = FakeHTTPServer()
        other.enqueue(.json(200, "{}"))
        let t = HTTPTransport(session: other.session, originMap: ["https://relay.example.test/": other.baseURL], sleep: { _ in })
        let a = try await t.send(policy: .idempotent, maxBody: 64) { URLRequest(url: URL(string: "https://relay.example.test/v1/mailbox?wait=1")!) }
        #expect(a.status == 200)
        #expect(other.requests[0].path == "/v1/mailbox" && other.requests[0].query == "wait=1")
    }
}

/// One answer of the collector tests' fake source.
enum SourceStep { case messages([RelayMessage]), error(Error) }

/// The mailbox collector against a fake source (vettid-android `RelayClientTest` collector cases).
@Suite struct MailboxCollectorTests {
    final class FakeSource: MailboxSource, @unchecked Sendable {
        let lock = NSLock()
        var steps: [SourceStep]
        var acks: [String] = []
        var stream: CollectStream?
        var streamOpens = 0

        init(_ steps: [SourceStep], stream: CollectStream? = nil) {
            self.steps = steps
            self.stream = stream
        }

        func collect(wait: TimeInterval, max: Int) async throws -> [RelayMessage] {
            let s: SourceStep = lock.withLock { steps.isEmpty ? .error(RelayError(status: 404, code: RelayError.mailboxUnknown)) : steps.removeFirst() }
            switch s {
            case .messages(let m): return m
            case .error(let e): throw e
            }
        }

        func ack(_ msgID: String) async throws { lock.withLock { acks.append(msgID) } }

        func openStream() throws -> CollectStream {
            try lock.withLock {
                streamOpens += 1
                guard let s = stream else { throw URLError(.cannotConnectToHost) }
                stream = nil
                return s
            }
        }
    }

    final class FakeStream: CollectStream, @unchecked Sendable {
        let messages: AsyncThrowingStream<RelayMessage, Error>
        let lock = NSLock()
        var acked: [String] = []

        init(_ m: [RelayMessage], end: Error?) {
            messages = AsyncThrowingStream { c in
                for x in m { c.yield(x) }
                c.finish(throwing: end)
            }
        }

        func ack(_ msgID: String) async -> Bool {
            lock.withLock { acked.append(msgID) }
            return true
        }

        func close() {}
    }

    static func msg(_ id: String) -> RelayMessage {
        RelayMessage(msgID: id, depositedAt: "x", sender: RelayVectorsTests.senderPub, jti: nil, payload: [1])
    }

    @Test func longPollHandlesThenAcks() async throws {
        let src = FakeSource([.messages([Self.msg("01P")])])
        let order = Recorder<String>()
        #expect(try await MailboxCollector(source: src).pollOnce { order.add("handle \($0.msgID)") } == 1)
        #expect(order.all == ["handle 01P"] && src.acks == ["01P"])
    }

    @Test func aMessageLeftForRedeliveryIsNotAcked() async throws {
        let src = FakeSource([.messages([Self.msg("01E"), Self.msg("01F")])])
        #expect(try await MailboxCollector(source: src).pollOnce { if $0.msgID == "01E" { throw LeaveUnacked("early") } } == 2)
        #expect(src.acks == ["01F"])
    }

    @Test func stopsOnTerminalErrorsAndBacksOffOnTransient() async throws {
        let e503 = RelayError(status: 503, code: RelayError.internalError)
        let src = FakeSource([.error(e503), .error(e503), .error(e503)])
        let waits = Recorder<TimeInterval>()
        await #expect(throws: RelayError(status: 404, code: RelayError.mailboxUnknown)) {
            try await MailboxCollector(source: src, sleep: { waits.add($0) }).run { _ in }
        }
        #expect(waits.all.count == 3 && waits.all.allSatisfy { $0 <= 30 })
    }

    @Test func goesOnAfterAStaleSignature() async throws {
        let src = FakeSource([.error(RelayError(status: 401, code: RelayError.timestampStale)), .messages([Self.msg("01S")])])
        let got = Recorder<String>()
        let waits = Recorder<TimeInterval>()
        await #expect(throws: RelayError.self) { try await MailboxCollector(source: src, sleep: { waits.add($0) }).run { got.add($0.msgID) } }
        #expect(got.all == ["01S"] && waits.all.count == 1 && src.acks == ["01S"])
    }

    @Test func saysWhenARequestIsOut() async throws {
        let src = FakeSource([.error(RelayError(status: 503, code: RelayError.internalError)), .messages([Self.msg("01S")])])
        let log = Recorder<String>()
        await #expect(throws: RelayError.self) {
            try await MailboxCollector(source: src, sleep: { _ in log.add("backoff") }, onRequest: { log.add($0 ? "out" : "ended") }).run { log.add("handle \($0.msgID)") }
        }
        #expect(log.all == ["out", "ended", "backoff", "out", "handle 01S", "ended", "out", "ended"])
    }

    /// (VAULT-MESSAGING 0.73.0 §3.6.5) A round that succeeds after failed ones says the relay connection is back, once.
    @Test func saysWhenTheConnectionIsBack() async throws {
        let e503 = RelayError(status: 503, code: RelayError.internalError)
        let src = FakeSource([.messages([]), .error(e503), .error(e503), .messages([Self.msg("01R")]), .messages([])])
        let log = Recorder<String>()
        await #expect(throws: RelayError.self) {
            try await MailboxCollector(source: src, sleep: { _ in }, onRecovered: { log.add("back") }).run { log.add("handle \($0.msgID)") }
        }
        #expect(log.all == ["handle 01R", "back"])
    }

    /// WebSocket: messages are handled and acked on the socket; a 4404 close ends the collector with `mailbox_unknown`.
    @Test func webSocketCollectAndAck() async throws {
        let stream = FakeStream([Self.msg("01W")], end: RelayError(status: 404, code: RelayError.mailboxUnknown))
        let src = FakeSource([], stream: stream)
        let got = Recorder<String>()
        await #expect(throws: RelayError(status: 404, code: RelayError.mailboxUnknown)) {
            try await MailboxCollector(source: src, mode: .webSocket, sleep: { _ in }).run { got.add($0.msgID) }
        }
        #expect(got.all == ["01W"] && stream.acked == ["01W"] && src.acks.isEmpty)
    }

    /// A socket that fails falls back to long-poll for the fallback period.
    @Test func aFailedSocketFallsBackToLongPoll() async throws {
        let src = FakeSource([.messages([Self.msg("01L")])])
        let got = Recorder<String>()
        await #expect(throws: RelayError.self) {
            try await MailboxCollector(source: src, mode: .webSocket, sleep: { _ in }).run { got.add($0.msgID) }
        }
        #expect(src.streamOpens == 1 && got.all == ["01L"] && src.acks == ["01L"])
    }

    @Test func theCloseCodes() {
        #expect(RelayStream.closeError(code: 1000, error: URLError(.unknown)) == nil)
        #expect(RelayStream.closeError(code: 4404, error: URLError(.unknown)) as? RelayError == RelayError(status: 404, code: RelayError.mailboxUnknown))
        #expect(RelayStream.closeError(code: 1011, error: URLError(.unknown)) is URLError)
        // A refused upgrade keeps its HTTP status.
        #expect(RelayStream.closeError(code: 0, upgradeStatus: 429, error: URLError(.badServerResponse)) as? RelayError == RelayError(status: 429, code: "http_429"))
    }

    /// A handler's own error (storage, decoding) ends the run; it is not retried as a transport failure.
    @Test func aHandlerErrorEndsTheRun() async throws {
        struct StoreFull: Error {}
        let src = FakeSource([.messages([Self.msg("01H")]), .messages([Self.msg("01I")])])
        let waits = Recorder<TimeInterval>()
        await #expect(throws: StoreFull.self) { try await MailboxCollector(source: src, sleep: { waits.add($0) }).run { _ in throw StoreFull() } }
        #expect(waits.all.isEmpty && src.acks.isEmpty)
    }
}

// swiftlint:enable line_length
