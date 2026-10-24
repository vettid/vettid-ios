import Foundation
import VettIDAltChan

// The name of the vault's current opening (VAULT-MESSAGING 0.56.4 §10.2 "Locks", release L). Mirrors vettid-android
// `VaultDevice.unlockId`.
extension VaultDevice {
    /// The name of the vault's current opening as this device last learned it: from the enroll, unlock or recovery-open
    /// result that opened it, and from every `vault.status`. **In memory only**: a new process starts without it (until a
    /// status read), and the app then locks as for a vault before L. Nil from a vault before L, and for `""` or another form
    /// (``UnlockIds``). Not a secret.
    public var unlockID: String? { openingLock.withLock { openingID } }

    /// The mark a `vault.status` request takes before it is sent (``noteUnlockID(_:since:)``): bumped at every change of
    /// opening this device learns of (an unlock built, an enroll, unlock or recovery-open result).
    func openingMark() -> Int { openingLock.withLock { openings } }

    /// An opening happened (or ended): [id] names it, nil for none.
    func opened(_ id: String?) {
        openingLock.withLock {
            openings += 1
            openingID = id
        }
    }

    /// A `vault.status`'s `unlock_id`; absent or of another form: none. Not applied when an opening came between the
    /// request ([mark]) and its answer: the answer may name the one before.
    func noteUnlockID(_ id: String?, since mark: Int) {
        openingLock.withLock { if openings == mark { openingID = UnlockIds.of(id) } }
    }

    /// The name of a lock that ended as "opened again" ([dead]) is forgotten, unless this device has learned a newer one since:
    /// the vault is no longer under it, and a later lock must not be bound to it. Nothing if the current name is another.
    public func forgetUnlockID(ifEqual dead: String?) {
        guard let dead else { return }
        // A `vault.status` answer already on its way is dropped too (it may name the dead opening): the mark moves.
        openingLock.withLock {
            if openingID == dead {
                openings += 1
                openingID = nil
            }
        }
    }

    /// (0.56.1) A recovery open is an opening: the `unlock_id` of its result (`""` from a release before L: none).
    public func recoveryOpened(unlockID id: String?) { opened(UnlockIds.of(id)) }
}
