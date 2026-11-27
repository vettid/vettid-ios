import Foundation
import VettIDCrypto

// Calls (VAULT-MESSAGING §10.10; CALLS-PLAN phases C1 and C2): the `call.*` types as an app sends and receives them.
// Signalling goes device → its vault → the peer's vault → the peer's devices. The media key is agreed between the two
// devices (``CallWire``); this file signs and checks the key-exchange shares, checks the vault-signed ICE configuration,
// negotiates the media suite inside the SDP and derives the two direction keys (``CallMedia``). Mirrors vettid-android
// `CallApi`.
//
// (C2) Against a vault whose `call.list` says `v: 2` a call also carries form 2 (the media suites signed with the share,
// both members named, the key confirmation) and the device sends keep-alives; against an S10 vault nothing changes
// ("Mixed releases").
//
// Sending: `call.start`, `call.answer`, `call.ice`, `call.ringing` and `call.keepalive` are deposited once and never kept or re-sent
// (``VaultDevice/sendOnce(_:body:exp:)``): none of them means anything later. `call.end` is an ordinary durable send, so
// that a hang-up that could not be delivered at once still reaches the vault and frees it.

/// Limits and times of §10.10, as vettid-vault's `features/calls` enforces them.
public enum CallLimits {
    public static let maxSdp = 32 * 1024
    public static let maxCandidate = 1024
    public static let maxSdpMid = 64
    public static let maxMLineIndex = 1023
    /// Candidates in one `call.ice`.
    public static let maxCandidates = 16
    /// `call.ice` messages a vault forwards for one call, both directions counted together.
    public static let maxIceMessages = 256
    /// A callee's vault drops an offer whose `exp` is further ahead than this.
    public static let maxOfferAhead: TimeInterval = 90
    /// `exp` of the ephemeral types (`call.ice`, `call.ringing`).
    public static let ephemeralTTL: TimeInterval = 30
    /// How long the app waits for the answer to `call.start` before it gives the call up (VAULT-MESSAGING 0.97.0 §10.10
    /// "Placing a call": 30 s after it first sent it).
    public static let startTimeout: TimeInterval = 30
    /// (0.97.0) When `call.start` is deposited again, with the same inner `id`, while no answer has come.
    public static let startResends: [TimeInterval] = [10, 20]
    /// The most entries one `call.list` may ask for (the vault keeps the latest 200 calls).
    public static let maxListLimit = 200
    /// (C2) How often the call's device sends `call.keepalive`, and the `exp` it gives one ("Liveness").
    public static let keepaliveEvery: TimeInterval = 30
    /// (C2) The largest suite number (`suites`, `offered`, `suite`: 1 to 65,535).
    public static let maxSuiteId: UInt64 = 65535
}

/// `call.end` reasons (§10.10).
public enum CallReason {
    public static let hangup = "hangup"
    public static let decline = "decline"
    public static let busy = "busy"
    public static let timeout = "timeout"
    public static let answeredElsewhere = "answered_elsewhere"
    public static let unavailable = "unavailable"
    public static let failed = "failed"
    public static let all: Set<String> = [hangup, decline, busy, timeout, answeredElsewhere, unavailable, failed]
}

/// A call message the device cannot use: a share or an ICE configuration that does not verify, or a malformed body.
public struct CallMessageError: Error, Equatable, Sendable, CustomStringConvertible {
    public let message: String

    public init(_ message: String) { self.message = message }

    public var description: String { "call: \(message)" }
}

private extension JsonObject {
    func need(_ k: String) throws -> String {
        guard let v = VaultJSON.string(self, k) else { throw CallMessageError("missing \(k)") }
        return v
    }

    func b64(_ k: String, _ n: Int = -1) throws -> [UInt8] {
        do {
            return try Base64s.decodeStd(try need(k), n)
        } catch is CryptoError {
            throw CallMessageError("malformed \(k)")
        }
    }

    func callId() throws -> String {
        let id = try need("call_id")
        guard Ulid.isValid(id) else { throw CallMessageError("call_id") }
        return id
    }

    /// (C2) A `suites` or `offered` list exactly as §10.10 allows it: 1 to 8 plain JSON integers 1–65,535 (no sign,
    /// fraction, exponent or string), none repeated. Anything else does not read.
    func suiteList(_ k: String) throws -> [Int] {
        guard case .array(_, let items)? = self[k], (1...CallMedia.maxSuites).contains(items.count) else {
            throw CallMessageError("malformed \(k)")
        }
        let out = try items.map { e -> Int in
            guard let v = try? e.asUint(min: 1, max: CallLimits.maxSuiteId) else { throw CallMessageError("malformed \(k)") }
            return Int(v)
        }
        guard Set(out).count == out.count else { throw CallMessageError("malformed \(k)") }
        return out
    }

    /// (C2) `suite` of an answer: a plain JSON integer 1–65,535.
    func suite() throws -> Int {
        guard let v = try? self["suite"]?.asUint(min: 1, max: CallLimits.maxSuiteId) else { throw CallMessageError("malformed suite") }
        return Int(v)
    }

    /// (C2) How many of [names] the object has: a form is carried whole or not at all.
    func count(of names: [String]) -> Int { names.filter(has).count }
}

/// Runs [block]; a ``CryptoError`` in it is a ``CallMessageError`` naming [what].
private func checked<T>(_ what: String, _ block: () throws -> T) throws -> T {
    do {
        return try block()
    } catch is CryptoError {
        throw CallMessageError(what)
    }
}

extension VaultApi {
    private func iceOf(_ o: JsonObject, _ callId: String) throws -> CallWire.IceConfig {
        let vaultIk = try device.vaultIdentityKey()
        let now = device.clockNow()
        return try checked("ice configuration") {
            let sig = try o.b64("ice_sig", Suite.ed25519SignatureSize)
            return try CallWire.verifyIce(vaultIk: vaultIk, config: try o.b64("ice_config"), sig: sig, callId: callId, now: now)
        }
    }

    /// The other side's share: its device's signature and its vault's, under the connection's identity key (`peer_ik`),
    /// which must be the key the app already knows the connection by: [pinnedFingerprint] is the fingerprint the
    /// connection's details show the member (VAULT-MESSAGING §10.8). A call is thereby bound to the identity the member
    /// can see, not only to what the event says.
    @discardableResult
    private func verifyPeerShare(_ o: JsonObject, _ message: [UInt8], _ pinnedFingerprint: String) throws -> [UInt8] {
        try checked("key-exchange share") {
            let peerIk = try peerIkOf(o, pinnedFingerprint)
            try CallWire.verifyShare(
                vaultIk: peerIk, deviceIk: try o.b64("device_ik", Suite.ed25519PublicSize), message: message,
                deviceSig: try o.b64("device_sig", Suite.ed25519SignatureSize),
                vaultSig: try o.b64("vault_sig", Suite.ed25519SignatureSize)
            )
            return peerIk
        }
    }

    /// `peer_ik`, which must be the key whose fingerprint the connection's details show (rule 6 of "Rules for a device").
    private func peerIkOf(_ o: JsonObject, _ pinnedFingerprint: String) throws -> [UInt8] {
        let peerIk = try o.b64("peer_ik", Suite.ed25519PublicSize)
        let shown = try IkFingerprint.format(peerIk)
        guard !pinnedFingerprint.isEmpty, Bytes.constantTimeEquals(Array(shown.utf8), Array(pinnedFingerprint.utf8)) else {
            throw CryptoError.signature("peer_ik is not the connection's identity key")
        }
        return peerIk
    }

    private func sdpOf(_ o: JsonObject) throws -> String {
        let sdp = try o.need("sdp")
        try checkSdp(sdp)
        return sdp
    }

    /// The size of §10.10 and the one shape a VettID call has: exactly one media section, audio, Opus alone. Anything
    /// else would be media outside the frame encryption, so it never reaches the media stack.
    private func checkSdp(_ sdp: String) throws {
        guard !sdp.isEmpty, sdp.utf8.count <= CallLimits.maxSdp else { throw CallMessageError("sdp size") }
        try checked("sdp") { try CallMedia.requireOneOpusAudioSection(sdp) }
    }

    /// `call.start`: places a call to [connectionId] with this device's SDP offer [sdp]; of [suites], what this device's
    /// media engine can do, those form 1 may offer (``MediaSuite/formOne(_:)``: suite 1) are added to it here, the
    /// preferred one first. This start carries a form 1 signature, so rule 3 of VAULT-MESSAGING §10.10 "Call forms"
    /// applies: no second suite while any `call.start` carries form 1. A fresh `call_id` and ephemeral KEM key, the share
    /// signed with the device's identity key. Deposited, again at [resendAfter], and awaited for [timeout]. Errors
    /// (``VaultOpError``): `busy` (this vault is already in a call), `not_found`, `connection_unavailable`, `owner_check_required`, `exists`,
    /// `bad_request`, `internal`, and `unsupported_type` from a vault release without calls. When it fails in any other
    /// way after the request may have left (no answer in time, a lost response, an answer that does not verify), a
    /// durable `call.end{hangup}` for the same `call_id` follows, so that a call the vault did place does not ring on for
    /// nobody.
    ///
    /// (C2) With [peerIk], the connection's identity key as this device's vault gives it (`connection.get`), the start
    /// also carries form 2 (`suites` and `ek_sig2` over `m2`, naming this vault and the connection's, VAULT-MESSAGING
    /// 0.88.16 §10.10) and `keepalive: true`; a device passes it only when its vault is C2 (`call.list` `v: 2`). Nil: form 1
    /// only, as to an S10 vault. Rule 3 holds for both: form 1 is in every start, so suite 1 alone is offered.
    public func callStart(
        _ connectionId: String, pinnedFingerprint: String, sdp: String, suites: [MediaSuite] = MediaSuite.default,
        media: String = CallWire.mediaAudio,
        timeout: TimeInterval = CallLimits.startTimeout, peerIk: [UInt8]? = nil,
        resendAfter: [TimeInterval] = CallLimits.startResends
    ) async throws -> OutgoingCall {
        // The call is bound to the identity the member sees: no fingerprint, no call. Nothing is sent.
        guard !pinnedFingerprint.isEmpty else { throw CallMessageError("pinned fingerprint") }
        guard media == CallWire.mediaAudio || media == CallWire.mediaVideo else { throw CallMessageError("media") }
        let callId = device.newRequestID()
        let offered = try checked("media suites") { try CallMedia.offerOf(MediaSuite.formOne(suites)) }
        let parties = try peerIk.map { ik in
            try checked("call parties") { try CallWire.Parties(caller: try device.vaultIdentityKey(), callee: ik) }
        }
        // Form 1's SDP attribute is kept in a form 2 start too: an S10 peer reads it (VAULT-MESSAGING "Call forms").
        let offer = try checked("media suites") { try CallMedia.sdpWithOffer(sdp, offered: offered) }
        try checkSdp(offer)
        let key = try CallWire.newOfferKey()
        var attempted = false
        do {
            let ek = key.publicKey.bytes
            let share = try device.signCallShare(CallWire.shareMessage(role: CallWire.roleOffer, callId: callId, media: media, share: ek))
            let share2 = try parties.map { p in
                try device.signCallShare(CallWire.offerMessage2(callId: callId, media: media, offered: offered, parties: p, ek: ek))
            }
            attempted = true
            let body = JsonBuilder().string("connection_id", connectionId).string("call_id", callId).string("media", media)
                .string("sdp", offer).base64("ek", ek).base64("ek_sig", share)
            if let share2 {
                body.raw("suites", JsonBuilder.array(offered.map(String.init))).base64("ek_sig2", share2).bool("keepalive", true)
            }
            // (0.97.0) Deposited again at 10 s and 20 s with the same `id`; the vault gives the live answer again, or once it
            // no longer holds the call a cached copy marked `withheld: true` without the TURN entry, which is kept as the
            // call all the same (it is not placed again: the callee sees one call).
            let o = VaultJSON.object(try await device.opOnce("call.start", body: body.bytes(), timeout: timeout, resendAfter: resendAfter))
            guard try o.need("call_id") == callId else { throw CallMessageError("call.start answered for another call") }
            let exp = try checked("exp") { try Timestamps.parseMillis(try o.need("exp")) }
            return OutgoingCall(
                callId: callId, connectionId: connectionId, media: media, exp: exp, ice: try iceOf(o, callId), offered: offered,
                pinnedFingerprint: pinnedFingerprint, offerKey: key, parties: parties
            )
        } catch let e as VaultOpError {
            // The vault's own refusal: there is no call.
            key.destroy()
            throw e
        } catch let e as OutboxHeld {
            // Held by the lock gate: nothing left this phone, so there is no call to end.
            key.destroy()
            throw e
        } catch {
            key.destroy()
            // No answer in time, an answer that was lost, or an answer that does not verify: the vault may have taken the
            // call and sent the offer on, and nothing here could end it later. The durable hang-up does (a vault that never
            // saw the call ignores it).
            if attempted { try? await callEnd(callId, reason: CallReason.hangup) }
            throw error
        }
    }

    /// Checks a `call.offer` event, in this order: the shape and sizes; that the offer has not expired; the vault-signed
    /// ICE configuration; `peer_ik` against [pinnedFingerprint] (the connection's identity as the app shows it); the
    /// caller's share under `peer_ik`; the SDP's one Opus audio section; the media suites, of which one must be among
    /// [suites] (what this device's media engine can do) as form 1 allows (``MediaSuite/formOne(_:)``: suite 1, so a
    /// form 1 offer without suite 1 does not ring). (C2) Every form an offer carries is checked: an offer with part of
    /// form 2 does not ring, and one with all of it is checked over `m2` too (the parties `peer_ik` and this device's own
    /// vault key) and answered in form 2, choosing from the signed `suites` (the SDP attribute is ignored and removed).
    /// Throws ``CallMessageError`` for an offer that must not ring: nothing of it is used, and nothing is sent.
    public func callIncoming(
        _ event: VaultMessage, pinnedFingerprint: String, suites: [MediaSuite] = MediaSuite.default
    ) throws -> IncomingCall {
        let o = event.object
        let callId = try o.callId()
        let media = try o.need("media")
        guard media == CallWire.mediaAudio || media == CallWire.mediaVideo else { throw CallMessageError("media") }
        let sdp = try sdpOf(o)
        let ek = try o.b64("ek", Suite.ekSize)
        let exp = try checked("exp") { try Timestamps.parseMillis(try o.need("exp")) }
        // Both times are the vault's: a phone whose clock is behind still rings for the right time. (An offer that has
        // expired by the phone's clock never gets here: the session layer drops it.)
        let ringFor = exp.timeIntervalSince(event.ts)
        guard ringFor > 0, ringFor <= CallLimits.maxOfferAhead, device.clockNow() < exp else {
            throw CallMessageError("offer expired or too far ahead")
        }
        let ice = try iceOf(o, callId)
        let peerIk = try verifyPeerShare(
            o, CallWire.shareMessage(role: CallWire.roleOffer, callId: callId, media: media, share: ek), pinnedFingerprint
        )
        let form2 = o.count(of: ["suites", "device_sig2", "vault_sig2"])
        guard form2 == 0 || form2 == 3 else { throw CallMessageError("part of form 2") }
        var parties: CallWire.Parties?
        let negotiated: CallMedia.Negotiated
        if form2 == 3 {
            let signed = try o.suiteList("suites")
            let p = try checked("call parties") { try CallWire.Parties(caller: peerIk, callee: try device.vaultIdentityKey()) }
            try checked("key-exchange share (form 2)") {
                try CallWire.verifyShare(
                    vaultIk: peerIk, deviceIk: try o.b64("device_ik", Suite.ed25519PublicSize),
                    message: CallWire.offerMessage2(callId: callId, media: media, offered: signed, parties: p, ek: ek),
                    deviceSig: try o.b64("device_sig2", Suite.ed25519SignatureSize),
                    vaultSig: try o.b64("vault_sig2", Suite.ed25519SignatureSize)
                )
            }
            // In form 2 the choice is from the signed list, among what this device's engine can do.
            negotiated = try checked("media suites") { try CallMedia.choose(offered: signed, supported: suites) }
            parties = p
        } else {
            negotiated = try checked("media suites") {
                try CallMedia.choose(offered: try CallMedia.offeredIn(sdp), supported: MediaSuite.formOne(suites))
            }
        }
        return IncomingCall(
            callId: callId, connectionId: try o.need("connection_id"), media: media,
            sdp: CallMedia.sdpWithoutSsrc(CallMedia.sdpWithout(sdp)), exp: exp,
            ringFor: ringFor, ice: ice, negotiated: negotiated, ek: ek, parties: parties
        )
    }

    /// `call.answer`: answers [call] with this device's SDP answer [sdp]; the media suite chosen when the offer was checked
    /// (``IncomingCall/negotiated``) is added to it here. Encapsulates to the caller's key, signs the share, deposits once,
    /// and returns the call's keys, which never leave this device. The vault does not answer: a call that was no longer
    /// ringing comes back as `call.end{unavailable}`. (C2) A form 2 offer is answered in form 2: form 2's `k_call`, and
    /// `suite`, `offered`, `confirm` and `enc_sig` over `m2`, with no VettID attribute in the SDP; [keepalive] says this
    /// device will send keep-alives (a device sends it when its vault is C2, or when the offer carried form 2).
    public func callAnswer(_ call: IncomingCall, sdp: String, keepalive: Bool = false) async throws -> CallKeys {
        let chosen = call.negotiated
        let parties = call.parties
        // (C2) A form 2 answer's SDP carries no VettID attribute: the choice is the signed `suite`.
        let answer = parties == nil ? CallMedia.sdpWithChoice(sdp, chosen: chosen.chosen) : sdp
        try checkSdp(answer)
        // An offer is answered once: a second answer would be a second share for the same call. Nothing is sent.
        guard call.answerOnce.claim() else { throw CallMessageError("call already answered") }
        var a = try checked("key agreement") {
            if let parties { return try CallWire.answer2(ek: call.ek, callId: call.callId, parties: parties) }
            return try CallWire.answer(ek: call.ek, callId: call.callId)
        }
        defer { Bytes.wipe(&a.kCall) }
        // (C2) confirm, from k_confirm, before the key derivation wipes k_call.
        let confirm = try parties.map { p -> [UInt8] in
            var kc = try checked("key confirmation") { try CallWire.confirmKey(kCall: a.kCall, callId: call.callId) }
            defer { Bytes.wipe(&kc) }
            return CallWire.confirm(kConfirm: kc, chosen: chosen.chosen.id, offered: chosen.offered, callId: call.callId, parties: p)
        }
        let keys = try CallKeys.derive(&a.kCall, chosen, callId: call.callId, caller: false)
        do {
            let shared = parties.map {
                CallWire.answerMessage2(callId: call.callId, chosen: chosen.chosen.id, offered: chosen.offered, parties: $0, enc: a.enc)
            } ?? CallWire.shareMessage(role: CallWire.roleAnswer, callId: call.callId, media: "", share: a.enc)
            let encSig = try device.signCallShare(shared)
            let body = JsonBuilder().string("call_id", call.callId).string("sdp", answer).base64("enc", a.enc).base64("enc_sig", encSig)
            if let confirm {
                body.uint("suite", UInt64(chosen.chosen.id)).raw("offered", JsonBuilder.array(chosen.offered.map(String.init)))
                    .base64("confirm", confirm)
            }
            if keepalive { body.bool("keepalive", true) }
            try await device.sendOnce("call.answer", body: body.bytes())
            return keys
        } catch {
            keys.destroy()
            throw error
        }
    }

    /// Checks the `call.answer` event for [call] on the calling device: `peer_ik` against the fingerprint of the
    /// connection [call] was placed to (``callStart(_:pinnedFingerprint:sdp:suites:media:timeout:)``), the
    /// answerer's share under it, the SDP's one Opus audio section and the choice of media suite; then derives the call's
    /// keys. The ephemeral KEM key is destroyed when the answer is accepted; after a ``CallMessageError`` the caller of
    /// this function destroys [call] (the call is over).
    public func callAccept(_ call: OutgoingCall, event: VaultMessage) throws -> AcceptedCall {
        let o = event.object
        guard try o.callId() == call.callId else { throw CallMessageError("answer for another call") }
        let sdp = try sdpOf(o)
        let enc = try o.b64("enc", Suite.encSize)
        // (C2) An answer is in exactly one form: part of form 2 is refused, all of it is form 2.
        let form2 = o.count(of: ["suite", "offered", "confirm"])
        guard form2 == 0 || form2 == 3 else { throw CallMessageError("part of form 2") }
        if form2 == 3 { return try acceptForm2(call, o, sdp: sdp, enc: enc) }
        // Rule 2 of "Call forms" binds once a device offers a suite other than 1, which no start does while form 1 exists
        // (rule 3); until form 1 is retired a form 1 answer to a form 2 offer is taken under form 1's rules.
        let shared = CallWire.shareMessage(role: CallWire.roleAnswer, callId: call.callId, media: "", share: enc)
        try verifyPeerShare(o, shared, call.pinnedFingerprint)
        let chosen = try checked("media suites") { try CallMedia.chosenIn(sdp, offered: call.offered) }
        var kCall = try checked("key agreement") { try CallWire.accept(offerKey: call.key(), enc: enc, callId: call.callId) }
        call.destroy()
        defer { Bytes.wipe(&kCall) }
        return AcceptedCall(
            callId: call.callId, sdp: CallMedia.sdpWithoutSsrc(CallMedia.sdpWithout(sdp)),
            keys: try CallKeys.derive(&kCall, chosen, callId: call.callId, caller: true)
        )
    }

    /// (C2) A form 2 answer (VAULT-MESSAGING 0.88.16 "Call forms", "Key confirmation"): only to an offer that carried
    /// form 2; `peer_ik` must be the callee this device named when it placed the call; the signatures over `m2` with the
    /// parties fixed then; `offered` exactly the list sent and `suite` in it and in the registry; and `confirm`, checked in
    /// constant time **before any key is set** (and before the SDP is used: nothing of the answer leaves here unless it
    /// verified).
    private func acceptForm2(_ call: OutgoingCall, _ o: JsonObject, sdp: String, enc: [UInt8]) throws -> AcceptedCall {
        guard let parties = call.parties else { throw CallMessageError("form 2 answer to a form 1 offer") }
        let offered = try o.suiteList("offered")
        let chosen = try o.suite()
        let confirm = try o.b64("confirm", CallWire.confirmSize)
        try checked("key-exchange share (form 2)") {
            let peerIk = try peerIkOf(o, call.pinnedFingerprint)
            guard Bytes.constantTimeEquals(peerIk, parties.callee) else { throw CryptoError.signature("the answer names another callee") }
            try CallWire.verifyShare(
                vaultIk: peerIk, deviceIk: try o.b64("device_ik", Suite.ed25519PublicSize),
                message: CallWire.answerMessage2(callId: call.callId, chosen: chosen, offered: offered, parties: parties, enc: enc),
                deviceSig: try o.b64("device_sig", Suite.ed25519SignatureSize),
                vaultSig: try o.b64("vault_sig", Suite.ed25519SignatureSize)
            )
        }
        guard offered == call.offered else { throw CallMessageError("offered is not the list sent") }
        guard offered.contains(chosen), let suite = MediaSuite.byId(chosen) else { throw CallMessageError("suite") }
        let negotiated = try checked("media suites") { try CallMedia.Negotiated(chosen: suite, offered: offered) }
        var kCall = try checked("key agreement") {
            try CallWire.accept2(offerKey: call.key(), enc: enc, callId: call.callId, parties: parties)
        }
        // k_call is wiped on every path out (derive wipes it too; a second wipe is harmless).
        defer { Bytes.wipe(&kCall) }
        var kc = try checked("key confirmation") { try CallWire.confirmKey(kCall: kCall, callId: call.callId) }
        let ok = CallWire.verifyConfirm(
            kConfirm: kc, chosen: chosen, offered: offered, callId: call.callId, parties: parties, confirm: confirm
        )
        Bytes.wipe(&kc)
        guard ok else { throw CallMessageError("key confirmation") }
        call.destroy()
        return AcceptedCall(
            callId: call.callId, sdp: CallMedia.sdpWithoutSsrc(CallMedia.sdpWithout(sdp)),
            keys: try CallKeys.derive(&kCall, negotiated, callId: call.callId, caller: true)
        )
    }

    /// (C2) `call.keepalive{call_id}` (ephemeral, `exp` now + 30 s) from the call's device to its own vault: the first as
    /// soon as the call is active here, then every ``CallLimits/keepaliveEvery`` (VAULT-MESSAGING §10.10 "Liveness").
    public func callKeepalive(_ callId: String) async throws {
        let body = JsonBuilder().string("call_id", callId)
        try await device.sendOnce(
            "call.keepalive", body: body.bytes(), exp: device.clockNow().addingTimeInterval(CallLimits.keepaliveEvery)
        )
    }

    /// `call.ringing` (ephemeral): this device is ringing; the caller hears a ring-back tone. Forwarded once per call.
    public func callRinging(_ callId: String) async throws {
        let body = JsonBuilder().string("call_id", callId)
        try await device.sendOnce("call.ringing", body: body.bytes(), exp: device.clockNow().addingTimeInterval(CallLimits.ephemeralTTL))
    }

    /// `call.ice` (ephemeral): 1 to ``CallLimits/maxCandidates`` candidates of the call's device. The caller of this
    /// function batches: a vault forwards at most ``CallLimits/maxIceMessages`` per call, and the relay takes 5 deposits a
    /// second from one sender.
    public func callIce(_ callId: String, _ candidates: [CallCandidate]) async throws {
        let ok = (1...CallLimits.maxCandidates).contains(candidates.count) && candidates.allSatisfy {
            $0.candidate.utf8.count <= CallLimits.maxCandidate && ($0.sdpMid?.utf8.count ?? 0) <= CallLimits.maxSdpMid
                && (0...CallLimits.maxMLineIndex).contains($0.sdpMLineIndex ?? 0)
        }
        guard ok else { throw CallMessageError("candidates") }
        let items = candidates.map { c -> String in
            let b = JsonBuilder().string("candidate", c.candidate)
            if let mid = c.sdpMid { b.string("sdp_mid", mid) }
            if let i = c.sdpMLineIndex { b.uint("sdp_mline_index", UInt64(i)) }
            return b.build()
        }
        let body = JsonBuilder().string("call_id", callId).raw("candidates", JsonBuilder.array(items))
        try await device.sendOnce("call.ice", body: body.bytes(), exp: device.clockNow().addingTimeInterval(CallLimits.ephemeralTTL))
    }

    /// `call.end`: hang up (``CallReason/hangup``), decline a ringing call, give up an unanswered one
    /// (``CallReason/timeout``, sent by the **caller** only: the callee's vault records the missed call when it arrives)
    /// or report a failure. Durable: kept until the relay has it. A reason that is none of §10.10's is refused.
    public func callEnd(_ callId: String, reason: String) async throws {
        guard CallReason.all.contains(reason) else { throw CallMessageError("reason") }
        let body = JsonBuilder().string("call_id", callId).string("reason", reason)
        try await device.send(VaultDevice.typeCallEnd, body: body.bytes())
    }

    /// `call.list`: the vault's call history, newest first ([limit] 1 to 200). A vault release without calls answers
    /// `unsupported_type`: that answer is how the app learns that the vault has no calls (§11.10.8: no message lists a
    /// release's features). An entry without a required member is left out, never silently: ``CallList/skipped`` counts
    /// them, so that the screen can say some calls could not be shown.
    public func callList(limit: Int = 50) async throws -> CallList {
        // A limit outside 1 to 200 is refused before anything is sent.
        guard (1...CallLimits.maxListLimit).contains(limit) else { throw CallMessageError("limit") }
        let o = VaultJSON.object(try await device.op("call.list", body: JsonBuilder().uint("limit", UInt64(limit)).bytes()))
        // `calls` that is not an array is a failed decode, as in vettid-android; an entry that is malformed is left out.
        let calls: [JsonValue]
        do { calls = o.has("calls") ? try o.array("calls") : [] } catch { throw CallMessageError("calls") }
        let records = calls.compactMap { (try? $0.asObject()).flatMap(CallRecord.init) }
        // (C2) `v: 2` and the vault's `now`: a C2 vault ("Mixed releases"). Read leniently: anything else is "not C2".
        let version = (try? o["v"]?.asUint(min: 0, max: 1 << 16)).map(Int.init)
        let now = VaultJSON.string(o, "now").flatMap { try? Timestamps.parseMillis($0) }
        return CallList(calls: records, skipped: calls.count - records.count, version: version, now: now)
    }
}
