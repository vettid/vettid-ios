import Foundation
import VettIDCrypto

// The time the keyring's retained epochs are judged by (as vettid-android #350): a phone clock set far ahead, even briefly,
// must not destroy the kept confirmed epoch (48 days) or a released one (16 days), which the vault may still rekey from or
// send under; a pair whose keys went early ends in gap F (VAULT-MESSAGING §6.3.1).
extension VaultDevice {
    /// How far past the vault's clock a key's destruction may be judged (``pruneTimeLocked(_:)``): the allowed clock skew.
    static let pruneSkew: TimeInterval = 5 * 60

    /// The time the keyring's retained epochs are destroyed by: this phone's [t], but never later than the keys' clock
    /// (``keyClockLocked()``) plus ``pruneSkew``; nil (nothing destroyed now) while no message from the vault in this process
    /// has shown its time. A wall clock set ahead so postpones a destruction and never makes one early: until a key is
    /// destroyed, ``Keyring/open(_:now:)`` only hides it while the clock says it is past its life, and it is usable again once
    /// the clock is back. Keys are destroyed only at an activation, and before the vault has shown its time in this process
    /// nothing is (keys past their life stay hidden, not destroyed); the first message after a restart may be up to 16 days
    /// old (the durable `ts` window), so its time is the vault's of then. Callers hold ``mem``.
    func pruneTimeLocked(_ t: Date) -> Date? {
        keyClockLocked().map { min(t, $0.addingTimeInterval(Self.pruneSkew)) }
    }

    /// ``pruneTimeLocked(_:)`` for a caller that does not hold ``mem``.
    func pruneTime(_ t: Date) -> Date? { mem.withLock { pruneTimeLocked(t) } }

    /// The time a key's life is counted from at an activation: the keys' clock once it is known in this process (at a rekey,
    /// `hs.fin`'s `ts` was just noted), so a clock ahead does not lengthen the kept epoch's 48 days or a receive key's 16; this
    /// phone's [t] before. Callers hold ``mem``.
    func keyBaseLocked(_ t: Date) -> Date { keyClockLocked() ?? t }

    /// A released epoch's receive key: kept 16 days from the latest of this phone's time, the keys' clock and the message's
    /// own authenticated [ts] (a clock behind does not shorten them), but never counted from later than the later of this
    /// phone's time and the keys' clock, plus the durable window and the allowed future skew (a stamp far in the future does
    /// not keep it to that date). Known limit: before the vault's time is known, a phone more than that far behind has the
    /// stamp capped too. Callers hold ``mem``.
    func releaseUntilLocked(_ t: Date, _ ts: Date) -> Date {
        let known = keyClockLocked().map { max(t, $0) } ?? t
        let cap = known.addingTimeInterval(Inner.maxDurableAge + Inner.maxClockSkewFuture)
        return min(max(known, ts), cap).addingTimeInterval(Epoch.receiveKeyRetention)
    }

    /// The verified `ts` of a handshake's `hs.init`, `hs.resp` or `hs.fin`: a second anchor the keys' clock reads, never
    /// ``vaultNow()`` (the settlement clock of §11.14.9 stays as it was). Callers hold ``mem``.
    func noteKeyTimeLocked(_ ts: Date) {
        let up = cfg.uptime()
        if let c = keyStamp, c.ts.addingTimeInterval(max(0, up - c.at)) >= ts { return }
        keyStamp = (ts, up)
    }

    /// The keys' clock: the later of the vault's clock as messages showed it (``vaultNow()``, when one did in this process) and
    /// the handshakes' stamps (``noteKeyTimeLocked(_:)``), each carried forward on the monotonic clock; nil while neither is
    /// known. Callers hold ``mem``.
    func keyClockLocked() -> Date? {
        let up = cfg.uptime()
        let fromVault = vaultClock.map { $0.ts.addingTimeInterval(max(0, up - $0.at)) }
        let fromKeys = keyStamp.map { $0.ts.addingTimeInterval(max(0, up - $0.at)) }
        return [fromVault, fromKeys].compactMap { $0 }.max()
    }
}
