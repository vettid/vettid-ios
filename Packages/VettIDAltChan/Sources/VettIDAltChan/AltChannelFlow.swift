import Foundation
import VettIDAttestation
import VettIDCrypto

/// What the app pins for the alternate channel (VAULT-MESSAGING §11.2, §11.10.1): the AWS Nitro root and the manifest
/// keys. ``production`` is the Release build's; the Staging and Debug builds' (the staging manifest key) and the dev
/// stack's TEST-ONLY anchors are made by the app target, never in this package. Mirrors vettid-android `AltTrust`.
public struct AltTrust: Sendable {
    public let nitroRoots: [[UInt8]]
    public let manifestKeys: [ManifestKey]

    public init(nitroRoots: [[UInt8]], manifestKeys: [ManifestKey]) {
        self.nitroRoots = nitroRoots
        self.manifestKeys = manifestKeys
    }

    public static var production: AltTrust { AltTrust(nitroRoots: [NitroRoot.der], manifestKeys: ManifestKeys.production) }
}

/// A canary manifest installed out of band (VAULT-RELEASES §10.1 step 9).
public protocol CanaryManifestSource: Sendable {
    /// The installed served document's exact bytes, or nil when none is installed.
    func served() -> [UInt8]?
    /// The canary document [served] is no longer needed (the published manifest reached its serial) or no longer
    /// verifies: forget it, unless another document replaced it meanwhile.
    func retire(_ served: [UInt8])
}

/// The device side of the alternate channel, implemented by the vault client (VettIDVault): it owns the keys and the
/// ``AltState`` and records what each request needs to open its result. Mirrors vettid-android `AltParty`.
public protocol AltParty: Sendable {
    /// The highest manifest serial this device has seen for its vault.
    func manifestSerialSeen() -> UInt64
    func vaultIDForUnlock() -> String?
    /// [vaultID]: the vault this request enrolls (the redeem's); kept with the request's nonce.
    func prepareEnroll( // swiftlint:disable:this function_parameter_count
        userGuid: String, pin: String, enclave: VerifiedEnclave, manifest: ReleaseManifest, attester: Attester, unlockSecret: [UInt8]?,
        vaultID: String
    ) async throws -> SealedRequest
    func openEnrollResult(_ raw: [UInt8], requestID: String) async throws -> EnrollResult
    func prepareUnlock( // swiftlint:disable:this function_parameter_count
        userGuid: String, pin: String, enclave: VerifiedEnclave, manifest: ReleaseManifest, attester: Attester, options: UnlockOptions
    ) async throws -> BuiltUnlock
    func openUnlockResult(_ raw: [UInt8]) async throws -> UnlockResult
}

/// The opened vault.enroll.result, the vault id the API assigned and where it ran.
public struct EnrollOutcome: Equatable, Sendable {
    public let vaultID: String
    public let ok: Bool
    public let code: String?
    public let instanceID: String
}

/// The opened vault.unlock.result and where it ran.
public struct UnlockOutcome: Sendable {
    public let result: UnlockResult
    public let instanceID: String
    public let releaseChanged: Bool

    public var ok: Bool { result.ok }
}

/// The alternate channel gave up: no answer, or the routed enclave's descriptor names another instance.
public struct AltChannelFailure: Error, Equatable, Sendable, CustomStringConvertible {
    public let message: String

    public var description: String { "alternate channel: \(message)" }
}

/// Verifies a routed enclave (descriptor, attestation, manifest, enroll, now): VettIDAttestation's
/// `EnclaveVerifier.verifyEnclave` with the pinned Nitro roots by default.
public typealias EnclaveCheck = @Sendable ([UInt8], [UInt8], ReleaseManifest, Bool, Date) throws -> VerifiedEnclave

/// The alternate-channel flows (§11.3, §11.4, §11.9), as vettid-vault's reference client runs them: verify the served
/// manifest (signature and serial floor) and the routed enclave (Nitro chain, user_data over the descriptor, PCRs listed
/// in the manifest, `active` to enroll), seal, post, poll the slot and open the result. Re-seals with a fresh descriptor
/// after `instance_moved`, an `expired` slot or `etk_unknown` (at most 4 attempts), and refetches the manifest once after
/// a `manifest` result. Mirrors vettid-android `AltChannelFlow`.
public struct AltChannelFlow: Sendable {
    public static let maxAttempts = 4
    public static let codeManifest = "manifest"

    private let api: MemberApiClient
    private let manifests: ManifestVerifier
    private let now: @Sendable () -> Date
    private let canary: CanaryManifestSource?
    private let verifyEnclave: EnclaveCheck

    public init(
        api: MemberApiClient,
        trust: AltTrust,
        now: @escaping @Sendable () -> Date = { Date() },
        canary: CanaryManifestSource? = nil,
        verifyEnclave: EnclaveCheck? = nil
    ) {
        self.api = api
        manifests = ManifestVerifier(pinned: trust.manifestKeys)
        self.now = now
        self.canary = canary
        let verifier = EnclaveVerifier(nitro: NitroVerifier(roots: trust.nitroRoots))
        self.verifyEnclave = verifyEnclave ?? { d, a, m, e, t in
            try verifier.verifyEnclave(descriptor: d, attestation: a, manifest: m, enroll: e, now: t)
        }
    }

    /// Fetches and verifies the served manifest; refuses one older than [seen]. With a canary manifest installed the one
    /// with the higher serial is used (``CanaryManifests/choose(published:canary:)``): the canary document while it is
    /// newer than the published one, also while nothing is published yet (404); once the published manifest reaches its
    /// serial, the canary document is retired. Only a 404 falls back to the canary (§11.10.1).
    public func manifest(seen: UInt64) async throws -> ReleaseManifest {
        let canaryDoc = canary?.served()
        let c = canaryDoc.flatMap(canaryManifest)
        var published: ReleaseManifest?
        do {
            published = try manifests.verify(try await api.manifest())
        } catch let e as MemberApiError {
            guard c != nil, e.code == MemberApiError.manifestUnavailable, e.status == 404 else { throw e }
        }
        if let canaryDoc, let c, let published, published.serial >= c.serial { canary?.retire(canaryDoc) }
        guard let m = CanaryManifests.choose(published: published, canary: c) else {
            throw MemberApiError(status: 0, code: MemberApiError.manifestUnavailable)
        }
        guard m.serial >= seen else { throw AltRefused.manifestOlder }
        return m
    }

    /// The installed canary manifest, verified again; one that no longer verifies is retired and ignored.
    private func canaryManifest(_ served: [UInt8]) -> ReleaseManifest? {
        do {
            return try manifests.verify(served)
        } catch {
            canary?.retire(served)
            return nil
        }
    }

    private func enclave(
        release: String?, manifest m: ReleaseManifest, enroll: Bool, onStarting: (@Sendable (Int) -> Void)? = nil
    ) async throws -> (EnclaveInfo, VerifiedEnclave) {
        let info = try await api.enclaveWait(release: release, onStarting: onStarting)
        let e = try verifyEnclave(info.descriptor, info.attestation, m, enroll, now())
        guard e.descriptor.instanceID == info.instanceID else { throw AltChannelFailure(message: "descriptor names another instance") }
        return (info, e)
    }

    private static func retryable(_ e: Error?, _ s: Slot?) -> Bool {
        if let e = e as? MemberApiError { return e.code == MemberApiError.instanceMoved }
        guard let s else { return false }
        return s.status == Slot.expired || s.code == Slot.etkUnknown
    }

    /// A posted request that certainly never reached the enclave's processing (`instance_moved`, `etk_unknown`).
    private static func unprocessed(_ e: Error?, _ s: Slot?) -> Bool {
        if let e = e as? MemberApiError { return e.code == MemberApiError.instanceMoved }
        return s?.code == Slot.etkUnknown
    }

    /// Posts [request] with [post] and polls its slot; a member API error is returned, not thrown, for the retry rules.
    private func postAndPoll(_ post: () async throws -> Void, _ requestID: String) async throws -> (Error?, Slot?) {
        do {
            try await post()
            return (nil, try await api.poll(requestID))
        } catch let e as MemberApiError {
            return (e, nil)
        }
    }

    private static func answered(_ s: Slot?, _ what: String) throws -> [UInt8] {
        guard let s, s.status == Slot.done, let env = s.envelope else {
            throw AltChannelFailure(message: "\(what) not answered (\(s?.status ?? "") \(s?.code ?? ""))")
        }
        return env
    }

    /// Enrolls this app (§11.3) into [vaultID], the vault the setup code's redeem named (§11.12.1). Success also arrives
    /// as vault.enrolled over the relay. (0.34.0, release R) [unlockSecretFor] is given the verified instance's
    /// capabilities (§11.10.9) before each request is built: it returns the phone's unlock secret for release R's shape,
    /// nil for the earlier one, or throws, and then nothing is sent. [onPosting] runs right before each request is
    /// posted (a failure after it may have reached the vault); its throw sends nothing. [onUnprocessed] runs for a
    /// posted request that certainly never reached the enclave's processing: the API refused it (`instance_moved`) or
    /// the enclave could not decrypt it (`etk_unknown`). An `expired` slot is not one: the parent also writes it when the
    /// enclave did not answer (§11.5).
    public func enroll(
        party: AltParty, vaultID: String, userGuid: String, pin: String, attester: Attester,
        unlockSecretFor: @Sendable ([String]) async throws -> [UInt8]? = { _ in nil },
        onPosting: @Sendable () async throws -> Void = {},
        onUnprocessed: @Sendable () async -> Void = {}
    ) async throws -> EnrollOutcome {
        var m = try await manifest(seen: party.manifestSerialSeen())
        var refetched = false
        var attempt = 1
        while true {
            let (info, e) = try await enclave(release: nil, manifest: m, enroll: true)
            var secret = try await unlockSecretFor(e.descriptor.capabilities)
            let req: SealedRequest
            do {
                defer { if secret != nil { Bytes.wipe(&secret!) } }
                req = try await party.prepareEnroll(
                    userGuid: userGuid, pin: pin, enclave: e, manifest: m, attester: attester, unlockSecret: secret,
                    vaultID: vaultID
                )
            }
            // From here the request may reach the vault: the caller records that before it is posted.
            try await onPosting()
            var vid = ""
            let (err, slot) = try await postAndPoll(
                { vid = try await api.enroll(vaultID: vaultID, instanceID: info.instanceID, req) }, req.requestID
            )
            if Self.unprocessed(err, slot) { await onUnprocessed() }
            if Self.retryable(err, slot), attempt < Self.maxAttempts {
                attempt += 1
                continue
            }
            if let err { throw err }
            let r = try await party.openEnrollResult(try Self.answered(slot, "enrollment"), requestID: req.requestID)
            if !r.ok, r.code == Self.codeManifest, !refetched {
                refetched = true
                m = try await manifest(seen: party.manifestSerialSeen())
                continue
            }
            return EnrollOutcome(vaultID: vid, ok: r.ok, code: r.code, instanceID: info.instanceID)
        }
    }

    /// Unlocks the vault (§11.4); [release] (a PCR0) only to abandon an unconfirmed move. [onStarting] hears each
    /// `503 release_starting` while the routed release starts (§11.10.5).
    public func unlock(
        party: AltParty, userGuid: String, pin: String, attester: Attester, options: UnlockOptions = UnlockOptions(),
        release: String? = nil, onStarting: (@Sendable (Int) -> Void)? = nil,
        unlockSecretFor: (@Sendable ([String]) async throws -> [UInt8]?)? = nil
    ) async throws -> UnlockOutcome {
        guard let vaultID = party.vaultIDForUnlock() else { throw AltRefused.notPaired }
        var m = try await manifest(seen: party.manifestSerialSeen())
        var refetched = false
        var attempt = 1
        while true {
            let (info, e) = try await enclave(release: release, manifest: m, enroll: false, onStarting: onStarting)
            // With a callback, its answer decides (nil: the earlier shape, no secret); without, the caller's.
            var secret: [UInt8]?
            if let f = unlockSecretFor { secret = try await f(e.descriptor.capabilities) } else { secret = options.unlockSecret }
            let built: BuiltUnlock
            do {
                var opts = options
                opts.unlockSecret = secret
                defer {
                    opts.unlockSecret = nil // drop the second reference first, so the wipe reaches the buffer itself
                    if secret != nil { Bytes.wipe(&secret!) }
                }
                built = try await party.prepareUnlock(
                    userGuid: userGuid, pin: pin, enclave: e, manifest: m, attester: attester, options: opts
                )
            }
            let (err, slot) = try await postAndPoll(
                { try await api.unlock(vaultID: vaultID, instanceID: info.instanceID, built.request) }, built.request.requestID
            )
            if Self.retryable(err, slot), attempt < Self.maxAttempts {
                attempt += 1
                continue
            }
            if let err { throw err }
            let r = try await party.openUnlockResult(try Self.answered(slot, "unlock"))
            if !r.ok, r.code == Self.codeManifest, !refetched {
                refetched = true
                m = try await manifest(seen: party.manifestSerialSeen())
                continue
            }
            return UnlockOutcome(result: r, instanceID: info.instanceID, releaseChanged: built.releaseChanged)
        }
    }

    /// What the app must know before it asks for the PIN (§11.2 step 4, §11.10.6): the verified manifest and the release
    /// the vault is routed to, compared with the release this device last unlocked into ([state]).
    public func preflight(_ state: AltState, release: String? = nil) async throws -> UnlockPreflight {
        let m = try await manifest(seen: state.manifestSerial)
        let (_, e) = try await enclave(release: release, manifest: m, enroll: false)
        return UnlockPreflight.of(state, routed: e.release, manifest: m)
    }

    /// Asks the leaseholder to lock the vault and waits for the slot: until it is no longer queued, or for [atMost]. An
    /// answered slot says that the request was handled, **not** that the vault locked; only the vault's status says.
    public func lock(vaultID: String, atMost: TimeInterval? = nil) async throws -> Slot {
        let rid = Ulid.new(now())
        try await api.lock(vaultID: vaultID, requestID: rid)
        return try await api.poll(rid, atMost: atMost)
    }

    /// Registers this app for a recovery (§11.11.3) with the portal's code. [build] seals the request to the verified
    /// enclave; [open] opens vault.recovery.result.
    public func recoveryRegister(
        vaultID: String,
        build: @Sendable (VerifiedEnclave) async throws -> SealedRequest,
        open: @Sendable ([UInt8], String) async throws -> RecoveryResult
    ) async throws -> RecoveryResult {
        let m = try await manifest(seen: 0)
        var attempt = 1
        while true {
            let (info, e) = try await enclave(release: nil, manifest: m, enroll: false)
            let req = try await build(e)
            let (err, slot) = try await postAndPoll(
                { try await api.recoveryRegister(vaultID: vaultID, instanceID: info.instanceID, req) }, req.requestID
            )
            if Self.retryable(err, slot), attempt < Self.maxAttempts {
                attempt += 1
                continue
            }
            if let err { throw err }
            return try await open(try Self.answered(slot, "recovery"), req.requestID)
        }
    }

    /// Opens a registered recovery (§11.14.6, release R), routed like an unlock. Never retried here: every open may use
    /// an attempt, so the member sends again. [onSent] runs once the member API has taken the request.
    public func recoveryOpen(
        vaultID: String,
        build: @Sendable (VerifiedEnclave, ReleaseManifest) async throws -> SealedRequest,
        open: @Sendable ([UInt8], String) async throws -> RecoveryOpen.Result,
        onSent: @Sendable () async -> Void = {}
    ) async throws -> RecoveryOpen.Result {
        let m = try await manifest(seen: 0)
        let (info, e) = try await enclave(release: nil, manifest: m, enroll: false)
        let req = try await build(e, m)
        try await api.recoveryOpen(vaultID: vaultID, instanceID: info.instanceID, req)
        await onSent()
        let s = try await api.poll(req.requestID)
        return try await open(try Self.answered(s, "recovery open"), req.requestID)
    }
}

/// The release check before an unlock (§11.10.6). [routed] is the manifest entry of the attested instance the vault is
/// routed to.
public struct UnlockPreflight: Equatable, Sendable {
    public let routed: Release
    public let lastNumber: UInt64
    public let manifestSerial: UInt64
    /// The newest `active` release when it is newer than the routed one: the member may approve the move (§11.10.3).
    public let offer: Release?
    /// The manifest's releases between the routed one and [offer] (What's new lists their summaries).
    public let between: [Release]

    /// Older than the release this device last unlocked into: the app MUST NOT send the PIN.
    public var rollback: Bool { lastNumber != 0 && routed.number < lastNumber }
    /// Newer than the last one (another device moved the vault): the app tells the member before sending the PIN.
    public var softwareUpdated: Bool { lastNumber != 0 && routed.number > lastNumber }

    public static func of(_ state: AltState, routed: Release, manifest m: ReleaseManifest) -> UnlockPreflight {
        let offer = m.newest().flatMap { $0.number > routed.number ? $0 : nil }
        let between = offer.map { o in m.releases.filter { $0.number > routed.number && $0.number < o.number } } ?? []
        return UnlockPreflight(routed: routed, lastNumber: state.releaseNumber, manifestSerial: m.serial, offer: offer, between: between)
    }
}
