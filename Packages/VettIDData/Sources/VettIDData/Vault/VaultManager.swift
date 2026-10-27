import Foundation
import Observation
import VettIDAltChan
import VettIDCrypto
import VettIDKeys
import VettIDVault

/// This device's session with the vault: the device (keys, state, mailbox), its typed client and the alternate
/// channel.
struct VaultSession: Sendable {
    let identity: IdentitySet // the device identity (IOS-PLAN 0.1.38 §4.9) whose keys and state this is
    let device: VaultDevice
    let api: VaultApi
    let alt: AltChannelFlow
}

/// The app's vault on this device: the member API signed by the app key (no sign-in, VAULT-MESSAGING §11.12), the
/// device keys behind their protocols, the device state and the account record in the encrypted file store, the vault
/// client and the alternate channel. Implements the repositories the features use; nothing in a feature touches
/// transport or crypto. One instance per process, on the main actor; the work it waits for runs off it.
///
/// The slices so far (IOS-PLAN §8): onboarding (I1.6), the unlock and the member's lock (I1.7a), Settings (I1.8), the
/// connections and messages (I2.1, I2.2), the feed, the approvals and History (I2.3), fed this manager's events; a vault
/// being deleted (IOS-PLAN §4.2). Every other operation keeps its protocol default until the row that brings it.
/// Mirrors vettid-android `VaultManager`.
@MainActor
@Observable
public final class VaultManager: AccountRepository, VaultRepository, CredentialRepository {
    // AccountRepository. ``phase`` reads ``AppPhase/deleting`` over the phase set while a vault is being deleted.
    public internal(set) var phase: AppPhase {
        get { deletion != nil ? .deleting : storedPhase }
        set { storedPhase = newValue }
    }
    var storedPhase: AppPhase = .starting {
        didSet {
            let phase = storedPhase
            phaseChanges += 1
            // The account is read again whenever the vault opens (an unlock, the end of onboarding, a start while open).
            if phase == .unlocked, oldValue != .unlocked { onOpened() }
            if phase != .unlocked, oldValue == .unlocked { forgetOpenLists() } // not kept once it is locked
            if phase != oldValue, OwnProfileStep.onPhase(phase) == .forget { forgetOwnProfile() } // IOS-PLAN §4.7
            // IOS-PLAN §4.4 (1): the root screen ends with the lock (``lock()``), "Try again", and when nothing is set up
            // any more (a sign-out, a wipe, a deletion); not in between, so that a refusal during an unlock that includes
            // the daily check still shows it.
            if phase == .signedOut {
                credentialRequired = false
                credentialRequiredResend = nil
            }
        }
    }
    public internal(set) var account: AccountInfo?
    @ObservationIgnored let ownAccount = OwnAccount() // memory only (IOS-PLAN §4.7)
    public internal(set) var servicePaused = false
    /// (IOS-PLAN §4.4 (1)) The vault answered `credential_required`: the root screen "This phone can't use your vault".
    public internal(set) var credentialRequired = false
    /// What "Try again" sends again (``credentialRequiredTryAgain()``): the ``Resend`` of the request that raised it.
    @ObservationIgnored var credentialRequiredResend: Resend?
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
    /// (IOS-PLAN §4.2) The vault being deleted, and the one-time notice on "no vault" after it.
    public internal(set) var deletion: VaultDeletion?
    public internal(set) var vaultDeletedNotice = false
    /// (IOS-PLAN §4.3) The unconfirmed move from the device's release records (``readMoveMarker()``).
    public internal(set) var unconfirmedMove: UnconfirmedMove?
    @ObservationIgnored var deletionWatch: DeletionWatch?
    /// This phone's own `vault.delete` on its way, and whether `device.unlinked{vault_deleted}` came meanwhile.
    @ObservationIgnored var ownDelete: OwnDelete?

    @ObservationIgnored let config: VaultManagerConfig
    @ObservationIgnored let record: AccountRecord
    @ObservationIgnored let member: MemberApiClient
    @ObservationIgnored let phoneSecrets: PhoneSecrets
    @ObservationIgnored let memberVault = MemberVaultID()
    @ObservationIgnored let timeScaleCell = TimeScaleCell()
    @ObservationIgnored var session: VaultSession?
    @ObservationIgnored private var opening: Task<VaultSession, any Error>?
    /// Bumped whenever the session is dropped: a session opened before is not kept.
    @ObservationIgnored var sessionGeneration = 0
    /// Bumped by every change of ``phase``: a refresh that started before one does not overwrite it.
    @ObservationIgnored private var phaseChanges = 0

    // The member's lock (VAULT-LOCK as vettid-android implements it) and what follows the vault's events.
    @ObservationIgnored let lockPorts: ManagerLockPorts
    @ObservationIgnored let lockGuard: LockGuard
    @ObservationIgnored let locking: LockSequence
    @ObservationIgnored let lockNotices = LockNotices()
    /// Bumped by every lock the member asks for: an unlock or a refresh that began before it publishes no open phase.
    @ObservationIgnored var lockGeneration = 0
    /// Bumped by each event that has the phase read again (`device.unlinked`, not a replacement): an unlock it reached
    /// on its way reads the phase again rather than publish its own (chosen; not in the spec).
    @ObservationIgnored var rereads = 0
    @ObservationIgnored private(set) var holder: HolderWatch?
    @ObservationIgnored private(set) var refusals: RefusalWatch?
    /// The daily owner check (VAULT-MESSAGING §3.6): its state, the check, the interval and the hold.
    @ObservationIgnored public let ownerChecks: OwnerCheckManager
    /// The account's names (VAULT-MESSAGING §10.8): the name change counts as an owner check (§3.6.4).
    @ObservationIgnored public let profiles: ProfileManager
    /// Connections, invitations and connection requests (VAULT-MESSAGING §6.4, §10.4), kept in their encrypted file.
    @ObservationIgnored public let connections: ConnectionsManager
    /// Messages with connections (VAULT-MESSAGING §10.5, §10.5.2), in memory only.
    @ObservationIgnored public let messages: MessagesManager
    /// Photo attachments (§10.5.1), the member's items and tags (§10.7, §10.8, ``VaultManager+Items``): in memory only,
    /// cleared whenever the vault is not open, held or due, and at a wipe.
    @ObservationIgnored public let attachments: AttachmentManager
    @ObservationIgnored public private(set) lazy var items: ItemsManager = Self.itemsManager(self)
    @ObservationIgnored public private(set) lazy var sharing: SharingManager = Self.sharingManager(self)
    /// The feed, the approvals, History and its export (VAULT-MESSAGING §10.9, §10.12, §10.13; ``VaultManager+Activity``).
    @ObservationIgnored public let feed: FeedManager
    @ObservationIgnored public let approvals: ApprovalsManager
    @ObservationIgnored public let history: HistoryManager
    @ObservationIgnored public let historyExport: HistoryExportManager
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
    /// A `vault.delete` of this process that got no answer, in memory only: a vault listed after its deadline means that it
    /// never will delete itself (``checkVaultDeleted()``); `{vault: null}` decides nothing.
    @ObservationIgnored var deleteUnanswered: UnansweredDelete?
    /// TEST ONLY: replaces making the record of a confirmed `pin.change` current (a write that fails).
    @ObservationIgnored var confirmPinChangeOverride: (@MainActor (String) throws -> Void)?
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
    /// Every device a session of this manager held, weakly: a session closed (a lock, a deletion) may leave a request on
    /// its way whose end still saves the device state. A wipe or a forget forgets them all (``forgetEveryDevice()``).
    @ObservationIgnored let devicesMade = MadeDevices()
    /// Set by ``halt()``: the process is going away, and nothing more is started.
    @ObservationIgnored var halted = false
    /// A wipe's marker left at the start was looked at (once, after the first-run cleanup).
    @ObservationIgnored private var wipeResumed = false
    @ObservationIgnored let moveFlags = MoveFlags() // the move to another phone, and the rotate offer (VaultManager+MoveState)
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
            ref.manager?.recordChanged(a)
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
                sleep: timing.sleep, onOpenedAgain: { ref.manager?.forgetUnlockID($0) }
            )
        }
        locking = LockSequence(sleep: timing.sleep)
        ownerChecks = Self.ownerCheckManager(config, ref, rec, scale)
        profiles = Self.profiles(ref, checks: ownerChecks, record: rec)
        connections = Self.connectionsManager(config, ref, rec)
        (messages, attachments) = Self.messageManagers(ref, connections)
        (feed, approvals, history, historyExport) = Self.activityManagers(config, ref, rec, connections, ownerChecks)
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
            // §3.6.3: nothing held back is replayed as events; the lists are read again (as vettid-android).
            onPassed: { ref.manager?.refreshListsQuietly() },
            onRecoveryStatus: { r, since in ref.manager?.noteRecoveryStatus(r, since: since) },
            now: config.now,
            mark: { rec.generation },
            sleep: config.lockTiming.sleep, timeScale: { scale.value },
            notes: Self.failureNotes(ref)
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
    static func pinGate(_ ref: ManagerRef) -> @Sendable () async throws -> Void {
        { try await ref.manager?.decideFirst(carriesPin: true) }
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
        connections.loadIfNeeded()
        approvals.loadIfNeeded()
        memberVault.set(recorded: record.value.vaultID)
        if account == nil { publishAccount() }
        if !moveFlags.book.lockResumed {
            moveFlags.book.lockResumed = true
            // A lock that was pending when the process ended: locked from the start, and tried again at once.
            lockGuard.keeper.resume()
            resumeLockNotices()
        }
        resumeMoveState()
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
    func resetRecord(_ a: LocalAccount, carryRule: Bool = false) throws {
        // IOS-PLAN 0.1.38 §4.9: only a new recovery's registration ([carryRule]) keeps the identities of a phone that could not
        // tell through its record; they are cleared with the completed pairing or when the vault is gone, in a save of their own.
        var a = a
        if carryRule { (a.activeIdentity, a.couldNotTell) = (record.value.activeIdentity, record.value.couldNotTell) }
        try record.reset(a)
        memberVault.set(recorded: a.vaultID)
        forgetOwnProfile() // another record: nothing of the one before (IOS-PLAN §4.7)
        recoveryOffered = ReleasePath.recoveryOffered(a.capabilities)
    }

    // MARK: - Session

    /// The session, opened once: the device keys (made when missing), the device restored from its state or created
    /// (registering its mailbox at the relay), and its collector started.
    func openSession() async throws -> VaultSession {
        if let session, session.identity == record.value.activeIdentity { return session }
        if session != nil { try await dropSession(forget: false) } // a session of another identity than the record's is stale
        if let opening { return try await join(opening) }
        guard !halted else { throw VaultFailure(.other, code: "halted") }
        try prepared()
        try refuseWhileDeleting()
        let c = config
        let member = member
        let source = canary.store
        let generation = sessionGeneration
        // §11.14.9 "A lost answer": checked again under the credential lock, where a change that began after an
        // operation's own check is seen.
        let gate: @Sendable (Bool) async throws -> Void = { [weak self] carriesPin in
            try await self?.credentialGate(carriesPin: carriesPin)
        }
        let identity = record.value.activeIdentity // (more than one identity: which App Attest keys)
        let two = identity != .first || record.value.couldNotTell != nil
        let task = Task { try await Self.makeSession(c, member, source, gate: gate, identity: (identity, two)) }
        opening = task
        defer { opening = nil }
        let s = try await task.value
        if let session { return session }
        // Dropped while it was being opened: not kept (its state may be forgotten already).
        guard generation == sessionGeneration else { throw VaultFailure(.other, code: "session_dropped") }
        session = s
        devicesMade.add(s.device)
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
        gate: @escaping @Sendable (Bool) async throws -> Void,
        identity: (set: IdentitySet, twoIdentities: Bool)
    ) async throws -> VaultSession {
        let (identity, twoIdentities) = identity
        try Task.checkCancellation() // a wipe cancels an opening: nothing more is made or written
        let keys = DeviceKeys(wrapper: SeedWrapper(source: c.keys.seedWrap), store: c.keys.wrapped)
        for slot in KeySlot.slots(of: identity) where try !keys.has(slot) {
            try Task.checkCancellation()
            try keys.generate(slot)
        }
        // The App Attest keys the vault bound to this identity are in use (IOS-PLAN 0.1.38 §4.9); the app key K is the same.
        if twoIdentities { try c.attester.use(identity: identity.rawValue) } else { try? c.attester.use(identity: 0) }
        let secrets = DeviceSecrets(
            identity: try keys.ed25519(KeySlot.identity.of(identity)), kem: try keys.kem(KeySlot.kem.of(identity)),
            relay: try keys.ed25519(KeySlot.relay.of(identity)), apiKey: try c.keys.appKeys.getOrCreate().spki()
        )
        let cfg = DeviceConfig(
            name: c.deviceName, relayURL: c.relayURL, transport: c.transport,
            store: FileDeviceStateStore(file: c.file(VaultFiles.device(of: identity))),
            enrolledAttestation: c.enrolledAttestation, now: c.now, collectMode: c.collectMode, pollWait: c.pollWait,
            requestTimeout: c.requestTimeout, requestTimeoutOf: c.requestTimeoutOf, uptime: c.uptime
        )
        let restored = try VaultDevice.load(cfg, secrets: secrets)
        try Task.checkCancellation()
        let device = if let restored { restored } else { try await VaultDevice.create(cfg, secrets: secrets) }
        try Task.checkCancellation()
        // IOS-PLAN ID8: every vault this app holds is of release R, whose passwords are normalized to NFC (§11.14.7).
        let api = VaultApi(device: device, normalizePasswords: { true }, credentialGate: gate, changeWaitSleep: c.changeWaitSleep)
        let alt = AltChannelFlow(api: member, trust: c.trust, now: c.now, canary: canary, verifyEnclave: c.enclaveCheck)
        return VaultSession(identity: identity, device: device, api: api, alt: alt)
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
            // A move to this phone still under way has its own code, so the screens can say so.
            let code = record.value.transferStartedMs != nil ? Self.codeTransferWaiting : Self.codeEnrollmentStarted
            return VaultFailure(.enrollmentStarted, code: code)
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
    /// [registrationOnly]: the device holds only a recovery's registration (``abandonRecovery()``), not taken for a vault.
    func dropSession(forget: Bool, vaultGone: Bool = false, registrationOnly: Bool = false) async throws {
        // IOS-PLAN 0.1.38 §4.9: never while the phone could not tell (K and every identity stay until the pairing completed), unless
        // the vault is gone: then the rule is cleared, in a save of its own, before any key is forgotten.
        if forget { try guardRule(vaultGone: vaultGone) }
        // [registrationOnly] skips the refusal only for a device with a vault id and nothing else (not pinned, not paired).
        let bare = registrationOnly && session?.device.hasVault != true && session?.device.deviceID == nil
        if forget, !vaultGone, !bare, let refusal = startOverRefusal(session?.device) { throw refusal }
        // A session still being opened is stopped and waited for, as at a wipe: no device made or written after the forget.
        if forget { _ = await cancelOpening() }
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
        await forgetEveryDevice()
        try await Self.forgetKeys(config)
        try phoneSecrets.delete()
        usesPhoneSecret = false
        pinChangeOperation = nil
        renewOperation = nil
        renewSecretSuggested = false
        forgetChangeCheck()
        releaseUpdate.clear()
        forgetOwnProfile()
        unlockWindow = nil
        try record.update(since: record.generation) {
            $0.setupComplete = false
            $0.capabilities = []
            $0.timeScale = 1
            $0.activeIdentity = .first
            $0.couldNotTell = nil
            $0.couldNotTellRead = nil
        }
        // The vault is no longer this phone's: nothing to lock from here. Only once the forget succeeded: a forget that
        // failed leaves the phone holding the vault, and its pending lock with it.
        lockGuard.keeper.abandon()
    }

    /// The code of a start-over refused because the phone may hold a vault (``mayHoldVault(_:)``).
    public nonisolated static let codeEnrollmentStarted = "enrollment_started"

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
        // A reset, a lock, or a newer phase set by an operation meanwhile, wins. (An unlock that a `device.unlinked`
        // reached on its way reads the phase again rather than set its own: ``rereads``.)
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
        // IOS-PLAN §4.2: a vault being deleted, before anything else is read or opened.
        if let d = record.value.deleting { return resumeDeleting(d) }
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
        let current = try await recordAfterResume(s, resumed: await resumeTransferIn(s))
        if d.deviceID == nil {
            if d.recovering { return .setup(.recovering) }
            // Enrolled, the first handshake (or the credential) not finished.
            if d.vaultID != nil { return .setup(.needsCredential) }
            // A redeemed code: enroll. The enrollment itself answers vault_exists for a vault this phone does not hold.
            return current.userGuid.isEmpty ? .signedOut : .setup(.newVault)
        }
        return try await pairedPhase(s, current)
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
}
