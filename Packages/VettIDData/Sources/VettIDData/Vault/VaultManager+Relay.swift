import Foundation
import VettIDVault

// The lasting notice of a relay key the relay refused (VAULT-MESSAGING 0.84.0 §3.4 "What the member sees", §10.2). Mirrors
// vettid-android `OwnerCheckManager.relayRefused` (PR 301), kept here because the manager hears every `vault.status`.
extension VaultManager {
    /// How long after a status that found the relay refused the status is read once more, before the time scale: the vault
    /// tries the relay once per unlock, after the unlock's own `vault.status` (§3.4).
    nonisolated static let relayRecheckSeconds = 60

    /// The latest `vault.status` has `relay: "refused"`: the vault could not move to its new relay address and may not
    /// receive messages until its keys are replaced. Memory only, so that nothing shows after a restart until a status is
    /// read; false at a lock, a sign-out and a wipe.
    public internal(set) var relayRefused: Bool {
        get { moveFlags.relayRefused }
        set { moveFlags.relayRefused = newValue }
    }

    /// Each `vault.status` of the open vault decides: `relay` absent (or any value but `"refused"`) takes the notice away.
    /// A status heard while the vault is not open (the unlock's own, which runs before it opens) decides nothing; the read
    /// after the unlock does.
    func noteRelay(status st: VaultStatusInfo) {
        guard phase == .unlocked else { return }
        relayRefused = st.relayRefused
        if st.relayRefused { scheduleRelayRecheck() }
    }

    /// The vault tries the relay once per unlock, after the unlock's read: when a status found it refused, one more is read
    /// a minute later (divided by the vault's time scale), once per unlock and only while the vault is open.
    private func scheduleRelayRecheck() {
        guard moveFlags.book.relayRecheck == nil, !moveFlags.book.relayRechecked else { return }
        moveFlags.book.relayRechecked = true
        let wait = Duration.seconds(Double(Self.relayRecheckSeconds) / Double(max(timeScale, 1)))
        moveFlags.book.relayRecheck = Task { [weak self, sleep = config.relaySleep] in
            try? await sleep(wait)
            guard !Task.isCancelled, let self, phase == .unlocked else { return }
            try? await ownerChecks.refreshOwnerCheck()
        }
    }

    /// A lock, a sign-out or a wipe: no relay notice, and the one re-read is cancelled.
    func forgetRelay() {
        relayRefused = false
        moveFlags.book.relayRecheck?.cancel()
        moveFlags.book.relayRecheck = nil
        moveFlags.book.relayRechecked = false
    }

    /// New keys end a refused relay key: the status is read again so that the notice goes (§3.4).
    func relayKeysReplaced() async {
        try? await ownerChecks.refreshOwnerCheck()
    }
}
