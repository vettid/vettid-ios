// The lock gate of the outbox: nothing but the lock (and a pending `call.end`) goes to a vault while a lock is pending
// (ANDROID-PLAN "Locking", "While pending"). Every deposit of an outbox entry, whoever starts the flush, asks the gate
// first, entry by entry.

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
}
