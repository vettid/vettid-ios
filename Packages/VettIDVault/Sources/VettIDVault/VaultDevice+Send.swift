import Foundation
import VettIDCrypto
import VettIDRelay

// Sending (VAULT-MESSAGING §8): sealing, the outbox, requests and their retries.
extension VaultDevice {
    /// Seals a message in the current epoch and deposits it through the outbox: a deposit that fails in transport goes out
    /// at a later flush. Only for messages that are no request and still mean the same later (``outboxTypes``: the
    /// standing tokens of §7.2); a request is deposited once from memory, and any other type is refused. Returns the inner
    /// id.
    @discardableResult
    public func send(_ type: String, body: [UInt8] = VaultJSON.empty, id: String? = nil) async throws -> String {
        guard Self.outboxTypes.contains(type) else { throw VaultStateError(message: "\(type): not kept in the outbox") }
        let entry = try await lock.withLock { try enqueueLocked(id: id, type: type, body: body, re: nil, status: nil, exp: nil) }
        // The deposit is made outside the device lock: a slow relay holds up this caller only.
        try await deliverInOrder(entry)
        return entry.id
    }

    /// Seals a message and hands it to the relay client **once**: never written to the outbox, so not sent again by a
    /// later flush or after a restart; a relay failure is the caller's. For messages that mean nothing later (a
    /// `vault.lock`, call signalling). Returns the inner id.
    @discardableResult
    public func sendOnce(_ type: String, body: [UInt8] = VaultJSON.empty, exp: Date? = nil) async throws -> String {
        try await sendOnceUnlocked(id: Ulid.new(now()), type: type, body: body, exp: exp)
    }

    /// Seals and persists under the device lock, then deposits outside it: a deposit that stalls holds up its own caller
    /// and not the answers to every other request (a relay call is bounded by its own timeout, ``RelayClient``).
    func sendOnceUnlocked(id: String, type: String, body: [UInt8], exp: Date?) async throws -> String {
        let (v, env) = try await lock.withLock { try sealOnceLocked(id: id, type: type, body: body, exp: exp) }
        try await depositToVault(v, env)
        return id
    }

    /// Seals [type] in the current epoch and saves the epoch's send counter; the caller deposits the envelope. Callers
    /// hold ``lock``.
    func sealOnceLocked(id: String, type: String, body: [UInt8], exp: Date?) throws -> (VaultRecord, [UInt8]) {
        let (v, env): (VaultRecord, [UInt8]) = try mem.withLock {
            if halted { throw Self.haltedError }
            if quieted { throw Self.quietedError }
            let v = try requireVault()
            guard let ep = keyring.current() else { throw VaultStateError(message: "no session with the vault") }
            guard !v.token.isEmpty else { throw VaultStateError(message: "no token for the vault") }
            return (v, try ep.seal(Inner(id: id, type: type, ts: now(), exp: exp, features: DeviceFeatures.all, body: body)))
        }
        try save() // the epoch's send counter
        return (v, env)
    }

    /// A request deposited once (``sendOnce(_:body:exp:)``) and awaited for [timeout]: no second deposit, unlike
    /// ``request(_:body:timeout:innerID:)``. [exp]: the vault drops the request after it (§5.3).
    public func requestOnce(
        _ type: String, body: [UInt8] = VaultJSON.empty, timeout: TimeInterval? = nil, exp: Date? = nil
    ) async throws -> VaultMessage {
        let id = Ulid.new(now())
        let d = OneShot<Inner>()
        mem.withLock { pending[id] = d }
        defer { mem.withLock { _ = pending.removeValue(forKey: id) } }
        // Held by the lock gate: nothing is sent (``requestMayGo(_:)``).
        guard await requestMayGo(type) else { throw OutboxHeld() }
        _ = try await countingSend(type) { try await sendOnceUnlocked(id: id, type: type, body: body, exp: exp) }
        guard let inner = await d.wait(timeout: timeout ?? cfg.requestTimeout(for: type)) else {
            try Task.checkCancellation()
            countingNoAnswer(type)
            throw VaultStateError(message: "\(type): no response")
        }
        return VaultMessage(inner: countingAnswer(type, inner))
    }

    /// ``requestOnce(_:body:timeout:exp:)``, returning the body of an ok response or throwing ``VaultOpError``.
    public func opOnce(
        _ type: String, body: [UInt8] = VaultJSON.empty, timeout: TimeInterval? = nil, exp: Date? = nil
    ) async throws -> [UInt8] {
        try Self.okBody(type, try await requestOnce(type, body: body, timeout: timeout, exp: exp))
    }

    /// Seals a message into the outbox and saves; the caller delivers it (``deliver(_:)``). Callers hold ``lock``.
    /// [save]: false while a message is being handled: the save that ends ``handleLocked(_:)`` stores the entry, and the
    /// deposit is made after it (``afterLock(_:)``), so the entry is stored before it goes out all the same.
    func enqueueLocked( // swiftlint:disable:this function_parameter_count
        id: String?, type: String, body: [UInt8], re: String?, status: String?, exp: Date?, save saves: Bool = true
    ) throws -> OutboxEntry {
        let entry: OutboxEntry = try mem.withLock {
            if halted { throw Self.haltedError }
            if quieted { throw Self.quietedError }
            let v = try requireVault()
            guard let ep = keyring.current() else { throw VaultStateError(message: "no session with the vault") }
            guard !v.token.isEmpty else { throw VaultStateError(message: "no token for the vault") }
            let t = now()
            let iid = id ?? Ulid.new(t)
            let env = try ep.seal(
                Inner(id: iid, type: type, ts: t, re: re, exp: exp, status: status, features: DeviceFeatures.all, body: body)
            )
            var e = OutboxEntry(
                id: iid, type: type, relayURL: v.relayURL, mailbox: v.mailbox, token: v.token, envelope: Base64s.encodeStd(env)
            )
            e.re = re
            st.outbox.append(e)
            outboxInFlight.insert(e.id)
            return e
        }
        do {
            if saves { try save() }
        } catch {
            // Nothing will deliver it: neither kept in flight nor left in the outbox.
            mem.withLock {
                outboxInFlight.remove(entry.id)
                st.outbox.removeAll { $0.id == entry.id }
            }
            throw error
        }
        return entry
    }

    /// Deposits an outbox entry; removes it once the relay accepted it, or on a terminal relay error (rethrown). A
    /// transport failure, `429 rate_limited`, 5xx and a stale or replayed signature keep it for the next flush.
    ///
    /// The entry is in flight meanwhile (``flushOutbox()`` leaves it alone). With [keepOnFailure] false a failure removes
    /// it, so that a request reported as failed is never deposited later.
    func deliver(_ e: OutboxEntry, keepOnFailure: Bool = true, since asked: Int? = nil) async throws {
        mem.withLock { _ = outboxInFlight.insert(e.id) }
        defer { mem.withLock { _ = outboxInFlight.remove(e.id) } }
        // A handshake's fin is counted before it is sent: a deposit that is cancelled or killed in flight may have reached the vault,
        // and a refusal of the next copy is then no evidence that the vault never took the first (chosen; not in the spec; by
        // analogy with VAULT-MESSAGING §8.6, 0.83.0). [priorAttempts] is the count before this one.
        var priorAttempts = e.attempts
        // As deposited: re-addressed when the token it had is spent (§8.6).
        var sent = e
        let mark = asked ?? stopMark // a stop since the caller asked for it wins
        do {
            try refuseSending()
            sent = try await awaitQuota(e)
            // The lock gate (``flushMayGo(_:since:)``), asked again here, after the waits above: before a fin is counted, so
            // that a held one is not, and right before the deposit.
            try await refuseWhileGated(e.type, since: mark)
            if e.type == Self.typeHsFin {
                guard let prior = try await countGatedFin(e, since: mark) else { return }
                priorAttempts = prior
            }
            #if DEBUG
            finSendHook?()
            #endif
            _ = try await relayFor(sent.relayURL).deposit(
                mailboxID: sent.mailbox, token: sent.token, payload: try Base64s.decodeStd(sent.envelope)
            )
            quotaAccepted(sent.mailbox)
            // The deposit is made: a failure to save what follows it is not a failure of the deposit. The entry is out of memory
            // at once and the next successful save drops it from the file; if the app ends before that, the file's copy is
            // deposited once more. That is harmless: every outbox type is durable and means the same when it arrives again
            // (``outboxTypes``: standing tokens, an `hs.fin`, `hs.confirm`, `device.features`), and the vault takes a repeated
            // inner id once (VAULT-MESSAGING §8.2). The same holds for the removal after a refusal for good below. Known residual:
            // the removals of `keepOnFailure: false` (a request reported as failed, such as a failed standing-token renewal that
            // ``enqueueLocked`` had stored) are not so: if their save is swallowed and the app ends before another save, a flush
            // after the restart deposits the entry that was meant never to go out.
            try? await withLockSaving { st.outbox.removeAll { $0.id == e.id && $0.envelope == e.envelope } }
        } catch let x as RelayError {
            // §8.6 (0.88.8): never sent again unchanged; held for the mailbox's backoff, or until another standing token.
            if x.code == RelayError.quotaExceeded { await quotaRefused(sent, x) }
            if keepOnFailure, !Self.isTerminal(x) {
                await noteAttempt(e)
                throw x
            }
            countRefusal(x, mailbox: sent.mailbox, token: sent.token)
            // Refused for good: the pairing cannot finish, and the flow that waits for it is told, but only for a fin that was
            // never sent before. A fin sent again may have reached the vault the first time, whose answer was lost: the refusal
            // is then silent, the entry is gone, and the deadline's collect decides.
            noteFinRefusal(e, x, prior: priorAttempts)
            try? await withLockSaving { st.outbox.removeAll { $0.id == e.id && $0.envelope == e.envelope } }
            throw x
        } catch let u as URLError {
            // A transport failure counts as an attempt too.
            if keepOnFailure {
                await noteAttempt(e)
            } else {
                try? await withLockSaving { st.outbox.removeAll { $0.id == e.id } }
            }
            throw u
        } catch {
            // Refused to send, cancelled, or an unreadable entry: a request reported as failed is not kept either.
            if !keepOnFailure { try? await withLockSaving { st.outbox.removeAll { $0.id == e.id } } }
            throw error
        }
    }

    /// Changes the state and saves it under the device lock. What follows a deposit is booked here, not beside it: a save made
    /// outside the lock could store another task's work that is half done (a message marked seen and not yet processed, a
    /// transfer pinned and not yet prepared), and a kill after it would lose that work.
    func withLockSaving(_ change: @Sendable () -> Void) async throws {
        try await lock.withLock {
            mem.withLock { change() }
            try save()
        }
    }

    /// A relay answer that trying again will not cure (it is kept for a later flush when it is not).
    static func isTerminal(_ x: RelayError) -> Bool { !(x.retryable || x.code == RelayError.quotaExceeded) }

    /// The outcome of counting a fin's deposit before it is made.
    enum FinCount {
        /// Counted and saved; the count before this deposit.
        case counted(prior: Int)
        /// The entry is gone, or the count could not be saved: the fin is not deposited.
        case skip
    }

    /// Counts a deposit of an `hs.fin` before it is made, and saves the count. The entry is looked up under the device lock: a
    /// flush that chose it before a new handshake removed it finds it gone.
    func countFinAttempt(_ e: OutboxEntry) async -> FinCount {
        #if DEBUG
        finCountHook?()
        #endif
        let counted: FinCount? = try? await lock.withLock {
            let prior: Int? = mem.withLock {
                guard let i = st.outbox.firstIndex(where: { $0.id == e.id }) else { return nil }
                st.outbox[i].attempts += 1
                return st.outbox[i].attempts - 1
            }
            guard let prior else { return .skip }
            do {
                try save()
            } catch {
                // Not counted: nothing is sent for it.
                mem.withLock { if let i = st.outbox.firstIndex(where: { $0.id == e.id }) { st.outbox[i].attempts -= 1 } }
                return .skip
            }
            return .counted(prior: prior)
        }
        return counted ?? .skip
    }

    /// Tells the flow that waits for a pairing that its fin was refused for good, if it was a fin never sent before.
    /// Only while the fin is still owed: a new handshake removes the fins and resets the failure in one step under ``mem``, and
    /// the check and the signal are one step under it too, so that no reset slips in between.
    private func noteFinRefusal(_ e: OutboxEntry, _ x: RelayError, prior: Int) {
        if e.type == Self.typeHsFin, Self.refusalIsDefinite(x, attempts: prior) { notifyFinFailed(ifOwed: e.id) }
    }

    /// Counts a failed deposit (a fin is counted before it is made: ``countFinAttempt(_:)``).
    private func noteAttempt(_ e: OutboxEntry) async {
        guard e.type != Self.typeHsFin else { return }
        try? await withLockSaving {
            if let i = st.outbox.firstIndex(where: { $0.id == e.id }) { st.outbox[i].attempts += 1 }
        }
    }

    /// A deposit to this device's vault under the vault's current token that the relay refused with `token_revoked`
    /// counts towards ``vaultRefusals`` (§7.4). A refusal by any other mailbox, or under another token, does not.
    func countRefusal(_ x: RelayError, mailbox: String, token: String) {
        let count: Int? = mem.withLock {
            guard x.code == RelayError.tokenRevoked, let v = st.vault, mailbox == v.mailbox, token == v.token else { return nil }
            refusals += 1
            return refusals
        }
        if let count { refusalBroadcast.emit(count) }
    }

    /// A deposit straight to the vault (handshake messages, outside the outbox), its refusal counted as deliver's.
    func depositToVault(_ v: VaultRecord, _ payload: [UInt8]) async throws {
        try refuseSending()
        do {
            _ = try await relayFor(v.relayURL).deposit(mailboxID: v.mailbox, token: v.token, payload: payload)
            quotaAccepted(v.mailbox) // the mailbox takes deposits again
        } catch let x as RelayError {
            countRefusal(x, mailbox: v.mailbox, token: v.token)
            throw x
        }
    }

    /// Removes undelivered messages of [type] from the outbox; returns how many. For a message that must not be
    /// delivered late (a `vault.lock` kept by an earlier app version would lock the vault after the next unlock).
    @discardableResult
    public func dropFromOutbox(_ type: String) async throws -> Int {
        try await lock.withLock {
            let n: Int = mem.withLock {
                let before = st.outbox.count
                st.outbox.removeAll { $0.type == type }
                return before - st.outbox.count
            }
            if n > 0 { try save() }
            return n
        }
    }

    /// The only types the outbox keeps (``send(_:body:id:)``): the standing tokens given to the vault and the refresh
    /// (§7.2), which mean the same when they arrive late, and the `hs.fin` of a handshake (§6.2), which is the same message
    /// whenever it arrives and is lost with its code if it does not (chosen; not in the spec: vettid-android's outbox types
    /// have no `hs.fin`). Anything else an earlier version left there is dropped at load.
    /// (0.87.0) `hs.confirm` and `device.features` too: durable, never answered, and the same whenever they arrive
    /// (VAULT-MESSAGING §6.3.1 "Responder": "queues `hs.confirm` … durable"; §10.2).
    /// Calls C1: `call.end` too (as vettid-android's outbox types have it): a hang-up that could not be delivered at once
    /// still reaches the vault and frees it (§10.10). A second `call.end` for the same call is harmless.
    static let outboxTypes: Set<String> = [
        "relay.token.issued", "relay.token.refresh", VaultDevice.typeHsFin, HsTypes.confirm, VaultDevice.typeDeviceFeatures,
        VaultDevice.typeCallEnd,
    ]

    /// Re-deposits what the outbox still holds (after a restart or a transport failure). The deposits are made outside the
    /// device lock, one flush at a time: a slow relay holds up the flush and nothing else. Each entry asks the lock gate
    /// first (``flushMayGo(_:since:)``): while a lock is pending only a `call.end` goes, and nothing goes after a ``stop()``
    /// that came since this flush was asked for, also when it waited for another flush to end.
    public func flushOutbox() async { await flushOutbox(since: stopMark) }

    /// ``flushOutbox()`` for a flush asked for at [mark] (``stopMark``): a stop since then ends it.
    func flushOutbox(since mark: Int) async {
        guard let entries = await takeFlushSlot() else { return }
        let nowMs = Self.ms(now())
        var ended = false
        for e in entries {
            // Not one that is being deposited just now (a renewal reported as failed must not go out later).
            // By id: an entry re-addressed meanwhile (§8.6) is still the same entry.
            let taken = mem.withLock { st.outbox.contains { $0.id == e.id } && outboxInFlight.insert(e.id).inserted }
            #if DEBUG
            flushSeen?(!taken)
            #endif
            guard taken else { continue }
            defer { mem.withLock { _ = outboxInFlight.remove(e.id) } }
            // A handshake's fin past its time is not sent again (chosen; not in the spec). That is no failure of the pairing: the
            // fin may have reached the vault, whose answer was lost, and the transfer's `device.paired` may wait in the mailbox
            // for the deadline's collect (VAULT-MESSAGING §11.14.10 rule 5). Only a first attempt's terminal refusal tells the flow.
            if e.type == Self.typeHsFin, let dropAfter = e.dropAfterMs, nowMs >= dropAfter {
                try? await withLockSaving { st.outbox.removeAll { $0.id == e.id } }
                continue
            }
            let go = await flushMayGo(e.type, since: mark)
            if go == .hold { continue }
            ended = go == .end
            if ended { break }
            if e.type == HsTypes.confirm {
                await deliverConfirm(e, since: mark) // its time follows a refusal for good
                continue
            }
            do {
                try await deliver(e, since: mark)
            } catch {} // (a fin refused for good is told to the flow, or not, by ``deliver``)
        }
        // The flush is over before the ack is tried: a vault that does not answer holds up the ack, not every flush.
        let waiters: OneShot<Bool>? = mem.withLock {
            flushing = false
            defer { flushEnded = nil }
            return flushEnded
        }
        waiters?.complete(true)
        // The ack is a deposit to the vault too: it asks the gate as an entry does.
        if !ended, await flushMayGo(nil, since: mark) == .go { await sendPendingAck() }
    }

    /// One flush at a time. A caller that comes while one runs waits for it and then runs its own, so that it always sees a
    /// flush that began after it asked (the credential settle wait relies on it). The outbox as the slot was taken, or nil
    /// when the waiter was cancelled.
    private func takeFlushSlot() async -> [OutboxEntry]? {
        while true {
            let (entries, running): ([OutboxEntry]?, OneShot<Bool>?) = mem.withLock {
                if flushing { return (nil, flushEnded) }
                flushing = true
                flushEnded = OneShot<Bool>()
                return (st.outbox, nil)
            }
            if let entries { return entries }
            // Woken when the running flush ends; a cancelled waiter returns at once. The timeout only bounds one wait: the
            // loop looks again.
            #if DEBUG
            flushWaits?()
            #endif
            _ = await running?.wait(timeout: 60)
            if Task.isCancelled { return nil }
        }
    }

    /// Whether a terminal refusal of an `hs.fin` shows that the vault never took it: the fin had not been sent before
    /// (`attempts` is 0) and the relay did not answer a retry of the same request.
    static func refusalIsDefinite(_ x: RelayError, attempts: Int) -> Bool { attempts == 0 && !x.afterRetry }

    /// Sends a request and waits for its response (§8.1). Without an answer within the request timeout, the same
    /// envelope id is re-sent at most twice (§8.6); the vault answers a duplicate from its response cache. [innerID]:
    /// for a request the member retries as the same request (§8.2). Each deposit is handed to the relay from memory, never
    /// through the outbox: a request whose deposit fails is reported as failed and is not sent later, nor after a restart.
    /// One that throws after a deposit may still have reached the vault: a caller that tries again does so with the same
    /// [innerID] (``newRequestID()``), never a fresh one, or the vault may act twice.
    /// [exp]: the vault drops the request after it, unanswered (§5.3).
    public func request(
        _ type: String, body: [UInt8] = VaultJSON.empty, timeout: TimeInterval? = nil, innerID: String? = nil, exp: Date? = nil
    ) async throws -> VaultMessage {
        try await request(type, body: body, timeout: timeout, innerID: innerID, exp: exp, retries: Self.appRetries)
    }

    /// ``request(_:body:timeout:innerID:exp:)`` with at most [retries] re-sends of the same id.
    func request( // swiftlint:disable:this function_parameter_count
        _ type: String, body: [UInt8], timeout: TimeInterval?, innerID: String?, exp: Date?, retries: Int
    ) async throws -> VaultMessage {
        let id = innerID ?? Ulid.new(now())
        let d = OneShot<Inner>()
        mem.withLock { pending[id] = d }
        defer { mem.withLock { _ = pending.removeValue(forKey: id) } }
        _ = try await countingSend(type) { try await sendOnceUnlocked(id: id, type: type, body: body, exp: exp) }
        for attempt in 0...retries {
            if let inner = await d.wait(timeout: timeout ?? cfg.requestTimeout(for: type)) {
                return VaultMessage(inner: countingAnswer(type, inner))
            }
            // Cancelled: not sent again (a copy already deposited may still reach the vault).
            try Task.checkCancellation()
            // Halted or quieted (its wait ended at once): not sent again either.
            try refuseSending()
            // No answer: the collection may have ended (the answer would then wait in the mailbox unread).
            ensureCollecting()
            // A re-send the lock gate holds is not sent: the request goes on waiting for the copy already out, as after a
            // re-send the relay could not take (``requestMayGo(_:)``).
            if attempt < retries, await requestMayGo(type) {
                _ = try await countingSend(type) { try await sendOnceUnlocked(id: id, type: type, body: body, exp: exp) }
            }
        }
        countingNoAnswer(type)
        throw VaultStateError(message: "\(type): no response")
    }

    /// ``request(_:body:timeout:innerID:)``, returning the body of an ok response or throwing ``VaultOpError``.
    public func op(
        _ type: String, body: [UInt8] = VaultJSON.empty, timeout: TimeInterval? = nil, innerID: String? = nil
    ) async throws -> [UInt8] {
        try Self.okBody(type, try await request(type, body: body, timeout: timeout, innerID: innerID))
    }

    static func okBody(_ type: String, _ r: VaultMessage) throws -> [UInt8] {
        guard r.inner.status == Inner.statusOK else {
            throw VaultOpError(
                type: type, code: r.inner.error?.code ?? "", detail: r.inner.error?.message ?? "",
                body: r.inner.body.isEmpty ? nil : r.inner.body
            )
        }
        return r.body
    }

    // MARK: - Events

    /// Waits for an event of [type] matching [match]; events that arrived earlier are searched first and the match is
    /// taken out of the inbox.
    public func awaitEvent(
        _ type: String, timeout: TimeInterval = awaitDefault, match: @escaping @Sendable (VaultMessage) -> Bool = { _ in true }
    ) async throws -> VaultMessage {
        try await awaitEvent(of: [type], timeout: timeout, match: match)
    }

    func awaitEvent(
        of types: Set<String>, timeout: TimeInterval, match: @escaping @Sendable (VaultMessage) -> Bool = { _ in true }
    ) async throws -> VaultMessage {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let (found, waiter): (VaultMessage?, OneShot<Bool>?) = try mem.withLock {
                if halted { throw Self.haltedError }
                if let i = inbox.firstIndex(where: { types.contains($0.type) && match($0) }) { return (inbox.remove(at: i), nil) }
                // A pairing that waits for device.paired cannot finish: its fin did not reach the vault.
                if types.contains("device.paired"), finFailed { throw PairingNotCompleted() }
                let w = OneShot<Bool>()
                inboxWaiters.append(w)
                return (nil, w)
            }
            if let found { return found }
            let left = deadline.timeIntervalSinceNow
            let woke = left > 0 ? await waiter?.wait(timeout: left) : nil
            guard woke != nil else {
                mem.withLock { inboxWaiters.removeAll { $0 === waiter } }
                try Task.checkCancellation()
                throw VaultStateError(message: "no \(types.sorted().joined(separator: "/")) within \(Int(timeout)) s", timedOut: true)
            }
        }
    }

    /// Drops the events kept for ``awaitEvent(_:timeout:match:)`` (the last ``inboxMax``): their bodies are vault content, which
    /// is not kept in memory once the vault is no longer open (IOS-PLAN §6.9). A wait that is under way is not ended.
    /// Events of a type a call has announced it will wait for (``keepingEvents(_:_:)``) are kept: its answer may arrive, and a
    /// hold begin, before its wait does. Once the last call that kept a type ended, the events of it that a clear spared and
    /// that nobody took are dropped.
    public func clearInbox() {
        mem.withLock {
            // The events spared are noted by their ids: only those go when the last call that kept their type ends.
            for m in inbox where memory.keptTypes[m.type, default: 0] > 0 { memory.sparedEvents.insert("\(m.type)/\(m.id)") }
            inbox.removeAll { memory.keptTypes[$0.type, default: 0] == 0 }
        }
    }

    /// Runs [body], during which ``clearInbox()`` keeps the events of [types]: for a call that sends a request and then waits
    /// for the event that answers it (the answer to the request may come before the wait begins).
    public func keepingEvents<T>(_ types: Set<String>, _ body: () async throws -> T) async rethrows -> T {
        mem.withLock { for t in types { memory.keptTypes[t, default: 0] += 1 } }
        defer {
            mem.withLock {
                for t in types { memory.keptTypes[t] = max(0, (memory.keptTypes[t] ?? 1) - 1) }
                // The events a clear spared for a type no call keeps any more, and that nobody took, go; those that arrived
                // after the clear are the inbox's as ever.
                let ended = types.filter { memory.keptTypes[$0, default: 0] == 0 }
                inbox.removeAll { ended.contains($0.type) && memory.sparedEvents.contains("\($0.type)/\($0.id)") }
                memory.sparedEvents = memory.sparedEvents.filter { !ended.contains(String($0.prefix { $0 != "/" })) }
            }
        }
        return try await body()
    }

    #if DEBUG
    /// How many calls keep the events of [type] (tests).
    func keptCount(_ type: String) -> Int { mem.withLock { memory.keptTypes[type, default: 0] } }

    /// The ids of the outbox's entries (tests).
    var outboxIDs: [String] { mem.withLock { st.outbox.map(\.id) } }

    /// How many events the inbox holds (tests).
    public var inboxCount: Int { mem.withLock { inbox.count } }
    #endif

    /// ``publish(_:)`` unless this event was published already: a message whose handling ended in an error is handled again
    /// when the relay delivers it again, and its event must not be shown twice (chosen; not in the spec: the last 512 ids).
    func publishOnce(_ m: VaultMessage) {
        let first: Bool = mem.withLock {
            guard memory.publishedIDs.insert(m.id).inserted else { return false }
            memory.publishedOrder.append(m.id)
            if memory.publishedOrder.count > 512 { memory.publishedIDs.remove(memory.publishedOrder.removeFirst()) }
            return true
        }
        if first { publish(m) }
    }

    /// Forgets what the inbox's bookkeeping remembers of events (the device is forgotten). Callers hold ``mem``.
    func forgetEventMemory() {
        memory.publishedOrder.removeAll()
        memory.publishedIDs.removeAll()
        memory.sparedEvents.removeAll()
    }

    func publish(_ m: VaultMessage) {
        let waiters: [OneShot<Bool>] = mem.withLock {
            inbox.append(m)
            if inbox.count > Self.inboxMax { inbox.removeFirst(inbox.count - Self.inboxMax) }
            defer { inboxWaiters.removeAll() }
            return inboxWaiters
        }
        for w in waiters { w.complete(true) }
        eventBroadcast.emit(m)
    }
}

// MARK: - Work after the device lock

extension VaultDevice {
    /// `hs.fin` (VAULT-MESSAGING §6.2).
    static let typeHsFin = "hs.fin"

    /// Runs [work] once the lock the caller holds is released: a deposit made while handling a message must not hold the
    /// lock across the network. The work belongs to the ``handle(_:)`` call that queued it (a task-local box), so that a
    /// concurrent handling never deposits another's entry before that one has saved. Callers hold ``lock``.
    ///
    /// Contract: only from code that ``handle(_:)`` runs. Outside it there is no box to take the work, and the work would be
    /// lost; that is a programming error, caught by an assertion in debug builds. A release build does not crash on it (the
    /// work is dropped, which a deposit owed in the outbox survives).
    /// [keep]: the work belongs to something a write of the handling's own stored (an `hs.fin`), so it is not dropped when the
    /// handling ends in an error (``AfterLockWork/drop()``).
    func afterLock(keep: Bool = false, _ work: @escaping @Sendable () async -> Void) {
        assert(AfterLockWork.current != nil, "afterLock outside handle(_:): the work would be lost")
        AfterLockWork.current?.add(work, keep: keep)
    }
}

/// The deposits one ``VaultDevice/handle(_:)`` call makes after it released the lock.
final class AfterLockWork: @unchecked Sendable {
    @TaskLocal static var current: AfterLockWork?
    private let lock = NSLock()
    private var work: [(keep: Bool, run: @Sendable () async -> Void)] = []

    func add(_ w: @escaping @Sendable () async -> Void, keep: Bool = false) { lock.withLock { work.append((keep, w)) } }

    func run() async {
        let all: [@Sendable () async -> Void] = lock.withLock {
            defer { work.removeAll() }
            return work.map(\.run)
        }
        for w in all { await w() }
    }

    /// Forgets the work queued by the handling without running it.
    func drop() { lock.withLock { work.removeAll { !$0.keep } } }
}

/// What the device remembers of events and of a handling in hand, between calls; all under ``VaultDevice``'s `mem`.
struct EventMemory {
    /// Event types calls wait for (``VaultDevice/keepingEvents(_:_:)``), and the events a clear spared for them.
    var keptTypes: [String: Int] = [:]
    var sparedEvents: Set<String> = []
    /// Outbox entries a handling stored by a write of its own (an `hs.fin`): kept if it fails.
    var keptOnError: Set<String> = []
    /// When `hs.confirm` was last queued again for a message under the confirmed epoch (VAULT-MESSAGING §6.3.1): at most
    /// once a minute. Memory only, as vettid-vault's `client`.
    var reconfirmedAt: Date?
    /// The ids of the events published (``VaultDevice/publishOnce(_:)``), in order and as a set.
    var publishedOrder: [String] = []
    var publishedIDs: Set<String> = []
}
