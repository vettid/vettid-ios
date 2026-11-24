import Foundation
import VettIDVault

// A transfer to this phone that is not finished, as the phase and the transfer screen see it (VAULT-MESSAGING §6.7.1,
// §11.14.10 rule 5): ``SetupStage/transferWaiting`` opens the transfer screen again, which takes the transfer up
// (``transferInWaiting()``). Mirrors vettid-android `TransferInResume.decide`, `StoppedMove.tells` and
// `transferInWaiting`. Nothing here sends anything.
extension VaultManager {
    /// Whether a transfer to this phone is not finished on the unpaired device [d]: its start stored in [local], or [d]
    /// pinned to a vault whose id it does not know yet (only a transfer pins so: an enrollment's `vault.enrolled` pins the
    /// vault with its id). The same test as ``transferWaitingRefusal(_:)``'s.
    func transferWaitsHere(_ local: LocalAccount, _ d: VaultDevice) -> Bool {
        guard d.deviceID == nil, d.vaultID == nil else { return false }
        return local.transferStartedMs != nil || d.hasVault
    }

    /// The transfer the screen takes up as it opens, while the phase says one waits. A comparison code shown (saved with
    /// the handshake, so also after a restart): ``TransferInWaiting/waiting(sas:startedAt:)``, and the background's wait
    /// stops (the screen's wait takes the `device.paired`, as a scan of the same code does, ``sameCodeMove(_:)``; should
    /// the screen's wait fail with the transfer kept, the background's starts again, ``awaitTransferIn()``). One that
    /// stopped on this phone untold: dropped here, as the wait would drop it, and ``TransferInWaiting/stopped``. Nil
    /// otherwise; nothing is fetched or sent.
    public func transferInWaiting() async throws -> TransferInWaiting? {
        // Only while the phase says so: no session is opened for a phone with nothing set up.
        guard phase == .setup(.transferWaiting), !halted, !record.closed else { return nil }
        return try await guarded {
            let d = try await openSession().device
            guard transferWaitsHere(record.value, d) else { return nil }
            if d.droppedWithoutUserGuid {
                moveFlags.book.transferWaiter?.cancel()
                moveFlags.book.transferWaiter = nil
                await dropTransfer(d)
                await rereadAfterTransferIn()
                return .stopped
            }
            guard let sas = d.transferSas, let started = transferStartedAt else { return nil }
            moveFlags.book.transferWaiter?.cancel()
            moveFlags.book.transferWaiter = nil
            return .waiting(sas: sas, startedAt: started)
        }
    }

    /// The phase read again once the transfer screen's own transfer ended (abandoned, dropped, rejected, stopped), while the
    /// phase still says it waits: a phone left with a redeemed code goes back to its new vault, one without to the welcome
    /// screen. The background's wait reads it again itself (``waitForTransferInBackground()``).
    func rereadAfterTransferIn() async {
        guard phase == .setup(.transferWaiting), !halted, !record.closed else { return }
        try? await refresh()
    }
}
