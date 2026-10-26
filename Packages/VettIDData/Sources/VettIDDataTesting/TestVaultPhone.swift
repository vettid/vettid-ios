#if DEBUG
import Foundation
import VettIDAltChan
import VettIDCrypto
import VettIDData
import VettIDKeys
import VettIDKeysTesting
import VettIDRelay
import VettIDVault

/// TEST ONLY. A device attestation the fake enclave does not check (the TEST iOS attester of I1.3 replaces it): an
/// iOS-shaped attestation and assertion over the challenge, whose key id is SHA-256 of the challenge. It records the
/// keys it attested and what the app confirmed and discarded (IOS-PLAN §6.2).
public final class TestAttester: Attester, @unchecked Sendable {
    private let lock = NSLock()
    private var attestedKeys: [[UInt8]] = []
    private var confirmedKeys: [[UInt8]] = []
    private var discardedKeys: [[UInt8]] = []
    private var identity = 0
    private var assertedBy: [Int] = []
    private var forgottenIdentities: [Int] = []
    private var resetCount = 0
    private var attestedBy: [Int] = []
    private var keptReplaced: [Int] = []
    private var settledIdentities: [Int] = []

    /// The App Attest key record of the iPhone (``AppAttestKey``) over a fake App Attest, once ``modelKeys()`` installed it.
    private var model: AppAttestKey?
    private let service = TestAppAttestService()
    private let keyIDs = TestKeyIDStore()
    private let aside = TestKeyIDStore()

    public init() {}

    /// (IOS-PLAN 0.1.35 §4.9) From now on the attestations, assertions and the bookkeeping of keys and identities also go through
    /// the app's own App Attest key record, over a fake App Attest that records which key each assertion used
    /// (``assertedKeys``, ``attestedKeyIDs``).
    public func modelKeys() {
        let key = AppAttestKey(
            service: service, keyID: keyIDs, aside: aside, mayStartOver: { true }, backoff: [], sleep: { _ in }, checkThread: false
        )
        lock.withLock { model = key }
    }

    /// A new process (``TestVaultPhone/restart()``): the modelled key record is read again from what it kept, without the
    /// choices it made in memory (the key tried after a refusal).
    public func newProcess() {
        if modelled != nil { modelKeys() }
    }

    /// The modelled key record as kept (its JSON), or nil.
    public var keptRecord: String? {
        guard case .found(let bytes) = keyIDs.lookup() else { return nil }
        return String(bytes: bytes, encoding: .utf8)
    }

    /// With ``modelKeys()``: the App Attest key id each assertion used, in order, and the key ids attested.
    public var assertedKeys: [String] { service.asserted }
    public var attestedKeyIDs: [String] { service.made }

    private var modelled: AppAttestKey? { lock.withLock { model } }

    /// The device identity (IOS-PLAN 0.1.33 §4.9) in use now, and the one in use at each assertion, in order.
    public var identityInUse: Int { lock.withLock { identity } }
    public var assertionIdentities: [Int] { lock.withLock { assertedBy } }
    public var forgotten: [Int] { lock.withLock { forgottenIdentities } }
    /// How many times a forget reset the identities.
    public var resets: Int { lock.withLock { resetCount } }
    /// (IOS-PLAN 0.1.35 §4.9) The identity in use at each attestation, in order (``attested`` holds the keys).
    public var attestationIdentities: [Int] { lock.withLock { attestedBy } }
    /// The identity in use each time its replaced keys were to be kept (a register of the new identity).
    public var keptReplacedKeys: [Int] { lock.withLock { keptReplaced } }
    /// The identities a completed handshake settled on, in order.
    public var settled: [Int] { lock.withLock { settledIdentities } }

    /// The key ids attested, in order.
    public var attested: [[UInt8]] { lock.withLock { attestedKeys } }
    public var confirmed: [[UInt8]] { lock.withLock { confirmedKeys } }
    public var discarded: [[UInt8]] { lock.withLock { discardedKeys } }

    public func attest(_ challenge: [UInt8]) throws -> DeviceAttest {
        if let m = modelled {
            let a = try m.attest(clientDataHash: challenge)
            if case .ios(let id, _) = a { lock.withLock { (attestedKeys, attestedBy) = (attestedKeys + [id], attestedBy + [identity]) } }
            return a
        }
        let k = Bytes.sha256(challenge)
        lock.withLock {
            attestedKeys.append(k)
            attestedBy.append(identity)
        }
        return try DeviceAttest.iosAttestation(keyID: k, attestation: Array("test-attestation".utf8))
    }

    public func assert(_ signed: AttestSigned) throws -> DeviceAssertion {
        lock.withLock { assertedBy.append(identity) }
        if let m = modelled { return try m.assert(clientDataHash: signed.clientDataHash) }
        return try DeviceAssertion.iosAssertion(Bytes.sha256(signed.clientDataHash))
    }

    public func confirm(keyID: [UInt8]) throws {
        lock.withLock { confirmedKeys.append(keyID) }
        try modelled?.confirm(keyID: keyID)
    }

    public func discard(keyID: [UInt8]) throws {
        lock.withLock { discardedKeys.append(keyID) }
        try modelled?.discard(keyID: keyID)
    }

    public func prune(keeping keyIDs: [[UInt8]]) throws { try modelled?.prune(keeping: keyIDs) }
    public func confirmInUse() throws { try modelled?.confirmInUse() }
    public func nextCandidate() throws -> Bool { try modelled?.nextCandidate() ?? false }

    public func use(identity n: Int) throws {
        lock.withLock { identity = n }
        try modelled?.use(identity: n)
    }

    public func forget(identity n: Int) throws {
        lock.withLock { forgottenIdentities.append(n) }
        try modelled?.forget(identity: n)
    }

    public func resetIdentities() throws {
        lock.withLock { (identity, resetCount) = (0, resetCount + 1) }
        try modelled?.resetIdentities()
    }

    public func keepReplacedKeys() throws {
        lock.withLock { keptReplaced.append(identity) }
        try modelled?.keepReplacedKeys()
    }

    public func settle(identity n: Int) throws {
        lock.withLock {
            identity = n
            settledIdentities.append(n)
        }
        try modelled?.settle(identity: n)
    }
}

/// TEST ONLY. App Attest on the phone, faked: key ids are `key-1`, `key-2`, … (base64), and each assertion records its key.
final class TestAppAttestService: AppAttestService, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String] = []
    private var asserts: [String] = []

    var made: [String] { lock.withLock { keys } }
    var asserted: [String] { lock.withLock { asserts } }

    var isSupported: Bool { true }

    func generateKey() throws -> String {
        lock.withLock {
            let id = Data("key-\(keys.count + 1)".utf8).base64EncodedString()
            keys.append(id)
            return id
        }
    }

    func attestKey(_ keyID: String, clientDataHash: [UInt8]) throws -> [UInt8] { Array("test-attestation".utf8) + clientDataHash }

    func generateAssertion(_ keyID: String, clientDataHash: [UInt8]) throws -> [UInt8] {
        lock.withLock { asserts.append(keyID) }
        return Array(keyID.utf8) + clientDataHash
    }
}

/// TEST ONLY. A kept App Attest key id in memory.
final class TestKeyIDStore: KeyIDStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: [UInt8]?

    func lookup() -> ItemLookup<[UInt8]> { lock.withLock { value.map { .found($0) } ?? .missing } }
    func write(_ value: [UInt8]) throws { lock.withLock { self.value = value } }
    func delete() throws { lock.withLock { value = nil } }
}

/// TEST ONLY. One iPhone running the app against a ``FakeVaultService``: software keys behind the Secure Enclave's
/// protocols (VettIDKeysTesting), the encrypted files in a fresh directory, the TEST attester, the fake's manifest key
/// pinned and its enclave check, and `vault.enrolled`'s attestation skipped. ``restart()`` is the same phone after the
/// app was killed and started again (the same keys and files, a new manager).
@MainActor
public final class TestVaultPhone {
    public let service: FakeVaultService
    public let appKeys = SoftwareAppKeyStore()
    public let seedWrap = SoftwareSeedWrapKeySource()
    public let wrapped = InMemoryWrappedKeyStore()
    public let phoneKeys = SoftwarePhoneSecretSource()
    public let fileKeys = InMemoryFileKeyHolder()
    public let protectedData = ProtectedDataFlag(available: true)
    /// The device attestation, kept across a restart.
    public let attester: TestAttester
    /// What the manager says of a damaged App Attest key record (``AttestStartOver``).
    public let attestStartOver: AttestStartOver
    public let directory: URL
    /// What the first-run gate answers; a test sets it to make it refuse ("Unlock your iPhone").
    public var prepareFailure: (any Error & Sendable)? {
        get { gate.failure }
        set { gate.failure = newValue }
    }
    public private(set) var manager: VaultManager
    /// Moves this phone's clock (seconds ahead of the real one).
    public var clockAhead: TimeInterval {
        get { clock.ahead }
        set { clock.ahead = newValue }
    }
    /// Moves this phone's monotonic clock ahead (seconds), and with it its idea of the vault's clock between answers.
    public var uptimeAhead: TimeInterval {
        get { uptime.ahead }
        set { uptime.ahead = newValue }
    }
    /// Stops this phone's clock and its monotonic clock at now, as ``FakeVaultService/freezeVaultClock()`` stops the
    /// vault's: a test of a window of seconds then depends on the clocks it moves, not on how long the machine takes.
    public func freezeClocks() {
        clock.freeze()
        uptime.freeze()
    }
    private let gate = PrepareSwitch()
    private let clock = TestPhoneClock()
    private let uptime = TestPhoneClock()
    /// The pauses between the checks of a change whose answer was lost: each waits until the test releases it.
    public let changePauses = TestPauses()
    /// A change's wait for the credential operations before it (§11.14.9 step 1): ends when the test releases it while
    /// ``holdsChangeWaits``, else after five seconds (room for a late answer on a loaded machine).
    public let changeWaits = TestPauses()
    /// (IOS-PLAN §4.2) The waits between the re-reads of a vault being deleted: each waits until the test releases it, so
    /// that only the reads a test asks for (a start, a return to the foreground, Check again) happen meanwhile.
    public let deletionPauses = TestPauses()
    /// The new phone's wait for the vault's `hs.resp` after a transfer's `hs.init` (60 s, §6.7.1 step 2): lasts until the
    /// test releases it.
    public let transferPauses = TestPauses()
    /// The old phone's wait to the end of a kept transfer (7 days, §11.14.10): lasts until the test releases it.
    public let keepPauses = TestPauses()
    /// The limit of the day-7 check's wait for `device.list`: a test that holds the vault silent waits until it has a waiter
    /// (``TestPauses/lengths``) and releases it; a test with an answer never does.
    public let keptEndPauses = TestPauses()
    /// The new phone's wait for the deadline of its transfer (11 minutes, §11.14.10 rule 5), released by the test.
    public let deadlinePauses = TestPauses()
    /// The bound of the one collect before the drop (30 s): never released unless a test wants a timed-out collect.
    public let collectPauses = TestPauses()
    /// Whether a change's wait lasts until the test releases it (``changeWaits``).
    public var holdsChangeWaits: Bool {
        get { changeWaits.holding }
        set { changeWaits.holding = newValue }
    }
    private let requestTimeout: TimeInterval
    private let lockStatusWait: TimeInterval
    /// What this phone's wipe erases: its directory and its software keys.
    public let wipeTargets: TestWipeTargets

    /// Whether this build can wipe (false: a manager without ``LocalWipe``).
    private let wipes: Bool

    /// The request timeout of the tests that make answers go missing: short, so that a lost answer is seen quickly. It
    /// applies to the requests whose answers the test makes go missing alone (``FakeVaultService/unanswered(_:)``).
    public static let shortRequestTimeout: TimeInterval = 1.0

    /// The request timeout of every request whose answer the test does not make go missing: roomy, so that the reads
    /// every opening of the vault makes and the test's own requests queued behind them are answered within their three
    /// tries on a loaded machine (1 s a try was not).
    public static let roomyRequestTimeout: TimeInterval = 5

    /// [requestTimeout]: how long a request waits for its answer before it is sent again (§8.6), for a request of a type
    /// whose answers the test makes go missing (``FakeVaultService/unanswered(_:)``); any other waits at least
    /// ``roomyRequestTimeout``. [wipes]: false for a build that cannot wipe. [lockStatusWait]: how long "Lock it now" waits for the status
    /// that names the opening (``LockTiming/lockStatusWait``).
    public init(
        service: FakeVaultService, requestTimeout: TimeInterval = 5, wipes: Bool = true, lockStatusWait: TimeInterval = 5
    ) throws {
        self.service = service
        self.lockStatusWait = lockStatusWait
        self.requestTimeout = requestTimeout
        self.wipes = wipes
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vettid-manager-tests/\(UUID().uuidString)/VettID")
        wipeTargets = TestWipeTargets(
            directory: directory, appKeys: appKeys, seedWrap: seedWrap, wrapped: wrapped, phoneKeys: phoneKeys, fileKeys: fileKeys
        )
        let attester = TestAttester()
        let startOver = AttestStartOver()
        self.attester = attester
        attestStartOver = startOver
        let waits = Waits(
            requestTimeout: requestTimeout, pauses: changePauses, changeWaits: changeWaits, deletion: deletionPauses,
            transfer: transferPauses, keep: keepPauses, keptEnd: keptEndPauses, deadline: deadlinePauses,
            collect: collectPauses, lockStatusWait: lockStatusWait
        )
        manager = VaultManager(config: try Self.configured(
            service, appKeys, seedWrap, wrapped, phoneKeys, fileKeys, protectedData, directory, gate, clock,
            wipes ? wipeTargets : nil, attester, startOver, waits, uptime
        ))
    }

    /// How long a recovered phone waits for the vault's `hs.resp` (90 s, or 30 s when resuming, when nil): a test of the handshake
    /// the vault does not answer sets it, then ``restart()``s.
    public var pairingWait: TimeInterval?

    /// The app killed and started again: a new manager over the same keys and files. The old manager is halted first
    /// (``VaultManager/halt()``): a process death ends what it had on the way, so nothing of it may send or write once the
    /// new one runs.
    public func restart() async throws {
        await manager.halt()
        attester.newProcess()
        var config = try Self.configured(
            service, appKeys, seedWrap, wrapped, phoneKeys, fileKeys, protectedData, directory, gate, clock,
            wipes ? wipeTargets : nil, attester, attestStartOver, waits, uptime
        )
        config.pairingWait = pairingWait
        manager = VaultManager(config: config)
    }

    private var waits: Waits {
        Waits(
            requestTimeout: requestTimeout, pauses: changePauses, changeWaits: changeWaits, deletion: deletionPauses,
            transfer: transferPauses, keep: keepPauses, keptEnd: keptEndPauses, deadline: deadlinePauses,
            collect: collectPauses, lockStatusWait: lockStatusWait
        )
    }

    /// A test phone's waits: how long a request waits for its answer, and the pauses the test releases.
    private struct Waits {
        let requestTimeout: TimeInterval
        let pauses: TestPauses
        let changeWaits: TestPauses
        let deletion: TestPauses
        let transfer: TestPauses
        let keep: TestPauses
        let keptEnd: TestPauses
        let deadline: TestPauses
        let collect: TestPauses
        let lockStatusWait: TimeInterval
    }

    // swiftlint:disable:next function_parameter_count
    private static func configured(
        _ service: FakeVaultService, _ appKeys: SoftwareAppKeyStore, _ seedWrap: SoftwareSeedWrapKeySource,
        _ wrapped: InMemoryWrappedKeyStore, _ phoneKeys: SoftwarePhoneSecretSource, _ fileKeys: InMemoryFileKeyHolder,
        _ protectedData: ProtectedDataFlag, _ directory: URL, _ gate: PrepareSwitch, _ clock: TestPhoneClock,
        _ wipeTargets: (any WipeTargets)?, _ attester: TestAttester, _ startOver: AttestStartOver,
        _ waits: Waits, _ uptime: TestPhoneClock
    ) throws -> VaultManagerConfig {
        var c = try config(service, appKeys, seedWrap, wrapped, phoneKeys, fileKeys, protectedData, directory, gate, clock, wipeTargets)
        c.attester = attester
        c.attestStartOver = startOver
        c.requestTimeout = waits.requestTimeout
        c.lockTiming.lockStatusWait = waits.lockStatusWait
        let short = waits.requestTimeout, roomy = max(waits.requestTimeout, roomyRequestTimeout)
        // Weak: the device outlives the test (its collection and requests end later), and must not keep the fake running.
        c.requestTimeoutOf = { [weak service] in service?.unanswered($0) ?? true ? short : roomy }
        let pauses = waits.pauses
        c.changeCheckSleep = { try await pauses.sleep($0) }
        let changeWaits = waits.changeWaits
        changeWaits.holding = false
        c.changeWaitSleep = { try await changeWaits.sleep($0) }
        c.releaseUpdateSleep = { _ in try await Task.sleep(for: .milliseconds(5)) }
        let deletion = waits.deletion
        c.deletionSleep = { d in try await deletion.sleep(Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18) }
        let transfer = waits.transfer, keep = waits.keep
        c.transferSleep = { d in try await transfer.sleep(Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18) }
        c.keepSleep = { d in try await keep.sleep(Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18) }
        // The waits that bound a check or a collect are pauses the test releases, never clocks that a loaded machine can win.
        let keptEnd = waits.keptEnd, deadline = waits.deadline, collect = waits.collect
        c.keptEndSleep = { d in try await keptEnd.sleep(Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18) }
        c.transferDeadlineSleep = { d in try await deadline.sleep(Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18) }
        c.transferCollectSleep = { d in try await collect.sleep(Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18) }
        c.uptime = { uptime.monotonic }
        return c
    }

    /// Stops the mailbox collection (the end of a test).
    public func close() { manager.stopCollecting() }

    // swiftlint:disable:next function_parameter_count
    private static func config(
        _ service: FakeVaultService, _ appKeys: SoftwareAppKeyStore, _ seedWrap: SoftwareSeedWrapKeySource,
        _ wrapped: InMemoryWrappedKeyStore, _ phoneKeys: SoftwarePhoneSecretSource, _ fileKeys: InMemoryFileKeyHolder,
        _ protectedData: ProtectedDataFlag, _ directory: URL, _ gate: PrepareSwitch, _ clock: TestPhoneClock,
        _ wipeTargets: (any WipeTargets)?
    ) throws -> VaultManagerConfig {
        VaultManagerConfig(
            apiOrigin: service.api.baseURL,
            manifestURL: service.api.baseURL + MemberApiClient.manifestPath,
            relayURL: service.relay.baseURL,
            trust: try service.trust,
            transport: HTTPTransport(session: service.api.session, sleep: { _ in }),
            directory: directory,
            keys: VaultKeys(appKeys: appKeys, seedWrap: seedWrap, wrapped: wrapped, phone: phoneKeys, files: fileKeys),
            attester: TestAttester(),
            protectedData: protectedData,
            // The fake's "attestation" is the nonce of the request that made the vault: checked as the document's is.
            enrolledAttestation: .verify { doc, _, nonce, _, _ in
                guard doc == nonce else { throw KeysError.invalid("enrolled nonce") }
            },
            enclaveCheck: FakeVaultService.enclaveCheck,
            deviceName: "iPhone",
            prepare: { try gate.check() },
            pollWait: 1,
            requestTimeout: 5,
            enrolledGrace: 0.5,
            // A lock's waits, short: the relay's answer, a relay lock's validity and margin, the retries.
            lockTiming: LockTiming(
                relayAnswer: 0.5, relayValid: 0.3, memberWait: 0.3, relayMargin: .milliseconds(50),
                backoff: { _ in .milliseconds(100) }
            ),
            wipeTargets: wipeTargets,
            environment: "test",
            now: { clock.now }
        )
    }
}

/// TEST ONLY. What a test phone's wipe erases: its data directory and its software keys. [failingErase] makes the next
/// erases leave a file behind (a wipe that does not finish).
public final class TestWipeTargets: WipeTargets, @unchecked Sendable {
    public let directory: URL
    private let appKeys: SoftwareAppKeyStore
    private let seedWrap: SoftwareSeedWrapKeySource
    private let wrapped: InMemoryWrappedKeyStore
    private let phoneKeys: SoftwarePhoneSecretSource
    private let fileKeys: InMemoryFileKeyHolder
    private let lock = NSLock()
    private var stuck = false
    private var notificationsCancelled = 0

    init(
        directory: URL, appKeys: SoftwareAppKeyStore, seedWrap: SoftwareSeedWrapKeySource, wrapped: InMemoryWrappedKeyStore,
        phoneKeys: SoftwarePhoneSecretSource, fileKeys: InMemoryFileKeyHolder
    ) {
        self.directory = directory
        self.appKeys = appKeys
        self.seedWrap = seedWrap
        self.wrapped = wrapped
        self.phoneKeys = phoneKeys
        self.fileKeys = fileKeys
    }

    /// A key that cannot be deleted for now (the next erases fail until it is set back).
    public var keyStuck: Bool {
        get { lock.withLock { stuck } }
        set { lock.withLock { stuck = newValue } }
    }

    public var cancelledNotifications: Int { lock.withLock { notificationsCancelled } }

    public var marker: URL { directory.appendingPathComponent(LocalWipe.marker) }
    public var dirs: [URL] { [directory] }
    public var kept: [URL] { [] }
    public var erasers: [any KeyEraser] { [StuckEraser(targets: self), appKeys, seedWrap, wrapped, phoneKeys, fileKeys] }

    public func keysLeft() throws -> Bool {
        keyStuck || appKeys.current != nil || seedWrap.exists || !wrapped.all.isEmpty || phoneKeys.count > 0 || fileKeys.holdsKey
    }

    public func cancelNotifications() { lock.withLock { notificationsCancelled += 1 } }

    private struct StuckEraser: KeyEraser {
        let targets: TestWipeTargets

        func deleteAll() throws {
            if targets.keyStuck { throw KeysError.unavailable("test key") }
        }
    }
}

/// TEST ONLY. Pauses a test releases: each ``sleep(_:)`` records its length and waits for ``release()`` (or its task's
/// cancellation).
public final class TestPauses: @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [TimeInterval] = []
    private var waiting: [UUID: CheckedContinuation<Void, Never>] = [:]

    private var hold = true

    /// The lengths asked for, in order.
    public var lengths: [TimeInterval] { lock.withLock { asked } }

    /// False: a pause lasts five seconds instead of waiting for ``release()`` (its length is recorded all the same).
    var holding: Bool {
        get { lock.withLock { hold } }
        set { lock.withLock { hold = newValue } }
    }

    func sleep(_ s: TimeInterval) async throws {
        if !holding {
            lock.withLock { asked.append(s) }
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return
        }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                let cancelled: Bool = lock.withLock {
                    asked.append(s)
                    if Task.isCancelled { return true }
                    waiting[id] = c
                    return false
                }
                if cancelled { c.resume() }
            }
        } onCancel: {
            lock.withLock { waiting.removeValue(forKey: id) }?.resume()
        }
        try Task.checkCancellation()
    }

    /// Ends the pauses waiting now.
    public func release() {
        let ws: [CheckedContinuation<Void, Never>] = lock.withLock {
            defer { waiting.removeAll() }
            return Array(waiting.values)
        }
        for w in ws { w.resume() }
    }
}

/// A test phone's clock: the real one, moved ahead.
final class TestPhoneClock: @unchecked Sendable {
    private let lock = NSLock()
    private var offset: TimeInterval = 0
    private var frozenAt: Date?
    private var frozenUptime: TimeInterval?

    var ahead: TimeInterval {
        get { lock.withLock { offset } }
        set { lock.withLock { offset = newValue } }
    }

    /// Stops the clock at now: from then on only ``ahead`` moves it.
    func freeze() {
        lock.withLock {
            frozenAt = Date()
            frozenUptime = DeviceConfig.monotonicNow()
        }
    }

    /// The monotonic clock (``DeviceConfig/monotonicNow()``), moved by ``ahead`` and stopped by ``freeze()``.
    var monotonic: TimeInterval { lock.withLock { (frozenUptime ?? DeviceConfig.monotonicNow()) + offset } }

    var now: Date { lock.withLock { (frozenAt ?? Date()).addingTimeInterval(offset) } }
}

/// The first-run gate of a test phone: open unless a test sets a failure.
final class PrepareSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (any Error & Sendable)?

    var failure: (any Error & Sendable)? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }

    func check() throws {
        if let failure { throw failure }
    }
}
#endif
