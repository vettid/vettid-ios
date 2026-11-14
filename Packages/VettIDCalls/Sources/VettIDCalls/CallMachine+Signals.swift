import Foundation
import VettIDVault

// What the vault says (VAULT-MESSAGING §10.10), and the glare of "Glare" (C2).

/// `call.end` reasons while an incoming call rings here; anything else is a missed call.
private let ringingHere: [String: CallEnd] = [CallReason.answeredElsewhere: .answeredElsewhere, CallReason.decline: .declinedHere]

/// While this device's call rings there; anything else is a failure.
private let ringingThere: [String: CallEnd] = [
    CallReason.decline: .declined,
    CallReason.busy: .busy,
    CallReason.timeout: .noAnswer,
    CallReason.unavailable: .unavailable,
    CallReason.hangup: .peerHungUp,
]

/// After the answer; anything else is the other member hanging up.
private let answeredReasons: [String: CallEnd] = [
    CallReason.unavailable: .unavailable,
    CallReason.failed: .failed,
    CallReason.answeredElsewhere: .answeredElsewhere,
]

extension CallMachine {
    func onSignal(_ s: CallSession?, _ e: SignalEvent) {
        switch e {
        case .offer(let offer): onOffer(s, offer)
        case .ringing(let callId): if let s { onRinging(s, callId) }
        case .answer(let a): onAnswerEvent(s, a)
        case .answerRejected(let callId):
            if let s, s.callId == callId, s.direction == .outgoing { finish(s, .notEncrypted, CallReason.failed) }
        case .ice(let callId, let candidates): if let s, s.callId == callId { onIce(s, candidates) }
        case .end(let callId, let reason, let supersededBy):
            if let s { onEnd(s, callId: callId, reason: reason, supersededBy: supersededBy) }
        }
    }

    private func onRinging(_ s: CallSession, _ callId: String) {
        guard s.callId == callId, s.phase == .calling else { return }
        s.phase = .ringing
        diagnostics.tapToRingingMs = clock.elapsedMs() - s.tappedAtMs
        publish(s)
    }

    private func onAnswerEvent(_ s: CallSession?, _ a: CallAnswer) {
        if let s, s.callId == a.callId, s.direction == .outgoing, s.phase == .calling || s.phase == .ringing {
            takeAnswer(s, a)
        } else {
            a.keys.wipe()
        }
    }

    private func onIce(_ s: CallSession, _ candidates: [CallCandidate]) {
        if s.remoteApplied, let engine = s.engine {
            s.enqueue { try await engine.addRemoteCandidates(candidates) }
        } else if s.pendingRemote.count + candidates.count <= Self.maxPendingCandidates {
            s.pendingRemote += candidates
        }
    }

    private func onOffer(_ s: CallSession?, _ offer: CallOffer) {
        if endedWinners.contains(offer.callId) { return } // a glare's winner that already ended
        guard let s else {
            ring(offer)
            return
        }
        if glareWith(s, offer) {
            if s.supersededBy == offer.callId { takeGlare(s, offer) } else { s.glareOffer = offer }
        }
        // Otherwise: busy here. The vault rings every device, and this one is in another call.
    }

    /// The vault's `call.end` for the call here, for its held glare offer, or for neither.
    private func onEnd(_ s: CallSession, callId: String, reason: String, supersededBy: String?) {
        if s.glareOffer?.callId == callId {
            // The connection's held offer ended (its caller hung up): it is no longer one to ring or answer, and an offer for
            // it delivered again is not either.
            s.glareOffer = nil
            rememberEnded(callId)
        } else if let by = s.supersededBy, by == callId {
            // The winner itself ended before its offer reached this device: there is nothing to answer, and the vault ended
            // this device's own call already. A late offer for it is not answered or rung.
            rememberEnded(callId)
            finish(s, .missed, nil)
        } else if s.callId == callId, s.supersededBy == nil {
            // (While a lost glare waits for its winner, X's own end came already: a second one changes nothing.)
            if superseded(s, reason: reason, by: supersededBy) {
                if let held = s.glareOffer, held.callId == supersededBy, clock.now() < held.exp {
                    takeGlare(s, held)
                } else {
                    lostGlare(s, supersededBy)
                }
            } else {
                finish(s, ended(s, reason), nil)
            }
        }
    }

    private func rememberEnded(_ callId: String) {
        endedWinners.append(callId)
        if endedWinners.count > Self.maxEndedWinners { endedWinners.removeFirst() }
    }

    /// [offer] is the connection's own call while this device's outgoing call to it still rings: a glare, perhaps.
    private func glareWith(_ s: CallSession, _ offer: CallOffer) -> Bool {
        s.direction == .outgoing && s.connectionId == offer.connectionId && offer.callId != s.callId
            && (s.supersededBy == nil || s.supersededBy == offer.callId)
            && (s.phase == .starting || s.phase == .calling || s.phase == .ringing)
    }

    /// The vault ended this device's ringing outgoing call because the connection's own call won a glare.
    private func superseded(_ s: CallSession, reason: String, by: String?) -> Bool {
        // Both vaults let the lower call id win (its 26 ASCII bytes): a winner that is not lower is no glare's.
        guard let by, let own = s.callId, Array(by.utf8).lexicographicallyPrecedes(Array(own.utf8)) else { return false }
        return reason == CallReason.busy && s.direction == .outgoing && (s.phase == .calling || s.phase == .ringing)
            && s.supersededBy == nil
    }

    /// The winner's offer is not here yet: this call's media goes (the microphone is let go), its screen stays, and the offer
    /// is answered when it comes. Nothing is sent: the vault already ended this call.
    private func lostGlare(_ s: CallSession, _ by: String?) {
        s.supersededBy = by
        s.glareOffer = nil
        cancelTimer(s, .gather)
        cancelTimer(s, .iceFlush)
        s.canSendIce = false
        s.pendingLocal.removeAll()
        s.pendingRemote.removeAll()
        // The lost call's queued engine work is dropped, not run on a closed engine.
        s.dropLane()
        s.engine?.close()
        s.engine = nil
    }

    /// (D21 a) The member asked for this call seconds ago: the winning call [offer] from the same connection is answered here
    /// without asking, as soon as this device's own lost call is let go (nothing is sent for it). Calls are audio only
    /// (C1-C3), so the answer never carries more media than the lost call did (VAULT-MESSAGING 0.88.14). A video offer does not
    /// reach the machine at all (`callIncoming` refuses anything but one audio section), so a video winner is not answered:
    /// the lost call shows busy at its ring timer.
    private func takeGlare(_ s: CallSession, _ offer: CallOffer) {
        release(s)
        let y = incoming(offer)
        answerIncoming(y)
    }

    func ring(_ offer: CallOffer) {
        let s = incoming(offer)
        publish(s)
        s.launch { [signalling] in try? await signalling.ringing(callId: offer.callId) }
        // The caller's `call.end{timeout}` normally ends the ringing; this is for a caller that has gone.
        let ringMs = (offer.ringFor + timings.incomingGrace).wholeMilliseconds
        let lo = timings.incomingGrace.wholeMilliseconds
        let hi = timings.maxIncomingRing.wholeMilliseconds
        timer(s, .ringIn, .milliseconds(min(max(ringMs, lo), hi)))
    }

    private func incoming(_ offer: CallOffer) -> CallSession {
        let s = newSession(offer.connectionId, .incoming)
        s.callId = offer.callId
        s.offer = offer
        s.phase = .incoming
        return s
    }

    private func takeAnswer(_ s: CallSession, _ a: CallAnswer) {
        guard let engine = s.engine else {
            a.keys.wipe()
            return
        }
        cancelTimer(s, .ringOut)
        // Answered: an offer from the connection now is no glare, and is not rung after this call either.
        s.glareOffer = nil
        s.phase = .connecting
        s.answeredAtMs = clock.elapsedMs()
        s.keysSet = true
        s.keys = a.keys
        // The keys first, then the answer: no frame is ever sent or played without them.
        s.enqueue { [self] in
            try await give(a.keys, to: engine)
            try await engine.acceptAnswer(sdp: a.sdp)
        }
        applyRemote(s)
        timer(s, .connect, timings.connect)
        startDiagnostics(s)
        publish(s)
    }

    /// What the other side's (or this member's other device's) `call.end` means here. (C2) The caller's `call.end{failed}` while
    /// this device still holds its track for a first decrypted frame is the caller's wrong `confirm`: the same text as the 20 s
    /// rule's, "couldn't be encrypted" (VAULT-MESSAGING "Key confirmation").
    private func ended(_ s: CallSession, _ reason: String) -> CallEnd {
        if s.heldForDecrypt && reason == CallReason.failed { return .notEncrypted }
        switch s.phase {
        case .incoming: return ringingHere[reason] ?? .missed
        case .starting, .calling, .ringing: return ringingThere[reason] ?? .failed
        case .connecting, .active: return answeredReasons[reason] ?? .peerHungUp
        }
    }
}
