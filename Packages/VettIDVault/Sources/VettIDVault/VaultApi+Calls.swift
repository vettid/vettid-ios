import Foundation
import VettIDCrypto

// Calls (VAULT-MESSAGING §10.10; CALLS-PLAN phase C1): the seven `call.*` types as an app sends and receives them.
// Signalling goes device → its vault → the peer's vault → the peer's devices. The media key is agreed between the two
// devices (``CallWire``); this file signs and checks the key-exchange shares, checks the vault-signed ICE configuration,
// negotiates the media suite inside the SDP and derives the two direction keys (``CallMedia``). Mirrors vettid-android
// `CallApi`.
//
// Sending: `call.start`, `call.answer`, `call.ice` and `call.ringing` are deposited once and never kept or re-sent
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
    /// How long the app waits for the answer to `call.start` before it gives the call up.
    public static let startTimeout: TimeInterval = 15
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

/// The two frame keys of a call on this device (``CallMedia``): ``send()`` encrypts the frames this device sends,
/// ``receive()`` decrypts the other device's. They exist only on the two devices of the call. ``destroy()`` wipes them.
///
/// Only ``VaultApi/callAnswer(_:sdp:)`` and ``VaultApi/callAccept(_:event:pinnedFingerprint:)`` make these in the app
/// (vettid-android marks the constructor `MadeByCallApi`: an `AcceptedCall` or `CallKeys` says "every signature was
/// checked"). Here the initializer is internal to the package; a test of code built on these types uses `@testable`.
public final class CallKeys: @unchecked Sendable, CustomStringConvertible {
    public let suite: MediaSuite
    private let lock = NSLock()
    private var live = true
    private var sendKey: [UInt8]
    private var receiveKey: [UInt8]

    init(suite: MediaSuite, send: [UInt8], receive: [UInt8]) {
        self.suite = suite
        sendKey = send
        receiveKey = receive
    }

    deinit { destroy() }

    /// A copy of the key for this device's sender; the caller wipes it after handing it to the media stack.
    public func send() throws -> [UInt8] {
        try lock.withLock {
            guard live else { throw VaultStateError(message: "call keys destroyed") }
            return sendKey
        }
    }

    /// A copy of the key for this device's receiver.
    public func receive() throws -> [UInt8] {
        try lock.withLock {
            guard live else { throw VaultStateError(message: "call keys destroyed") }
            return receiveKey
        }
    }

    public func destroy() {
        lock.withLock {
            live = false
            Bytes.wipe(&sendKey)
            Bytes.wipe(&receiveKey)
        }
    }

    public var description: String { "CallKeys(suite=\(suite.id), [redacted])" }

    /// Derives both direction keys from [kCall] and wipes it.
    static func derive(_ kCall: [UInt8], _ n: CallMedia.Negotiated, callId: String, caller: Bool) throws -> CallKeys {
        var kCall = kCall
        defer { Bytes.wipe(&kCall) }
        let fromCaller = try CallMedia.directionKey(kCall: kCall, negotiated: n, direction: CallMedia.directionCaller, callId: callId)
        let fromCallee = try CallMedia.directionKey(kCall: kCall, negotiated: n, direction: CallMedia.directionCallee, callId: callId)
        return caller
            ? CallKeys(suite: n.chosen, send: fromCaller, receive: fromCallee)
            : CallKeys(suite: n.chosen, send: fromCallee, receive: fromCaller)
    }
}

/// A call this device placed, while it waits for the answer. Holds the ephemeral KEM key: ``destroy()`` when the call is
/// over.
public final class OutgoingCall: @unchecked Sendable, CustomStringConvertible {
    public let callId: String
    public let connectionId: String
    public let media: String
    /// When the offer expires (the vault's clock): the caller sends `call.end{timeout}` then.
    public let exp: Date
    /// The servers this device may use, and no others.
    public let ice: CallWire.IceConfig
    let offered: [Int]
    private let offerKey: KemPrivateKey

    init(callId: String, connectionId: String, media: String, exp: Date, ice: CallWire.IceConfig, offered: [Int], offerKey: KemPrivateKey) {
        self.callId = callId
        self.connectionId = connectionId
        self.media = media
        self.exp = exp
        self.ice = ice
        self.offered = offered
        self.offerKey = offerKey
    }

    func key() -> KemPrivateKey { offerKey }

    public func destroy() { offerKey.destroy() }

    public var description: String { "OutgoingCall(\(callId))" }
}

/// A verified `call.offer`: a connection is calling. Nothing of it is used before every signature has checked out.
public struct IncomingCall: Sendable, CustomStringConvertible {
    public let callId: String
    public let connectionId: String
    public let media: String
    /// The caller's SDP offer, without the media-suite attribute: ready for the media stack.
    public let sdp: String
    /// When the offer expires, by the vault's clock.
    public let exp: Date
    /// How long the offer had to live when the vault sent it (`exp` minus the event's `ts`, both the vault's clock): how
    /// long the device rings, whatever its own clock says.
    public let ringFor: TimeInterval
    public let ice: CallWire.IceConfig
    /// The suite this device will answer with, and the caller's list as sent: fixed before the phone rings.
    public let negotiated: CallMedia.Negotiated
    let ek: [UInt8]

    /// The caller's media suites, as sent (numbers this build does not know included).
    public var offered: [Int] { negotiated.offered }

    public var description: String { "IncomingCall(\(callId))" }
}

/// The callee's verified answer on the calling device: its SDP (without the media-suite attribute) and the call's keys.
public struct AcceptedCall: Sendable {
    public let callId: String
    public let sdp: String
    public let keys: CallKeys
}

/// One ICE candidate of `call.ice`. It holds a network address: ``description`` does not print it.
public struct CallCandidate: Equatable, Sendable, CustomStringConvertible {
    public let candidate: String
    public let sdpMid: String?
    public let sdpMLineIndex: Int?

    public init(_ candidate: String, sdpMid: String? = nil, sdpMLineIndex: Int? = nil) {
        self.candidate = candidate
        self.sdpMid = sdpMid
        self.sdpMLineIndex = sdpMLineIndex
    }

    public var description: String { "CallCandidate([redacted])" }
}

/// `call.ice` as received.
public struct CallIce: Equatable, Sendable {
    public let callId: String
    public let candidates: [CallCandidate]
}

/// `call.end` as received.
public struct CallEnded: Equatable, Sendable {
    public let callId: String
    public let reason: String
}

/// One entry of `call.list` (the vault keeps the latest 200 calls; no SDP, no keys).
public struct CallRecord: Equatable, Sendable {
    public let callId: String
    public let connectionId: String
    /// `in` or `out`.
    public let direction: String
    public let media: String
    /// `ringing`, `active` or `ended`.
    public let state: String
    public let reason: String?
    public let startedAt: String
    public let answeredAt: String?
    public let endedAt: String?

    init?(_ o: JsonObject) {
        guard let callId = VaultJSON.string(o, "call_id"), let connectionId = VaultJSON.string(o, "connection_id"),
              let direction = VaultJSON.string(o, "direction"), let media = VaultJSON.string(o, "media"),
              let state = VaultJSON.string(o, "state"), let startedAt = VaultJSON.string(o, "started_at")
        else { return nil }
        self.callId = callId
        self.connectionId = connectionId
        self.direction = direction
        self.media = media
        self.state = state
        self.startedAt = startedAt
        reason = VaultJSON.string(o, "reason")
        answeredAt = VaultJSON.string(o, "answered_at")
        endedAt = VaultJSON.string(o, "ended_at")
    }

    init(
        callId: String, connectionId: String, direction: String, media: String, state: String, reason: String? = nil,
        startedAt: String, answeredAt: String? = nil, endedAt: String? = nil
    ) {
        self.callId = callId
        self.connectionId = connectionId
        self.direction = direction
        self.media = media
        self.state = state
        self.reason = reason
        self.startedAt = startedAt
        self.answeredAt = answeredAt
        self.endedAt = endedAt
    }
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
    private func verifyPeerShare(_ o: JsonObject, _ message: [UInt8], _ pinnedFingerprint: String) throws {
        try checked("key-exchange share") {
            let peerIk = try o.b64("peer_ik", Suite.ed25519PublicSize)
            let shown = try IkFingerprint.format(peerIk)
            guard !pinnedFingerprint.isEmpty, Bytes.constantTimeEquals(Array(shown.utf8), Array(pinnedFingerprint.utf8)) else {
                throw CryptoError.signature("peer_ik is not the connection's identity key")
            }
            try CallWire.verifyShare(
                vaultIk: peerIk, deviceIk: try o.b64("device_ik", Suite.ed25519PublicSize), message: message,
                deviceSig: try o.b64("device_sig", Suite.ed25519SignatureSize),
                vaultSig: try o.b64("vault_sig", Suite.ed25519SignatureSize)
            )
        }
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
    /// signed with the device's identity key. Deposited once and awaited for [timeout]. Errors (``VaultOpError``): `busy`
    /// (this vault is already in a call), `not_found`, `connection_unavailable`, `owner_check_required`, `exists`,
    /// `bad_request`, `internal`, and `unsupported_type` from a vault release without calls. When it fails in any other
    /// way after the request may have left (no answer in time, a lost response, an answer that does not verify), a
    /// durable `call.end{hangup}` for the same `call_id` follows, so that a call the vault did place does not ring on for
    /// nobody.
    public func callStart(
        _ connectionId: String, sdp: String, suites: [MediaSuite] = MediaSuite.default, media: String = CallWire.mediaAudio,
        timeout: TimeInterval = CallLimits.startTimeout
    ) async throws -> OutgoingCall {
        let callId = device.newRequestID()
        let offered = try checked("media suites") { try CallMedia.offerOf(MediaSuite.formOne(suites)) }
        let offer = try checked("media suites") { try CallMedia.sdpWithOffer(sdp, offered: offered) }
        try checkSdp(offer)
        let key = try CallWire.newOfferKey()
        var attempted = false
        do {
            let ek = key.publicKey.bytes
            let share = try device.signCallShare(CallWire.shareMessage(role: CallWire.roleOffer, callId: callId, media: media, share: ek))
            attempted = true
            let body = JsonBuilder().string("connection_id", connectionId).string("call_id", callId).string("media", media)
                .string("sdp", offer).base64("ek", ek).base64("ek_sig", share)
            let o = VaultJSON.object(try await device.opOnce("call.start", body: body.bytes(), timeout: timeout))
            guard try o.need("call_id") == callId else { throw CallMessageError("call.start answered for another call") }
            let exp = try checked("exp") { try Timestamps.parseMillis(try o.need("exp")) }
            return OutgoingCall(
                callId: callId, connectionId: connectionId, media: media, exp: exp, ice: try iceOf(o, callId), offered: offered,
                offerKey: key
            )
        } catch let e as VaultOpError {
            // The vault's own refusal: there is no call.
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
    /// form 1 offer without suite 1 does not ring). Throws ``CallMessageError`` for an offer that must not ring: nothing
    /// of it is used, and nothing is sent.
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
        try verifyPeerShare(o, CallWire.shareMessage(role: CallWire.roleOffer, callId: callId, media: media, share: ek), pinnedFingerprint)
        let negotiated = try checked("media suites") {
            try CallMedia.choose(offered: try CallMedia.offeredIn(sdp), supported: MediaSuite.formOne(suites))
        }
        return IncomingCall(
            callId: callId, connectionId: try o.need("connection_id"), media: media, sdp: CallMedia.sdpWithout(sdp), exp: exp,
            ringFor: ringFor, ice: ice, negotiated: negotiated, ek: ek
        )
    }

    /// `call.answer`: answers [call] with this device's SDP answer [sdp]; the media suite chosen when the offer was checked
    /// (``IncomingCall/negotiated``) is added to it here. Encapsulates to the caller's key, signs the share, deposits once,
    /// and returns the call's keys, which never leave this device. The vault does not answer: a call that was no longer
    /// ringing comes back as `call.end{unavailable}`.
    public func callAnswer(_ call: IncomingCall, sdp: String) async throws -> CallKeys {
        let chosen = call.negotiated
        let answer = CallMedia.sdpWithChoice(sdp, chosen: chosen.chosen)
        try checkSdp(answer)
        let a = try checked("key agreement") { try CallWire.answer(ek: call.ek, callId: call.callId) }
        let keys = try CallKeys.derive(a.kCall, chosen, callId: call.callId, caller: false)
        do {
            let shared = CallWire.shareMessage(role: CallWire.roleAnswer, callId: call.callId, media: "", share: a.enc)
            let encSig = try device.signCallShare(shared)
            let body = JsonBuilder().string("call_id", call.callId).string("sdp", answer).base64("enc", a.enc).base64("enc_sig", encSig)
            try await device.sendOnce("call.answer", body: body.bytes())
            return keys
        } catch {
            keys.destroy()
            throw error
        }
    }

    /// Checks the `call.answer` event for [call] on the calling device: `peer_ik` against [pinnedFingerprint], the
    /// answerer's share under it, the SDP's one Opus audio section and the choice of media suite; then derives the call's
    /// keys. The ephemeral KEM key is destroyed when the answer is accepted; after a ``CallMessageError`` the caller of
    /// this function destroys [call] (the call is over).
    public func callAccept(_ call: OutgoingCall, event: VaultMessage, pinnedFingerprint: String) throws -> AcceptedCall {
        let o = event.object
        guard try o.callId() == call.callId else { throw CallMessageError("answer for another call") }
        let sdp = try sdpOf(o)
        let enc = try o.b64("enc", Suite.encSize)
        let shared = CallWire.shareMessage(role: CallWire.roleAnswer, callId: call.callId, media: "", share: enc)
        try verifyPeerShare(o, shared, pinnedFingerprint)
        let chosen = try checked("media suites") { try CallMedia.chosenIn(sdp, offered: call.offered) }
        let kCall = try checked("key agreement") { try CallWire.accept(offerKey: call.key(), enc: enc, callId: call.callId) }
        call.destroy()
        return AcceptedCall(
            callId: call.callId, sdp: CallMedia.sdpWithout(sdp), keys: try CallKeys.derive(kCall, chosen, callId: call.callId, caller: true)
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
    /// release's features). An entry without a required member is left out (§10.1).
    public func callList(limit: Int = 50) async throws -> [CallRecord] {
        let o = VaultJSON.object(try await device.op("call.list", body: JsonBuilder().uint("limit", UInt64(max(limit, 0))).bytes()))
        return ((try? o.array("calls")) ?? []).compactMap { (try? $0.asObject()).flatMap(CallRecord.init) }
    }
}

/// One call event from the vault, in the order the vault's events arrived.
public enum CallEvent: Sendable {
    /// `call.offer`, **unchecked**: pass the message to ``VaultApi/callIncoming(_:pinnedFingerprint:suites:)``.
    case offer(VaultMessage)
    /// `call.answer`, **unchecked**: pass the message to ``VaultApi/callAccept(_:event:pinnedFingerprint:)`` with the
    /// call it is for.
    case answer(VaultMessage)
    case ringing(callId: String)
    case ended(CallEnded)
    case ice(CallIce)

    /// For an offer, the connection the event names, to look its identity up before the check; not yet verified.
    public var connectionId: String? {
        guard case .offer(let m) = self else { return nil }
        return VaultJSON.string(m.object, "connection_id")
    }

    /// For an answer, the call it names; not yet verified.
    public var answerCallId: String? {
        guard case .answer(let m) = self else { return nil }
        return VaultJSON.string(m.object, "call_id")
    }
}

private let callEventTypes: Set<String> = ["call.offer", "call.answer", "call.ringing", "call.end", "call.ice"]

private func parseCandidate(_ v: JsonValue) -> CallCandidate? {
    guard let o = try? v.asObject(), let candidate = VaultJSON.string(o, "candidate") else { return nil }
    var mid: String?
    switch o["sdp_mid"] {
    case nil, .null?: mid = nil
    case .string(_, let s)?: mid = s
    default: return nil
    }
    var index: Int?
    switch o["sdp_mline_index"] {
    case nil, .null?: index = nil
    case .number?: guard let i = try? o["sdp_mline_index"]?.asUint(min: 0, max: UInt64(Int32.max)) else { return nil }
        index = Int(i)
    default: return nil
    }
    return CallCandidate(candidate, sdpMid: mid, sdpMLineIndex: index)
}

private func parseIce(_ m: VaultMessage) -> CallIce? {
    let o = m.object
    guard let id = VaultJSON.string(o, "call_id") else { return nil }
    let list = ((try? o.array("candidates")) ?? []).compactMap(parseCandidate)
        .filter { $0.candidate.utf16.count <= CallLimits.maxCandidate }.prefix(CallLimits.maxCandidates)
    return list.isEmpty ? nil : CallIce(callId: id, candidates: Array(list))
}

private func parseEnd(_ m: VaultMessage) -> CallEnded? {
    guard let id = VaultJSON.string(m.object, "call_id"), let reason = VaultJSON.string(m.object, "reason") else { return nil }
    return CallEnded(callId: id, reason: reason)
}

/// [events] as call events: the `call.*` ones, in the order they arrived; anything else is left out.
public func callEventsIn<S: AsyncSequence & Sendable>(
    _ events: S
) -> AsyncCompactMapSequence<S, CallEvent> where S.Element == VaultMessage {
    events.compactMap { m -> CallEvent? in
        guard callEventTypes.contains(m.type) else { return nil }
        switch m.type {
        case "call.offer": return .offer(m)
        case "call.answer": return .answer(m)
        case "call.ringing": return VaultJSON.string(m.object, "call_id").map { .ringing(callId: $0) }
        case "call.end": return parseEnd(m).map { .ended($0) }
        default: return parseIce(m).map { .ice($0) }
        }
    }
}

extension VaultApi {
    /// Every `call.*` event, one stream, so that their order is the vault's (an answer before the candidates after it).
    public func callEvents() -> AsyncCompactMapSequence<AsyncStream<VaultMessage>, CallEvent> {
        callEventsIn(device.events())
    }
}
