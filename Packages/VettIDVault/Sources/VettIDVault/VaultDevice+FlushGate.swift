// The lock gate of the outbox: nothing but the lock (and a pending `call.end`) goes to a vault while a lock is pending
// (ANDROID-PLAN "Locking", "While pending"). Every flush, whoever starts it, asks the gate before each entry, and so does
// every reply queued while a vault message is handled (``deliverQueued(_:since:)``, a rekey's `hs.resp`). Not gated here:
// the entry a ``send(_:body:id:)`` deposits itself, whose caller is gated by the manager (its one caller today is
// `call.end`, which passes anyway), and the requests, which the manager gates.

import VettIDCrypto

extension VaultDevice {
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

    /// Whether an outbox entry of [type] may be deposited now, by a flush asked for at [mark] (``stopMark``). Asked again
    /// before each entry, so that a lock that goes pending, or a stop, while a flush runs (or waits for another to end)
    /// holds what is left. [type] nil: a deposit that is not an entry (the flush's `credential.ack`). A `call.end`
    /// passes the gate: a hang-up still goes while a lock is pending. The gate is asked outside the device's locks; a
    /// stop while it is asked wins.
    func flushMayGo(_ type: String?, since mark: Int) async -> FlushGo {
        let (gate, live) = mem.withLock { (flushGate, stops == mark && !forgotten) }
        guard live else { return .end }
        if type == Self.typeCallEnd { return .go }
        if let gate, await !gate() { return .hold }
        return mem.withLock({ stops == mark && !forgotten }) ? .go : .end
    }

    /// Deposits an outbox entry queued outside a flush (a reply queued while a vault message was handled, the 12-day
    /// `hs.confirm`), only when the lock gate admits it: a lock pending, the handling's replies wait in the outbox for a
    /// flush after it. Held, the entry is no longer in flight (``enqueueLocked``), so that the flush sends it. False when
    /// held; a deposit's failure is thrown, as ``deliver(_:keepOnFailure:)``'s (an `hs.confirm`'s is handled by
    /// ``deliverConfirm(_:)``).
    @discardableResult
    func deliverQueued(_ e: OutboxEntry, since mark: Int? = nil) async throws -> Bool {
        let mark = mark ?? stopMark
        if await flushMayGo(e.type, since: mark) != .go {
            mem.withLock { _ = outboxInFlight.remove(e.id) }
            // A flush that ran while it was still marked (the lock ended meanwhile) left it alone: asked once more, and taken
            // back unless a flush has it now.
            guard await flushMayGo(e.type, since: mark) == .go,
                  mem.withLock({ st.outbox.contains { $0.id == e.id } && outboxInFlight.insert(e.id).inserted })
            else { return false }
        }
        if e.type == HsTypes.confirm {
            await deliverConfirm(e)
        } else {
            try await deliver(e)
        }
        return true
    }
}
