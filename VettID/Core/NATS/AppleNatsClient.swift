import Foundation
import Network
import CryptoKit
import NKeys

// MARK: - NatsTransport protocol

/// Common shape both `NatsClientWrapper` (nats.swift-backed) and
/// `AppleNatsClient` (Network.framework + SPKI pinning) conform to.
/// Lets `NatsConnectionManager` swap implementations behind a flag
/// during burn-in.
protocol NatsTransport: AnyObject {
    var endpoint: String { get }
    func connect() async throws
    func disconnect() async
    func publish(_ data: Data, to topic: String) async throws
    func request(_ subject: String, payload: Data, timeout: TimeInterval) async throws -> Data
    func subscribe(to topic: String) async throws -> AsyncStream<NatsMessage>
    func unsubscribe(from topic: String) async
}

// MARK: - Apple NATS Client (#11)

/// Homegrown NATS client built on `Network.framework`'s `NWConnection`.
///
/// **Why this exists**: `nats-io/nats.swift` doesn't expose a TLS-verifier
/// hook, so SPKI pinning against the same Amazon-issued pin set we use for
/// HTTPS isn't possible through that library. Android worked around this by
/// rolling its own NATS client on raw `SSLSocket` (~600 lines in
/// `AndroidNatsClient.kt`); this is the iOS equivalent.
///
/// The TLS handshake is performed by Apple's `Network.framework` which,
/// crucially, accepts a `sec_protocol_options_set_verify_block` callback
/// that lets us veto the chain after Apple has done normal trust evaluation.
/// We use that hook to require at least one certificate in the chain whose
/// SPKI hash matches a pinned value — same algorithm
/// (`SHA-256(DER SubjectPublicKeyInfo)` → base64) as the HTTPS pins.
///
/// Conforms to the same public shape as `NatsClientWrapper` (the old
/// `nats.swift`-backed wrapper) so the surrounding code can swap one for
/// the other behind a feature flag while we burn in.
///
/// **Protocol surface implemented**
///   • CONNECT — NKey auth: sign the server's nonce with the user's seed
///   • PUB — basic publish
///   • SUB / UNSUB — subscriptions keyed by integer SID
///   • PING / PONG — keepalive
///   • Request-reply — auto-generated `_INBOX.<nuid>` reply subjects
///
/// **Wire format**: NATS speaks newline-delimited text commands followed by
/// `\r\n`-bounded payload blocks. We parse incrementally out of a rolling
/// `Data` buffer; we don't try to decode UTF-8 until we know the payload
/// bytes are payload (not control bytes).
///
/// **Threading**: NWConnection's callbacks fire on a dedicated dispatch
/// queue. State that callers mutate (subscriptions, pending requests) lives
/// behind a `DispatchQueue` so we don't need actor isolation for the
/// protocol layer. Public methods are `async` so callers feel like they're
/// talking to an actor anyway.
final class AppleNatsClient: NatsTransport {

    // MARK: - Public surface (parity with NatsClientWrapper)

    let endpoint: String
    private let jwt: String
    private let seed: String

    init(endpoint: String, jwt: String, seed: String) {
        self.endpoint = endpoint
        self.jwt = jwt
        self.seed = seed
    }

    deinit {
        // Best-effort tear-down. Callers should invoke disconnect() before
        // releasing the client; this just guards against leaks if they
        // don't. NWConnection.cancel is thread-safe and idempotent.
        connection?.cancel()
    }

    // MARK: - Internal state

    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "vettid.nats.connection")
    private let stateQueue = DispatchQueue(label: "vettid.nats.state")
    private var serverInfo: ServerInfo?

    /// Rolling read buffer. Filled by `NWConnection.receive` callbacks;
    /// drained one NATS frame at a time. Mutated only on `queue`.
    private var readBuffer = Data()

    /// SID → continuation. Multiple subscriptions on the same subject
    /// each get a unique SID. Mutated only on `stateQueue`.
    private var subscriptions: [Int: AsyncStream<NatsMessage>.Continuation] = [:]
    private var subscriptionTopics: [Int: String] = [:]
    private var nextSid: Int = 1

    /// Reply inbox → continuation. Request-reply uses `_INBOX.<nuid>.<rid>`
    /// subjects so we can demultiplex multiple in-flight requests on a
    /// single shared `_INBOX.<nuid>.>` wildcard subscription.
    private var inboxSubject: String?
    private var pendingRequests: [String: CheckedContinuation<Data, Error>] = [:]

    /// Continuation waiting for the very first `+OK` (or `-ERR`) that
    /// follows CONNECT, so `connect()` can return success/failure
    /// synchronously.
    private var connectAck: CheckedContinuation<Void, Error>?

    // MARK: - Connect / disconnect

    /// Resolve, TLS-handshake-with-pin, and complete the NATS protocol
    /// handshake (read INFO → send CONNECT → wait for +OK).
    func connect() async throws {
        guard let (host, port) = Self.parseEndpoint(endpoint) else {
            throw NatsConnectionError.connectionFailed("Invalid endpoint URL: \(endpoint)")
        }

        let tlsOptions = NWProtocolTLS.Options()
        configureTLS(tlsOptions, hostname: host)

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.connectionTimeout = 15
        tcpOptions.keepaliveIdle = 30
        tcpOptions.keepaliveCount = 3
        tcpOptions.keepaliveInterval = 10

        let params = NWParameters(tls: tlsOptions, tcp: tcpOptions)
        params.allowLocalEndpointReuse = false
        params.includePeerToPeer = false

        let nwHost = NWEndpoint.Host(host)
        let nwPort = NWEndpoint.Port(rawValue: port) ?? NWEndpoint.Port(integerLiteral: 4222)
        let conn = NWConnection(host: nwHost, port: nwPort, using: params)
        self.connection = conn

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            // The NATS handshake races against TLS bring-up:
            //   1. NWConnection reaches .ready (TLS handshake passed pin check)
            //   2. Server sends INFO over the wire
            //   3. We sign INFO.nonce with the NKey seed and send CONNECT
            //   4. Server replies with +OK (or -ERR)
            // We store `cont` as `connectAck` and resume it when step 4
            // arrives. .ready on its own isn't enough — TLS up doesn't
            // mean NATS auth succeeded.
            stateQueue.async { self.connectAck = cont }

            conn.stateUpdateHandler = { [weak self] state in
                self?.handleConnectionState(state)
            }
            conn.start(queue: self.queue)
        }
    }

    /// Cancel the connection and drain all pending state.
    func disconnect() async {
        connection?.cancel()
        connection = nil

        stateQueue.sync {
            // Fail any in-flight request continuations so callers don't hang.
            for (_, cont) in pendingRequests {
                cont.resume(throwing: NatsConnectionError.notConnected)
            }
            pendingRequests.removeAll()
            // Close all subscription streams; consumers will exit their
            // for-await loops cleanly.
            for (_, sub) in subscriptions { sub.finish() }
            subscriptions.removeAll()
            subscriptionTopics.removeAll()
            inboxSubject = nil
        }
    }

    // MARK: - Publish

    func publish(_ data: Data, to topic: String) async throws {
        try await send(serializePub(subject: topic, replyTo: nil, payload: data))
    }

    // MARK: - Request / reply

    /// Publish to `subject` with a reply-to inbox and wait for the first
    /// message that lands on that inbox. The inbox subscription is
    /// lazily established on first request and shared across all
    /// subsequent requests via a wildcard SID.
    func request(_ subject: String, payload: Data, timeout: TimeInterval = 30) async throws -> Data {
        try await ensureInboxSubscription()
        guard let inbox = stateQueue.sync(execute: { self.inboxSubject }) else {
            throw NatsConnectionError.notConnected
        }
        let rid = Self.nuid()
        let reply = "\(inbox).\(rid)"

        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                    self.stateQueue.async {
                        self.pendingRequests[reply] = cont
                    }
                    Task {
                        do {
                            try await self.send(self.serializePub(subject: subject,
                                                                  replyTo: reply,
                                                                  payload: payload))
                        } catch {
                            self.stateQueue.async {
                                if let pending = self.pendingRequests.removeValue(forKey: reply) {
                                    pending.resume(throwing: error)
                                }
                            }
                        }
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self.stateQueue.async {
                    if let pending = self.pendingRequests.removeValue(forKey: reply) {
                        pending.resume(throwing: NatsConnectionError.connectionFailed("Request timeout"))
                    }
                }
                throw NatsConnectionError.connectionFailed("Request timeout")
            }
            guard let first = try await group.next() else {
                throw NatsConnectionError.connectionFailed("Request returned no result")
            }
            group.cancelAll()
            return first
        }
    }

    private func ensureInboxSubscription() async throws {
        let needed: Bool = stateQueue.sync { self.inboxSubject == nil }
        guard needed else { return }
        let inbox = "_INBOX.\(Self.nuid())"
        let sid = stateQueue.sync {
            let s = self.nextSid
            self.nextSid += 1
            self.inboxSubject = inbox
            // Reserve the SID for the wildcard but don't put a
            // subscription stream against it — request-reply is
            // dispatched via `pendingRequests` lookup, not the stream.
            self.subscriptionTopics[s] = "\(inbox).>"
            return s
        }
        try await send("SUB \(inbox).> \(sid)\r\n".data(using: .utf8)!)
    }

    // MARK: - Subscribe / unsubscribe

    func subscribe(to topic: String) async throws -> AsyncStream<NatsMessage> {
        let (stream, cont) = makeStream()
        let sid = stateQueue.sync { () -> Int in
            let s = self.nextSid
            self.nextSid += 1
            self.subscriptions[s] = cont
            self.subscriptionTopics[s] = topic
            return s
        }
        try await send("SUB \(topic) \(sid)\r\n".data(using: .utf8)!)
        cont.onTermination = { [weak self] _ in
            self?.unsubscribeBySid(sid)
        }
        return stream
    }

    func unsubscribe(from topic: String) async {
        // Find every SID bound to this topic and tear them all down.
        // Multiple subscriptions to the same subject are uncommon but
        // legal in NATS, so don't assume one-to-one.
        let sids = stateQueue.sync {
            self.subscriptionTopics.compactMap { $0.value == topic ? $0.key : nil }
        }
        for sid in sids {
            unsubscribeBySid(sid)
            try? await send("UNSUB \(sid)\r\n".data(using: .utf8)!)
        }
    }

    private func unsubscribeBySid(_ sid: Int) {
        stateQueue.sync {
            if let cont = self.subscriptions.removeValue(forKey: sid) {
                cont.finish()
            }
            self.subscriptionTopics.removeValue(forKey: sid)
        }
    }

    // MARK: - Connection state machine

    private func handleConnectionState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            startReceiveLoop()
            // NATS server speaks first with INFO; we wait for it.
        case .failed(let error):
            #if DEBUG
            print("[AppleNatsClient] NWConnection failed: \(error)")
            #endif
            stateQueue.async {
                if let ack = self.connectAck {
                    self.connectAck = nil
                    ack.resume(throwing: NatsConnectionError.connectionFailed("\(error)"))
                }
            }
        case .cancelled:
            stateQueue.async {
                if let ack = self.connectAck {
                    self.connectAck = nil
                    ack.resume(throwing: NatsConnectionError.notConnected)
                }
            }
        case .waiting(let error):
            #if DEBUG
            print("[AppleNatsClient] NWConnection waiting: \(error)")
            #endif
        case .preparing, .setup:
            break
        @unknown default:
            break
        }
    }

    // MARK: - Read loop

    private func startReceiveLoop() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let error = error {
                #if DEBUG
                print("[AppleNatsClient] receive error: \(error)")
                #endif
                self.handleSocketTermination()
                return
            }
            if let data = data, !data.isEmpty {
                self.queue.async {
                    self.readBuffer.append(data)
                    self.drainFrames()
                }
            }
            if isComplete {
                self.handleSocketTermination()
                return
            }
            // Continue reading. The recursion happens on `self.queue`
            // (the NWConnection's queue) so we don't blow the Swift
            // stack — each call returns immediately after scheduling.
            self.startReceiveLoop()
        }
    }

    private func handleSocketTermination() {
        stateQueue.async {
            if let ack = self.connectAck {
                self.connectAck = nil
                ack.resume(throwing: NatsConnectionError.notConnected)
            }
            for (_, cont) in self.pendingRequests {
                cont.resume(throwing: NatsConnectionError.notConnected)
            }
            self.pendingRequests.removeAll()
            for (_, sub) in self.subscriptions { sub.finish() }
            self.subscriptions.removeAll()
            self.subscriptionTopics.removeAll()
            self.inboxSubject = nil
        }
    }

    /// Try to peel one full frame off the buffer; loop until we can't.
    /// Each NATS frame is either:
    ///   • A control line ending in `\r\n` (PING, PONG, +OK, -ERR, INFO, MSG-header, HMSG-header)
    ///   • A control line followed by a payload of known length + trailing `\r\n`
    private func drainFrames() {
        while true {
            guard let lineEnd = readBuffer.range(of: Data([0x0d, 0x0a])) else { return }
            let lineData = readBuffer.subdata(in: 0..<lineEnd.lowerBound)
            guard let line = String(data: lineData, encoding: .utf8) else {
                // Corrupt line — drop everything up to and including the
                // bad terminator and try to resynchronize. Better than
                // wedging the client on one bad byte.
                readBuffer.removeSubrange(0..<lineEnd.upperBound)
                continue
            }
            let consumedLineLength = lineEnd.upperBound

            if line.hasPrefix("MSG ") {
                // MSG <subject> <sid> [reply-to] <#bytes>
                let parts = line.dropFirst(4).split(separator: " ").map(String.init)
                guard parts.count >= 3, parts.count <= 4,
                      let sid = Int(parts[1]),
                      let payloadLen = Int(parts.last!) else {
                    readBuffer.removeSubrange(0..<consumedLineLength)
                    continue
                }
                let subject = parts[0]
                let replyTo: String? = parts.count == 4 ? parts[2] : nil
                let needed = consumedLineLength + payloadLen + 2 // payload + \r\n
                guard readBuffer.count >= needed else { return } // wait for more
                let payload = readBuffer.subdata(in: consumedLineLength..<(consumedLineLength + payloadLen))
                readBuffer.removeSubrange(0..<needed)
                dispatchMessage(sid: sid, subject: subject, replyTo: replyTo, payload: payload, headers: nil)
                continue
            }

            if line.hasPrefix("HMSG ") {
                // HMSG <subject> <sid> [reply-to] <#header-bytes> <#total-bytes>
                let parts = line.dropFirst(5).split(separator: " ").map(String.init)
                guard parts.count >= 4, parts.count <= 5,
                      let sid = Int(parts[1]),
                      let headerLen = Int(parts[parts.count - 2]),
                      let totalLen  = Int(parts.last!),
                      totalLen >= headerLen else {
                    readBuffer.removeSubrange(0..<consumedLineLength)
                    continue
                }
                let subject = parts[0]
                let replyTo: String? = parts.count == 5 ? parts[2] : nil
                let needed = consumedLineLength + totalLen + 2
                guard readBuffer.count >= needed else { return }
                let headerBytes = readBuffer.subdata(in: consumedLineLength..<(consumedLineLength + headerLen))
                let payloadBytes = readBuffer.subdata(in: (consumedLineLength + headerLen)..<(consumedLineLength + totalLen))
                readBuffer.removeSubrange(0..<needed)
                let headers = Self.parseHeaders(headerBytes)
                dispatchMessage(sid: sid, subject: subject, replyTo: replyTo, payload: payloadBytes, headers: headers)
                continue
            }

            // Single-line control commands.
            readBuffer.removeSubrange(0..<consumedLineLength)
            switch line {
            case "PING":
                // Server keepalive; echo PONG back.
                Task { try? await self.send("PONG\r\n".data(using: .utf8)!) }
            case "PONG":
                // We piggyback a PING onto CONNECT in `handleInfo`. The
                // server's PONG reply means auth + handshake succeeded
                // — that's what unblocks the connectAck continuation.
                // With verbose=false the server never sends +OK, so PONG
                // is the only positive ack we get. Subsequent PONGs are
                // just keepalive responses; the nil-check makes them
                // harmless no-ops.
                stateQueue.async {
                    if let ack = self.connectAck {
                        self.connectAck = nil
                        ack.resume()
                    }
                }
            case "+OK":
                // Only emitted when `verbose: true` (which we don't
                // request). Treat as a no-op for forward compat.
                break
            default:
                if line.hasPrefix("INFO ") {
                    handleInfo(jsonString: String(line.dropFirst(5)))
                } else if line.hasPrefix("-ERR ") {
                    let reason = String(line.dropFirst(5)).trimmingCharacters(in: CharacterSet(charactersIn: "'"))
                    #if DEBUG
                    print("[AppleNatsClient] server -ERR: \(reason)")
                    #endif
                    stateQueue.async {
                        if let ack = self.connectAck {
                            self.connectAck = nil
                            ack.resume(throwing: NatsConnectionError.connectionFailed("Server -ERR: \(reason)"))
                        }
                    }
                }
            }
        }
    }

    private func dispatchMessage(sid: Int,
                                 subject: String,
                                 replyTo: String?,
                                 payload: Data,
                                 headers: [String: String]?) {
        // Request-reply path: messages arriving on the inbox wildcard
        // demultiplex via pendingRequests keyed by full reply subject.
        stateQueue.sync {
            if let pending = self.pendingRequests.removeValue(forKey: subject) {
                pending.resume(returning: payload)
                return
            }
            if let cont = self.subscriptions[sid] {
                cont.yield(NatsMessage(topic: subject, data: payload, headers: headers))
            }
        }
    }

    private func handleInfo(jsonString: String) {
        guard let data = jsonString.data(using: .utf8),
              let info = try? JSONDecoder().decode(ServerInfo.self, from: data) else {
            stateQueue.async {
                if let ack = self.connectAck {
                    self.connectAck = nil
                    ack.resume(throwing: NatsConnectionError.connectionFailed("Failed to parse server INFO"))
                }
            }
            return
        }
        serverInfo = info

        // Build CONNECT. Sign the server's nonce with the user's seed
        // — NATS treats the (jwt, sig) pair as proof of identity.
        let connect: ConnectCommand
        do {
            connect = try buildConnect(nonce: info.nonce ?? "")
        } catch {
            stateQueue.async {
                if let ack = self.connectAck {
                    self.connectAck = nil
                    ack.resume(throwing: NatsConnectionError.connectionFailed("CONNECT build failed: \(error)"))
                }
            }
            return
        }

        do {
            let json = try JSONEncoder().encode(connect)
            guard let jsonStr = String(data: json, encoding: .utf8) else {
                throw NatsConnectionError.connectionFailed("CONNECT JSON encode failed")
            }
            Task {
                try? await self.send("CONNECT \(jsonStr)\r\nPING\r\n".data(using: .utf8)!)
            }
        } catch {
            stateQueue.async {
                if let ack = self.connectAck {
                    self.connectAck = nil
                    ack.resume(throwing: error)
                }
            }
        }
    }

    private func buildConnect(nonce: String) throws -> ConnectCommand {
        let kp = try KeyPair(seed: seed)
        let sig: String
        if !nonce.isEmpty {
            let signature = try kp.sign(input: Data(nonce.utf8))
            sig = Self.base64URLEncode(signature)
        } else {
            sig = ""
        }
        // nkeys.swift `publicKeyEncoded` already produces the canonical
        // base32 form with prefix byte + CRC16, which is exactly what
        // NATS expects for `CONNECT.nkey`.
        let pubKey = kp.publicKeyEncoded
        return ConnectCommand(
            verbose: false,
            pedantic: false,
            tls_required: true,
            lang: "swift",
            version: "1.0.0",
            jwt: jwt,
            sig: sig.isEmpty ? nil : sig,
            nkey: pubKey
        )
    }

    // MARK: - Wire serialization

    private func serializePub(subject: String, replyTo: String?, payload: Data) -> Data {
        var head = "PUB \(subject)"
        if let r = replyTo { head += " \(r)" }
        head += " \(payload.count)\r\n"
        var out = Data(head.utf8)
        out.append(payload)
        out.append(0x0d) // \r
        out.append(0x0a) // \n
        return out
    }

    private func send(_ data: Data) async throws {
        guard let conn = connection else {
            throw NatsConnectionError.notConnected
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { error in
                if let error = error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            })
        }
    }

    // MARK: - TLS configuration + SPKI pinning

    /// Configures `tlsOptions` with our pinned SPKI verify block. Apple's
    /// default trust evaluation still runs first (CA chain validity,
    /// expiry, hostname); the verify block only authorizes the chain if
    /// at least one cert's SPKI hash matches a pinned value. This
    /// matches the HTTPS pin set in `CertificatePinningDelegate`.
    private func configureTLS(_ tlsOptions: NWProtocolTLS.Options, hostname: String) {
        let secOptions = tlsOptions.securityProtocolOptions

        // Require TLS 1.2 or higher — never negotiate down to 1.0 / 1.1.
        sec_protocol_options_set_min_tls_protocol_version(secOptions, .TLSv12)
        // Set SNI so the server picks the right cert.
        sec_protocol_options_set_tls_server_name(secOptions, hostname)

        let pins = Self.spkiPins
        sec_protocol_options_set_verify_block(
            secOptions,
            { _, sec_trust, complete in
                let trust = sec_trust_copy_ref(sec_trust).takeRetainedValue()
                SecTrustEvaluateAsyncWithError(trust, DispatchQueue.global()) { trust, ok, error in
                    guard ok else {
                        #if DEBUG
                        print("[AppleNatsClient] system trust failed: \(error?.localizedDescription ?? "?")")
                        #endif
                        complete(false)
                        return
                    }
                    let count = SecTrustGetCertificateCount(trust)
                    var matched = false
                    let chainCerts = SecTrustCopyCertificateChain(trust) as? [SecCertificate] ?? []
                    let chain: [SecCertificate]
                    if !chainCerts.isEmpty {
                        chain = chainCerts
                    } else {
                        // Fallback for very old iOS — SecTrustGetCertificateAtIndex
                        // is deprecated but still works.
                        chain = (0..<count).compactMap { idx -> SecCertificate? in
                            SecTrustGetCertificateAtIndex(trust, idx)
                        }
                    }
                    for cert in chain {
                        guard let publicKey = SecCertificateCopyKey(cert),
                              let hash = CertificatePinningDelegate.spkiSHA256Base64(for: publicKey) else {
                            continue
                        }
                        if pins.contains(hash) {
                            matched = true
                            break
                        }
                    }
                    #if DEBUG
                    if !matched {
                        print("[AppleNatsClient] NATS TLS chain didn't match any pinned SPKI; failing handshake")
                        for cert in chain {
                            if let publicKey = SecCertificateCopyKey(cert),
                               let hash = CertificatePinningDelegate.spkiSHA256Base64(for: publicKey) {
                                print("  chain SPKI: \(hash)")
                            }
                        }
                    }
                    #endif
                    complete(matched)
                }
            },
            DispatchQueue.global()
        )
    }

    /// Pinned SPKI set — matches Android's `verifyNatsCertificateChain`
    /// in `AndroidNatsClient.kt`. Pins to the Amazon RSA 2048 M04
    /// intermediate the NATS endpoint serves, plus the Amazon Root CA 1
    /// fallback so an intermediate rotation doesn't lock users out
    /// instantly.
    static let spkiPins: Set<String> = [
        "G9LNNAql897egYsabashkzUCTEJkWBzgoEtk8X/678c=", // Amazon RSA 2048 M04
        "++MBgDH5WGvL9Bcn5Be30cRcL0f5O+NyoXuWtQdX1aI=", // Amazon Root CA 1
    ]

    // MARK: - Helpers

    /// Parse `tls://host:port` / `nats://host:port` / `host:port` /
    /// `host` (default port 4222).
    private static func parseEndpoint(_ endpoint: String) -> (host: String, port: UInt16)? {
        var stripped = endpoint
        if let schemeEnd = endpoint.range(of: "://") {
            stripped = String(endpoint[schemeEnd.upperBound...])
        }
        if let colon = stripped.firstIndex(of: ":") {
            let host = String(stripped[..<colon])
            let portStr = String(stripped[stripped.index(after: colon)...])
            // Strip trailing path if present.
            let portClean = portStr.split(separator: "/").first.map(String.init) ?? portStr
            guard let port = UInt16(portClean) else { return nil }
            return (host, port)
        }
        return (stripped, 4222)
    }

    /// Base64URL encode (no padding). RFC 4648 §5 — NATS sig is base64url
    /// not standard base64, otherwise the server rejects `=` / `+` / `/`.
    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// 12-character random ID used for inbox subjects and request IDs.
    /// Doesn't need crypto strength — just collision avoidance — but we
    /// pull from SecRandom anyway since it's already available.
    private static func nuid() -> String {
        let chars = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        var bytes = [UInt8](repeating: 0, count: 12)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return String(bytes.map { chars[Int($0) % chars.count] })
    }

    private static func parseHeaders(_ raw: Data) -> [String: String]? {
        guard let text = String(data: raw, encoding: .utf8) else { return nil }
        var result: [String: String] = [:]
        for line in text.split(separator: "\r\n", omittingEmptySubsequences: true) {
            // Skip the leading "NATS/1.0" status line.
            if line.hasPrefix("NATS/1.0") { continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            result[key] = value
        }
        return result.isEmpty ? nil : result
    }

    private func makeStream() -> (AsyncStream<NatsMessage>, AsyncStream<NatsMessage>.Continuation) {
        var stored: AsyncStream<NatsMessage>.Continuation!
        let stream = AsyncStream<NatsMessage> { cont in stored = cont }
        return (stream, stored)
    }
}

// MARK: - Wire types

/// Subset of the server INFO frame we care about. NATS streams a much
/// bigger object (server id, version, max payload, cluster info, …) —
/// we only need `nonce` to sign, and `tls_required` is informational
/// because we already require TLS.
private struct ServerInfo: Decodable {
    let nonce: String?
    let server_id: String?
    let version: String?
    let max_payload: Int?
    let tls_required: Bool?
}

/// CONNECT command shape. Mandatory fields: verbose, pedantic, tls_required,
/// lang, version. NKey auth fills `nkey` + `sig`; JWT auth adds `jwt`.
private struct ConnectCommand: Encodable {
    let verbose: Bool
    let pedantic: Bool
    let tls_required: Bool
    let lang: String
    let version: String
    let jwt: String?
    let sig: String?
    let nkey: String?
}

