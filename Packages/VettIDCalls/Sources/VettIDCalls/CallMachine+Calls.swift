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
            // Not cancelled by a hang-up: once `call.start` may have left, its answer is needed to end the call.
            try await uncancellable { [self] in
                do {
                    let placed = try await signalling.start(connectionId: connectionId, sdp: sdp, suites: offered)
                    post(.placed(seq: s.seq, placed, atMs: clock.elapsedMs()))
                } catch let e as CallRefusedError {
                    post(.failed(seq: s.seq, Self.refusal(e.code)))
                }
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

    func onPlaced(_ s: CallSession?, seq: Int, call: PlacedCall, atMs: Int64) {
        guard let s, s.seq == seq else {
            // The member hung up while the vault was answering: the call exists there, so it is ended there.
            if let i = abandoned.firstIndex(of: seq) {
                abandoned.remove(at: i)
                sendEnd(call.callId, CallReason.hangup)
            }
            return
        }
        let early = s.early
        s.early.removeAll()
        s.callId = call.callId
        // An offer held before the call had its id, that turns out to carry this very id, is no other call.
        if s.glareOffer?.callId == call.callId { s.glareOffer = nil }
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
            } else if case .answer(let a) = e {
                a.keys.wipe()
            }
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
        s.memberEnded = true
        if s.phase == .incoming {
            finish(s, reason == .hungUp ? .declinedHere : reason, CallReason.decline)
        } else if s.callId == nil || s.supersededBy != nil {
            finish(s, reason, nil)
        } else {
            finish(s, reason, CallReason.hangup)
        }
    }
}
