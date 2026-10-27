import Foundation
import VettIDAltChan
import VettIDAttestation
import VettIDKeys
import VettIDRelay
import VettIDVault

/// The keys behind their protocols (IOS-PLAN §6.1): the Secure Enclave and App Attest on the iPhone, software
/// keys in tests.
public struct VaultKeys: Sendable {
    /// The app key (VAULT-MESSAGING §11.12.2), which signs every member API request.
    public var appKeys: any AppKeyStore
    /// The key the device seeds are wrapped under, and where the wrapped seeds are kept.
    public var seedWrap: any SeedWrapKeySource
    public var wrapped: any WrappedKeyStore
    /// The phone keys of the unlock secret (§11.14.1 "On an iPhone").
    public var phone: any PhoneSecretSource
    /// The key of the encrypted files.
    public var files: any FileKeyHolder

    public init(
        appKeys: any AppKeyStore,
        seedWrap: any SeedWrapKeySource,
        wrapped: any WrappedKeyStore,
        phone: any PhoneSecretSource,
        files: any FileKeyHolder
    ) {
        self.appKeys = appKeys
        self.seedWrap = seedWrap
        self.wrapped = wrapped
        self.phone = phone
        self.files = files
    }
}

/// The vault manager's files in the app's data directory (`Application Support/VettID`, excluded from backups, IOS-PLAN
/// §6.1): the account record, the device state, the phone-secret records and the lock's record. Their presence refuses the first-run
/// cleanup (``FirstRunCleanup``'s `dataFiles`).
public enum VaultFiles {
    public static let account = "account"
    public static let device = "vault-device"
    public static let phoneSecrets = "phone-secrets"
    public static let lock = "lock-record"
    /// The owner check as this phone last learnt it (``OwnerCheckManager``).
    public static let ownerCheck = "owner-check"
    /// The canary manifest installed out of band (``CanaryManifestManager``). Not one of ``all(in:)``: it holds nothing
    /// of a vault, so its presence alone does not refuse the first-run cleanup (chosen; not in the spec).
    public static let canary = "canary-manifest"
    /// What only this phone learns of connection requests (``ConnectionsManager``).
    public static let connections = "connections"
    /// The approvals that arrive only as events (``ApprovalsManager``).
    public static let approvals = "approvals"

    /// Every data file of the vault manager in [directory].
    public static func all(in directory: URL) -> [URL] {
        ([account] + IdentitySet.all.map(device(of:)) + [phoneSecrets, lock, ownerCheck, connections, approvals])
            .map { directory.appendingPathComponent($0) }
    }

    /// (IOS-PLAN 0.1.38 §4.9) The device state of identity [set]: the first is `vault-device`, the others (a phone that could not
    /// tell) `vault-device-2`, `vault-device-3`, …
    public static func device(of set: IdentitySet) -> String { set.rawValue == 0 ? device : "\(device)-\(set.rawValue + 1)" }
}

/// How the member's lock waits (VAULT-LOCK as vettid-android implements it): the app's values by default; the tests
/// shorten them.
public struct LockTiming: Sendable {
    /// How long the relay's `vault.lock` waits for the vault's answer.
    public var relayAnswer: TimeInterval
    /// How long after it was asked a `vault.lock` may still be acted on (its `exp`).
    public var relayValid: TimeInterval
    /// How long a lock through the member API waits for its slot (vettid-android: 12 s).
    public var memberWait: TimeInterval
    /// Added to a relay lock's validity before an unlock may follow it.
    public var relayMargin: Duration
    /// "Lock it now" (release L): how long the status read that names the opening running now may take; then the lock goes
    /// out unconditional.
    public var lockStatusWait: TimeInterval
    /// The wait before each retry of a pending lock.
    public var backoff: @Sendable (Int) -> Duration
    /// How the lock waits (``realLockSleep`` in the app).
    public var sleep: LockSleep

    public init(
        relayAnswer: TimeInterval = VaultApi.lockAnswer,
        relayValid: TimeInterval = VaultApi.lockValid,
        memberWait: TimeInterval = 12,
        lockStatusWait: TimeInterval = 5,
        relayMargin: Duration = LockKeeper.relayMargin,
        backoff: @escaping @Sendable (Int) -> Duration = LockKeeper.defaultBackoff,
        sleep: @escaping LockSleep = realLockSleep
    ) {
        self.relayAnswer = relayAnswer
        self.relayValid = relayValid
        self.memberWait = memberWait
        self.lockStatusWait = lockStatusWait
        self.relayMargin = relayMargin
        self.backoff = backoff
        self.sleep = sleep
    }
}

/// Where the vault manager talks to and what it trusts and holds, from the build's environment (IOS-PLAN §5). Nothing
/// here is printed.
public struct VaultManagerConfig: Sendable {
    /// The member API origin (`https://account.vettid.org`), also the identifier setup codes name (§11.12.1).
    public var apiOrigin: String
    /// Where the release manifest is served (§11.10.1).
    public var manifestURL: String
    /// This device's relay base URL (RELAY-PROTOCOL).
    public var relayURL: String
    /// The pinned Nitro root and manifest keys (§11.2, §11.10.1).
    public var trust: AltTrust
    public var transport: HTTPTransport
    /// The app's data directory.
    public var directory: URL
    public var keys: VaultKeys
    /// The device attestation (§11.7): App Attest on the iPhone, the TEST attester on the dev stack (VettIDAltChanTesting).
    public var attester: any Attester
    public var protectedData: any ProtectedData
    /// How `vault.enrolled`'s attestation is checked (§11.3): ``EnrolledAttestation/nitro(roots:)`` in the app.
    public var enrolledAttestation: EnrolledAttestation
    /// The check of a routed enclave (§11.2); nil: VettIDAttestation's verifier with [trust]'s Nitro roots. Tests only.
    public var enclaveCheck: EnclaveCheck?
    /// The name the vault shows for this device (`profile.name`).
    public var deviceName: String
    /// Runs before anything touches a key or a data file: the first-run cleanup (IOS-PLAN §6.1, ``FirstRunGate``).
    /// Throws while it cannot run yet (``KeysError/unavailable(_:)``: protected data is not available).
    public var prepare: @Sendable () throws -> Void
    public var collectMode: MailboxCollector.Mode
    public var pollWait: TimeInterval
    public var requestTimeout: TimeInterval
    /// TEST ONLY. ``DeviceConfig/requestTimeoutOf``: a request timeout by request type instead of [requestTimeout].
    public var requestTimeoutOf: (@Sendable (String) -> TimeInterval)?
    /// How long an enrollment waits for a `vault.enrolled` that a request whose answer was lost may have caused, before
    /// it sends another or reports `vault_exists` as another phone's vault (chosen; not in the spec: 15 s, a relay
    /// round trip with margin).
    public var enrolledGrace: TimeInterval
    /// How the member's lock waits.
    public var lockTiming: LockTiming
    /// What a wipe of this phone erases (``LocalWipe``); nil: this build cannot wipe (``AccountRepository/eraseThisPhone()``
    /// refuses with ``FailureKind/notSupported``).
    public var wipeTargets: (any WipeTargets)?
    /// The build's environment as Settings → Attestation names it (`production`, `staging`, …).
    public var environment: String
    public var now: @Sendable () -> Date
    /// (iPhone) Told whether no vault made or being made here can hold an App Attest key of this phone, from the account
    /// record (``AttestStartOver``); nil where nothing listens.
    public var attestStartOver: AttestStartOver?
    /// The release update's waits: for the member API to see the vault locked, and for the API to route an unlock to the
    /// release a vault just moved to (a virtual clock in the tests).
    public var releaseUpdateSleep: LockSleep = realLockSleep
    /// (IOS-PLAN §4.2) The waits between the re-reads of a vault being deleted (a virtual clock in the tests).
    public var deletionSleep: LockSleep = realLockSleep
    /// The pause before a change whose answer was lost is checked again (VAULT-MESSAGING §11.14.9 "A lost answer": 30 s,
    /// doubling up to 5 minutes), in seconds.
    public var changeCheckSleep: @Sendable (TimeInterval) async throws -> Void
    /// How long "Finish the move" holds the screen that asked for it at most (``FinishMoveRunner``; as vettid-android's
    /// 90 s hold, chosen; not in the spec).
    public var finishMoveHold: Duration = .seconds(90)
    /// The new phone's wait for the vault's `hs.resp` after its transfer `hs.init` (``MoveCodes/hsRespWait``; a pause the tests
    /// release).
    public var transferSleep: LockSleep = realLockSleep
    /// The new phone's wait for the deadline of its transfer (VAULT-MESSAGING §11.14.10 rule 5; a pause the tests release).
    public var transferDeadlineSleep: LockSleep = realLockSleep
    /// The bound of the one collect before the drop (30 s; a pause the tests release).
    public var transferCollectSleep: LockSleep = realLockSleep
    /// The limit of the day-7 check's wait for `device.list` (``keptEndCheck``; a pause the tests release).
    public var keptEndSleep: LockSleep = realLockSleep
    /// The wait to the end of a kept transfer (``VaultManager/checkKeptTransfer()``; a pause the tests release).
    public var keepSleep: LockSleep = realLockSleep
    /// How long the end-of-keep check of a transfer's old phone waits for the vault's `device.list` (vettid-android
    /// `KEPT_END_CHECK_MS`: 60 s).
    public var keptEndCheck: Duration = .seconds(60)
    /// How long a recovered phone waits for the vault's `hs.resp` after its `hs.init` (90 s after `ok`, 30 s when resuming):
    /// when set, the tests' wait for both.
    public var pairingWait: TimeInterval?
    /// The monotonic clock the vault's clock is counted on between its answers (seconds; tests move it).
    public var uptime: @Sendable () -> TimeInterval = DeviceConfig.monotonicNow
    /// How a change of PIN or password waits for the credential operations before it (VAULT-MESSAGING §11.14.9 step 1:
    /// at most 30 s): a sleep of the given length (tests pass their own).
    public var changeWaitSleep: @Sendable (TimeInterval) async throws -> Void = VaultApi.sleep

    public init(
        apiOrigin: String,
        manifestURL: String,
        relayURL: String,
        trust: AltTrust,
        transport: HTTPTransport,
        directory: URL,
        keys: VaultKeys,
        attester: any Attester,
        protectedData: any ProtectedData,
        enrolledAttestation: EnrolledAttestation,
        enclaveCheck: EnclaveCheck? = nil,
        deviceName: String,
        prepare: @escaping @Sendable () throws -> Void,
        collectMode: MailboxCollector.Mode = .longPoll,
        pollWait: TimeInterval = RelayClient.defaultWait,
        requestTimeout: TimeInterval = DeviceConfig.defaultTimeout,
        enrolledGrace: TimeInterval = 15,
        lockTiming: LockTiming = LockTiming(),
        wipeTargets: (any WipeTargets)? = nil,
        environment: String = "",
        now: @escaping @Sendable () -> Date = { Date() },
        changeCheckSleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.apiOrigin = apiOrigin.hasSuffix("/") ? String(apiOrigin.dropLast()) : apiOrigin
        self.manifestURL = manifestURL
        self.relayURL = relayURL
        self.trust = trust
        self.transport = transport
        self.directory = directory
        self.keys = keys
        self.attester = attester
        self.protectedData = protectedData
        self.enrolledAttestation = enrolledAttestation
        self.enclaveCheck = enclaveCheck
        self.deviceName = deviceName
        self.prepare = prepare
        self.collectMode = collectMode
        self.pollWait = pollWait
        self.requestTimeout = requestTimeout
        self.enrolledGrace = enrolledGrace
        self.lockTiming = lockTiming
        self.wipeTargets = wipeTargets
        self.environment = environment
        self.now = now
        self.changeCheckSleep = changeCheckSleep
    }

    /// An encrypted file of the vault manager in [directory].
    func file(_ name: String) -> EncryptedFileStore {
        EncryptedFileStore(
            url: directory.appendingPathComponent(name), purpose: name, keys: keys.files, protectedData: protectedData
        )
    }
}

public extension EnrolledAttestation {
    /// The app's check of `vault.enrolled` (§11.3): VettIDAttestation's verifier with the pinned Nitro [roots].
    static func nitro(roots: [[UInt8]]) -> EnrolledAttestation {
        let verifier = EnclaveVerifier(nitro: NitroVerifier(roots: roots))
        return .verify { doc, bundle, nonce, p, now in
            try verifier.verifyEnrolled(
                attestation: doc, vaultBundle: bundle, nonce: nonce,
                expected: Measurements(pcr0: p.pcr0, pcr1: p.pcr1, pcr2: p.pcr2), now: now
            )
        }
    }
}

/// The app key as the member API client signs with it: the key the store holds at each request, so that a new key for a
/// new vault (``AppKeyStore/regenerate()``) is used from the next request on. It never makes one: a setup, a recovery's
/// claim and a device make the key before their first request, and a request still on its way after a wipe must fail
/// rather than leave a new key on a phone left as freshly installed (``KeysError/missing(_:)``).
struct StoredAppKeySigner: AppKeySigner {
    let store: any AppKeyStore

    func spki() throws -> [UInt8] { try key().spki() }
    func sign(_ message: [UInt8]) throws -> [UInt8] { try key().sign(message) }

    private func key() throws -> any AppSigningKey { try store.lookup().get("app key") }
}

/// The device state in the encrypted file store (secret: it holds session keys).
struct FileDeviceStateStore: DeviceStateStore {
    let file: EncryptedFileStore

    func load() throws -> [UInt8]? { try file.load() }
    func save(_ state: [UInt8]) throws { try file.save(state) }
    func clear() throws { try file.clear() }
}

/// The vault id the member API signature names (§11.12.2): the paired device's, else the account record's; nil before
/// a redeem. Read by the client on any thread.
final class MemberVaultID: @unchecked Sendable {
    private let lock = NSLock()
    private var device: VaultDevice?
    private var recorded: String?

    func set(device: VaultDevice?) { lock.withLock { self.device = device } }
    func set(recorded: String?) { lock.withLock { self.recorded = recorded?.isEmpty == true ? nil : recorded } }

    var current: String? {
        let d = currentDevice()
        return d?.vaultID ?? currentRecorded()
    }

    private func currentDevice() -> VaultDevice? {
        lock.lock()
        defer { lock.unlock() }
        return device
    }

    private func currentRecorded() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}
