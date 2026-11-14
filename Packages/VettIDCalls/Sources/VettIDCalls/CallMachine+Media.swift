import Foundation
import VettIDVault

// What the media engine says, the timers, and this device's candidates.
extension CallMachine {
    func onMedia(_ s: CallSession, _ e: MediaEvent) {
        switch e {
        case .localCandidate(let candidate):
            s.gathered += 1
            cancelTimer(s, .gather)
            s.pendingLocal.append(candidate)
            scheduleFlush(s, timings.iceBatch)
        case .gatheringDone:
            // Not an end: the stack can finish a round before the phone's network has reported its addresses, and the engine
            // keeps watching the networks, so a candidate may still come. The gather timer alone decides `noAddress`.
            break
        case .connection(let state): onConnection(s, state)
        case .cryptor(let direction, let state):
            if cryptorFailed(s, state) {
                finish(s, .notEncrypted, CallReason.failed)
            } else if direction == .receive, state == .ok, s.heldForDecrypt {
                // The first frame decrypted: the caller holds the same keys. The member's own mute still applies.
                s.heldForDecrypt = false
                cancelTimer(s, .decrypt)
                s.engine?.setHeld(false)
            }
        case .failed: finish(s, .failed, CallReason.failed)
        }
    }

    private func onConnection(_ s: CallSession, _ state: MediaConnection) {
        switch state {
        case .connected: if s.phase == .connecting || s.phase == .active { connected(s) }
        case .disconnected:
            if s.phase == .active {
                s.reconnecting = true
                publish(s)
            }
        case .failed: finish(s, s.activeSince != nil ? .connectionLost : .couldNotConnect, CallReason.failed)
        case .new, .connecting, .closed: break
        }
    }

    private func connected(_ s: CallSession) {
        cancelTimer(s, .connect)
        cancelTimer(s, .gather)
        if s.heldForDecrypt, s.timers[.decrypt] == nil { timer(s, .decrypt, timings.decrypt) }
        if s.activeSince == nil {
            s.activeSince = clock.now()
            if let at = s.answeredAtMs { diagnostics.answerToMediaMs = clock.elapsedMs() - at }
        }
        s.phase = .active
        s.reconnecting = false
        publish(s)
    }

    /// Frames that do not decrypt are never played, and the call does not go on without them. A missing key is a failure only
    /// once the keys have been set: before the answer the caller has none, and sends nothing.
    private func cryptorFailed(_ s: CallSession, _ state: CryptorState) -> Bool {
        switch state {
        case .decryptionFailed, .encryptionFailed, .internalError, .unknown: true
        case .missingKey: s.keysSet && s.phase == .active
        case .new, .ok: false
        }
    }

    // MARK: timers

    func timer(_ s: CallSession, _ kind: TimerKind, _ after: Duration) {
        s.timers.removeValue(forKey: kind)?.cancel()
        s.timers[kind] = s.launch { [self] in
            do { try await clock.sleep(for: after) } catch { return }
            post(.timer(seq: s.seq, kind))
        }
    }

    func cancelTimer(_ s: CallSession, _ kind: TimerKind) {
        s.timers.removeValue(forKey: kind)?.cancel()
    }

    // swiftlint:disable:next cyclomatic_complexity
    func onTimer(_ s: CallSession, _ kind: TimerKind) {
        // A lost glare waits for its winner: only its ring timer still counts (a timer already queued is stale).
        if s.supersededBy != nil && kind != .ringOut { return }
        switch kind {
        case .ringOut: ringOutOver(s)
        // Nothing is sent: the missed call is recorded by this member's vault when the caller's timeout arrives.
        case .ringIn: if s.phase == .incoming { finish(s, .missed, nil) }
        case .gather: if s.gathered == 0 { finish(s, .noAddress, CallReason.failed) }
        case .connect: if s.phase == .connecting { finish(s, .couldNotConnect, CallReason.failed) }
        case .decrypt: if s.heldForDecrypt { finish(s, .notEncrypted, CallReason.failed) }
        case .iceFlush: flush(s)
        }
    }

    private func ringOutOver(_ s: CallSession) {
        if s.supersededBy != nil {
            // The glare's winner never came: busy, as before C2; the vault already ended this call.
            finish(s, .busy, nil)
        } else if s.phase == .calling || s.phase == .ringing {
            finish(s, .noAnswer, CallReason.timeout)
        }
    }

    // MARK: this device's candidates

    func scheduleFlush(_ s: CallSession, _ after: Duration) {
        if s.flushScheduled || !s.canSendIce || s.pendingLocal.isEmpty { return }
        s.flushScheduled = true
        timer(s, .iceFlush, after)
    }

    /// Sends up to 16 candidates in one `call.ice`, then waits ``CallTimings/iceInterval`` before the next.
    private func flush(_ s: CallSession) {
        s.flushScheduled = false
        guard let callId = s.callId, s.canSendIce, !s.pendingLocal.isEmpty else { return }
        if s.iceMessages >= timings.maxIceMessages {
            s.pendingLocal.removeAll()
            return
        }
        let n = min(CallLimits.maxCandidates, s.pendingLocal.count)
        let batch = Array(s.pendingLocal.prefix(n))
        s.pendingLocal.removeFirst(n)
        s.iceMessages += 1
        // A candidate that could not be sent is lost, like any ephemeral message; the call's own timeouts cover it.
        s.launch { [signalling] in try? await signalling.ice(callId: callId, candidates: batch) }
        scheduleFlush(s, timings.iceInterval)
    }

    // MARK: diagnostics

    func startDiagnostics(_ s: CallSession) {
        guard let engine = s.engine else { return }
        s.launch { [self] in
            while !Task.isCancelled {
                do { try await clock.sleep(for: timings.diagnosticsEvery) } catch { return }
                guard let media = await engine.diagnostics() else { continue }
                diagnostics.media = media
                if let r = media.relayed { post(.path(seq: s.seq, relayed: r)) }
                // A second audio stream is RTP on an SSRC nobody announced, in the one section the call has: its frames go
                // through the same decryption and are dropped, and the call does not go on beside it.
                if media.inboundAudioStreams > 1 { post(.failed(seq: s.seq, .notEncrypted)) }
            }
        }
    }
}
