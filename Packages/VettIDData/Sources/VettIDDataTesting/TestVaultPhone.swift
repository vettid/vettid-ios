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

    public init() {}

    /// The key ids attested, in order.
    public var attested: [[UInt8]] { lock.withLock { attestedKeys } }
    public var confirmed: [[UInt8]] { lock.withLock { confirmedKeys } }
    public var discarded: [[UInt8]] { lock.withLock { discardedKeys } }

    public func attest(_ challenge: [UInt8]) throws -> DeviceAttest {
        let k = Bytes.sha256(challenge)
        lock.withLock { attestedKeys.append(k) }
        return try DeviceAttest.iosAttestation(keyID: k, attestation: Array("test-attestation".utf8))
    }

    public func assert(_ signed: AttestSigned) throws -> DeviceAssertion {
        try DeviceAssertion.iosAssertion(Bytes.sha256(signed.clientDataHash))
    }

    public func confirm(keyID: [UInt8]) throws { lock.withLock { confirmedKeys.append(keyID) } }
    public func discard(keyID: [UInt8]) throws { lock.withLock { discardedKeys.append(keyID) } }
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
    private let gate = PrepareSwitch()
    private let clock = TestPhoneClock()
    private let uptime = TestPhoneClock()
    /// The pauses between the checks of a change whose answer was lost: each waits until the test releases it.
    public let changePauses = TestPauses()
    private let requestTimeout: TimeInterval
    /// What this phone's wipe erases: its directory and its software keys.
    public let wipeTargets: TestWipeTargets

    /// Whether this build can wipe (false: a manager without ``LocalWipe``).
    private let wipes: Bool

    /// [requestTimeout]: how long a request waits for its answer before it is sent again (§8.6). [wipes]: false for a
    /// build that cannot wipe.
    public init(service: FakeVaultService, requestTimeout: TimeInterval = 5, wipes: Bool = true) throws {
        self.service = service
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
        manager = VaultManager(config: try Self.configured(
            service, appKeys, seedWrap, wrapped, phoneKeys, fileKeys, protectedData, directory, gate, clock,
            wipes ? wipeTargets : nil, attester, startOver, (requestTimeout, changePauses), uptime
        ))
    }

    /// The app killed and started again: a new manager over the same keys and files.
    public func restart() throws {
        manager.stopCollecting()
        manager = VaultManager(config: try Self.configured(
            service, appKeys, seedWrap, wrapped, phoneKeys, fileKeys, protectedData, directory, gate, clock,
            wipes ? wipeTargets : nil, attester, attestStartOver, (requestTimeout, changePauses), uptime
        ))
    }

    // swiftlint:disable:next function_parameter_count
    private static func configured(
        _ service: FakeVaultService, _ appKeys: SoftwareAppKeyStore, _ seedWrap: SoftwareSeedWrapKeySource,
        _ wrapped: InMemoryWrappedKeyStore, _ phoneKeys: SoftwarePhoneSecretSource, _ fileKeys: InMemoryFileKeyHolder,
        _ protectedData: ProtectedDataFlag, _ directory: URL, _ gate: PrepareSwitch, _ clock: TestPhoneClock,
        _ wipeTargets: (any WipeTargets)?, _ attester: TestAttester, _ startOver: AttestStartOver,
        _ waits: (requestTimeout: TimeInterval, pauses: TestPauses), _ uptime: TestPhoneClock
    ) throws -> VaultManagerConfig {
        var c = try config(service, appKeys, seedWrap, wrapped, phoneKeys, fileKeys, protectedData, directory, gate, clock, wipeTargets)
        c.attester = attester
        c.attestStartOver = startOver
        c.requestTimeout = waits.requestTimeout
        let pauses = waits.pauses
        c.changeCheckSleep = { try await pauses.sleep($0) }
        c.uptime = { DeviceConfig.monotonicNow() + uptime.ahead }
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

    /// The lengths asked for, in order.
    public var lengths: [TimeInterval] { lock.withLock { asked } }

    func sleep(_ s: TimeInterval) async throws {
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

    var ahead: TimeInterval {
        get { lock.withLock { offset } }
        set { lock.withLock { offset = newValue } }
    }

    var now: Date { Date().addingTimeInterval(ahead) }
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
