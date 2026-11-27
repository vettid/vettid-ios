import Foundation
import VettIDCrypto

// The values of call signalling (VAULT-MESSAGING §10.10) that ``VaultApi`` makes and takes in `VaultApi+Calls.swift`:
// the call's keys, a placed and an incoming call, an accepted answer, candidates, ends and the call history. Mirrors the
// types of vettid-android `CallApi`.

/// The two frame keys of a call on this device (``CallMedia``): ``send()`` encrypts the frames this device sends,
/// ``receive()`` decrypts the other device's. They exist only on the two devices of the call. ``destroy()`` wipes them.
///
/// Only ``VaultApi/callAnswer(_:sdp:)`` and ``VaultApi/callAccept(_:event:)`` make these in the app
/// (vettid-android marks the constructor `MadeByCallApi`: an `AcceptedCall` or `CallKeys` says "every signature was
/// checked"). Here the initializer is internal to the package; a test of code built on these types uses `@testable`.
public final class CallKeys: @unchecked Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
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
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }

    /// Derives both direction keys from [kCall] and wipes it in place: the caller's own buffer, not a copy of it.
    static func derive(_ kCall: inout [UInt8], _ n: CallMedia.Negotiated, callId: String, caller: Bool) throws -> CallKeys {
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
public final class OutgoingCall: @unchecked Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let callId: String
    public let connectionId: String
    public let media: String
    /// When the offer expires (the vault's clock): the caller sends `call.end{timeout}` then.
    public let exp: Date
    /// The servers this device may use, and no others.
    public let ice: CallWire.IceConfig
    let offered: [Int]
    /// The fingerprint of the connection that was called (§10.8), as the app showed it when the call was placed: the
    /// answer's `peer_ik` must be that connection's identity, not any other the vault could name.
    let pinnedFingerprint: String
    private let offerKey: KemPrivateKey
    /// (C2) The call's two members as this device named them in its form 2 offer, fixed when it placed the call: the
    /// answer is checked, and `k_call` derived, with these (an answer naming another callee fails, VAULT-MESSAGING
    /// 0.88.16). Nil for a form 1 call.
    let parties: CallWire.Parties?

    /// (C2) Whether the offer carried form 2.
    public var formTwo: Bool { parties != nil }

    init(
        callId: String, connectionId: String, media: String, exp: Date, ice: CallWire.IceConfig, offered: [Int],
        pinnedFingerprint: String, offerKey: KemPrivateKey, parties: CallWire.Parties? = nil
    ) {
        self.parties = parties
        self.pinnedFingerprint = pinnedFingerprint
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
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// The single use of an ``IncomingCall``: the first ``claim()`` is true, every later one false.
final class AnswerOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            defer { claimed = true }
            return !claimed
        }
    }
}

/// A verified `call.offer`: a connection is calling. Nothing of it is used before every signature has checked out.
public struct IncomingCall: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let callId: String
    public let connectionId: String
    public let media: String
    /// The caller's SDP offer, without the media-suite attribute and the `a=ssrc` lines: ready for the media stack.
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
    /// (C2) The members as this device names them when the offer carried form 2 (it then answers in form 2); else nil.
    var parties: CallWire.Parties?

    /// (C2) Whether this device answers in form 2.
    public var formTwo: Bool { parties != nil }

    /// The caller's media suites, as sent (numbers this build does not know included).
    public var offered: [Int] { negotiated.offered }

    /// Set by the one ``VaultApi/callAnswer(_:sdp:)`` this call gets: a second would encapsulate to the caller's key again.
    let answerOnce = AnswerOnce()

    public var description: String { "IncomingCall(\(callId))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// The callee's verified answer on the calling device: its SDP (without the media-suite attribute) and the call's keys.
public struct AcceptedCall: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let callId: String
    public let sdp: String
    public let keys: CallKeys

    public var description: String { "AcceptedCall(\(callId))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// One ICE candidate of `call.ice`. It holds a network address: ``description`` does not print it.
public struct CallCandidate: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let candidate: String
    public let sdpMid: String?
    public let sdpMLineIndex: Int?

    public init(_ candidate: String, sdpMid: String? = nil, sdpMLineIndex: Int? = nil) {
        self.candidate = candidate
        self.sdpMid = sdpMid
        self.sdpMLineIndex = sdpMLineIndex
    }

    public var description: String { "CallCandidate([redacted])" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// `call.ice` as received.
public struct CallIce: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let callId: String
    public let candidates: [CallCandidate]

    public var description: String { "CallIce(\(callId), \(candidates.count) candidates)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// `call.end` as received. ``supersededBy`` (VAULT-MESSAGING §10.10 "Glare"): this device's own outgoing call lost a glare
/// to the connection's call with that id. Read only when it is a call id of its own and not this call's.
public struct CallEnded: Equatable, Sendable {
    public let callId: String
    public let reason: String
    public let supersededBy: String?

    public init(callId: String, reason: String, supersededBy: String? = nil) {
        self.callId = callId
        self.reason = reason
        self.supersededBy = supersededBy
    }
}

/// The answer of `call.list`: the entries that could be read, and how many the vault sent that could not.
public struct CallList: Equatable, Sendable {
    public let calls: [CallRecord]
    /// Entries left out because a required member was missing or of the wrong type; 0 for a clean list.
    public let skipped: Int
    /// (C2) The vault's `v`: 2 for a C2 vault, nil for an S10 one.
    public let version: Int?
    /// (C2) The vault's clock when it answered.
    public let now: Date?

    public init(calls: [CallRecord], skipped: Int, version: Int? = nil, now: Date? = nil) {
        self.calls = calls
        self.skipped = skipped
        self.version = version
        self.now = now
    }

    /// (C2) The vault is C2 ("Mixed releases"): form 2, keep-alives, and the stale sweep by `device_id`, `exp` and `now`.
    public var formTwo: Bool { (version ?? 0) >= 2 && now != nil }
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
    /// (C2, `v: 2`) The offer's `exp`.
    public let exp: String?
    /// (C2, `v: 2`) The call's device (as `device.list` gives it); absent while an incoming call rings.
    public let deviceId: String?

    private static func isTimestamp(_ s: String) -> Bool {
        (try? Timestamps.parseMillis(s)) != nil || (try? Timestamps.parseSeconds(s)) != nil
    }

    init?(_ o: JsonObject) {
        guard let callId = VaultJSON.string(o, "call_id"), let connectionId = VaultJSON.string(o, "connection_id"),
              let direction = VaultJSON.string(o, "direction"), ["in", "out"].contains(direction),
              let media = VaultJSON.string(o, "media"),
              let state = VaultJSON.string(o, "state"), ["ringing", "active", "ended"].contains(state),
              let startedAt = VaultJSON.string(o, "started_at"), Self.isTimestamp(startedAt)
        else { return nil }
        // A timestamp that is present must be one: an entry the app cannot read is not shown, and is counted as skipped.
        for name in ["answered_at", "ended_at", "exp"] {
            if o.has(name), !(VaultJSON.string(o, name).map(Self.isTimestamp) ?? false) { return nil }
        }
        self.callId = callId
        self.connectionId = connectionId
        self.direction = direction
        self.media = media
        self.state = state
        self.startedAt = startedAt
        reason = VaultJSON.string(o, "reason")
        answeredAt = VaultJSON.string(o, "answered_at")
        endedAt = VaultJSON.string(o, "ended_at")
        exp = VaultJSON.string(o, "exp")
        deviceId = VaultJSON.string(o, "device_id")
    }

    init(
        callId: String, connectionId: String, direction: String, media: String, state: String, reason: String? = nil,
        startedAt: String, answeredAt: String? = nil, endedAt: String? = nil, exp: String? = nil, deviceId: String? = nil
    ) {
        self.exp = exp
        self.deviceId = deviceId
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
