import Foundation
import VettIDCrypto
import VettIDKeys

/// What the earlier-secret step did (VAULT-MESSAGING §11.14.1 rule 7, IOS-PLAN §6.3 item 5).
public enum EarlierSecretOutcome<Answer> {
    /// A replaced record is current again. [opened] (`ok`): the caller writes the History entry and asks for a new phone
    /// secret (`vault.secret.renew`) at once; otherwise the answer was `transfer_incomplete`.
    case restored(Answer, opened: Bool)
    /// Nothing moved: no replaced record, every one answered `device_secret`, or an answer that moves nothing (`bad_pin`,
    /// a refusal decided before the secret check). [last] is the last answer, if any request was sent.
    case unchanged(last: Answer?)
}

extension PhoneSecrets {
    // MARK: - Changes of the phone secret (pin.change, vault.secret.renew)

    /// The next epoch's secret for the change [operation] (its request id), its record written as a candidate **before**
    /// this returns. A retry of the same operation reuses its candidate. While four candidates are unconfirmed a new
    /// operation is refused before anything is made or sent (``FailureKind/unconfirmedChanges``), and no candidate is
    /// dropped. The caller wipes the secret after building the request.
    ///
    /// From here until ``endChange(operation:)`` (or its answer) the operation is **in flight**: an unlock's `ok` with
    /// the current record leaves its candidate alone, since the vault may store it after that unlock. At most one change
    /// is in flight per records file (chosen; not in the spec): a new operation while another is in flight is refused
    /// before anything is made or sent (``FailureKind/busy``), so the vault can never store two changes whose answers
    /// then arrive in the other order. A retry of the same operation is allowed. In memory only: after a process restart
    /// nothing is in flight.
    /// Internal: the only public entry is ``change(isolation:operation:unresolved:send:confirmed:)``, which always frees
    /// the slot. [unresolved] is stored in the same atomic write as the candidate (VAULT-MESSAGING §11.14.9 "A lost
    /// answer" step 1); so is [exp], the `exp` of the request about to carry it (a renew's; a retry's later `exp` replaces
    /// an earlier one).
    func beginChange(
        operation: String, unresolved: UnresolvedChange? = nil, exp: Date? = nil, sent: PhoneRecords.SentRequest? = nil
    ) throws -> [UInt8] {
        let reserved = ChangesInFlight.reserve(store.url, operation)
        guard reserved != .refused else { throw VaultFailure(.busy, code: "change_in_flight") }
        do {
            let next = try prepareChange(operation: operation, unresolved: unresolved, exp: exp, sent: sent)
            // A change or a renew is about to go out: a PIN taken before it may no longer be the one the vault expects.
            pinMoved()
            return next
        } catch {
            // A retry that fails leaves its earlier send in flight; a new operation that fails frees the slot.
            if reserved == .reserved { ChangesInFlight.end(store.url, operation) }
            throw error
        }
    }

    private func prepareChange(
        operation: String, unresolved: UnresolvedChange?, exp: Date?, sent: PhoneRecords.SentRequest?
    ) throws -> [UInt8] {
        try store.exclusive {
            var recs = try readRecords()
            guard let cur = recs.current else { throw Self.lost }
            try Self.refuseOther(recs, unresolved)
            if let i = recs.candidates.firstIndex(where: { $0.operation == operation }) {
                return try reuse(&recs, candidate: i, unresolved: unresolved, exp: exp, sent: sent)
            }
            guard recs.candidates.count < Self.maxCandidates else {
                throw VaultFailure(.unconfirmedChanges, code: "unconfirmed_changes")
            }
            var made = try newEpoch(try phoneKey(cur), keyVault: cur.record.keyVault, epoch: cur.record.epoch + 1, creating: false)
            let entry = PhoneRecords.Entry(keyID: cur.keyID, record: made.record)
            recs.candidates.append(PhoneRecords.Candidate(operation: operation, entry: entry, exp: exp, sent: sent))
            if let unresolved { recs.unresolved = unresolved }
            do {
                try write(recs)
            } catch {
                Bytes.wipe(&made.secret)
                throw error
            }
            return made.secret
        }
    }

    /// A retry: candidate [i]'s secret, with [unresolved] and a later [exp] written first. Callers hold the store.
    private func reuse(
        _ recs: inout PhoneRecords, candidate i: Int, unresolved: UnresolvedChange?, exp: Date?, sent: PhoneRecords.SentRequest?
    ) throws -> [UInt8] {
        var s = try secret(of: recs.candidates[i].entry)
        let c = recs.candidates[i]
        let later = exp.map { e in c.exp.map { $0 < e } ?? true } ?? false
        guard unresolved != nil || later || sent != nil else { return s }
        if let unresolved { recs.unresolved = unresolved }
        recs.candidates[i] = PhoneRecords.Candidate(
            operation: c.operation, entry: c.entry, exp: later ? exp : c.exp, sent: sent ?? c.sent
        )
        do {
            try write(recs)
        } catch {
            Bytes.wipe(&s)
            throw error
        }
        return s
    }

    /// Whether any change is on its way now (in this process).
    public var anyInFlight: Bool { !ChangesInFlight.current(store.url).isEmpty }

    /// Whether the change [operation] is on its way now (in this process).
    public func inFlight(operation: String) -> Bool { ChangesInFlight.current(store.url).contains(operation) }

    /// The change [operation] is no longer in flight: its request failed before sending, got no answer, or was
    /// abandoned. Its candidate stays a candidate.
    func endChange(operation: String) { ChangesInFlight.end(store.url, operation) }

    /// The change [operation]'s answer arrived (`pin.change` with `epoch_advanced: true`, `vault.secret.renew` with its
    /// result): its record becomes current, and the record it replaces and every other candidate become replaced
    /// records. The vault's own answer also proves a record that only an unlock's `ok` made a replaced record, so it is
    /// found there too; never one that a later confirmed record displaced (a late or repeated answer of an older change).
    /// False when no record can be made current that way. [clearing]: the unresolved change of that id is cleared in the
    /// same write.
    @discardableResult
    public func confirmChange(operation: String, clearing: String? = nil) throws -> Bool {
        try store.exclusive {
            defer { ChangesInFlight.end(store.url, operation) }
            var recs = try readRecords()
            // Only a marker that matched is cleared, and only then is anything written without a record made current
            // (never an empty file after a wipe).
            let cleared = clearing != nil && recs.unresolved?.id == clearing
            if cleared { recs.unresolved = nil }
            if let i = recs.candidates.firstIndex(where: { $0.operation == operation }) {
                promote(&recs, candidate: i)
            } else if let i = recs.replaced.lastIndex(where: { $0.operation == operation && $0.byUnlock }) {
                let back = recs.replaced.remove(at: i)
                recs.candidates.insert(PhoneRecords.Candidate(operation: operation, entry: back.entry), at: 0)
                promote(&recs, candidate: 0)
            } else {
                if cleared {
                    try write(recs)
                    pinMoved()
                }
                return false
            }
            try write(recs)
            pinMoved()
            return true
        }
    }

    // MARK: - The unresolved change (§11.14.9 "A lost answer")

    /// The change of PIN or password sent and not yet decided, if any.
    public func unresolvedChange() throws -> UnresolvedChange? { try store.exclusive { try readRecords().unresolved } }

    /// Stores [change] as the unresolved change (a password change, which makes no record), before its request is sent.
    /// Refused while another change is unresolved (VAULT-MESSAGING 0.45.0 §11.14.9 step 1: two changes started together
    /// never overwrite each other's marker).
    public func setUnresolved(_ change: UnresolvedChange) throws {
        try store.exclusive {
            var recs = try readRecords()
            try Self.refuseOther(recs, change)
            recs.unresolved = change
            try write(recs)
            pinMoved()
        }
    }

    /// Throws when [recs] hold an unresolved change other than [change].
    static func refuseOther(_ recs: PhoneRecords, _ change: UnresolvedChange?) throws {
        guard let change, let other = recs.unresolved, other.id != change.id else { return }
        throw VaultFailure(.changeUnresolved, code: "change_unresolved")
    }

    /// The check of [marker] ended without a decision (§11.14.9 step 3): the marker is cleared and, after a PIN change,
    /// its PIN is uncertain until an unlock settles it, in one write.
    public func endUnresolved(_ marker: UnresolvedChange) throws {
        try store.exclusive {
            var recs = try readRecords()
            guard recs.unresolved?.id == marker.id else { return }
            recs.unresolved = nil
            if marker.type == .pin, let op = marker.operation { recs.uncertainPinOperation = op }
            try write(recs)
            pinMoved()
        }
    }

    /// VAULT-MESSAGING 0.51.1; IOS-PLAN 0.1.13: the vault answered `forbidden` (another phone is the holder) while
    /// [marker] was being decided, a definite outcome. The marker goes with, for a PIN change, its candidate record and
    /// an uncertain PIN of it (the PIN is not left uncertain), in one write; the candidate's phone key is deleted
    /// afterwards.
    public func abandonUnresolved(_ marker: UnresolvedChange) throws {
        try store.exclusive {
            var recs = try readRecords()
            guard recs.unresolved?.id == marker.id else { return }
            recs.unresolved = nil
            var dropped: [PhoneRecords.Entry] = []
            if let op = marker.operation {
                dropped = recs.candidates.filter { $0.operation == op }.map(\.entry)
                recs.candidates.removeAll { $0.operation == op }
                if recs.uncertainPinOperation == op { recs.uncertainPinOperation = nil }
            }
            try write(recs)
            for e in dropped { try? keys.delete(keyVault: e.record.keyVault, keyID: e.keyID) }
            pinMoved()
        }
    }

    /// VAULT-MESSAGING 0.51.1; IOS-PLAN 0.1.13: a renew being decided was answered `forbidden`: the candidates of
    /// [operations] go, and their phone keys.
    public func dropCandidates(operations: Set<String>) throws {
        try store.exclusive {
            var recs = try readRecords()
            let dropped = recs.candidates.filter { operations.contains($0.operation) }.map(\.entry)
            guard !dropped.isEmpty else { return }
            recs.candidates.removeAll { operations.contains($0.operation) }
            if let op = recs.uncertainPinOperation, operations.contains(op) { recs.uncertainPinOperation = nil }
            try write(recs)
            for e in dropped { try? keys.delete(keyVault: e.record.keyVault, keyID: e.keyID) }
            pinMoved()
        }
    }

    /// The renew [operation]'s request [id] is decided as not applied, or was never sent (VAULT-MESSAGING 0.46.0 §11.14.9
    /// step 1): nothing is left to decide for it. Its candidate stays as it is.
    public func clearSent(operation: String, id: String? = nil) throws {
        try store.exclusive {
            var recs = try readRecords()
            guard let i = recs.candidates.firstIndex(where: { $0.operation == operation }), let sent = recs.candidates[i].sent,
                  id == nil || sent.id == id
            else { return }
            recs.candidates[i].sent = nil
            try write(recs)
            pinMoved()
        }
    }

    /// The operation of a PIN change whose PIN is uncertain (§11.14.9 step 3), nil when none.
    public func uncertainPin() throws -> String? { try store.exclusive { try readRecords().uncertainPin } }

    /// The change [id] is decided (or was never sent): it is no longer unresolved. Its candidate stays as it is.
    public func clearUnresolved(id: String) throws {
        try store.exclusive {
            var recs = try readRecords()
            guard recs.unresolved?.id == id else { return }
            recs.unresolved = nil
            try write(recs)
            pinMoved()
        }
    }

    /// A change: [send] carries the next epoch's secret (written as a candidate first) and awaits the vault's answer;
    /// when [confirmed] says the answer is the operation's own, the candidate becomes current. Any other answer, an error,
    /// no answer or a cancellation leaves it a candidate (VAULT-MESSAGING §11.14.1 rule 5). The in-flight slot is held
    /// only while [send] runs and is freed however it ends (throw or cancellation included). A retry passes the same
    /// [operation]. [unresolved] and [exp] (the request's `exp`, a renew's) are stored with the candidate, in the same write.
    public func change<Answer>(
        isolation: isolated (any Actor)? = #isolation,
        operation: String,
        unresolved: UnresolvedChange? = nil,
        exp: Date? = nil,
        sent: PhoneRecords.SentRequest? = nil,
        send: ([UInt8]) async throws -> Answer,
        confirmed: (Answer) -> Bool
    ) async throws -> Answer {
        var next = try beginChange(operation: operation, unresolved: unresolved, exp: exp, sent: sent)
        defer {
            Bytes.wipe(&next)
            endChange(operation: operation)
        }
        let answer = try await send(next)
        if confirmed(answer) { try confirmChange(operation: operation) }
        return answer
    }

    // MARK: - Unlock

    /// An unlock with the current record; on `device_secret`, the candidates, newest first, then the pending epoch-1
    /// records, newest first, each once: the first that gets an answer given only after the secret matched (`ok`,
    /// `bad_pin`, `transfer_incomplete`) becomes current. With no current record the pending ones are tried first. An
    /// answer decided before the secret check ends the tries with the records unchanged. `ok` with the current record
    /// makes the candidates that existed when its secret was taken, and are not in flight, replaced records (the vault
    /// holds none of them); a candidate written or sent meanwhile stays. Returns the answer that decided.
    ///
    /// [tries] (VAULT-MESSAGING §11.14.9 "A lost answer" step 5, while a PIN change is unresolved): ``UnlockTries/current``
    /// sends only the current record, whose `device_secret` is then the answer; ``UnlockTries/previous(excluding:)`` (the
    /// previous PIN) sends the current record, then on `device_secret` the other candidates (an unanswered renew's),
    /// newest first, never the change's own; ``UnlockTries/candidate(operation:)`` sends only that change's candidate
    /// (with the new PIN), or tries as ``UnlockTries/all`` when it is no longer a candidate.
    public func unlock<Answer: SecretCheckedAnswer>(
        isolation: isolated (any Actor)? = #isolation,
        tries only: UnlockTries = .all,
        attempt: ([UInt8]) async throws -> Answer
    ) async throws -> Answer {
        let snapshot = try records()
        let tries: [PhoneRecords.Entry] = snapshot.candidates.reversed().map(\.entry) + snapshot.pendings.reversed()
        if case .candidate(let op) = only, let own = snapshot.candidates.first(where: { $0.operation == op }) {
            let outcome = try await tryInTurn([own.entry], attempt)
            guard let answer = outcome.decided ?? outcome.last else { throw Self.lost }
            return answer
        }
        guard let cur = snapshot.current else {
            let outcome = try await tryInTurn(tries, attempt)
            guard let answer = outcome.decided ?? outcome.last else { throw Self.lost }
            return answer
        }
        let first = try await send(cur, attempt)
        if first.ok {
            try settle(openedWith: cur, candidatesThen: snapshot.candidates, at: first.at)
            return first
        }
        guard first.code == UnlockEpoch.deviceSecret, only != .current else { return first }
        if case .previous(let change) = only {
            // 0.45.0: a candidate that goes with the previous PIN is tried with it before the new PIN is asked for.
            let others = snapshot.candidates.filter { $0.operation != change }.reversed().map(\.entry)
            return try await tryInTurn(others, attempt).decided ?? first
        }
        return try await tryInTurn(tries, attempt).decided ?? first
    }

    // MARK: - The earlier secret

    /// Whether the earlier-secret step can be offered: a replaced record exists (within its 7 days).
    public func hasEarlierSecret() throws -> Bool {
        try store.exclusive { !Self.pruned(try readRecords(), nowMs: nowMs()).replaced.isEmpty }
    }

    /// The earlier-secret step, **only from the member's explicit tap** on the "this phone no longer holds the keys"
    /// screen, never on its own: the replaced records, newest first, each once. Only `ok`, or `transfer_incomplete` for
    /// an unfinished transfer, makes that record current again (the record it displaces becomes a replaced record);
    /// `bad_pin` changes nothing.
    public func tryEarlierSecret<Answer: SecretCheckedAnswer>(
        isolation: isolated (any Actor)? = #isolation,
        attempt: ([UInt8]) async throws -> Answer
    ) async throws -> EarlierSecretOutcome<Answer> {
        let replaced = try store.exclusive { Self.pruned(try readRecords(), nowMs: nowMs()).replaced }
        // Newest first: the higher epoch, then the later one written.
        let ordered = replaced.enumerated().sorted {
            ($0.element.entry.record.epoch, $0.offset) > ($1.element.entry.record.epoch, $1.offset)
        }
        var last: Answer?
        for entry in ordered.map(\.element.entry) {
            let answer: Answer
            do {
                answer = try await send(entry, attempt)
            } catch let f as VaultFailure where f.kind == .deviceSecret {
                continue
            }
            last = answer
            if UnlockEpoch.restoresEarlier(ok: answer.ok, code: answer.code) {
                try restore(entry)
                return .restored(answer, opened: answer.ok)
            }
            if answer.code != UnlockEpoch.deviceSecret { return .unchanged(last: answer) }
        }
        return .unchanged(last: last)
    }

    // MARK: - Internals

    /// [entries] in turn, each once: the first answer given after the secret matched makes its record current and is
    /// the decided one; an answer decided before the secret check is the decided one with nothing changed; with every
    /// one `device_secret` (or not computable) nothing is decided, and [last] is the last answer, if any.
    private func tryInTurn<Answer: SecretCheckedAnswer>(
        _ entries: [PhoneRecords.Entry],
        isolation: isolated (any Actor)? = #isolation,
        _ attempt: ([UInt8]) async throws -> Answer
    ) async throws -> (decided: Answer?, last: Answer?) {
        var last: Answer?
        for entry in entries {
            let answer: Answer
            do {
                answer = try await send(entry, attempt)
            } catch let f as VaultFailure where f.kind == .deviceSecret {
                continue
            }
            last = answer
            if UnlockEpoch.confirmsNext(ok: answer.ok, code: answer.code) {
                try confirmByUnlock(entry, at: answer.at)
                return (answer, answer)
            }
            if answer.code != UnlockEpoch.deviceSecret { return (answer, answer) }
        }
        return (nil, last)
    }

    /// One request with [entry]'s secret, wiped once the request is built and sent.
    private func send<Answer>(
        _ entry: PhoneRecords.Entry,
        isolation: isolated (any Actor)? = #isolation,
        _ attempt: ([UInt8]) async throws -> Answer
    ) async throws -> Answer {
        var s = try store.exclusive { try secret(of: entry) }
        defer { Bytes.wipe(&s) }
        return try await attempt(s)
    }

    /// A candidate or the pending record that an unlock proved becomes current. The candidate of a change in flight, of
    /// the unresolved change, or of a renew whose `exp` has not passed by more than a minute when the vault answered at
    /// [at], stays a candidate: its request may still reach the vault after this unlock (§11.14.9 step 5: a renew's
    /// candidate confirmed with the previous PIN leaves the PIN change undecided).
    private func confirmByUnlock(_ entry: PhoneRecords.Entry, at: Date?) throws {
        try store.exclusive {
            var recs = try readRecords()
            let uncertain = recs.uncertainPin
            if let i = recs.candidates.firstIndex(where: { $0.entry == entry }) {
                var keep = ChangesInFlight.current(store.url).union([recs.unresolved?.operation].compactMap { $0 })
                keep.formUnion(recs.candidates.filter { Self.mayStillApply($0, at: at) }.map(\.operation))
                promote(&recs, candidate: i, keeping: keep)
            } else if let i = recs.pendings.firstIndex(of: entry) {
                promotePending(&recs, at: i)
            } else {
                return
            }
            try write(recs, uncertainBefore: uncertain)
        }
    }

    /// `ok` with the current record (answered at [at]): the candidates of [then] (those that existed when its secret was
    /// taken) that are not in flight become replaced records, marked as put there by an unlock; a candidate written or
    /// sent after that may be one the vault stores after this unlock, and stays. So does a renew's whose request may still
    /// wait in the vault's mailbox (``mayStillApply(_:at:)``).
    private func settle(openedWith record: PhoneRecords.Entry, candidatesThen then: [PhoneRecords.Candidate], at: Date?) throws {
        try store.exclusive {
            var recs = try readRecords()
            guard recs.current == record else { return }
            let uncertain = recs.uncertainPin
            // The unresolved change's candidate is in flight too: its request may still reach the vault after this unlock.
            let inFlight = ChangesInFlight.current(store.url).union([recs.unresolved?.operation].compactMap { $0 })
            let settles = { (c: PhoneRecords.Candidate) in
                then.contains { $0.operation == c.operation && $0.entry == c.entry } && !inFlight.contains(c.operation)
                    && !Self.mayStillApply(c, at: at)
            }
            let settled = recs.candidates.filter(settles)
            guard !settled.isEmpty else { return }
            let ms = nowMs()
            recs.replaced += settled.map { PhoneRecords.Replaced(entry: $0.entry, operation: $0.operation, byUnlock: true, since: ms) }
            recs.candidates.removeAll(where: settles)
            try write(recs, uncertainBefore: uncertain)
        }
    }

    /// Writes [recs] after an unlock; the uncertain PIN ([uncertainBefore] before it) settled moves ``pinGeneration``.
    private func write(_ recs: PhoneRecords, uncertainBefore: String?) throws {
        try write(recs)
        if recs.uncertainPin != uncertainBefore { pinMoved() }
    }

    /// How long after a renew's `exp`, by the vault's clock, no copy of it can apply any more (as for a change, §11.14.9
    /// step 3: the vault's clock does not step back by more than this).
    static let expMargin: TimeInterval = 60

    /// Whether a copy of the renew that made [c] may still apply after an answer the vault gave at [at]: its `exp`, plus
    /// a minute, has not passed then (an answer of unknown time counts as early). A candidate without `exp` never does.
    static func mayStillApply(_ c: PhoneRecords.Candidate, at: Date?) -> Bool {
        guard let exp = c.exp else { return false }
        guard let at else { return true }
        return at <= exp.addingTimeInterval(expMargin)
    }

    /// Candidate [i] becomes current; the current record and every other candidate, except those of the operations
    /// [keep], become replaced records.
    func promote(_ recs: inout PhoneRecords, candidate i: Int, keeping keep: Set<String> = []) {
        let ms = nowMs()
        recs.confirmed()
        let chosen = recs.candidates.remove(at: i)
        if let cur = recs.current { recs.replaced.append(PhoneRecords.Replaced(entry: cur, operation: nil, since: ms)) }
        let replaced = recs.candidates.filter { !keep.contains($0.operation) }
        recs.replaced += replaced.map { PhoneRecords.Replaced(entry: $0.entry, operation: $0.operation, since: ms) }
        recs.candidates = recs.candidates.filter { keep.contains($0.operation) }
        recs.current = chosen.entry
    }

    /// A replaced [entry] becomes current again; the current one becomes a replaced record.
    private func restore(_ entry: PhoneRecords.Entry) throws {
        try store.exclusive {
            var recs = try readRecords()
            guard let i = recs.replaced.firstIndex(where: { $0.entry == entry }) else { return }
            recs.replaced.remove(at: i)
            recs.confirmed()
            if let cur = recs.current { recs.replaced.append(PhoneRecords.Replaced(entry: cur, operation: nil, since: nowMs())) }
            recs.current = entry
            try write(recs)
        }
    }
}

/// Which records an unlock tries (``PhoneSecrets/unlock(isolation:tries:attempt:)``).
public enum UnlockTries: Equatable, Sendable {
    /// The current record, then on `device_secret` the candidates and the pending records.
    case all
    /// The current record only.
    case current
    /// (§11.14.9 step 5, the previous PIN) The current record, then on `device_secret` the candidates other than that of
    /// the change [excluding], newest first.
    case previous(excluding: String?)
    /// The candidate of this change only (``all`` when it is no longer a candidate).
    case candidate(operation: String)
}

/// The change operations in flight, per records file, for the whole process (in memory: nothing after a restart).
enum ChangesInFlight {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var operations: [String: Set<String>] = [:]

    private static func key(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }

    enum Reservation { case reserved, alreadyInFlight, refused }

    /// Marks [operation] in flight unless another operation is (one change at a time).
    static func reserve(_ url: URL, _ operation: String) -> Reservation {
        lock.withLock {
            let k = key(url)
            let busy = operations[k] ?? []
            if busy.contains(operation) { return .alreadyInFlight }
            if !busy.isEmpty { return .refused }
            operations[k] = [operation]
            return .reserved
        }
    }

    static func end(_ url: URL, _ operation: String) {
        lock.withLock { _ = operations[key(url)]?.remove(operation) }
    }

    static func current(_ url: URL) -> Set<String> { lock.withLock { operations[key(url)] ?? [] } }

    /// A process restart, for tests: nothing is in flight.
    static func forgetAll(_ url: URL) { lock.withLock { _ = operations.removeValue(forKey: key(url)) } }
}
