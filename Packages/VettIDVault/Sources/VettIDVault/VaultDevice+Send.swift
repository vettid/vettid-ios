import Foundation
import VettIDCrypto
import VettIDRelay

// Sending (VAULT-MESSAGING §8): sealing, the outbox, requests and their retries.
extension VaultDevice {
    /// Seals a message in the current epoch and deposits it (through the outbox). Returns the inner id.
    @discardableResult
    public func send(_ type: String, body: [UInt8] = VaultJSON.empty, id: String? = nil) async throws -> String {
        try await lock.withLock { try await sendLocked(id: id, type: type, body: body, re: nil, status: nil, exp: nil) }
    }

    /// Seals a message and hands it to the relay client **once**: never written to the outbox, so not sent again by a
    /// later flush or after a restart; a relay failure is the caller's. For messages that mean nothing later (a
    /// `vault.lock`, call signalling). Returns the inner id.
    @discardableResult
    public func sendOnce(_ type: String, body: [UInt8] = VaultJSON.empty, exp: Date? = nil) async throws -> String {
        try await lock.withLock { try await sendOnceLocked(id: Ulid.new(now()), type: type, body: body, exp: exp) }
    }

    func sendOnceLocked(id: String, type: String, body: [UInt8], exp: Date?) async throws -> String {
        let (v, env): (VaultRecord, [UInt8]) = try mem.withLock {
            let v = try requireVault()
            guard let ep = keyring.current() else { throw VaultStateError(message: "no session with the vault") }
            guard !v.token.isEmpty else { throw VaultStateError(message: "no token for the vault") }
            return (v, try ep.seal(Inner(id: id, type: type, ts: now(), exp: exp, body: body)))
        }
        try save() // the epoch's send counter
        try await depositToVault(v, env)
        return id
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
        _ = try await lock.withLock { try await sendOnceLocked(id: id, type: type, body: body, exp: exp) }
        guard let inner = await d.wait(timeout: timeout ?? cfg.requestTimeout) else {
            try Task.checkCancellation()
            throw VaultStateError(message: "\(type): no response")
        }
        return VaultMessage(inner: inner)
    }

    /// ``requestOnce(_:body:timeout:exp:)``, returning the body of an ok response or throwing ``VaultOpError``.
    public func opOnce(
        _ type: String, body: [UInt8] = VaultJSON.empty, timeout: TimeInterval? = nil, exp: Date? = nil
    ) async throws -> [UInt8] {
        try Self.okBody(type, try await requestOnce(type, body: body, timeout: timeout, exp: exp))
    }

    func sendLocked( // swiftlint:disable:this function_parameter_count
        id: String?, type: String, body: [UInt8], re: String?, status: String?, exp: Date?
    ) async throws -> String {
        let entry: OutboxEntry = try mem.withLock {
            let v = try requireVault()
            guard let ep = keyring.current() else { throw VaultStateError(message: "no session with the vault") }
            guard !v.token.isEmpty else { throw VaultStateError(message: "no token for the vault") }
            let t = now()
            let iid = id ?? Ulid.new(t)
            let env = try ep.seal(Inner(id: iid, type: type, ts: t, re: re, exp: exp, status: status, body: body))
            let e = OutboxEntry(
                id: iid, type: type, relayURL: v.relayURL, mailbox: v.mailbox, token: v.token, envelope: Base64s.encodeStd(env)
            )
            st.outbox.append(e)
            return e
        }
        try save()
        try await deliver(entry)
        return entry.id
    }

    /// Deposits an outbox entry; removes it once the relay accepted it, or on a terminal relay error (rethrown). A
    /// transport failure, `429 rate_limited`, 5xx and a stale or replayed signature keep it for the next flush.
    func deliver(_ e: OutboxEntry) async throws {
        do {
            _ = try await relayFor(e.relayURL).deposit(mailboxID: e.mailbox, token: e.token, payload: try Base64s.decodeStd(e.envelope))
            mem.withLock { st.outbox.removeAll { $0.id == e.id && $0.envelope == e.envelope } }
            try save()
        } catch let x as RelayError {
            // §8.6: a quota the recipient's mailbox ran out of is not cured by a fresh token; the deposit waits in the
            // outbox and goes out at a later flush (vettid-android drops it).
            if x.retryable || x.code == RelayError.quotaExceeded {
                mem.withLock {
                    if let i = st.outbox.firstIndex(of: e) { st.outbox[i].attempts += 1 }
                }
                try save()
                throw x
            }
            countRefusal(x, mailbox: e.mailbox, token: e.token)
            mem.withLock { st.outbox.removeAll { $0.id == e.id && $0.envelope == e.envelope } }
            try save()
            throw x
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
        do {
            _ = try await relayFor(v.relayURL).deposit(mailboxID: v.mailbox, token: v.token, payload: payload)
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

    /// Re-deposits what the outbox still holds (after a restart or a transport failure).
    public func flushOutbox() async {
        let entries = mem.withLock { st.outbox }
        for e in entries {
            try? await lock.withLock {
                if mem.withLock({ st.outbox.contains(e) }) { try await deliver(e) }
            }
        }
    }

    /// Sends a request and waits for its response (§8.1). Without an answer within the request timeout, the same
    /// envelope id is re-sent at most twice (§8.6); the vault answers a duplicate from its response cache. [innerID]:
    /// for a request the member retries as the same request (§8.2). A request that throws may still be delivered from
    /// the outbox later: a caller that tries again does so with the same [innerID] (``newRequestID()``), never a fresh
    /// one, or the vault may act twice.
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
        _ = try await lock.withLock { try await sendLocked(id: id, type: type, body: body, re: nil, status: nil, exp: exp) }
        for attempt in 0...retries {
            if let inner = await d.wait(timeout: timeout ?? cfg.requestTimeout) { return VaultMessage(inner: inner) }
            // Cancelled: not sent again (a copy already deposited may still reach the vault).
            try Task.checkCancellation()
            // No answer: the collection may have ended (the answer would then wait in the mailbox unread).
            ensureCollecting()
            if attempt < retries {
                _ = try await lock.withLock { try await sendLocked(id: id, type: type, body: body, re: nil, status: nil, exp: exp) }
            }
        }
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
            let (found, waiter): (VaultMessage?, OneShot<Bool>?) = mem.withLock {
                if let i = inbox.firstIndex(where: { types.contains($0.type) && match($0) }) { return (inbox.remove(at: i), nil) }
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
                throw VaultStateError(message: "no \(types.sorted().joined(separator: "/")) within \(Int(timeout)) s")
            }
        }
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
