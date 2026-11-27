import Foundation
import VettIDCrypto
import VettIDVault

// Placing and answering a call.
extension CallMachine {
    func startOutgoing(_ connectionId: String) {
        let s = newSession(connectionId, .outgoing)
        publish(s)
        guard openEngine(s), let engine = s.engine else { return }
        // What this start offers (form 1: suite 1). The engine's cryptors are made for its first suite, the only one the call can
        // use: an answer that names another is refused by the engine, never remade for.
        let offered = signalling.offerable(engine.suites)
        guard let first = offered.first else {
            finish(s, .notEncrypted, nil)
            return
        }
        s.enqueue { [self] in
            let sdp = try await engine.createOffer(suite: first)
            // Ended while the offer was made (a hang-up, a lock): this start does not go, so there is no call to end. Checked
            // and counted in the same turn: from the count on, a lock waits for the start's answer (``startsInFlight``).
            guard session === s, !Task.isCancelled else { return }
            startsInFlight += 1
            // Posted once the start has returned and after its answer's own message, whichever way it went (a refusal, an
            // error, nothing placed included): this lane waits for the start to its end, whatever cancels it.
            defer { post(.startReturned) }
            // Not cancelled by a hang-up: once `call.start` may have left, its answer is needed to end the call.
            try await uncancellable { [self] in
                do {
                    let placed = try await signalling.start(connectionId: connectionId, sdp: sdp, suites: offered)
                    post(.placed(seq: s.seq, placed, atMs: clock.elapsedMs()))
                } catch let e as CallRefusedError {
                    post(.failed(seq: s.seq, Self.refusal(e.code)))
                } catch let e as CallLostError {
                    post(.lost(seq: s.seq, callId: e.callId, end: e.end))
                }
                // Any other failure after the request may have left (no answer in time, a lost answer, one that does not
                // verify) leaves the lane failed with no end sent here: `VaultApi.callStart` has already sent the durable
                // `call.end{hangup}` for the call's id (VAULT-MESSAGING §10.10 "Placing a call") before this start returned.
                // The lock gate lets it through, and a pending lock waits for it, though only for ``CallsController/lockWait``.
            }
        }
    }

    static func refusal(_ code: String) -> CallEnd {
        switch code {
        case "busy": .ownVaultBusy
        case "calls_off": .callsOff
        case "not_found", "connection_unavailable": .unavailable
        case "owner_check_required": .ownerCheckRequired
        case "unsupported_type": .notSupported
        default: .failed
        }
    }

    /// `call.start` placed a call that can no longer be made (``CallLostError``). When the vault's end for it is known (held
    /// here, or carried as [end]), the call shows that end (busy, declined, missed for a glare whose winner ended) and nothing
    /// is sent. Otherwise it is ended at the vault through ``sendEnd(_:_:)`` like every end (a lock waits for it): the member's
    /// call shows it failed, and one no session shows is ended as hung up (``lostUnshown(seq:callId:end:)``).
    func onLost(_ s: CallSession?, seq: Int, callId: String, end: CallLostError.End?) {
        guard let s, s.seq == seq else { return lostUnshown(seq: seq, callId: callId, end: end) }
        // The machine may hold the vault's own end for it among its early events (the oldest ``maxEarly`` of every kind, where
        // the signalling remembers the newest ends): that end says how the call ended (`busy`, a glare's winner, the winner's own
        // end), as for a placed call (``onPlaced(_:seq:call:atMs:)``). Nothing else held is of use: the call has no key, and its
        // media never started.
        let ended = replayHeldEnds(s, callId: callId, carried: end)
        guard session === s else { return }
        // The vault's end the signalling remembered, which the machine may not have had yet (it may be on its way here, to land
        // with no session) or at all: applied as it would have been, so a `busy` or a glare's end is what the call shows, and
        // nothing is sent for it.
        if let end, s.supersededBy == nil {
            onSignal(s, .end(callId: callId, reason: end.reason, supersededBy: end.supersededBy))
            guard session === s else { return }
        }
        settleLost(s, endedEarly: ended)
    }

    /// The lost call takes its id and the ends held for it are applied; the calls they ended are returned. Candidates of
    /// another call (a glare's winner) are given to the session they are for: kept with the held offer, or applied to the
    /// winner once it is answered. The lost call's own are of no use. The end the start [carried], applied after the replay,
    /// counts for the winners' rule as a held one does (``rememberHeldWinners(_:of:carried:)``).
    private func replayHeldEnds(_ s: CallSession, callId: String, carried: CallLostError.End?) -> Set<String> {
        let early = s.early
        s.early.removeAll()
        s.callId = callId
        // An offer held before the call had its id, that turns out to carry this very id, is no other call.
        if s.glareOffer?.callId == callId { s.glareOffer = nil }
        forgetEndedGlareOffer(s, early)
        rememberHeldWinners(early, of: callId, carried: carried)
        s.phase = .calling
        var ended: Set<String> = []
        for e in early {
            if case .answer(let a) = e {
                a.keys.wipe()
            } else if case .end(let id, _, _) = e, session === s {
                ended.insert(id)
                onSignal(s, e)
            } else if case .end = e {
                afterReplay(e)
            } else if case .ice(let id, _) = e, id != callId, let current = session {
                onSignal(current, e)
            }
        }
        return ended
    }

    /// A lost call still shown once its ends are applied: a glare it lost waits for its winner (unless the winner ended), and
    /// one whose end is not known fails now.
    private func settleLost(_ s: CallSession, endedEarly: Set<String>) {
        if let by = s.supersededBy, hasEnded(by) || endedEarly.contains(by) {
            // Lost to a call that has ended already: nothing to answer, nothing to wait for, and a late offer for the winner is
            // not rung (as for a placed call). The winners' rule normally settles this before the replay
            // (``rememberHeldWinners(_:of:carried:)``), and ``lostGlare`` finishes the call; this stays as a safety net for a
            // winner whose end was held but is no longer among the ended calls when the glare's end is applied.
            rememberEnded(by)
            finish(s, .missed, nil)
        } else if s.supersededBy != nil {
            // The winner's offer is not here yet: it comes in moments, or the call ends busy at the ring timer (``onTimer(_:_:)``),
            // as a placed call's wait does.
            timer(s, .ringOut, timings.minRing)
            publish(s)
        } else {
            // Its end is not known (it may have been lost): it fails now.
            finish(s, .failed, CallReason.failed)
        }
    }

    /// A lost call no session shows (the member hung up while the vault was answering) is ended as hung up, as
    /// ``onPlaced(_:seq:call:atMs:)`` ends a placed one. Not when the vault ended it already ([end] is its end).
    private func lostUnshown(seq: Int, callId: String, end: CallLostError.End?) {
        if end == nil { sendEnd(callId, CallReason.hangup) }
    }

    func onPlaced(_ s: CallSession?, seq: Int, call: PlacedCall, atMs: Int64) {
        guard let s, s.seq == seq else {
            // No session shows the call: the member hung up while the vault was answering. The call exists there, so it is
            // ended there, as hung up, as a lost one is (``lostUnshown(seq:callId:end:)``).
            sendEnd(call.callId, CallReason.hangup)
            return
        }
        let early = s.early
        s.early.removeAll()
        s.callId = call.callId
        // An offer held before the call had its id, that turns out to carry this very id, is no other call.
        if s.glareOffer?.callId == call.callId { s.glareOffer = nil }
        forgetEndedGlareOffer(s, early)
        rememberHeldWinners(early, of: call.callId)
        s.formTwo = call.formTwo
        s.phase = .calling
        s.canSendIce = true
        diagnostics.tapToPlacedMs = atMs - s.tappedAtMs
        guard let engine = s.engine else { return }
        s.enqueue { try await engine.startGathering(servers: call.servers) }
        timer(s, .gather, timings.gather)
        let ringMs = Int64((call.exp.timeIntervalSince(clock.now()) * 1000).rounded())
        timer(s, .ringOut, .milliseconds(min(max(ringMs, timings.minRing.wholeMilliseconds), timings.maxRing.wholeMilliseconds)))
        publish(s)
        // What arrived before this, in its order; each is checked against the call's id as usual.
        for e in early {
            if session === s {
                onSignal(s, e)
            } else {
                afterReplay(e)
            }
        }
    }

    /// Before a replay: the winner of a glare this call [callId] lost, when the winner's own end is among the held events too
    /// or it is already known to have ended here (``hasEnded(_:)``), is remembered among the winners first, so that the other
    /// calls' ends held with it cannot push it out before the glare's end is applied (``lostGlare``). Only this call's own
    /// glare end counts, under the rule ``superseded`` applies (`busy`, a lower winner): other calls' ends that name a winner
    /// do not fill the winners' list. On the lost path the glare's end may be the one the start [carried] (``CallLostError``)
    /// rather than a held one: it counts the same, so that a winner known to have ended only among the other calls' ends
    /// (``endedOthers``) is not pushed out by the ends held with the start before that end is applied.
    private func rememberHeldWinners(_ early: [SignalEvent], of callId: String, carried: CallLostError.End? = nil) {
        var ended: Set<String> = []
        for case .end(let id, _, _) in early { ended.insert(id) }
        var own: [(reason: String, by: String)] = []
        for case .end(let id, let reason, let by?) in early where id == callId { own.append((reason, by)) }
        if let carried, let by = carried.supersededBy { own.append((carried.reason, by)) }
        for (reason, by) in own
        where reason == CallReason.busy && (ended.contains(by) || hasEnded(by))
            && Array(by.utf8).lexicographicallyPrecedes(Array(callId.utf8)) {
            rememberEnded(by)
        }
    }

    /// A held event left once the replay has finished the call, or handed the session to a glare's winner: an answer's keys
    /// are wiped, and an end is still recorded, for the session it is for or as another call's (``endedOthers``).
    private func afterReplay(_ e: SignalEvent) {
        switch e {
        case .answer(let a):
            a.keys.wipe()
        case .end(let id, _, _):
            // The session made meanwhile can only be a held offer rung or answered (``finish``, ``takeGlare``), whose own end
            // ``forgetEndedGlareOffer`` would have found first: an end for it here is not expected, and is applied all the
            // same should it come.
            if let current = session, current.callId == id { onSignal(current, e) } else { rememberEndedOther(id) }
        case .ice:
            // A glare's winner answered meanwhile (``takeGlare``): its candidates held with these are its own.
            if let current = session { onSignal(current, e) }
        default:
            break
        }
    }

    /// A held glare offer whose own end is among the held events has ended, as ``onEnd`` treats one live: it is let go and
    /// remembered before they are applied (or dropped, when the call ends before it has its id), so the glare's end does not
    /// answer it (that end is applied before the winner's, which would then reach the answered call no more), the call is
    /// missed when the winner's end is applied, and a call that ends otherwise does not ring it (``finish(_:_:_:)``).
    func forgetEndedGlareOffer(_ s: CallSession, _ early: [SignalEvent]) {
        guard let held = s.glareOffer else { return }
        for case .end(let id, _, _) in early where id == held.callId {
            s.glareOffer = nil
            rememberEnded(id)
            return
        }
    }

    func answerIncoming(_ s: CallSession) {
        guard let offer = s.offer else { return }
        cancelTimer(s, .ringIn)
        s.phase = .connecting
        s.answeredAtMs = clock.elapsedMs()
        publish(s)
        guard openEngine(s) else {
            sendEnd(offer.callId, CallReason.failed)
            return
        }
        guard let engine = s.engine else { return }
        // (C2, VAULT-MESSAGING "Key confirmation") A device answering a form 2 offer (it answers in form 2, whatever the vault
        // probe has found yet) sends no media, microphone or camera, until its receiver first decrypts a frame: that proves the
        // caller holds the same keys.
        if offer.formTwo {
            s.formTwo = true
            s.heldForDecrypt = true
            engine.setHeld(true)
        }
        // The callee gathers no address before the member answers (CALLS-PLAN §2 step 6).
        s.enqueue { [self] in
            // The cryptors are made for the suite chosen when the offer was checked, the one the keys will be for.
            let sdp = try await engine.acceptOffer(sdp: offer.sdp, servers: offer.servers, suite: offer.suite)
            post(.gathering(seq: s.seq))
            // Not cancellable between the answer's return and the keys' hand-over: a hang-up at that instant must not leave the
            // keys with nobody to wipe them.
            try await uncancellable { [self] in
                let keys = try await signalling.answer(callId: offer.callId, sdp: sdp, suites: engine.suites)
                defer { keys.wipe() }
                try await give(keys, to: engine)
            }
            post(.answered(seq: s.seq))
        }
        applyRemote(s)
    }

    /// The keys into the engine, which wipes the copies it is given; the originals are wiped here whatever happens.
    func give(_ keys: MediaKeys, to engine: any MediaEngine) async throws {
        var send = keys.send
        var receive = keys.receive
        defer {
            Bytes.wipe(&send)
            Bytes.wipe(&receive)
            keys.wipe()
        }
        try await engine.setKeys(keys.suite, send: &send, receive: &receive)
    }

    func onAnswered(_ s: CallSession) {
        s.keysSet = true
        publish(s) // the answer is with the vault: keep-alives may go
        s.canSendIce = true
        timer(s, .connect, timings.connect)
        scheduleFlush(s, timings.iceBatch)
        startDiagnostics(s)
    }

    /// The other device's SDP is applied in the lane before this runs there: its candidates may follow.
    /// The remote description is in: candidates go straight to the engine from now on, and those that came after
    /// ``applyRemote(_:)`` took the waiting ones (while the offer or the answer was being applied) follow them.
    func onRemoteApplied(_ s: CallSession) {
        s.remoteApplied = true
        guard !s.pendingRemote.isEmpty, let engine = s.engine else { return }
        let late = s.pendingRemote
        s.pendingRemote.removeAll()
        s.enqueue { try await engine.addRemoteCandidates(late) }
    }

    func applyRemote(_ s: CallSession) {
        guard let engine = s.engine else { return }
        let waiting = s.pendingRemote
        s.pendingRemote.removeAll()
        s.enqueue { [self] in
            if !waiting.isEmpty { try await engine.addRemoteCandidates(waiting) }
            post(.remoteApplied(seq: s.seq))
        }
    }

    func hangUp(_ s: CallSession, _ reason: CallEnd) {
        // A local failure of a call that still rings (CallKit refused the answer, or timed out) is not the member's end and not a
        // decline: nothing is sent, and the call rings out as missed.
        if s.phase == .incoming, reason == .failed { return }
        // A failure is not the member's own end (``CallTransition/memberEnded``): a held glare offer still rings after it.
        s.memberEnded = reason != .failed
        if s.phase == .incoming {
            finish(s, reason == .hungUp ? .declinedHere : reason, CallReason.decline)
        } else if s.callId == nil || s.supersededBy != nil {
            finish(s, reason, nil)
        } else {
            // A failure is told to the other side as one (`call.end{failed}`), so that its call ends at once as failed.
            finish(s, reason, reason == .failed ? CallReason.failed : CallReason.hangup)
        }
    }
}
