import Foundation
import VettIDVault

// A transfer to this phone that is not finished, as the phase and the transfer screen see it (VAULT-MESSAGING §6.7.1,
// §11.14.10 rule 5): ``SetupStage/transferWaiting`` opens the transfer screen again, which takes the transfer up
// (``transferInWaiting()``). Mirrors vettid-android `TransferInResume.decide`, `StoppedMove.tells` and
// `transferInWaiting`. Nothing here sends anything.
extension VaultManager {
    /// The code of a scan refused while a setup code's redeem is under way (no move is under way then; the general text).
    public nonisolated static let codeRedeemUnderWay = "redeem_under_way"

    /// Whether a transfer to this phone is not finished on [d]: unpaired and pinned to a vault whose id it does not know yet
    /// (only a transfer pins so: an enrollment's `vault.enrolled` pins the vault with its id), as vettid-android's pending
    /// transfer is the device's. A stored start that nothing pins is no transfer here: it is cleared at the start's resume,
    /// or refuses an enrollment until its background wait clears it (``transferWaitingRefusal(_:)``).
    func transferWaitsHere(_ d: VaultDevice) -> Bool {
        d.deviceID == nil && d.vaultID == nil && d.hasVault
    }

    /// The phase's own step for a transfer waiting on [d] (``transferWaitsHere(_:)``): one pinned with no start stored is
    /// adopted (``adoptPinWithoutStart(_:)``), and one that nothing waits for is waited for in the background; never one that
    /// stopped on this phone untold (the transfer screen tells it first, ``transferInWaiting()``).
    func watchWaitingTransfer(_ d: VaultDevice) async {
        guard !d.droppedWithoutUserGuid else { return }
        if await adoptPinWithoutStart(d) { return }
        let book = moveFlags.book
        guard book.transferWaiter == nil, book.settling == nil, book.waitingIn == 0, book.startingIn == 0, book.screenWaits == 0
        else { return }
        waitForTransferInBackground()
    }

    /// (§11.14.10 rule 5) A transfer pinned on [d] with no start stored (an older race wiped it), and no scan writing its
    /// own. Its handshake never answered (no comparison code saved, none awaited here): nothing can complete it, so it is
    /// dropped now, as a start's resume drops one. Otherwise its real start is unknown, and counts as past the vault's minute
    /// 10 (owner decision): no abandon is offered, and the full deadline from now, then the settlement's window, is waited
    /// for before it is dropped, since the vault may still approve a recent one (``writeUnknownStart()``). Never dropped
    /// outright then. True when it was adopted (or dropped).
    @discardableResult
    func adoptPinWithoutStart(_ d: VaultDevice) async -> Bool {
        guard moveFlags.book.startingIn == 0, record.value.transferStartedMs == nil, transferWaitsHere(d) else { return false }
        if !d.holdsTransferSas, !d.awaitsPairingResp, await dropTransfer(d) { return true }
        writeUnknownStart()
        waitForTransferInBackground()
        return true
    }

    /// A start for a transfer whose own start is unknown: now, marked as adopted (``LocalAccount/transferStartAdoptedMs``),
    /// so that the abandon is closed from the start (``abandonClosed``) while the deadline is the full 11 minutes.
    func writeUnknownStart() {
        let started = nowMs
        _ = try? record.update(since: record.generation) {
            $0.transferIn = true
            $0.transferStartedMs = started
            $0.transferStartAdoptedMs = started
        }
    }

    /// The screen's wait for the transfer to this phone (``MoveRepository/awaitTransferIn()``): it takes the background's
    /// place as it begins (one waiter takes the `device.paired`; a settlement under way is joined, with its collects and its
    /// outcome). Should it fail with the transfer kept, the background's starts again.
    public func awaitTransferIn() async throws -> Bool {
        moveFlags.book.screenWaits += 1
        defer { moveFlags.book.screenWaits -= 1 }
        moveFlags.book.transferWaiter?.cancel()
        moveFlags.book.transferWaiter = nil
        return try await awaitTransferInWaiting()
    }

    /// The transfer the screen takes up as it opens, while the phase says one waits. A comparison code shown (saved with
    /// the handshake, so also after a restart): ``TransferInWaiting/waiting(sas:startedAt:)``; the background's wait goes on
    /// until the screen's begins (``awaitTransferIn()``), so that nothing is left unwatched in between. One that stopped on
    /// this phone untold: ``TransferInWaiting/stopped``, once per process, with the notice (``transferEnd``) standing until
    /// the screen has shown it; the transfer is dropped then, and a drop that cannot be saved is left to the background's
    /// wait. Nil otherwise; nothing is fetched or sent.
    public func transferInWaiting() async throws -> TransferInWaiting? {
        // Only while the phase says so: no session is opened for a phone with nothing set up.
        guard phase == .setup(.transferWaiting), !halted, !record.closed else { return nil }
        return try await guarded {
            let d = try await openSession().device
            guard transferWaitsHere(d) else { return nil }
            if d.droppedWithoutUserGuid {
                guard !moveFlags.book.stopTold else { return nil }
                moveFlags.book.stopTold = true
                moveFlags.book.transferWaiter?.cancel()
                moveFlags.book.transferWaiter = nil
                transferEnd = .stopped
                if await !dropTransfer(d) {
                    if record.value.transferStartedMs == nil { writeUnknownStart() }
                    waitForTransferInBackground(quiet: true)
                }
                await rereadAfterTransferIn()
                return .stopped
            }
            guard let sas = d.transferSas, let started = transferStartedAt else { return nil }
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
