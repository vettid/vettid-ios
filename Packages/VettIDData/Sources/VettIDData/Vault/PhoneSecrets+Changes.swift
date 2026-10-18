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
    /// Internal: the only public entry is ``change(isolation:operation:send:confirmed:)``, which always frees the slot.
    func beginChange(operation: String) throws -> [UInt8] {
        let reserved = ChangesInFlight.reserve(store.url, operation)
        guard reserved != .refused else { throw VaultFailure(.busy, code: "change_in_flight") }
        do {
            return try prepareChange(operation: operation)
        } catch {
            // A retry that fails leaves its earlier send in flight; a new operation that fails frees the slot.
            if reserved == .reserved { ChangesInFlight.end(store.url, operation) }
            throw error
        }
    }

    private func prepareChange(operation: String) throws -> [UInt8] {
        try store.exclusive {
            var recs = try readRecords()
            guard let cur = recs.current else { throw Self.lost }
            if let again = recs.candidates.first(where: { $0.operation == operation }) { return try secret(of: again.entry) }
            guard recs.candidates.count < Self.maxCandidates else {
                throw VaultFailure(.unconfirmedChanges, code: "unconfirmed_changes")
            }
            var made = try newEpoch(try phoneKey(cur), keyVault: cur.record.keyVault, epoch: cur.record.epoch + 1, creating: false)
            let entry = PhoneRecords.Entry(keyID: cur.keyID, record: made.record)
            recs.candidates.append(PhoneRecords.Candidate(operation: operation, entry: entry))
            do {
                try write(recs)
            } catch {
                Bytes.wipe(&made.secret)
                throw error
            }
            return made.secret
        }
    }

    /// The change [operation] is no longer in flight: its request failed before sending, got no answer, or was
    /// abandoned. Its candidate stays a candidate.
    func endChange(operation: String) { ChangesInFlight.end(store.url, operation) }

    /// The change [operation]'s answer arrived (`pin.change` with `epoch_advanced: true`, `vault.secret.renew` with its
    /// result): its record becomes current, and the record it replaces and every other candidate become replaced
    /// records. The vault's own answer also proves a record that only an unlock's `ok` made a replaced record, so it is
    /// found there too; never one that a later confirmed record displaced (a late or repeated answer of an older change).
    /// False when no record can be made current that way.
    @discardableResult
    public func confirmChange(operation: String) throws -> Bool {
        try store.exclusive {
            defer { ChangesInFlight.end(store.url, operation) }
            var recs = try readRecords()
            if let i = recs.candidates.firstIndex(where: { $0.operation == operation }) {
                promote(&recs, candidate: i)
            } else if let i = recs.replaced.lastIndex(where: { $0.operation == operation && $0.byUnlock }) {
                let back = recs.replaced.remove(at: i)
                recs.candidates.insert(PhoneRecords.Candidate(operation: operation, entry: back.entry), at: 0)
                promote(&recs, candidate: 0)
            } else {
                return false
            }
            try write(recs)
            return true
        }
    }

    /// A change: [send] carries the next epoch's secret (written as a candidate first) and awaits the vault's answer;
    /// when [confirmed] says the answer is the operation's own, the candidate becomes current. Any other answer, an error,
    /// no answer or a cancellation leaves it a candidate (VAULT-MESSAGING §11.14.1 rule 5). The in-flight slot is held
    /// only while [send] runs and is freed however it ends (throw or cancellation included). A retry passes the same
    /// [operation].
    public func change<Answer>(
        isolation: isolated (any Actor)? = #isolation,
        operation: String,
        send: ([UInt8]) async throws -> Answer,
        confirmed: (Answer) -> Bool
    ) async throws -> Answer {
        var next = try beginChange(operation: operation)
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
    public func unlock<Answer: SecretCheckedAnswer>(
        isolation: isolated (any Actor)? = #isolation,
        attempt: ([UInt8]) async throws -> Answer
    ) async throws -> Answer {
        let snapshot = try records()
        let tries: [PhoneRecords.Entry] = snapshot.candidates.reversed().map(\.entry) + snapshot.pendings.reversed()
        guard let cur = snapshot.current else {
            let outcome = try await tryInTurn(tries, attempt)
            guard let answer = outcome.decided ?? outcome.last else { throw Self.lost }
            return answer
        }
        let first = try await send(cur, attempt)
        if first.ok {
            try settle(openedWith: cur, candidatesThen: snapshot.candidates)
            return first
        }
        guard first.code == UnlockEpoch.deviceSecret else { return first }
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
                try confirmByUnlock(entry)
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

    /// A candidate or the pending record that an unlock proved becomes current.
    private func confirmByUnlock(_ entry: PhoneRecords.Entry) throws {
        try store.exclusive {
            var recs = try readRecords()
            if let i = recs.candidates.firstIndex(where: { $0.entry == entry }) {
                promote(&recs, candidate: i)
            } else if let i = recs.pendings.firstIndex(of: entry) {
                promotePending(&recs, at: i)
            } else {
                return
            }
            try write(recs)
        }
    }

    /// `ok` with the current record: the candidates of [then] (those that existed when its secret was taken) that are
    /// not in flight become replaced records, marked as put there by an unlock; a candidate written or sent after that
    /// may be one the vault stores after this unlock, and stays.
    private func settle(openedWith record: PhoneRecords.Entry, candidatesThen then: [PhoneRecords.Candidate]) throws {
        try store.exclusive {
            var recs = try readRecords()
            guard recs.current == record else { return }
            let inFlight = ChangesInFlight.current(store.url)
            let settles = { (c: PhoneRecords.Candidate) in then.contains(c) && !inFlight.contains(c.operation) }
            let settled = recs.candidates.filter(settles)
            guard !settled.isEmpty else { return }
            let ms = nowMs()
            recs.replaced += settled.map { PhoneRecords.Replaced(entry: $0.entry, operation: $0.operation, byUnlock: true, since: ms) }
            recs.candidates.removeAll(where: settles)
            try write(recs)
        }
    }

    /// Candidate [i] becomes current; the current record and every other candidate become replaced records.
    func promote(_ recs: inout PhoneRecords, candidate i: Int) {
        let ms = nowMs()
        recs.confirmed()
        let chosen = recs.candidates.remove(at: i)
        if let cur = recs.current { recs.replaced.append(PhoneRecords.Replaced(entry: cur, operation: nil, since: ms)) }
        recs.replaced += recs.candidates.map { PhoneRecords.Replaced(entry: $0.entry, operation: $0.operation, since: ms) }
        recs.candidates = []
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
