import Foundation
import VettIDCrypto
import VettIDVault

/// ``CallSignalling`` on the vault. **This is where a call's checks are asked for**: ``CallMachine`` trusts what comes out of
/// ``events()``, so nothing reaches it that has not been through ``CallGateway/incoming(_:pinnedFingerprint:suites:)`` or
/// ``CallGateway/accept(_:event:)`` (the signature, identity, SDP and suite checks of `VaultApi`). The rules, each one line below:
///
/// 1. An offer rings only if its connection is one the app knows, and it verifies against **that connection's identity as the
///    app shows it** (``pinned``) and against the suites this device can do. Otherwise it is dropped: no ring, nothing sent
///    (``refused`` counts it).
/// 2. An answer is used only if it is for a call this device placed and verifies against the identity of the connection **that
///    call was placed to**. Otherwise the call is over: ``SignalEvent/answerRejected(callId:)``.
/// 3. Key material is this object's to destroy: an `OutgoingCall`'s ephemeral key when its call ends in any way, `CallKeys` as
///    soon as their copies are on their way to the engine.
/// 4. **Nothing that goes wrong with one event ends the listening.** Whatever a check or the vault client throws (not only a
///    failed check: a locked vault, a relay error), the event is refused and counted, and the next one is handled.
///
/// The only implementation of ``CallSignalling`` outside tests.
@MainActor
package final class VaultCallSignalling: CallSignalling {
    private let gateway: any CallGateway
    /// The fingerprint of the connection's pinned identity key, as its details show it; nil for no such connection.
    private let pinned: @MainActor (_ connectionId: String) async -> String?
    /// What this device's media engines can do (``MediaEngineFactory/suites``).
    private let suites: [MediaSuite]
    /// Reads the app's connections again. The list is in memory and is filled after the vault opens: the offer that was waiting
    /// in the mailbox at unlock can be handled before it. So a connection that is not found is looked for once more after this.
    private let refreshConnections: @MainActor () async -> Void
    /// Whether an offer may ring now: the vault is open on this phone (asked for every offer; it may wait a moment for an unlock
    /// that is just completing, and says false if none comes). The vault's events are listened to from before the unlock is
    /// complete, so an offer can arrive in the moments before the app shows the open vault: it rings only once it does, never
    /// over the unlock screen.
    private let mayRing: @MainActor () async -> Bool
    private let clock: any CallClock

    private var placed: [(callId: String, call: OutgoingCall)] = []
    private var ringingCalls: [(callId: String, call: IncomingCall)] = []
    /// Calls being started whose id is not known here yet (``start(connectionId:sdp:suites:)`` has not returned).
    private var starting = 0
    /// Answers that arrived for no known call while one was being started: looked at again when it is.
    private var heldAnswers: [(callId: String, message: VaultMessage)] = []
    private var sink: AsyncThrowingStream<SignalEvent, Error>.Continuation?
    private var late: [SignalEvent] = []

    /// Offers and answers that did not pass their checks since the process started (diagnostics; no detail is kept).
    package private(set) var refused = 0
    /// Of those, the ones refused because something failed (the vault client, the relay), not because a check did.
    package private(set) var errors = 0

    /// One call at a time: anything beyond a few is left over from calls that ended without a word.
    private static let maxKept = 4
    /// What reading the connections again may take inside the ordered flow of events.
    private static let refreshTimeout = Duration.seconds(3)

    package init(
        gateway: any CallGateway, pinned: @escaping @MainActor (String) async -> String?, suites: [MediaSuite],
        refreshConnections: @escaping @MainActor () async -> Void = {}, mayRing: @escaping @MainActor () async -> Bool = { true },
        clock: any CallClock = SystemCallClock()
    ) {
        self.gateway = gateway
        self.pinned = pinned
        self.suites = suites
        self.refreshConnections = refreshConnections
        self.mayRing = mayRing
        self.clock = clock
    }

    package func events() -> AsyncThrowingStream<SignalEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: SignalEvent.self)
        sink = continuation
        let held = late
        late.removeAll()
        for e in held { continuation.yield(e) }
        let source = gateway.events()
        let pump = Task { [weak self] in
            for await e in source {
                guard let self, let mapped = await map(e) else { continue }
                continuation.yield(mapped)
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in pump.cancel() }
        return stream
    }

    private func map(_ e: CallEvent) async -> SignalEvent? {
        switch e {
        case .offer: return await offer(e)
        case .answer: return await answer(e)
        case .ringing(let callId): return .ringing(callId: callId)
        case .ice(let i): return .ice(callId: i.callId, candidates: i.candidates)
        case .ended(let ended):
            forget(ended.callId)
            return .end(callId: ended.callId, reason: ended.reason, supersededBy: ended.supersededBy)
        }
    }

    /// An event for the listener, outside the flow of the gateway's events (an answer that overtook `call.start`).
    private func emitLate(_ e: SignalEvent) {
        if let sink { sink.yield(e) } else { late.append(e) }
    }

    /// The connection's identity, looked for a second time after the list has been read again (see ``refreshConnections``). The
    /// reading is given ``refreshTimeout`` and no more: the events are handled in order, and a slow vault must not hold the next
    /// ones (a hang-up, the candidates) behind one unknown connection.
    private func identity(_ connectionId: String) async throws -> String {
        if let p = await pinned(connectionId) { return p }
        await within(Self.refreshTimeout, refreshConnections)
        guard let p = await pinned(connectionId) else { throw CallMessageError("no such connection") }
        return p
    }

    /// Runs [body] for at most [limit]: whichever of the two ends first lets this go on, and the other is cancelled.
    private func within(_ limit: Duration, _ body: @escaping @MainActor () async -> Void) async {
        let (done, finished) = AsyncStream.makeStream(of: Void.self)
        let work = Task {
            await body()
            finished.yield()
        }
        let timeout = Task { [clock] in
            try? await clock.sleep(for: limit)
            finished.yield()
        }
        var it = done.makeAsyncIterator()
        _ = await it.next()
        timeout.cancel()
        work.cancel()
    }

    /// Rule 4: [e] is counted, and whether it was a check that refused or something that failed.
    private func count(_ e: Error) {
        refused += 1
        if !(e is CallMessageError) { errors += 1 }
    }

    /// Rule 1.
    private func offer(_ e: CallEvent) async -> SignalEvent? {
        guard case .offer(let message) = e else { return nil }
        let call: IncomingCall
        do {
            // No connection named, or the vault not open on this phone: no ring.
            guard let connectionId = e.connectionId, await mayRing() else { throw CallMessageError("not an offer to ring for") }
            call = try await gateway.incoming(message, pinnedFingerprint: try await identity(connectionId), suites: suites)
        } catch is CancellationError {
            return nil
        } catch {
            count(error)
            return nil
        }
        ringingCalls.append((call.callId, call))
        while ringingCalls.count > Self.maxKept { ringingCalls.removeFirst() }
        return .offer(CallOffer(
            callId: call.callId, connectionId: call.connectionId, sdp: call.sdp, exp: call.exp, ringFor: .rounded(seconds: call.ringFor),
            servers: call.ice.servers, suite: call.negotiated.chosen
        ))
    }

    /// Rule 2.
    private func answer(_ e: CallEvent) async -> SignalEvent? {
        guard case .answer(let message) = e, let callId = e.answerCallId else { return nil }
        return await check(answer: message, callId: callId)
    }

    private func check(answer message: VaultMessage, callId: String) async -> SignalEvent? {
        // Taken out first: one answer is checked per call, and a duplicate finds nothing (it cannot end a call another answer
        // was accepted for).
        guard let call = take(placed: callId) else {
            // The vault can pass the answer on before its answer to `call.start` has been read here.
            if starting > 0, heldAnswers.count < Self.maxKept { heldAnswers.append((callId, message)) }
            return nil
        }
        defer {
            // Answered or refused, the ephemeral key has done its work (rule 3).
            call.destroy()
        }
        do {
            // The connection must still be one the app knows; the answer is checked against the identity the call was placed to.
            _ = try await identity(call.connectionId)
            let accepted = try await gateway.accept(call, event: message)
            return .answer(CallAnswer(callId: accepted.callId, sdp: accepted.sdp, keys: try handOver(accepted.keys)))
        } catch is CancellationError {
            return nil
        } catch {
            count(error)
            return .answerRejected(callId: call.callId)
        }
    }

    private func take(placed callId: String) -> OutgoingCall? {
        guard let i = placed.firstIndex(where: { $0.callId == callId }) else { return nil }
        return placed.remove(at: i).call
    }

    /// Rule 3: copies for the engine (which wipes them), and the originals destroyed here.
    private func handOver(_ keys: CallKeys) throws -> MediaKeys {
        defer { keys.destroy() }
        return MediaKeys(suite: keys.suite, send: try keys.send(), receive: try keys.receive())
    }

    private func forget(_ callId: String) {
        take(placed: callId)?.destroy()
        ringingCalls.removeAll { $0.callId == callId }
    }

    package func start(connectionId: String, sdp: String, suites: [MediaSuite]) async throws -> PlacedCall {
        starting += 1
        let call: OutgoingCall
        do {
            let fingerprint: String
            do {
                fingerprint = try await identity(connectionId)
            } catch is CallMessageError {
                // A connection the app does not know: no call is placed.
                throw CallRefusedError(code: "not_found")
            }
            call = try await gateway.start(connectionId: connectionId, pinnedFingerprint: fingerprint, sdp: sdp, suites: suites)
            placed.append((call.callId, call))
            while placed.count > Self.maxKept { placed.removeFirst().call.destroy() }
        } catch let e as VaultOpError {
            endStart()
            throw CallRefusedError(code: e.code)
        } catch is CallMessageError {
            endStart()
            throw CallSecurityError("call.start")
        } catch {
            endStart()
            throw error
        }
        let held = endStart()
        // An answer that overtook the vault's answer to `call.start`: checked now, as any answer.
        for h in held where h.callId == call.callId {
            if let a = await check(answer: h.message, callId: h.callId) { emitLate(a) }
        }
        return PlacedCall(callId: call.callId, exp: call.exp, servers: call.ice.servers)
    }

    @discardableResult
    private func endStart() -> [(callId: String, message: VaultMessage)] {
        starting -= 1
        let held = heldAnswers
        if starting == 0 { heldAnswers.removeAll() }
        return held
    }

    package func answer(callId: String, sdp: String, suites: [MediaSuite]) async throws -> MediaKeys {
        guard let i = ringingCalls.firstIndex(where: { $0.callId == callId }) else {
            throw CallSecurityError("no verified offer for this call")
        }
        let call = ringingCalls.remove(at: i).call
        // The suite was fixed when the offer was checked; an engine that cannot do it must not answer.
        guard suites.contains(call.negotiated.chosen) else { throw CallSecurityError("the engine cannot do the negotiated suite") }
        do {
            return try handOver(try await gateway.answer(call, sdp: sdp))
        } catch is CallMessageError {
            throw CallSecurityError("call.answer")
        }
    }

    package func ringing(callId: String) async throws { try await gateway.ringing(callId) }

    package func ice(callId: String, candidates: [CallCandidate]) async throws { try await gateway.ice(callId, candidates) }

    package func end(callId: String, reason: String) async throws {
        forget(callId)
        try await gateway.end(callId, reason: reason)
    }
}
