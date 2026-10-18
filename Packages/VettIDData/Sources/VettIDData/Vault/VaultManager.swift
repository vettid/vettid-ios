import Foundation
import Observation
import VettIDAltChan
import VettIDCrypto
import VettIDKeys
import VettIDVault

/// This device's session with the vault: the device (keys, state, mailbox), its typed client and the alternate
/// channel.
struct VaultSession: Sendable {
    let device: VaultDevice
    let api: VaultApi
    let alt: AltChannelFlow
}

/// The app's vault on this device: the member API signed by the app key (no sign-in, VAULT-MESSAGING §11.12), the
/// device keys behind their protocols, the device state and the account record in the encrypted file store, the vault
/// client and the alternate channel. Implements the repositories the features use; nothing in a feature touches
/// transport or crypto. One instance per process, on the main actor; the work it waits for runs off it.
///
/// This slice (IOS-PLAN §8 I1.6) is the part onboarding needs: the phase at start, the setup code, enrollment with the
/// phone's unlock secret of epoch 1 (§11.14.1 "On an iPhone"), the first handshake, the credential and Finish setup.
/// Every other operation keeps its protocol default or refuses with ``FailureKind/notSupported`` until the row that
/// brings it (`VaultManager+Later.swift`). Mirrors vettid-android `VaultManager`.
@MainActor
@Observable
public final class VaultManager: AccountRepository, VaultRepository, CredentialRepository {
    // AccountRepository.
    public internal(set) var phase: AppPhase = .starting {
        didSet { phaseChanges += 1 }
    }
    public internal(set) var account: AccountInfo?
    public internal(set) var servicePaused = false
    public let apiOrigin: String
    /// DevStack hints come with the dev stack's helpers (I1.3).
    public var devHint: String? { nil }

    // VaultRepository.
    public internal(set) var usesPhoneSecret = false
    public internal(set) var recoveryOffered = true
    /// The relay's refusals are followed with the unlock (I1.7, `RefusalWatch`).
    public internal(set) var refusedByVault = false

    // CredentialRepository: the alarm and the unlock window come with the credential screen (I1.8).
    public internal(set) var alarm: CredentialAlarm?
    public internal(set) var unlockWindow: Date?

    @ObservationIgnored let config: VaultManagerConfig
    @ObservationIgnored let record: AccountRecord
    @ObservationIgnored let member: MemberApiClient
    @ObservationIgnored let phoneSecrets: PhoneSecrets
    @ObservationIgnored let memberVault = MemberVaultID()
    @ObservationIgnored var session: VaultSession?
    @ObservationIgnored private var opening: Task<VaultSession, any Error>?
    /// Bumped whenever the session is dropped: a session opened before is not kept.
    @ObservationIgnored private var sessionGeneration = 0
    /// Bumped by every change of ``phase``: a refresh that started before one does not overwrite it.
    @ObservationIgnored private var phaseChanges = 0

    public init(config: VaultManagerConfig) {
        self.config = config
        apiOrigin = config.apiOrigin
        record = AccountRecord(store: config.file(VaultFiles.account))
        let ids = memberVault
        member = MemberApiClient(
            apiBase: config.apiOrigin, manifestURL: config.manifestURL, transport: config.transport,
            auth: .appKey(StoredAppKeySigner(store: config.keys.appKeys), vaultID: { ids.current })
        )
        phoneSecrets = PhoneSecrets(keys: config.keys.phone, store: config.file(VaultFiles.phoneSecrets), now: config.now)
    }

    // MARK: - Failures

    /// Runs [body] and turns every failure into a ``VaultFailure`` (a cancellation stays one). Mirrors vettid-android
    /// `VaultManager.guard`.
    @discardableResult
    func guarded<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            throw noted(VaultFailures.map(error))
        }
    }

    @discardableResult
    func guardedSync<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch {
            throw noted(VaultFailures.map(error))
        }
    }

    /// MEMBER-API 1.2.0: a refusal while paused also shows the banner (the status may not have been read yet).
    private func noted(_ e: any Error) -> any Error {
        if let f = e as? VaultFailure, f.kind == .servicePaused { servicePaused = true }
        return e
    }

    // MARK: - Local state

    /// The first-run cleanup, then the account record (IOS-PLAN §6.1: nothing is read before the cleanup ran).
    func prepared() throws {
        try config.prepare()
        try record.load()
        memberVault.set(recorded: record.value.vaultID)
        if account == nil { account = record.value.info }
    }

    /// A record of its own (a redeem, or none after "that is not my account").
    func resetRecord(_ a: LocalAccount) throws {
        try record.reset(a)
        memberVault.set(recorded: a.vaultID)
        account = a.info
        recoveryOffered = ReleasePath.recoveryOffered(a.capabilities)
    }

    // MARK: - Session

    /// The session, opened once: the device keys (made when missing), the device restored from its state or created
    /// (registering its mailbox at the relay), and its collector started.
    func openSession() async throws -> VaultSession {
        if let session { return session }
        if let opening { return try await opening.value }
        try prepared()
        let c = config
        let member = member
        let generation = sessionGeneration
        let task = Task { try await Self.makeSession(c, member) }
        opening = task
        defer { opening = nil }
        let s = try await task.value
        if let session { return session }
        // Dropped while it was being opened: not kept (its state may be forgotten already).
        guard generation == sessionGeneration else { throw VaultFailure(.other, code: "session_dropped") }
        session = s
        memberVault.set(device: s.device)
        s.device.start()
        return s
    }

    private nonisolated static func makeSession(_ c: VaultManagerConfig, _ member: MemberApiClient) async throws -> VaultSession {
        let keys = DeviceKeys(wrapper: SeedWrapper(source: c.keys.seedWrap), store: c.keys.wrapped)
        for slot in KeySlot.allCases where try !keys.has(slot) { try keys.generate(slot) }
        let secrets = DeviceSecrets(
            identity: try keys.ed25519(.identity), kem: try keys.kem(), relay: try keys.ed25519(.relay),
            apiKey: try c.keys.appKeys.getOrCreate().spki()
        )
        let cfg = DeviceConfig(
            name: c.deviceName, relayURL: c.relayURL, transport: c.transport,
            store: FileDeviceStateStore(file: c.file(VaultFiles.device)), enrolledAttestation: c.enrolledAttestation, now: c.now,
            collectMode: c.collectMode, pollWait: c.pollWait, requestTimeout: c.requestTimeout
        )
        let restored = try VaultDevice.load(cfg, secrets: secrets)
        let device = if let restored { restored } else { try await VaultDevice.create(cfg, secrets: secrets) }
        // IOS-PLAN ID8: every vault this app holds is of release R, whose passwords are normalized to NFC (§11.14.7).
        let api = VaultApi(device: device) { true }
        let alt = AltChannelFlow(api: member, trust: c.trust, now: c.now, verifyEnclave: c.enclaveCheck)
        return VaultSession(device: device, api: api, alt: alt)
    }

    /// How long the keys of an enrollment with an unknown outcome are kept from a start-over: a provisional vault not
    /// confirmed within 24 h may be replaced (§11.3), plus an hour's margin (chosen; not in the spec).
    static let unknownEnrollmentKept: TimeInterval = 25 * 3600

    /// Whether this phone may hold a vault, even a provisional one: paired, a vault pinned by `vault.enrolled`, or an
    /// enrollment request whose outcome is not known (a lost answer, a crash mid-request) started less than
    /// ``unknownEnrollmentKept`` ago. Its keys are then never forgotten by a start-over (chosen; not in the spec:
    /// vettid-android forgets an unpaired device's).
    func mayHoldVault(_ d: VaultDevice?) -> Bool { startOverRefusal(d) != nil }

    /// The refusal of a start-over (or of another vault's code) while the phone may hold a vault: kind
    /// ``FailureKind/enrollmentStarted``, code ``codeEnrollmentStarted``, and, for an unknown outcome, the seconds until
    /// the start-over becomes possible.
    func startOverRefusal(_ d: VaultDevice?) -> VaultFailure? {
        if let d, d.deviceID != nil || d.hasVault || d.vaultID != nil {
            return VaultFailure(.enrollmentStarted, code: Self.codeEnrollmentStarted)
        }
        guard let started = record.value.enrollStartedMs else { return nil }
        let left = Double(started) / 1000 + Self.unknownEnrollmentKept - config.now().timeIntervalSince1970
        guard left > 0 else { return nil }
        return VaultFailure(.enrollmentStarted, code: Self.codeEnrollmentStarted, retryAfterSeconds: Int64(left.rounded(.up)))
    }

    /// Drops the session. [forget]: the device state goes, with fresh device keys and a new app key for the next setup
    /// (the app key is per vault, §11.12.2), and every phone key and record. Refused while the phone may hold a vault
    /// (``mayHoldVault(_:)``) unless [vaultGone]: the member API, asked again, said explicitly that it has none.
    func dropSession(forget: Bool, vaultGone: Bool = false) async throws {
        if forget, !vaultGone, let refusal = startOverRefusal(session?.device) { throw refusal }
        let s = session
        session = nil
        sessionGeneration += 1
        memberVault.set(device: nil)
        guard forget else {
            s?.device.stop()
            return
        }
        if let d = s?.device { try await d.forget() }
        try await Self.forgetKeys(config)
        try phoneSecrets.delete()
        usesPhoneSecret = false
        try record.update(since: record.generation) {
            $0.setupComplete = false
            $0.capabilities = []
        }
    }

    private nonisolated static func forgetKeys(_ c: VaultManagerConfig) async throws {
        let keys = DeviceKeys(wrapper: SeedWrapper(source: c.keys.seedWrap), store: c.keys.wrapped)
        for slot in KeySlot.allCases { try keys.generate(slot) }
        _ = try c.keys.appKeys.regenerate()
        try c.file(VaultFiles.device).clear()
    }

    /// The code of a start-over refused because the phone may hold a vault (``mayHoldVault(_:)``).
    public nonisolated static let codeEnrollmentStarted = "enrollment_started"

    /// The session when this phone has a device: the open one, or the one its stored state restores. Nil when it has
    /// none (nothing to protect, and no mailbox registered for nothing).
    func storedSession() async throws -> VaultSession? {
        if let session { return session }
        guard try config.file(VaultFiles.device).load() != nil else { return nil }
        return try await openSession()
    }

    /// Stops the mailbox collection (the app leaving the foreground, IOS-PLAN §6.6; the end of a test). The next
    /// operation that needs the vault starts it again.
    public func stopCollecting() {
        session?.device.stop()
        session = nil
        sessionGeneration += 1
        memberVault.set(device: nil)
    }

    // MARK: - The phase

    public func refresh() async throws {
        let gen = record.generation
        let changes = phaseChanges
        let p: AppPhase
        do {
            p = try await guarded { try await evaluate() }
        } catch let f as VaultFailure {
            // What the phone stores for the vault could not be read: said as that, with the way out (I1.7), rather
            // than as "cannot connect".
            p = .unreachable(f.code == VaultFailures.codeKeystore ? .localState : f.kind)
        }
        // A reset, or a newer phase set by an operation meanwhile, wins.
        if gen == record.generation, changes == phaseChanges { phase = p }
    }

    private func evaluate() async throws -> AppPhase {
        try prepared()
        usesPhoneSecret = phoneSecrets.inUse
        recoveryOffered = ReleasePath.recoveryOffered(record.value.capabilities)
        let local = record.value
        // Nothing redeemed on this phone: the welcome screen.
        if local.userGuid.isEmpty && !local.transferIn { return .signedOut }
        let s = try await openSession()
        let d = s.device
        // vault.enrolled pinned the vault: the epoch-1 secret it holds is this phone's (a crash or a lost answer
        // before the enrollment's own answer confirmed it).
        try confirmEnrolledSecret(local, d)
        if d.deviceID == nil {
            if d.recovering { return .setup(.recovering) }
            // Enrolled, the first handshake (or the credential) not finished.
            if d.vaultID != nil { return .setup(.needsCredential) }
            // A redeemed code: enroll. The enrollment itself answers vault_exists for a vault this phone does not hold.
            return local.userGuid.isEmpty ? .signedOut : .setup(.newVault)
        }
        let status: VaultStatus?
        do {
            status = try await vaultStatus()
        } catch let e as MemberApiError where e.code == MemberApiError.unauthorized {
            // The API no longer accepts this phone's app key: the unlock screen says so (I1.7); only the enclave's own
            // answer erases anything.
            return .locked
        }
        // The API says, explicitly, that the account has no vault: the member decides (``forgetMissingVault()``).
        guard let status else { return .unreachable(.noVault) }
        if d.recovering { return .setup(.recovering) }
        guard status.state == Self.stateUnlocked else { return .locked }
        if d.credentialVersion == nil { return .setup(.needsCredential) }
        // A restart after the credential and before the confirmation: the vault is still provisional (§11.3) and may be
        // replaced; the backup choice and vault.enroll.confirm are sent before anything else.
        // Only the phone whose enrollment made the vault confirms it.
        if !local.enrollConfirmed, local.enrolledHere { try await confirmEnrollment(s, backup: local.backupChoice) { _ in } }
        return local.setupComplete ? .unlocked : .setup(.finishing)
    }

    nonisolated static let stateUnlocked = "unlocked"

    /// `GET /api/vault/status`, following its top-level `service` (MEMBER-API 1.2.0) for the banner.
    func vaultStatus() async throws -> VaultStatus? {
        let a = try await member.vaultStatusAnswer()
        servicePaused = a.servicePaused
        return a.vault
    }
}
