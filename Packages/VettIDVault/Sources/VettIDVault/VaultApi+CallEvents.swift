import Foundation
import VettIDCrypto

// The `call.*` events of VAULT-MESSAGING §10.10 as one ordered stream (`VaultApi+Calls.swift` has the calls).

/// One call event from the vault, in the order the vault's events arrived.
public enum CallEvent: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// `call.offer`, **unchecked**: pass the message to ``VaultApi/callIncoming(_:pinnedFingerprint:suites:)``.
    case offer(VaultMessage)
    /// `call.answer`, **unchecked**: pass the message to ``VaultApi/callAccept(_:event:pinnedFingerprint:)`` with the
    /// call it is for.
    case answer(VaultMessage)
    case ringing(callId: String)
    case ended(CallEnded)
    case ice(CallIce)

    public var description: String {
        switch self {
        case .offer: "CallEvent(offer)"
        case .answer: "CallEvent(answer)"
        case .ringing(let id): "CallEvent(ringing, \(id))"
        case .ended(let e): "CallEvent(ended, \(e.callId), \(e.reason))"
        case .ice(let i): "CallEvent(ice, \(i.callId))"
        }
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }

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
    case .number?: guard let i = try? o["sdp_mline_index"]?.asUint(min: 0, max: UInt64(CallLimits.maxMLineIndex)) else { return nil }
        index = Int(i)
    default: return nil
    }
    // The limits of `call.ice` (§10.10), in bytes: a candidate that is longer, or a `sdp_mid` that is, is left out.
    guard candidate.utf8.count <= CallLimits.maxCandidate, (mid?.utf8.count ?? 0) <= CallLimits.maxSdpMid else { return nil }
    return CallCandidate(candidate, sdpMid: mid, sdpMLineIndex: index)
}

private func parseIce(_ m: VaultMessage) -> CallIce? {
    let o = m.object
    guard let id = VaultJSON.string(o, "call_id") else { return nil }
    let raw = (try? o.array("candidates")) ?? []
    // More than 16 candidates is not a message a vault forwards: it is refused whole, not cut to 16.
    guard raw.count <= CallLimits.maxCandidates else { return nil }
    let list = raw.compactMap(parseCandidate)
    return list.isEmpty ? nil : CallIce(callId: id, candidates: list)
}

private func parseEnd(_ m: VaultMessage) -> CallEnded? {
    guard let id = VaultJSON.string(m.object, "call_id"), let reason = VaultJSON.string(m.object, "reason") else { return nil }
    let by = VaultJSON.string(m.object, "superseded_by").flatMap { Ulid.isValid($0) && $0 != id ? $0 : nil }
    return CallEnded(callId: id, reason: reason, supersededBy: by)
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
