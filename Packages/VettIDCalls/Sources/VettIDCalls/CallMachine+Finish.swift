import Foundation
import VettIDVault

// Publishing the state and ending a call.
extension CallMachine {
    func publish(_ s: CallSession) {
        setState(.live(CallState.Live(
            connectionId: s.connectionId, direction: s.direction, phase: s.phase, callId: s.callId, muted: s.muted,
            activeSince: s.activeSince, reconnecting: s.reconnecting, answerThrough: s.keysSet, formTwo: s.formTwo
        )), seq: s.seq)
    }

    /// Ends the call here; [tell] is the `call.end` reason for the vault, or nil when nothing is to be sent.
    func finish(_ s: CallSession, _ reason: CallEnd, _ tell: String?) {
        guard session === s else { return }
        // A held offer whose own end is held too (the call ends before it had its id) has ended: it is not rung below. An end
        // of the call itself `call.start` may still bring is handled when it does (``onPlaced``, ``onLost``).
        forgetEndedGlareOffer(s, s.early)
        // Other calls' ends held while the start was out are not dropped with the session: an offer that comes after one of
        // them (VAULT-MESSAGING §8.4 gives no order) is not rung.
        for case .end(let id, _, _) in s.early { rememberEndedOther(id) }
        let held = s.glareOffer
        // Its candidates: those kept with it, and those still held among the call's early events (a start refused or failed
        // replays nothing).
        var heldIce = s.glareIce
        if let held {
            for case .ice(let id, let candidates) in s.early where id == held.callId { heldIce += candidates }
            heldIce = Array(heldIce.prefix(Self.maxPendingCandidates))
        }
        release(s)
        let callId = s.callId
        if let tell, let callId { sendEnd(callId, tell) }
        let duration = s.activeSince.map { Duration.rounded(seconds: clock.now().timeIntervalSince($0)) }
        if duration != nil { countPath(s) }
        setState(.ended(CallState.Ended(
            connectionId: s.connectionId, direction: s.direction, reason: reason, callId: callId, duration: duration
        )), seq: s.seq, memberEnded: s.memberEnded)
        // The connection's own call that arrived while this one rang to it is not lost when this one ended another way (the
        // vault, the other side, a refusal of `call.start` such as `busy`, a failure): it rings. Never after this member's own
        // end, a lock's above all: a call rings only while the vault is open on this phone, and a lock would decline it unseen.
        if let held, !s.memberEnded, clock.now() < held.exp {
            ring(held)
            // Its candidates that came meanwhile wait for its answer, as a ringing call's own do.
            if !heldIce.isEmpty, let rung = session, rung.callId == held.callId { onIce(rung, heldIce) }
        }
    }

    /// A connected call ended: its path is counted, by the last one the stack reported (relayed, direct, or not said).
    private func countPath(_ s: CallSession) {
        switch s.relayed {
        case true?: paths.relayed += 1
        case false?: paths.direct += 1
        case nil: paths.unknown += 1
        }
    }

    /// Lets the call go: its tasks, engine and keys. Publishes nothing and sends nothing.
    func release(_ s: CallSession) {
        guard session === s else { return }
        session = nil
        s.cancelTasks()
        s.engine?.close()
        s.keys?.wipe()
        for case .answer(let a) in s.early { a.keys.wipe() }
        s.early.removeAll()
        s.pendingRemote.removeAll()
        s.pendingLocal.removeAll()
        s.glareOffer = nil
    }

    /// `call.end` outlives the call: it is durable in the device's outbox once it has been handed over. A failure here is not
    /// its loss (the outbox keeps it until the relay has it, and the other side's ring timer bounds the wait); nothing of it is
    /// logged.
    func sendEnd(_ callId: String, _ reason: String) {
        pendingEnds += 1
        Task { [self] in
            defer { pendingEnds -= 1 }
            try? await signalling.end(callId: callId, reason: reason)
        }
    }
}
