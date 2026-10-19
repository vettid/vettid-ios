import Foundation

// The credential requests of this device that may still reach the vault (VAULT-MESSAGING 0.46.0 §11.14.9 step 1,
// "Nothing else in flight" and "Settled on answers only"): each carries an `exp` and is recorded before it is sent; it is
// settled by its answer, or once the `ts` of an answer from the vault (to any request) is more than a minute past its
// `exp`, after which no copy of it can apply. Events and other messages from the vault settle nothing. A change of PIN or
// password is sent only when every one is settled. Mirrors vettid-android `VaultDevice.trackCredential` and
// `awaitCredentialSettled`.
extension VaultDevice {
    /// How long after its `exp`, by the vault's clock, an unanswered request can no longer apply.
    public static let settleMargin: TimeInterval = 60
    /// How often a wait for the settling looks again.
    static let settlePoll: TimeInterval = 0.1

    /// The credential request [id], valid until [exp], is about to be sent: unsettled until its answer arrives or the
    /// vault's clock is past [exp] plus ``settleMargin``. Saved before the send.
    func trackCredential(_ id: String, exp: Date) async throws {
        try await lock.withLock {
            mem.withLock {
                var u = st.unsettled ?? [:]
                u[id] = Self.ms(exp)
                st.unsettled = u
            }
            try save()
        }
    }

    /// An answer to [re], stamped [ts]: its request is settled, and the vault's clock as answers show it moves on. Callers
    /// hold ``lock`` (the state is saved after the message).
    func settled(_ re: String, at ts: Date) {
        mem.withLock {
            if answerTs.map({ $0 < ts }) ?? true { answerTs = ts }
            _ = st.unsettled?.removeValue(forKey: re)
        }
    }

    /// The credential request [id] is settled by a decision (a change decided applied by `credential.version`).
    public func settleCredential(_ id: String) async {
        await lock.withLock {
            let removed: Bool = mem.withLock { st.unsettled?.removeValue(forKey: id) != nil }
            if removed { try? save() }
        }
    }

    /// Whether no credential request of this device can still reach the vault: each was answered, or the newest `ts` the
    /// vault stamped on an answer (never the phone's estimate) is more than ``settleMargin`` past its `exp`.
    public func credentialSettled() async -> Bool {
        await lock.withLock {
            let pruned: Bool = mem.withLock { Self.pruneSettled(&st.unsettled, answerTs) }
            if pruned { try? save() }
            return mem.withLock { st.unsettled?.isEmpty ?? true }
        }
    }

    /// Drops from [unsettled] every request the vault can no longer act on; true when any was dropped.
    static func pruneSettled(_ unsettled: inout [String: Int64]?, _ seen: Date?) -> Bool {
        guard let u = unsettled, let seen else { return false }
        let seenMs = ms(seen)
        let left = u.filter { seenMs <= $0.value + Int64(settleMargin * 1000) }
        guard left.count != u.count else { return false }
        unsettled = left.isEmpty ? nil : left
        return true
    }

    /// Flushes the outbox and waits until no credential request of this device can still reach the vault, for at most
    /// [timeout] (measured by [sleep]); false when some did not settle in time. In a quiet session no answer may come to
    /// move the vault's clock: once every pending request should have expired by the phone's estimate, one
    /// `credential.version` (not a credential operation) is sent to obtain a stamped time (0.46.0 step 1).
    public func awaitCredentialSettled(
        within timeout: TimeInterval, sleep: @escaping @Sendable (TimeInterval) async throws -> Void
    ) async -> Bool {
        if await credentialSettled() { return true }
        await flushOutbox()
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask { await self.pollSettled() }
            group.addTask {
                try? await sleep(timeout)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    /// Looks again until every request is settled (true), probing the vault's time once; false when cancelled.
    private func pollSettled() async -> Bool {
        var probed = false
        while !Task.isCancelled {
            if await credentialSettled() { return true }
            if !probed, expiredByEstimate() {
                probed = true
                _ = try? await requestOnce("credential.version")
                continue
            }
            try? await Task.sleep(nanoseconds: UInt64(Self.settlePoll * 1e9))
        }
        return false
    }

    /// Every pending request is past its `exp` plus the margin by ``vaultNow()`` (an estimate: it only triggers a probe).
    private func expiredByEstimate() -> Bool {
        let now = Self.ms(vaultNow())
        return mem.withLock {
            guard let u = st.unsettled, !u.isEmpty else { return false }
            return u.values.allSatisfy { now > $0 + Int64(Self.settleMargin * 1000) }
        }
    }
}
