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
/// The slices so far (IOS-PLAN §8): what onboarding needs (I1.6: the phase at start, the setup code, enrollment with the
/// phone's unlock secret of epoch 1, §11.14.1 "On an iPhone", the first handshake, the credential and Finish setup),
/// the unlock and the member's lock (I1.7a: §11.4 with the phone secret, VAULT-LOCK as vettid-android implements it, the
/// vault events they follow), and Settings (I1.8: the account snapshot, the name change, the credential screen, the PIN
/// change). Every other operation keeps its protocol default or refuses with
/// ``FailureKind/notSupported`` until the row that brings it (`VaultManager+Later.swift`). Mirrors vettid-android
/// `VaultManager`.
@MainActor
@Observable
public final class VaultManager: AccountRepository, VaultRepository, CredentialRepository {
    // AccountRepository.
    public internal(set) var phase: AppPhase = .starting {
        didSet {
            phaseChanges += 1
            // The account is read again whenever the vault opens (an unlock, the end of onboarding, a start while open).
            if phase == .unlocked, oldValue != .unlocked { onOpened() }
        }
    }
    public internal(set) var account: AccountInfo?
    public internal(set) var servicePaused = false
    public let apiOrigin: String
    /// DevStack hints come with the dev stack's helpers (I1.3).
    public var devHint: String? { nil }

    // VaultRepository.
    public internal(set) var usesPhoneSecret = false
    public internal(set) var recoveryOffered = true
    /// The relay kept refusing this phone's messages to the vault while it was open (``RefusalWatch``).
    public internal(set) var refusedByVault = false
    /// (iPhone, IOS-PLAN §6.3 item 5) The earlier-secret step opened the vault: a new phone secret is asked for at once
    /// (the shell's prompt), until one is made or the member dismisses the prompt. The History entry comes with History.
    public internal(set) var renewSecretSuggested = false
    /// (STAGING-TIME-SCALE §5.2) The vault's time scale as this phone last learnt it (``LocalAccount/timeScale``).
    public internal(set) var timeScale: UInt64 = 1

    // CredentialRepository.
    public internal(set) var alarm: CredentialAlarm?
    /// Until when the unlock window is open (§3.5.3), as this app opened it.
    public internal(set) var unlockWindow: Date?

    @ObservationIgnored let config: VaultManagerConfig
    @ObservationIgnored let record: AccountRecord
    @ObservationIgnored let member: MemberApiClient
    @ObservationIgnored let phoneSecrets: PhoneSecrets
    @ObservationIgnored let memberVault = MemberVaultID()
    @ObservationIgnored let timeScaleCell = TimeScaleCell()
    @ObservationIgnored var session: VaultSession?
    @ObservationIgnored private var opening: Task<VaultSession, any Error>?
    /// Bumped whenever the session is dropped: a session opened before is not kept.
    @ObservationIgnored private var sessionGeneration = 0
    /// Bumped by every change of ``phase``: a refresh that started before one does not overwrite it.
    @ObservationIgnored private var phaseChanges = 0

    // The member's lock (VAULT-LOCK as vettid-android implements it) and what follows the vault's events.
    @ObservationIgnored let lockPorts: ManagerLockPorts
    @ObservationIgnored let lockGuard: LockGuard
    @ObservationIgnored let locking: LockSequence
    @ObservationIgnored let lockNotices = LockNotices()
    /// Bumped by every lock the member asks for: an unlock or a refresh that began before it publishes no open phase.
    @ObservationIgnored var lockGeneration = 0
    /// The pending lock found at the start was taken up (once, after the first-run cleanup and the record).
    @ObservationIgnored private var lockResumed = false
    @ObservationIgnored private(set) var holder: HolderWatch?
    @ObservationIgnored private(set) var refusals: RefusalWatch?
    /// The daily owner check (VAULT-MESSAGING §3.6): its state, the check, the interval and the hold.
    @ObservationIgnored public let ownerChecks: OwnerCheckManager
    /// The account's names (VAULT-MESSAGING §10.8): the name change, which counts as an owner check for its PIN and
    /// password (§3.6.4).
    @ObservationIgnored public let profiles: ProfileManager
    /// The canary manifest installed out of band (VAULT-RELEASES §10.1 step 9, VAULT-MESSAGING §11.10.1): used by the
    /// alternate channel instead of the published manifest only while it is newer.
    @ObservationIgnored public let canary: CanaryManifestManager
    /// The proactive release update (RELEASE-UPDATES §2): the offer and the one-step update.
    @ObservationIgnored public let releaseUpdate: ReleaseUpdateManager
    /// The `pin.change` the member started and whose answer has not confirmed it: a retry reuses its next-epoch record
    /// (IOS-PLAN §6.3 item 2). In memory only.
    @ObservationIgnored var pinChangeOperation: String?
    /// The `vault.secret.renew` the member started and whose answer has not confirmed it: a retry reuses its next-epoch
    /// record (IOS-PLAN §6.3 item 2). In memory only.
    @ObservationIgnored var renewOperation: String?
    /// A `vault.delete` of this process that got no answer: the member API's explicit "no vault" then means that the
    /// vault deleted itself, and a vault still listed after its deadline means it never will (``checkVaultDeleted()``). In
    /// memory only.
    @ObservationIgnored var deleteUnanswered: UnansweredDelete?
    /// TEST ONLY: replaces making the record of a confirmed `pin.change` current (a write that fails).
    @ObservationIgnored var confirmPinChangeOverride: (@MainActor (String) throws -> Void)?
    /// (VAULT-MESSAGING §11.14.9 "A lost answer") Where the decision of a change whose answer was lost stands.
    public internal(set) var changeCheck: ChangeCheck?
    /// (§11.14.9 step 5) Which PIN the unlock asks for while a PIN change is unresolved.
    public internal(set) var unlockPinStep: UnlockPinStep = .pin
    /// The unresolved change's request, to send again as the same request. In memory only, never on disk.
    @ObservationIgnored var heldChange: HeldRequest?
    /// The decision running now, and the next one after a pause.
    @ObservationIgnored var deciding: Task<Void, Never>?
    @ObservationIgnored var recheck: Task<Void, Never>?
    /// The previous PIN was answered `device_secret`: the unlock asks for the new one.
    @ObservationIgnored var newPinAsked = false
    /// A change of PIN or password is on its way in this process (its first send and resends): not decided meanwhile.
    @ObservationIgnored var sendingChange = false
    /// Bumped by a wipe or a forget: a decision that began before acts on nothing.
    @ObservationIgnored var changeGeneration = 0
    /// The change screen waiting for the decision, if any: the shell's notice leaves the decision to it.
    @ObservationIgnored weak var changeCheckWaiter: AnyObject?
    /// The wipe of this phone (nil: this build cannot wipe), and what it resets in memory besides the manager's own.
    @ObservationIgnored let wiper: LocalWipe?
    @ObservationIgnored var wipeHooks: [@MainActor () async -> Void] = []
    /// The old vault's device, detached by a wipe and kept until it is forgotten (a retried wipe too).
    @ObservationIgnored var wipeDevice: VaultDevice?
    /// A wipe's marker left at the start was looked at (once, after the first-run cleanup).
    @ObservationIgnored private var wipeResumed = false
    /// The tasks that follow the open session's events and refusals.
    @ObservationIgnored var observers: [Task<Void, Never>] = []
    /// Bumped by every return to the foreground: a background task that began before one does not stop the collection.
    @ObservationIgnored var foregrounds = 0
    /// The app left the foreground and its background work stopped the collection.
    @ObservationIgnored var backgrounded = false

    public init(config: VaultManagerConfig) {
        self.config = config
        apiOrigin = config.apiOrigin
        record = AccountRecord(store: config.file(VaultFiles.account))
        let ref = ManagerRef()
        let gate = config.attestStartOver
        let scale = timeScaleCell
        let policy = config.trust.timeScales
        record.onChange = { a in
            gate?.set(a.noVaultHoldsAttestKey)
            // A stored scale this build does not accept is real time: no writer can shorten a wait in a Release build.
            let s = policy.accepts(a.timeScale) ? a.timeScale : 1
            scale.set(s)
            if ref.manager?.timeScale != s { ref.manager?.timeScale = s }
        }
        let ids = memberVault
        member = MemberApiClient(
            apiBase: config.apiOrigin, manifestURL: config.manifestURL, transport: config.transport,
            auth: .appKey(StoredAppKeySigner(store: config.keys.appKeys), vaultID: { ids.current })
        )
        phoneSecrets = PhoneSecrets(
            keys: config.keys.phone, store: config.file(VaultFiles.phoneSecrets), now: config.now, timeScale: { scale.value }
        )
        canary = Self.canaryManifests(config, member, ref)
        releaseUpdate = ReleaseUpdateManager(ops: VaultReleaseUpdateOps(ref: ref))
        let timing = config.lockTiming
        let rec = record
        let lockFile = LockRecordFile(
            file: config.file(VaultFiles.lock),
            // During a wipe, and after one that did not finish, a missing lock file is no lock: nothing is left to lock.
            inUse: { rec.value.lockFileInUse && !rec.closed },
            onFirstSave: { _ = try? rec.update(since: rec.generation) { $0.lockFileInUse = true } },
            now: config.now
        )
        lockPorts = ManagerLockPorts(timing: timing)
        lockGuard = LockGuard(ports: lockPorts, now: config.now, sleep: timing.sleep) { attempt in
            LockKeeper(
                store: lockFile, attempt: attempt, now: config.now, backoff: timing.backoff, relayMargin: timing.relayMargin,
                sleep: timing.sleep
            )
        }
        locking = LockSequence(sleep: timing.sleep)
        ownerChecks = Self.ownerCheckManager(config, ref, rec, scale)
        profiles = Self.profiles(ref, checks: ownerChecks, record: rec)
        wiper = config.wipeTargets.map { LocalWipe(targets: $0, hooks: [{ await ref.manager?.runWipeHooks() }]) }
        ref.manager = self
        lockPorts.manager = self
        holder = HolderWatch { [weak self] in await self?.wipeReplacedPhone() }
        refusals = RefusalWatch { [weak self] in self?.refusedOnRelay() }
    }

    /// The daily owner check over the open session, kept in its encrypted file; [scale] the vault's time scale.
    private static func ownerCheckManager(
        _ config: VaultManagerConfig, _ ref: ManagerRef, _ rec: AccountRecord, _ scale: TimeScaleCell
    ) -> OwnerCheckManager {
        let checkFile = config.file(VaultFiles.ownerCheck)
        return OwnerCheckManager(
            ops: {
                guard let m = ref.manager else { throw VaultFailure(.other, code: "session_dropped") }
                // The record the session was opened for: a status answered after a reset is not stored.
                let since = rec.generation
                return VaultOwnerCheckOps(
                    api: try m.openApi(try await m.openSession()), gate: Self.pinGate(ref),
                    onStatus: { st in await ref.manager?.learnTimeScale(status: st, since: since) }
                )
            },
            load: { try checkFile.load() },
            // Nothing is written while a wipe runs or after one that did not finish.
            persist: { b in
                guard !rec.closed else { return }
                if b.isEmpty { try checkFile.clear() } else { try checkFile.save(b) }
            },
            now: config.now,
            mark: { rec.generation },
            sleep: config.lockTiming.sleep,
            timeScale: { scale.value }
        )
    }

    /// The canary manifest in its encrypted file, checked against the serial this phone used and the published manifest.
    private static func canaryManifests(_ config: VaultManagerConfig, _ api: MemberApiClient, _ ref: ManagerRef) -> CanaryManifestManager {
        CanaryManifestManager(
            store: CanaryManifestStore(file: config.file(VaultFiles.canary)), trust: config.trust,
            seen: { try await ref.manager?.manifestSerialUsed() ?? 0 },
            published: { try await api.manifest() }
        )
    }

    /// The relay kept refusing this phone's messages to the vault (``RefusalWatch``): the unlock screen, which says so.
    private func refusedOnRelay() {
        phase = .locked
        refusedByVault = true
    }

    /// The gate of an operation that carries the PIN (VAULT-MESSAGING §11.14.9 steps 2 and 3).
    private static func pinGate(_ ref: ManagerRef) -> @Sendable () async throws -> Void {
        { try await ref.manager?.decideFirst(carriesPin: true) }
    }

    /// The name change over this manager's session: the request kept with the account record it was sent for, the checks
    /// left read again after a wrong PIN or password.
    private static func profiles(_ ref: ManagerRef, checks: OwnerCheckManager, record rec: AccountRecord) -> ProfileManager {
        ProfileManager(
            ops: {
                guard let m = ref.manager else { throw VaultFailure(.other, code: "session_dropped") }
                return VaultProfileOps(api: try m.openApi(try await m.openSession()), gate: Self.pinGate(ref))
            },
            onRequest: { r, since in ref.manager?.keepNameRequest(r, since: since) },
            checksLeft: {
                try? await checks.refreshOwnerCheck()
                return checks.ownerCheck?.checksLeft
            },
            mark: { rec.generation }
        )
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
        resumePendingWipe()
        try record.refuseWhileClosed()
        try record.load()
        ownerChecks.loadIfNeeded()
        canary.loadIfNeeded()
        memberVault.set(recorded: record.value.vaultID)
        if account == nil { account = record.value.info }
        if !lockResumed {
            lockResumed = true
            // A lock that was pending when the process ended: locked from the start, and tried again at once.
            lockGuard.keeper.resume()
            lockNotices.opened(at: record.value.lastOpenedMs.map { Date(timeIntervalSince1970: Double($0) / 1000) })
        }
    }

    /// At the start, right after the first-run cleanup and before anything reads local files: a wipe a crash interrupted
    /// is finished; one that still cannot finish shuts the record until a wipe completes. Once per process.
    public func resumePendingWipe() {
        guard !wipeResumed, let wiper else { return }
        wipeResumed = true
        guard wiper.pending else { return }
        wiper.resumeIfPending()
        ownerChecks.clear()
        if wiper.pending { record.markEraseFailed() }
    }

    /// Protected data became available: what could not be read before (the owner check kept on the phone) is read now.
    public func reloadLocalState() { try? prepared() }

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
        let source = canary.store
        let generation = sessionGeneration
        // §11.14.9 "A lost answer": checked again under the credential lock, where a change that began after an
        // operation's own check is seen.
        let gate: @Sendable (Bool) async throws -> Void = { [weak self] carriesPin in
            try await self?.credentialGate(carriesPin: carriesPin)
        }
        let task = Task { try await Self.makeSession(c, member, source, gate: gate) }
        opening = task
        defer { opening = nil }
        let s = try await task.value
        if let session { return session }
        // Dropped while it was being opened: not kept (its state may be forgotten already).
        guard generation == sessionGeneration else { throw VaultFailure(.other, code: "session_dropped") }
        session = s
        memberVault.set(device: s.device)
        // A phone registered for a recovery holds the key the vault bound at the register (IOS-PLAN §6.2).
        config.attestStartOver?.set(recovering: s.device.recovering)
        // In the background nothing starts the collection again (a lock's retry opens the session): the return to the
        // foreground does (IOS-PLAN §6.6).
        if !backgrounded { s.device.start() }
        observe(s)
        // A start or a reconnection: a change whose answer was lost is decided first (§11.14.9 step 2).
        kickChangeCheck()
        return s
    }

    private nonisolated static func makeSession(
        _ c: VaultManagerConfig, _ member: MemberApiClient, _ canary: CanaryManifestStore,
        gate: @escaping @Sendable (Bool) async throws -> Void
    ) async throws -> VaultSession {
        // A wipe cancels an opening: nothing more is made or written from here.
        try Task.checkCancellation()
        let keys = DeviceKeys(wrapper: SeedWrapper(source: c.keys.seedWrap), store: c.keys.wrapped)
        for slot in KeySlot.allCases where try !keys.has(slot) {
            try Task.checkCancellation()
            try keys.generate(slot)
        }
        let secrets = DeviceSecrets(
            identity: try keys.ed25519(.identity), kem: try keys.kem(), relay: try keys.ed25519(.relay),
            apiKey: try c.keys.appKeys.getOrCreate().spki()
        )
        let cfg = DeviceConfig(
            name: c.deviceName, relayURL: c.relayURL, transport: c.transport,
            store: FileDeviceStateStore(file: c.file(VaultFiles.device)), enrolledAttestation: c.enrolledAttestation, now: c.now,
            collectMode: c.collectMode, pollWait: c.pollWait, requestTimeout: c.requestTimeout, uptime: c.uptime
        )
        let restored = try VaultDevice.load(cfg, secrets: secrets)
        try Task.checkCancellation()
        let device = if let restored { restored } else { try await VaultDevice.create(cfg, secrets: secrets) }
        try Task.checkCancellation()
        // IOS-PLAN ID8: every vault this app holds is of release R, whose passwords are normalized to NFC (§11.14.7).
        let api = VaultApi(device: device, normalizePasswords: { true }, credentialGate: gate, changeWaitSleep: c.changeWaitSleep)
        let alt = AltChannelFlow(api: member, trust: c.trust, now: c.now, canary: canary, verifyEnclave: c.enclaveCheck)
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

    /// Cancels a session being opened and waits until it stopped (a wipe: nothing it writes outlives the erase). True
    /// when one was.
    func cancelOpening() async -> Bool {
        guard let task = opening else { return false }
        sessionGeneration += 1
        task.cancel()
        _ = try? await task.value
        return true
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
        stopObserving()
        guard forget else {
            s?.device.stop()
            return
        }
        if let d = s?.device { try await d.forget() }
        try await Self.forgetKeys(config)
        try phoneSecrets.delete()
        usesPhoneSecret = false
        pinChangeOperation = nil
        renewOperation = nil
        renewSecretSuggested = false
        forgetChangeCheck()
        releaseUpdate.clear()
        unlockWindow = nil
        try record.update(since: record.generation) {
            $0.setupComplete = false
            $0.capabilities = []
            $0.timeScale = 1
        }
        // The vault is no longer this phone's: nothing to lock from here. Only once the forget succeeded: a forget that
        // failed leaves the phone holding the vault, and its pending lock with it.
        lockGuard.keeper.abandon()
    }

    private nonisolated static func forgetKeys(_ c: VaultManagerConfig) async throws {
        let keys = DeviceKeys(wrapper: SeedWrapper(source: c.keys.seedWrap), store: c.keys.wrapped)
        for slot in KeySlot.allCases { try keys.generate(slot) }
        _ = try c.keys.appKeys.regenerate()
        try c.file(VaultFiles.device).clear()
    }

    /// The code of a start-over refused because the phone may hold a vault (``mayHoldVault(_:)``).
    public nonisolated static let codeEnrollmentStarted = "enrollment_started"

    /// The highest manifest serial this phone has used for its vault (§11.10.1), 0 without a device: the canary
    /// manifest's installation check.
    func manifestSerialUsed() async throws -> UInt64 {
        try await storedSession()?.device.manifestSerialSeen() ?? 0
    }

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
        stopObserving()
    }

    // MARK: - The phase

    public func refresh() async throws {
        let gen = record.generation
        let changes = phaseChanges
        let locks = lockGeneration
        let p: AppPhase
        do {
            p = try await guarded { try await evaluate() }
        } catch let f as VaultFailure {
            // What the phone stores for the vault could not be read: said as that, with the way out, rather than as
            // "cannot connect".
            let kind = f.code == VaultFailures.codeKeystore ? FailureKind.localState : f.kind
            // Nothing has reached the vault service for a long time: erase-or-recover beside "Try again".
            let last = [record.value.lastContactMs, record.value.lastOpenedMs].compactMap { $0 }.max()
            let long = StuckScreens.longUnreachable(kind, lastContactMs: last, nowMs: nowMs, timeScale: record.value.timeScale)
            p = .unreachable(kind, longUnreachable: long)
        }
        // A reset, a lock, or a newer phase set by an operation meanwhile, wins.
        if gen == record.generation, changes == phaseChanges, locks == lockGeneration { phase = p }
    }

    /// The phone's clock, in Unix ms.
    var nowMs: Int64 { Int64((config.now().timeIntervalSince1970 * 1000).rounded(.down)) }

    private func evaluate() async throws -> AppPhase {
        if record.eraseFailed {
            // "Try again" after a wipe that did not finish: it runs again, and its phase says how it ended.
            await holder?.wipeNow()
            return phase
        }
        try prepared()
        usesPhoneSecret = phoneSecrets.inUse
        // §11.14.9 step 5: a PIN change left unresolved by an earlier run makes the unlock ask for the previous PIN.
        refreshPinStep()
        recoveryOffered = ReleasePath.recoveryOffered(record.value.capabilities)
        let local = record.value
        // Nothing redeemed on this phone: the welcome screen.
        if local.userGuid.isEmpty && !local.transferIn { return .signedOut }
        let s = try await openSession()
        let d = s.device
        config.attestStartOver?.set(recovering: d.recovering)
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
        return try await pairedPhase(s, local)
    }

    /// The phase of a paired phone: from the member API's status, unless a lock is pending.
    private func pairedPhase(_ s: VaultSession, _ local: LocalAccount) async throws -> AppPhase {
        let d = s.device
        let status: VaultStatus?
        let rec = record.generation
        // Taken before the status is awaited: an answer produced while an unlock ran confirms no lock (``LockKeeper``).
        let mark = lockGuard.keeper.evidenceMark
        do {
            status = try await vaultStatus()
            // The last contact, for the stuck screen: a record that cannot be written now changes nothing here.
            _ = try? record.contacted(since: rec, nowMs: nowMs)
        } catch {
            // A lock is pending and the vault cannot be reached: the unlock screen, with its notice (never the open app,
            // and not "cannot connect" either: the member has to see that the lock is not confirmed).
            if lockGuard.lockedWhatever(unlocked: nil) { return .locked }
            // The API no longer accepts this phone's app key: the unlock screen says so; only the enclave's own answer
            // erases anything.
            if let e = error as? MemberApiError, e.code == MemberApiError.unauthorized { return .locked }
            throw error
        }
        // A lock is pending: locked on this phone whatever the status says, and confirmed if it says so.
        if lockGuard.lockedWhatever(unlocked: status?.state == Self.stateUnlocked, since: mark) { return .locked }
        // The API says, explicitly, that the account has no vault: the member decides (``forgetMissingVault()``).
        guard let status else { return .unreachable(.noVault) }
        if d.recovering { return .setup(.recovering) }
        guard status.state == Self.stateUnlocked else { return .locked }
        if d.credentialVersion == nil { return .setup(.needsCredential) }
        ownerChecks.onOpened()
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

/// The vault manager, for what it makes before it is fully initialised (the owner check's operations).
@MainActor
final class ManagerRef {
    weak var manager: VaultManager?
}
