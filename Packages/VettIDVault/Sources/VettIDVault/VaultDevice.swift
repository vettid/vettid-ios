import Foundation
import VettIDAltChan
import VettIDCrypto
import VettIDRelay

/// Checks vault.enrolled's attestation document (§11.3): nonce = the app's enroll nonce, user_data over the vault
/// bundle, the enrollment's measurements (PCR0, PCR1, PCR2) and freshness at [now]. The app passes VettIDAttestation's
/// `EnclaveVerifier.verifyEnrolled` with the pinned Nitro root; throws when the document does not pass.
public typealias EnrolledAttestationCheck = @Sendable (
    _ attestation: [UInt8], _ vaultBundle: [UInt8], _ nonce: [UInt8], _ pcrs: EnrolledPCRs, _ now: Date
) throws -> Void

/// PCR0–PCR2 of the enclave an enrollment was sealed to (lowercase hex).
public struct EnrolledPCRs: Equatable, Sendable {
    public let pcr0: String
    public let pcr1: String
    public let pcr2: String
}

/// How vault.enrolled's attestation is checked (§11.3). Required, without a default: an app that forgot it would accept
/// a vault.enrolled built by anyone who knows its KEM public key.
public enum EnrolledAttestation: Sendable {
    /// The app and the dev stack: VettIDAttestation's `EnclaveVerifier.verifyEnrolled` with the pinned Nitro root.
    case verify(EnrolledAttestationCheck)
    #if DEBUG
    /// TEST ONLY (debug builds): in-process tests without an enclave.
    case skipForTests
    #endif
}

/// How a device is set up.
public struct DeviceConfig: Sendable {
    public static let roleApp = "app"
    /// Interactive requests time out after 30 s (§8.1); a request is re-sent with the same inner id at most twice (§8.6).
    public static let defaultTimeout: TimeInterval = 30

    public let role: String
    /// The name the vault shows for this device (`profile.name`).
    public let name: String
    /// The device's own relay base URL, as tokens name it (`aud`).
    public let relayURL: String
    public let transport: HTTPTransport
    public let store: DeviceStateStore
    /// vault.enrolled's attestation check (§11.3).
    public let enrolledAttestation: EnrolledAttestation
    public let now: @Sendable () -> Date
    public let collectMode: MailboxCollector.Mode
    public let pollWait: TimeInterval
    public let requestTimeout: TimeInterval

    public init(
        role: String = roleApp,
        name: String,
        relayURL: String,
        transport: HTTPTransport,
        store: DeviceStateStore,
        enrolledAttestation: EnrolledAttestation,
        now: @escaping @Sendable () -> Date = { Date() },
        collectMode: MailboxCollector.Mode = .longPoll,
        pollWait: TimeInterval = RelayClient.defaultWait,
        requestTimeout: TimeInterval = defaultTimeout
    ) {
        self.role = role
        self.name = name
        self.relayURL = relayURL.hasSuffix("/") ? String(relayURL.dropLast()) : relayURL
        self.transport = transport
        self.store = store
        self.enrolledAttestation = enrolledAttestation
        self.now = now
        self.collectMode = collectMode
        self.pollWait = pollWait
        self.requestTimeout = requestTimeout
    }
}

/// One owner device of a vault (VAULT-MESSAGING §6.7, §9.1, §11.3), the counterpart of vettid-vault's reference
/// `client.Device` and vettid-android `VaultDevice`.
///
/// - ``start()`` runs the collector on the device's own mailbox: every message is deduplicated by msg_id, classified
///   only by sender and recipient kid (§13.6), decrypted, applied and persisted before the relay ack (§8.3).
/// - Responses complete the request that awaits them; events go to ``events()`` and to an inbox that
///   ``awaitEvent(_:timeout:match:)`` searches first.
/// - Outgoing messages are sealed in the current epoch and kept in a persisted outbox until the relay accepts them; a
///   request that gets no answer is re-sent with the same inner id at most twice (§8.6).
/// - Tokens are refreshed in both directions (§7.2), vault-initiated rekeys answered (§6.5) and identity rotations
///   followed (§3.4).
///
/// Persisted with the device state: the keyring, the outbox and the vault's rekeys awaiting their `hs.fin`. Not
/// persisted: an in-flight first handshake (a restart before device.paired repeats ``completeEnrollment(timeout:)``).
///
/// Concurrency: ``lock`` serializes every operation on the state across suspension points (as Android's `Mutex`);
/// ``mem`` guards the in-memory fields for the short synchronous reads and writes, never across a suspension.
public final class VaultDevice: @unchecked Sendable {
    static let typeHsInit = "hs.init"
    static let typePairRejected = "device.pair.rejected"
    /// §10.1 (0.13.0): the vault is past its owner-check deadline (§3.6.3).
    public static let codeOwnerCheckRequired = "owner_check_required"
    static let inboxMax = 500
    static let pcrHex = 96
    static let appRetries = 2
    static let openTokenTTL: TimeInterval = 600
    public static let awaitDefault: TimeInterval = 90
    static let seenRetention: TimeInterval = 16 * 86_400
    /// How long a rekey waits for its hs.fin (vettid-vault `HandshakeTTL`).
    static let handshakeTTL: TimeInterval = 16 * 86_400
    static let maxAwaiting = 8
    static let issueBefore: TimeInterval = 10 * 86_400
    static let refreshBefore: TimeInterval = 3 * 86_400

    let cfg: DeviceConfig
    let secrets: DeviceSecrets
    let st: DeviceState
    let lock = AsyncLock()
    let mem = NSLock()
    let own: RelayClient
    var relays: [String: RelayClient] = [:]
    var keyring: Keyring
    var ini: Initiator?

    /// A vault rekey this device answered (`hs.resp` sent), awaiting its `hs.fin` (§6.5).
    struct Awaiting {
        let resp: Responder
        let createdMs: Int64
    }

    var awaiting: [Awaiting] = []
    /// The unlock built and not yet answered (§11.4): what its result is opened and applied with.
    var pendingUnlock: PendingUnlock?
    var pending: [String: OneShot<Inner>] = [:]
    var inbox: [VaultMessage] = []
    var inboxWaiters: [OneShot<Bool>] = []
    let eventBroadcast = Broadcast<VaultMessage>()
    let timeDropBroadcast = Broadcast<String>()
    let ownerCheckBroadcast = Broadcast<String>()
    var isPaired: Bool
    var sas: String?
    var refusals = 0
    var collector: Task<Void, Never>?
    var collectEnded: String?
    var collectSince: Date?
    var stopped = true
    /// Set by ``forget()``: nothing is written to the store any more.
    var forgotten = false

    init(cfg: DeviceConfig, secrets: DeviceSecrets, st: DeviceState) throws {
        self.cfg = cfg
        self.secrets = secrets
        self.st = st
        own = RelayClient(baseURL: cfg.relayURL, key: secrets.relay, transport: cfg.transport, now: cfg.now)
        if let s = st.vault?.sessions, !s.isEmpty {
            keyring = try Keyring.import(try Base64s.decodeStd(s))
        } else {
            keyring = Keyring()
        }
        isPaired = st.deviceID != nil
        awaiting = restoreAwaiting()
    }

    /// A new device with fresh state; registers its mailbox on its relay.
    public static func create(_ cfg: DeviceConfig, secrets: DeviceSecrets) async throws -> VaultDevice {
        let d = try VaultDevice(cfg: cfg, secrets: secrets, st: DeviceState(role: cfg.role, name: cfg.name, relayURL: cfg.relayURL))
        _ = try await d.own.register()
        try d.save()
        return d
    }

    /// Restores a device from its store; nil if the store is empty.
    public static func load(_ cfg: DeviceConfig, secrets: DeviceSecrets) throws -> VaultDevice? {
        guard let b = try cfg.store.load() else { return nil }
        return try VaultDevice(cfg: cfg, secrets: secrets, st: JSONDecoder().decode(DeviceState.self, from: Data(b)))
    }

    // MARK: - Observed state

    /// Every event from the vault (no responses), as it arrives.
    public func events() -> AsyncStream<VaultMessage> { eventBroadcast.stream() }

    /// The types of authenticated messages dropped for their time by this phone's clock (expired, or from the future).
    public func droppedForTime() -> AsyncStream<String> { timeDropBroadcast.stream() }

    /// The types of requests the vault answered `owner_check_required` (§3.6.3, 0.13.0).
    public func ownerCheckRequired() -> AsyncStream<String> { ownerCheckBroadcast.stream() }

    /// True once device.paired arrived: the session with the vault is up.
    public var paired: Bool { mem.withLock { isPaired } }
    public var vaultID: String? { mem.withLock { st.vaultID } }
    public var deviceID: String? { mem.withLock { st.deviceID } }
    public var name: String { mem.withLock { st.name } }
    /// True when the device has pinned a vault (enrolled, recovering after its unlock, or pairing).
    public var hasVault: Bool { mem.withLock { st.vault != nil } }
    /// True while this app recovers a vault (§11.11).
    public var recovering: Bool { mem.withLock { st.recovery != nil } }
    /// The SAS of the pairing handshake in progress (§6.3): set once the vault's `hs.resp` checked out.
    public var pairingSas: String? { mem.withLock { sas } }
    /// Deposits to the vault's mailbox under the vault's current token that the relay refused with `token_revoked`
    /// since the vault last spoke to this device (§7.4: a vault that removed this device denylists it). Not
    /// authenticated (the relay says so): never proof of anything.
    public var vaultRefusals: Int { mem.withLock { refusals } }
    /// The relay error code that ended the last collection, or nil while it runs or never ended.
    public var collectionEnded: String? { mem.withLock { collectEnded } }
    /// Whether the mailbox collector runs.
    public var collecting: Bool { mem.withLock { collector != nil && collectEnded == nil && !stopped } }
    /// When the collection's current relay request went out, nil while none is out.
    public var collectRequestSince: Date? { mem.withLock { collectSince } }
    /// This device's relay address (§6.2).
    public var relayAddr: RelayAddr {
        RelayAddr(url: cfg.relayURL, mailbox: RelayAuth.mailboxID(secrets.relay.publicKey), pk: secrets.relay.publicKey)
    }
    /// The device's identity public key.
    public var identityKey: [UInt8] { secrets.identity.publicKey }
    public var kemKey: KemPublicKey { secrets.kem.publicKey }
    /// A copy of the alternate-channel state.
    public var altState: AltState { mem.withLock { alt() } }
    /// UTKs held (tests, diagnostics).
    public var utkCount: Int { mem.withLock { st.utks.count } }
    /// The credential version this app holds, or nil.
    public var credentialVersion: Int64? { mem.withLock { st.credential?.version } }

    /// Starts [vaultRefusals] again (after a sealed unlock result: the enclave knows this device).
    public func clearVaultRefusals() { mem.withLock { refusals = 0 } }

    // MARK: - Helpers (callers hold ``mem`` where they touch state)

    func now() -> Date { cfg.now() }

    static func ms(_ t: Date) -> Int64 { Int64((t.timeIntervalSince1970 * 1000).rounded(.down)) }

    func relayFor(_ url: String) -> RelayClient {
        let key = url.hasSuffix("/") ? String(url.dropLast()) : url
        if key == cfg.relayURL { return own }
        return mem.withLock {
            if let r = relays[key] { return r }
            let r = RelayClient(baseURL: key, key: secrets.relay, transport: cfg.transport, now: cfg.now)
            relays[key] = r
            return r
        }
    }

    func alt() -> AltState {
        guard let s = st.alt, let o = try? StrictJson.parseObject(Array(s.utf8)), let a = try? AltState.parse(o) else { return AltState() }
        return a
    }

    func setAlt(_ a: AltState) { st.alt = a.marshal() }

    func requireVault() throws -> VaultRecord {
        guard let v = st.vault else { throw VaultStateError(message: "not paired with a vault") }
        return v
    }

    // MARK: - Persistence

    /// Writes the state (with the keyring and the awaiting rekeys) to the store. Callers hold ``lock``.
    func save() throws {
        let data: Data? = try mem.withLock {
            if forgotten { return nil }
            if st.vault != nil {
                st.vault?.sessions = Base64s.encodeStd(try keyring.export())
                st.vault?.awaiting = awaiting.compactMap { a in
                    // A responder that is done (aborted) has nothing left to keep.
                    (try? a.resp.export()).map { AwaitingRekey(createdMs: a.createdMs, state: Base64s.encodeStd($0)) }
                }
            }
            return try JSONEncoder().encode(st)
        }
        if let data { try cfg.store.save(Array(data)) }
    }

    /// The persisted rekeys awaiting `hs.fin`; one that does not restore or is past ``handshakeTTL`` is dropped.
    func restoreAwaiting() -> [Awaiting] {
        let cutoff = Self.ms(now().addingTimeInterval(-Self.handshakeTTL))
        return (st.vault?.awaiting ?? []).filter { $0.createdMs >= cutoff }.compactMap { a in
            guard let b = try? Base64s.decodeStd(a.state), let r = try? Responder.import(b) else { return nil }
            return Awaiting(resp: r, createdMs: a.createdMs)
        }
    }

    /// Ends the rekeys awaiting `hs.fin` for longer than ``handshakeTTL``, and all but the newest ``maxAwaiting``.
    func pruneAwaiting(_ t: Date) {
        let cutoff = Self.ms(t.addingTimeInterval(-Self.handshakeTTL))
        let sorted = awaiting.sorted { $0.createdMs > $1.createdMs }
        let keep = sorted.prefix(Self.maxAwaiting).filter { $0.createdMs >= cutoff }
        for a in awaiting where !keep.contains(where: { $0.resp === a.resp }) { a.resp.abort() }
        awaiting = Array(keep)
    }

    // MARK: - Lifecycle

    /// Starts collecting from the device's mailbox and flushes the outbox; does nothing while a collection runs. A
    /// terminal relay error ends the collection (``collectionEnded``); start it again to go on.
    public func start() {
        let begin: Bool = mem.withLock {
            stopped = false
            if collector != nil, collectEnded == nil { return false }
            collectEnded = nil
            return true
        }
        guard begin else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            let flush = Task { await self.flushOutbox() }
            defer { flush.cancel() }
            let source = RelayMailbox(client: own, transport: cfg.transport)
            let c = MailboxCollector(
                source: source, mode: cfg.collectMode, wait: cfg.pollWait, now: cfg.now,
                onRequest: { [weak self] out in self?.mem.withLock { self?.collectSince = out ? Date() : nil } }
            )
            do {
                try await c.run { m in try await self.handle(m) }
            } catch let e as RelayError {
                // A terminal relay error ends the collection; the next start() collects again.
                mem.withLock { collectEnded = e.code }
            } catch is CancellationError {
                return
            } catch {
                // Anything else that ends it is reported the same way, so that the collection is started again.
                mem.withLock { collectEnded = String(describing: type(of: error)) }
            }
        }
        // A stop() since the start above wins: the collection it would have stopped is cancelled at once.
        let cancel: Bool = mem.withLock {
            if stopped { return true }
            collector = task
            return false
        }
        if cancel { task.cancel() }
    }

    /// Starts the collection again if it is not running (it ended, or never ran) after a ``start()``; nothing after
    /// ``stop()``. Returns whether it started one.
    @discardableResult
    public func ensureCollecting() -> Bool {
        let restart: Bool = mem.withLock { !stopped && (collector == nil || collectEnded != nil) }
        if restart { start() }
        return restart
    }

    /// Stops collecting.
    public func stop() {
        let task: Task<Void, Never>? = mem.withLock {
            stopped = true
            defer {
                collector = nil
                collectSince = nil
            }
            return collector
        }
        task?.cancel()
    }

    /// One long-poll round (tests and background refreshes).
    public func pollOnce() async throws -> Int {
        try await MailboxCollector(source: RelayMailbox(client: own, transport: cfg.transport), wait: cfg.pollWait, now: cfg.now)
            .pollOnce { m in try await self.handle(m) }
    }

    /// The limits this device's relay advertises (RELAY-PROTOCOL §6.1; register is idempotent).
    public func relayLimits() async throws -> RelayLimits { try await own.register().limits }

    /// A fresh inner id (a ULID by this device's clock), for a request the member may retry as the same one.
    public func newRequestID() -> String { Ulid.new(now()) }

    /// Forgets the vault and every key's state on this device (sign-out, transfer away). The device is unusable after:
    /// nothing is written to the store again, and it holds no vault.
    public func forget() async throws {
        try await lock.withLock {
            stop()
            mem.withLock {
                forgotten = true
                keyring.destroy()
                ini?.abort()
                ini = nil
                for a in awaiting { a.resp.abort() }
                awaiting.removeAll()
                st.vault = nil
                st.outbox.removeAll()
                st.utks.removeAll()
                st.credential = nil
            }
            try cfg.store.clear()
        }
    }

    /// Stops collecting and deletes the device's own mailbox at its relay with everything in it (RELAY-PROTOCOL
    /// §6.10; idempotent): a replaced app erasing itself.
    public func deleteMailbox() async throws {
        stop()
        try await own.deleteMailbox()
    }
}
