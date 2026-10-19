import Foundation
import VettIDAttestation
import VettIDCrypto

/// The app refuses to build a request (VAULT-MESSAGING §11.10.6, §13.2).
public enum AltRefused: Error, Equatable, Sendable {
    /// Never send a PIN to an older release than the last one unlocked into.
    case rollbackRelease
    /// The unlock right after a move (``UnlockOptions/afterMove``) is routed to exactly the release the vault left: the
    /// member API has not learnt the move yet. Nothing is sent; the caller may wait and try again.
    case notYetRouted
    /// The manifest is older than one already seen.
    case manifestOlder
    /// The device is not paired with a vault.
    case notPaired
}

/// What the app shares about itself in an enrollment or recovery: identity and KEM keys, relay address, name, and the
/// app key's SPKI DER (§11.12.2).
public struct AppIdentity: Sendable {
    public let ik: [UInt8]
    public let kem: KemPublicKey
    public let relay: RelayAddr
    public let name: String
    public let apiKey: [UInt8]?

    public init(ik: [UInt8], kem: KemPublicKey, relay: RelayAddr, name: String, apiKey: [UInt8]? = nil) {
        self.ik = ik
        self.kem = kem
        self.relay = relay
        self.name = name
        self.apiKey = apiKey
    }
}

/// An enrollment built and the state the app keeps until vault.enrolled (§11.3 "App state").
public struct BuiltEnroll: Sendable {
    public let request: SealedRequest
    public let state: AltState
}

/// Kept between building an unlock and opening its result.
public struct PendingUnlock: Equatable, Sendable {
    public let requestID: String
    public let release: String
    public let number: UInt64
    public let serial: UInt64
    public let toNumber: UInt64
}

/// An unlock built, and what the app keeps until its result.
public struct BuiltUnlock: Sendable {
    public let request: SealedRequest
    public let pending: PendingUnlock
    public let releaseChanged: Bool
}

/// A member-approved release update (§11.10.3).
public struct Approval: Equatable, Sendable {
    public let toPcr0: String
    public let toRelease: UInt64

    public init(toPcr0: String, toRelease: UInt64) {
        self.toPcr0 = toPcr0
        self.toRelease = toRelease
    }
}

/// The less common unlock paths (§11.10.4, §11.11.4). [sendChain] (§11.7.1): the device key's chain, Android only.
/// [unlockSecret] (§11.14.1, release R): sent right after `pin`; the signing string ends with its hash. Never logged.
public struct UnlockOptions: Sendable, CustomStringConvertible {
    public var approve: Approval?
    public var abandon = false
    public var cancelRecovery = false
    public var sendChain = false
    public var unlockSecret: [UInt8]?
    /// The unlock right after `update: moved` (§11.10.6): routed to exactly the release moved from, it is
    /// ``AltRefused/notYetRouted`` rather than a rollback.
    public var afterMove = false

    public init(
        approve: Approval? = nil, abandon: Bool = false, cancelRecovery: Bool = false, sendChain: Bool = false, unlockSecret: [UInt8]? = nil
    ) {
        self.approve = approve
        self.abandon = abandon
        self.cancelRecovery = cancelRecovery
        self.sendChain = sendChain
        self.unlockSecret = unlockSecret
    }

    public var description: String {
        "UnlockOptions(approve=\(String(describing: approve)), abandon=\(abandon), cancelRecovery=\(cancelRecovery), " +
            "sendChain=\(sendChain), unlockSecret=\(unlockSecret != nil ? "set" : "none"))"
    }
}

/// Builds the sealed requests of the alternate channel, as vettid-vault's reference client does (`BuildEnroll`,
/// `BuildUnlock`, `BuildRecoveryRegister`). Pure: keys, tokens and state come in, sealed bytes and the state to keep come
/// out. Every request is padded to exactly 12,288 bytes and sealed to the enclave's ETK. Mirrors vettid-android
/// `AltRequests`.
public enum AltRequests {
    public static let typeRecoveryRegister = "vault.recovery.register"
    static let nonceSize = 32
    static let maxCert = 16 * 1024
    static let pcrHex = 96

    /// [now] at millisecond precision: the request id, its `ts` and the sealed inner all come from this one value.
    static func ms(_ now: Date) -> Date {
        Date(timeIntervalSince1970: Double(Int64((now.timeIntervalSince1970 * 1000).rounded(.down))) / 1000)
    }

    /// vault.enroll (§11.3): a fresh device key attested over the request's challenge (vault_id empty), a fresh 32-byte
    /// nonce, the app's open token for the vault's first deposit, and the verified manifest by hash and serial.
    public static func buildEnroll( // swiftlint:disable:this function_parameter_count
        userGuid: String, pin: String, enclave: VerifiedEnclave, manifest: ReleaseManifest, attester: Attester,
        app: AppIdentity, openToken: String, state: AltState, now: Date, unlockSecret: [UInt8]? = nil, vaultID: String = ""
    ) throws -> BuiltEnroll {
        let t = ms(now)
        let rid = Ulid.new(t)
        // IOS-PLAN §6.2: only the keys of the requests the state still keeps can be bound by a later vault.enrolled.
        try attester.prune(keeping: state.enrollAttempts.compactMap(\.attestKeyID))
        let attest = try attester.attest(try AltChannel.devattChallenge(requestID: rid, vaultID: "", ts: Timestamps.formatMillis(t)))
        let nonce = Randomness.bytes(nonceSize)
        let request = EnrollRequest(
            userGuid: userGuid, requestID: rid, nonce: nonce, pin: pin, ik: app.ik, kem: app.kem, relay: app.relay, openToken: openToken,
            name: app.name, attest: attest, manifestSHA256: manifest.sha256Hex, manifestSerial: manifest.serial, apiKey: app.apiKey,
            unlockSecret: unlockSecret
        )
        var body = try request.marshal()
        request.wipe()
        defer { Bytes.wipe(&body) }
        let env = try AltChannel.sealRequest(etk: enclave.descriptor.etk, type: AltChannel.typeEnroll, requestID: rid, ts: t, body: body)
        // The earlier requests of this enrollment stay acceptable: one whose answer was lost may have made the vault.
        let next = state.startingEnrollRequest(
            nonce: nonce, pcrs: enclave.measurements.joined(), number: enclave.release.number, vaultID: vaultID,
            attestKeyID: attest.iosKeyID
        )
        // A request dropped from the kept ones (the oldest, or every one of another vault's enrollment) can no longer be
        // answered by vault.enrolled: its key is never confirmed (IOS-PLAN §6.2).
        let kept = Set(next.enrollAttempts.compactMap(\.attestKeyID))
        for k in state.enrollAttempts.compactMap(\.attestKeyID) where !kept.contains(k) { try attester.discard(keyID: k) }
        return BuiltEnroll(
            request: SealedRequest(
                requestID: rid, etkKid: enclave.descriptor.kid.description, envelope: env, manifestSHA256: manifest.sha256Hex,
                attestedKeyID: attest.iosKeyID
            ),
            state: next
        )
    }

    /// vault.unlock (§11.4): rollback minimums from [state], a fresh standing [token] for this device's mailbox (an open
    /// token while recovering), the device assertion over the challenge, an optional release approval, and the Ed25519
    /// signature by the app's identity key [ik].
    public static func buildUnlock( // swiftlint:disable:this function_parameter_count function_body_length
        userGuid: String, vaultID: String, pin: String, enclave: VerifiedEnclave, manifest: ReleaseManifest, attester: Attester,
        ik: Ed25519PrivateKey, token: String, state: AltState, options: UnlockOptions, now: Date
    ) throws -> BuiltUnlock {
        guard manifest.serial >= state.manifestSerial else { throw AltRefused.manifestOlder }
        let rel = enclave.release
        let changed = !state.release.isEmpty && state.release != rel.pcr0
        if state.releaseNumber != 0, rel.number < state.releaseNumber {
            if options.afterMove, !options.abandon, !state.previousRelease.isEmpty, rel.pcr0 == state.previousRelease {
                throw AltRefused.notYetRouted
            }
            guard options.abandon, rel.pcr0 == state.previousRelease else { throw AltRefused.rollbackRelease }
        }
        let t = ms(now)
        let tss = Timestamps.formatMillis(t)
        let rid = Ulid.new(t)
        let challenge = try AltChannel.devattChallenge(requestID: rid, vaultID: vaultID, ts: tss)
        // §11.7.1: the bound key's chain while the vault has not recorded this app's signer (Android only).
        let assertion = try unlockAssertion(attester, challenge, withChain: options.sendChain)
        let upd = options.abandon ? Approval(toPcr0: rel.pcr0, toRelease: rel.number) : options.approve
        let update = try upd.map { a in
            let s = try AltChannel.approvalSigningString(
                vaultID: vaultID, requestID: rid, fromPcr0: rel.pcr0, toPcr0: a.toPcr0, toRelease: a.toRelease, serial: manifest.serial
            )
            return UnlockRequest.ReleaseUpdate(to: a.toPcr0, toRelease: a.toRelease, approval: try attester.assert(.string(s)))
        }
        let minHeader = state.headerSeq[rel.pcr0] ?? 0
        let signing = try AltChannel.unlockSigningString(AltChannel.UnlockFields(
            userGuid: userGuid, vaultID: vaultID, requestID: rid, ts: tss, etkKid: enclave.descriptor.kid,
            minStateSeq: state.stateSeq, minHeaderSeq: minHeader, pin: pin, token: token, manifestSHA256: manifest.sha256Hex,
            toPcr0: upd?.toPcr0 ?? "", cancelRecovery: options.cancelRecovery, unlockSecret: options.unlockSecret
        ))
        let sig = try ik.signRaw(Array(signing.utf8))
        func seal(_ a: DeviceAssertion) throws -> [UInt8] {
            let request = UnlockRequest(
                userGuid: userGuid, vaultID: vaultID, requestID: rid, deviceIk: ik.publicKey, pin: pin, minStateSeq: state.stateSeq,
                minHeaderSeq: minHeader, token: token, assertion: a, manifestSHA256: manifest.sha256Hex, manifestSerial: manifest.serial,
                update: update, cancelRecovery: options.cancelRecovery, sig: sig, unlockSecret: options.unlockSecret
            )
            var body = try request.marshal()
            request.wipe()
            defer { Bytes.wipe(&body) }
            return try AltChannel.sealRequest(etk: enclave.descriptor.etk, type: AltChannel.typeUnlock, requestID: rid, ts: t, body: body)
        }
        // A chain that does not fit the request's 12,288 bytes goes out without the chain rather than not at all.
        let env: [UInt8]
        do {
            env = try seal(assertion)
        } catch let e as CryptoError where e.kind == .format && assertion != assertion.withoutChain() {
            env = try seal(assertion.withoutChain())
        }
        return BuiltUnlock(
            request: SealedRequest(
                requestID: rid, etkKid: enclave.descriptor.kid.description, envelope: env, manifestSHA256: manifest.sha256Hex
            ),
            pending: PendingUnlock(
                requestID: rid, release: rel.pcr0, number: rel.number, serial: manifest.serial, toNumber: upd?.toRelease ?? 0
            ),
            releaseChanged: changed
        )
    }

    /// Applies an opened unlock result to the app state (§11.4, §11.10.4): floors only move up; a result from another
    /// release than the attested one is refused; a move records the previous release for abandonment.
    public static func applyUnlock(_ state: AltState, _ p: PendingUnlock, _ r: UnlockResult) throws -> AltState {
        var s = state
        guard r.ok else {
            if r.headerSeq > (s.headerSeq[p.release] ?? 0) { s.headerSeq[p.release] = r.headerSeq }
            return s
        }
        guard r.release == p.release, r.releaseNumber == p.number else { throw AltResultFailure(what: "result from another release") }
        s.stateSeq = max(s.stateSeq, r.stateSeq)
        s.manifestSerial = max(s.manifestSerial, r.manifestSerial)
        var release = p.release
        var number = p.number
        switch r.update?.result {
        case "moved":
            s.previousRelease = p.release
            s.previousReleaseNumber = p.number
            release = r.update?.to ?? release
            number = p.toNumber
        case "abandoned":
            s.previousRelease = ""
            s.previousReleaseNumber = 0
        default: break
        }
        if r.headerSeq > (s.headerSeq[release] ?? 0) { s.headerSeq[release] = r.headerSeq }
        s.release = release
        if number != 0 { s.releaseNumber = number }
        return s
    }

    /// Applies an `ok` `vault.recovery.open.result` (§11.14.6, release R): floors only move up, and the result's release
    /// with its `header_seq` becomes the release the next unlock names. A result without a well-formed release moves
    /// only the state floor.
    public static func applyRecoveryOpen(
        _ state: AltState, stateSeq: UInt64, headerSeq: UInt64, release: String, releaseNumber: UInt64
    ) -> AltState {
        var s = state
        s.stateSeq = max(s.stateSeq, stateSeq)
        guard release.utf8.count == pcrHex, releaseNumber > 0 else { return s }
        if headerSeq > (s.headerSeq[release] ?? 0) { s.headerSeq[release] = headerSeq }
        s.release = release
        s.releaseNumber = releaseNumber
        return s
    }

    /// vault.recovery.register (§11.11.3): the code from the portal's QR, a fresh device key attested over the
    /// challenge (with the vault id).
    public static func buildRecoveryRegister( // swiftlint:disable:this function_parameter_count
        userGuid: String, code: RecoveryCode, enclave: VerifiedEnclave, attester: Attester, app: AppIdentity, now: Date
    ) throws -> SealedRequest {
        let t = ms(now)
        let rid = Ulid.new(t)
        let challenge = try AltChannel.devattChallenge(requestID: rid, vaultID: code.vaultID, ts: Timestamps.formatMillis(t))
        let attest = try attester.attest(challenge)
        let appObj = JsonBuilder().base64("ik", app.ik).base64("kem", app.kem.bytes).raw("relay", relayJSON(app.relay))
            .string("name", app.name).raw("device_attest", attest.marshal())
        if let k = app.apiKey { appObj.base64("api_key", k) }
        let body = JsonBuilder().string("user_guid", userGuid).string("vault_id", code.vaultID).string("request_id", rid)
            .string("recovery_id", code.recoveryID).string("code", code.code).raw("app", appObj.build()).bytes()
        let env = try AltChannel.sealRequest(etk: enclave.descriptor.etk, type: typeRecoveryRegister, requestID: rid, ts: t, body: body)
        return SealedRequest(
            requestID: rid, etkKid: enclave.descriptor.kid.description, envelope: env, manifestSHA256: nil,
            attestedKeyID: attest.iosKeyID
        )
    }

    /// `vault.recovery.open` (§11.14.6, release R): the registered phone's PIN, password (NFC) and unlock secret, an open
    /// token for its own mailbox, the device assertion over the challenge, the verified manifest, and the signature by
    /// its identity key [ik].
    public static func buildRecoveryOpen( // swiftlint:disable:this function_parameter_count
        userGuid: String, vaultID: String, recoveryID: String, pin: String, password: String, unlockSecret: [UInt8],
        enclave: VerifiedEnclave, manifest: ReleaseManifest, attester: Attester, ik: Ed25519PrivateKey, token: String, now: Date
    ) throws -> SealedRequest {
        let t = ms(now)
        let tss = Timestamps.formatMillis(t)
        let rid = Ulid.new(t)
        let assertion = try attester.assert(.challenge(try AltChannel.devattChallenge(requestID: rid, vaultID: vaultID, ts: tss)))
        var secrets = try Passwords.recoverySecrets(pin: pin, password: password)
        let signing: String
        do {
            defer { Bytes.wipe(&secrets) }
            signing = try RecoveryOpen.signingString(RecoveryOpen.Fields(
                userGuid: userGuid, vaultID: vaultID, requestID: rid, recoveryID: recoveryID, ts: tss, etkKid: enclave.descriptor.kid,
                secrets: secrets, token: token, manifestSHA256: manifest.sha256Hex, unlockSecret: unlockSecret
            ))
        }
        let sig = try ik.signRaw(Array(signing.utf8))
        var body = try RecoveryOpen.marshal(
            userGuid: userGuid, vaultID: vaultID, requestID: rid, recoveryID: recoveryID, deviceIk: ik.publicKey, pin: pin,
            password: password, unlockSecret: unlockSecret, token: token, assertion: assertion, manifestSHA256: manifest.sha256Hex,
            manifestSerial: manifest.serial, sig: sig
        )
        defer { Bytes.wipe(&body) }
        let env = try AltChannel.sealRequest(etk: enclave.descriptor.etk, type: RecoveryOpen.type, requestID: rid, ts: t, body: body)
        return SealedRequest(requestID: rid, etkKid: enclave.descriptor.kid.description, envelope: env, manifestSHA256: manifest.sha256Hex)
    }

    /// The unlock's assertion over [challenge], with the device key's chain when [withChain] and there is a usable one.
    static func unlockAssertion(_ attester: Attester, _ challenge: [UInt8], withChain: Bool) throws -> DeviceAssertion {
        let a = try attester.assert(.challenge(challenge))
        guard withChain, case .android(let sig, _) = a,
              let chain = attester.chain(), (1...DeviceAttest.maxChain).contains(chain.count),
              !chain.contains(where: { $0.isEmpty || $0.count > maxCert })
        else { return a }
        return try DeviceAssertion.androidSignature(sig, chain: chain)
    }

    static func relayJSON(_ r: RelayAddr) -> String {
        JsonBuilder().string("url", r.url).string("mailbox", r.mailbox).base64("pk", r.pk).build()
    }
}
