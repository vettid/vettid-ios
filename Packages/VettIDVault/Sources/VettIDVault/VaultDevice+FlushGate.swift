// The lock gate of the outbox: nothing but the lock (and a pending `call.end`) goes to a vault while a lock is pending
// (ANDROID-PLAN "Locking", "While pending"). Every flush, whoever starts it, asks the gate before each entry, and so does
// every reply queued while a vault message is handled (``deliverQueued(_:since:)``), and every deposit right before it is
// made (``deliver(_:keepOnFailure:since:)``, a ``send(_:body:id:)``'s own entry included). A rekey's `hs.resp` is sent
// ungated, as a pending `call.end` passes (``handleRekey``). Not gated here: the requests, which the manager gates.

import VettIDCrypto

/// An outbox entry not deposited because the lock gate holds it, or the device was stopped since it was asked for: it stays in
/// the outbox for a later flush (one the gate admits), unless its deposit was one never kept for later (a renewal of the
/// standing token during a move, ``VaultDevice/renewStandingToken()``), which is then gone, as after any failure.
public struct OutboxHeld: Error, Equatable, Sendable, CustomStringConvertible {
    public var description: String { "held by the lock gate" }
}

extension VaultDevice {
    /// A fin's count before its deposit (``countFinAttempt(_:)``), and the gate asked again after it: the count before this
    /// deposit, or nil when the fin is not to be deposited (gone, as when a new handshake replaced it, or the count could not
    /// be saved: a fin still owed waits for the next flush, so that "saved before sent" holds). Held by the gate after the
    /// count, it is taken back, since this copy never went out, and ``OutboxHeld`` is thrown.
    func countGatedFin(_ e: OutboxEntry, since mark: Int) async throws -> Int? {
        guard case .counted(let prior) = await countFinAttempt(e) else { return nil }
        do {
            try await refuseWhileGated(e.type, since: mark)
        } catch {
            try? await withLockSaving {
                if let i = st.outbox.firstIndex(where: { $0.id == e.id }) { st.outbox[i].attempts = prior }
            }
            throw error
        }
        return prior
    }

    /// Throws ``OutboxHeld`` unless an entry of [type] may be deposited now (``flushMayGo(_:since:)``).
    func refuseWhileGated(_ type: String, since mark: Int) async throws {
        if await flushMayGo(type, since: mark) != .go { throw OutboxHeld() }
    }

    /// What a flush may do with its next entry (``flushMayGo(_:since:)``).
    enum FlushGo {
        /// Deposit it.
        case go
        /// Leave it in the outbox: the gate is shut to it. A `call.end` after it may still go.
        case hold
        /// End the flush: the device was stopped or forgotten since the flush was asked for.
        case end
    }

    /// The count of ``stop()``s so far: a flush asked for before a stop deposits nothing after it.
    var stopMark: Int { mem.withLock { stops } }

    /// The mark of a deposit no ``stop()`` holds: a reply queued while a vault message was handled
    /// (``deliverQueued(_:since:)``). The handling ran, and its reply goes, as before the gate; only the gate and a forget
    /// hold it. A pairing's `hs.fin` queued just before the app goes to the background must not wait for the next flush.
    static let noStopMark = Int.min

    /// Whether an outbox entry of [type] may be deposited now, by a flush asked for at [mark] (``stopMark``; ``noStopMark``: no stop ends it). Asked again
    /// before each entry, so that a lock that goes pending, or a stop, while a flush runs (or waits for another to end)
    /// holds what is left. [type] nil: a deposit that is not an entry (the flush's `credential.ack`). A `call.end`
    /// passes the gate: a hang-up still goes while a lock is pending. The gate is asked outside the device's locks; a
    /// stop while it is asked wins.
    func flushMayGo(_ type: String?, since mark: Int) async -> FlushGo {
        let (gate, live) = mem.withLock { (flushGate, (mark == Self.noStopMark || stops == mark) && !forgotten) }
        guard live else { return .end }
        if type == Self.typeCallEnd { return .go }
        if let gate, await !gate() { return .hold }
        return mem.withLock({ (mark == Self.noStopMark || stops == mark) && !forgotten }) ? .go : .end
    }

    /// Deposits an outbox entry queued outside a flush (a reply queued while a vault message was handled, the 12-day
    /// `hs.confirm`), only when the lock gate admits it: a lock pending, the handling's replies wait in the outbox for a
    /// flush after it. Held, the entry is no longer in flight (``enqueueLocked``), so that the flush sends it. False when
    /// held; a deposit's failure is thrown, as ``deliver(_:keepOnFailure:since:)``'s (an `hs.confirm`'s is handled by
    /// ``deliverConfirm(_:since:)``). [mark]: a flush's stop mark (the 12-day `hs.confirm` of a start); nil for a
    /// handling's reply, which no stop holds (``noStopMark``).
    @discardableResult
    func deliverQueued(_ e: OutboxEntry, since mark: Int? = nil) async throws -> Bool {
        let mark = mark ?? Self.noStopMark
        if await flushMayGo(e.type, since: mark) != .go {
            mem.withLock { _ = outboxInFlight.remove(e.id) }
            // A flush that ran while it was still marked (the lock ended meanwhile) left it alone: asked once more, and taken
            // back unless a flush has it now.
            guard await flushMayGo(e.type, since: mark) == .go,
                  mem.withLock({ st.outbox.contains { $0.id == e.id } && outboxInFlight.insert(e.id).inserted })
            else { return false }
        }
        if e.type == HsTypes.confirm { return await deliverConfirm(e, since: mark) }
        do {
            try await deliver(e, since: mark)
        } catch is OutboxHeld {
            return false // held at the deposit itself: in the outbox, and no longer in flight (``deliver``)
        }
        return true
    }
}
