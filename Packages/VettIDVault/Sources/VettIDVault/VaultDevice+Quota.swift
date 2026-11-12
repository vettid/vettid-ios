import Foundation
import VettIDCrypto
import VettIDRelay

/// An outbox entry waits for a relay quota (a fresh standing token, or the mailbox's backoff, VAULT-MESSAGING §8.6): nothing
/// was sent, and the entry is kept for a later flush.
public struct QuotaWait: Error, Equatable, Sendable, CustomStringConvertible {
    public var description: String { "waiting for a relay quota" }
}

// VAULT-MESSAGING 0.88.8 §8.6 `quota_exceeded`, "A device" (RELAY-PROTOCOL §7.1: never retried unchanged). Mirrors
// vettid-android #345 (`VaultDevice.quotaRefused`, `awaitQuota`, `deliverInOrder`).
extension VaultDevice {
    // ``quotaBackoff`` (VaultDevice.swift): per mailbox after `quota_exceeded` for its quota, the uptime before which nothing
    // is deposited to it and the last wait; in memory only, and a deposit the relay accepts ends it.

    /// The first wait after `quota_exceeded` for the mailbox's quota, doubled at each refusal up to ``quotaBackoffMax``.
    static let quotaBackoffMin: TimeInterval = 60
    static let quotaBackoffMax: TimeInterval = 3600
    static let typeTokenRefresh = "relay.token.refresh"

    /// An outbox entry refused for a quota is kept and never sent again unchanged. A device asks for no fresh token and
    /// reconnects to nothing: its standing token has no quota (§7.1), the refresh after `quota_exceeded` is a peer vault's
    /// (§7.2), and §6.6 is between vaults.
    /// - the **token**'s (`quota: token`): it waits, and so does every entry under that token, the refresh too, until the
    ///   device holds another standing token for the vault (an unlock result, `relay.token.issued`, a new pairing), and is
    ///   then sent once under it (``awaitQuota(_:)``). The spent token is kept with the entry (persisted);
    /// - the **mailbox**'s (`quota: mailbox`, and a `quota_exceeded` with no `quota`, which a device reads as the mailbox's):
    ///   backoff from ``quotaBackoffMin`` doubling to ``quotaBackoffMax``, in memory; a deposit the relay takes ends it.
    func quotaRefused(_ e: OutboxEntry, _ x: RelayError) async {
        guard x.quota == RelayError.quotaToken else {
            let next: TimeInterval = mem.withLock {
                let last = quotaBackoff[e.mailbox]?.last ?? 0
                let next = last == 0 ? Self.quotaBackoffMin : min(last * 2, Self.quotaBackoffMax)
                quotaBackoff[e.mailbox] = (cfg.uptime() + next, next)
                return next
            }
            // A flush when the wait ends, so that a foreground app tries again on time (not only at its next start or unlock),
            // through the manager's lock gate.
            let sleep = mem.withLock { quotaSleep }
            Task { [weak self] in
                await sleep(next)
                await self?.gatedFlush()
            }
            return
        }
        try? await withLockSaving {
            // Every entry under the spent token is marked, and the token kept on its own, so that the knowledge outlives
            // the entry it refused.
            for i in st.outbox.indices where st.outbox[i].token == e.token { st.outbox[i].quotaToken = e.token }
            var spent = (st.quotaSpentTokens ?? []).filter { $0 != e.token }
            spent.append(e.token)
            st.quotaSpentTokens = Array(spent.suffix(Self.maxSpentTokens))
        }
    }

    /// How many spent tokens are kept (``DeviceState/quotaSpentTokens``), the newest: a device holds one standing token for
    /// its vault at a time (chosen; not in the spec).
    static let maxSpentTokens = 8

    /// Sets the gate of the flushes the device starts on its own (``gatedFlush()``).
    public func setFlushGate(_ gate: @escaping @Sendable () async -> Bool) { mem.withLock { flushGate = gate } }

    /// A flush the device starts on its own (the end of a quota backoff, a new standing token for held entries): only while
    /// it collects, and only when the manager's gate admits it (nothing but the lock while one is pending).
    func gatedFlush() async {
        let (gate, running) = mem.withLock { (flushGate, !stopped && !forgotten) }
        guard running else { return }
        if let gate, await !gate() { return }
        // A stop() while the gate was asked wins.
        guard mem.withLock({ !stopped && !forgotten }) else { return }
        await flushOutbox()
    }

    /// The relay took a deposit to [mailbox]: its quota backoff ends.
    func quotaAccepted(_ mailbox: String) { mem.withLock { quotaBackoff[mailbox] = nil } }

    /// Before an outbox entry's deposit: the entry as it is to be deposited, or ``QuotaWait``. An entry under a token whose
    /// quota is spent (its own or an earlier entry's) waits for another standing token for its mailbox, one not known to be
    /// spent, and is re-addressed to it (saved). While its mailbox waits for a quota, an entry goes only after every earlier
    /// entry of that mailbox has gone, except `relay.token.refresh`, which passes them; and nothing goes while the mailbox's
    /// backoff runs. An entry no longer in the outbox is held by the same rules, without a save.
    func awaitQuota(_ e: OutboxEntry) async throws -> OutboxEntry {
        let (out, changed): (OutboxEntry?, Bool) = mem.withLock {
            let i = st.outbox.firstIndex(where: { $0.id == e.id })
            var cur = i.map { st.outbox[$0] } ?? e
            let spent = Set(st.outbox.compactMap(\.quotaToken) + (st.quotaSpentTokens ?? []))
            var changed = false
            if cur.quotaToken == nil, spent.contains(cur.token) {
                cur.quotaToken = cur.token
                changed = true
            }
            // Only to the vault's own token: an entry to another mailbox or relay under a spent token waits until it is
            // dropped (a fin at its time) or the outbox is (chosen; not in the spec: the device holds no other token for it).
            if cur.quotaToken != nil {
                if let v = st.vault, !v.token.isEmpty, v.mailbox == cur.mailbox, v.relayURL == cur.relayURL, !spent.contains(v.token) {
                    cur.token = v.token
                    cur.quotaToken = nil
                    changed = true
                }
            }
            if let i { st.outbox[i] = cur } else { changed = false } // an entry gone meanwhile is not saved
            if cur.quotaToken != nil { return (nil, changed) }
            let before = i.map { st.outbox[..<$0] } ?? st.outbox[...]
            let behindEarlier = before.contains { $0.mailbox == cur.mailbox && $0.id != cur.id }
            if cur.type != Self.typeTokenRefresh, behindEarlier, quotaWaitingLocked(cur.mailbox) { return (nil, changed) }
            if let b = quotaBackoff[cur.mailbox], cfg.uptime() < b.until { return (nil, changed) }
            return (cur, changed)
        }
        if changed { try? await withLockSaving {} }
        guard let out else { throw QuotaWait() }
        return out
    }

    /// [mailbox] waits for a quota: an entry to it waits for a fresh token, or its backoff has not ended with a deposit.
    /// Under ``mem``.
    func quotaWaitingLocked(_ mailbox: String) -> Bool {
        quotaBackoff[mailbox] != nil || st.outbox.contains { $0.mailbox == mailbox && $0.quotaToken != nil }
    }

    /// [entry], new, after every older entry of its mailbox still in the outbox while the mailbox waits for a quota: they
    /// are tried first, in order; one still there after its try holds [entry] for the next flush (``awaitQuota(_:)``), so a
    /// new entry never overtakes one queued before it. [entry]'s own failure (or wait) is thrown, as ``deliver(_:keepOnFailure:)``'s.
    func deliverInOrder(_ entry: OutboxEntry) async throws {
        let earlier: [OutboxEntry] = mem.withLock {
            guard quotaWaitingLocked(entry.mailbox), let i = st.outbox.firstIndex(where: { $0.id == entry.id }) else { return [] }
            return st.outbox[..<i].filter { $0.mailbox == entry.mailbox }
        }
        let nowMs = Self.ms(now())
        for e in earlier {
            // A fin past its time is dropped, not sent, as by a flush.
            if e.type == Self.typeHsFin, let dropAfter = e.dropAfterMs, nowMs >= dropAfter {
                try? await withLockSaving { st.outbox.removeAll { $0.id == e.id } }
                continue
            }
            // Not one a flush is depositing just now.
            let taken = mem.withLock { st.outbox.contains { $0.id == e.id } && outboxInFlight.insert(e.id).inserted }
            guard taken else { continue }
            defer { mem.withLock { _ = outboxInFlight.remove(e.id) } }
            if e.type == HsTypes.confirm {
                await deliverConfirm(e)
            } else {
                try? await deliver(e)
            }
        }
        try await deliver(entry)
    }
}
