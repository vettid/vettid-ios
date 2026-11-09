import Foundation
import VettIDVault

// A second scan of the same transfer code on the new phone (VAULT-MESSAGING 0.88.4 §11.14.10 rule 5). The transfer
// itself: ``VaultManager+Move``.
extension VaultManager {
    /// (VAULT-MESSAGING 0.88.4 §11.14.10 rule 5, "A second scan of the same code"; owner decision a) The open transfer's
    /// comparison code when [code] is that transfer's own code (the same `r` and `c`, whatever its expiry), else nil, and
    /// the scan is handled as any other. **Nothing is fetched, sent or dropped here, whatever happens**: the member goes
    /// back to the move as it stands, from what this phone stored. Its comparison code once the `hs.fin` went out (saved
    /// with the device's handshake, so also after a restart); before that, the wait for it until 60 s after the transfer's
    /// stored start, ending in ``MoveCodes/hsUnanswered`` with nothing dropped (the scan that started it decides its own
    /// end). A transfer that ends meanwhile makes this scan one of its own (nil). Open: see ``sameCodeOpen(_:_:startedMs:)``.
    /// Mirrors vettid-android `sameTransferCode`.
    func sameCodeMove(_ code: String) async throws -> String? {
        guard let id = InviteLinks.transferCodeID(code), record.value.transferCode == id,
              let startedMs = record.value.transferStartedMs else { return nil }
        return try await guarded {
            let d = try await openSession().device
            guard sameCodeOpen(d, id, startedMs: startedMs) else { return nil }
            let wait = TimeInterval(MoveCodes.hsRespWait.components.seconds)
            let deadline = Date(timeIntervalSince1970: Double(startedMs) / 1000).addingTimeInterval(wait)
            while true {
                if let sas = d.transferSas {
                    // The screen's wait takes the move over from the background's, as a scan's does (one waiter takes the
                    // `device.paired`; the other would only learn of it at the deadline). Should the screen's wait fail
                    // with the transfer kept, the background's is started again (``awaitTransferIn()``).
                    moveFlags.book.transferWaiter?.cancel()
                    moveFlags.book.transferWaiter = nil
                    return sas
                }
                guard sameCodeOpen(d, id, startedMs: startedMs) else { return nil }
                let left = deadline.timeIntervalSince(config.now())
                guard left > 0 else { throw VaultFailure(.noResponse, code: MoveCodes.hsUnanswered) }
                try await sasOrLook(d, left: left)
            }
        }
    }

    /// Whether the transfer that started from the code [id] at [startedMs] is still open on [d]: this phone is not paired,
    /// and either its scan is under way (the claim fetch included, before the handshake is saved), or it holds the
    /// handshake and that handshake can still finish: the vault answered it (its comparison code is saved, and its `hs.fin`
    /// is out or owed), or its `hs.init` waits for the vault's answer in this process. A handshake a restart cut off before its `hs.resp` cannot send an
    /// `hs.fin` any more, so the vault cannot approve it: that transfer is over (0.88.4), and its code is a spent code.
    func sameCodeOpen(_ d: VaultDevice, _ id: TransferCodeID, startedMs: Int64) -> Bool {
        guard record.value.transferCode == id, record.value.transferStartedMs == startedMs, d.deviceID == nil else { return false }
        if moveFlags.book.startingIn > 0 { return true }
        return d.hasVault && (d.holdsTransferSas || d.awaitsPairingResp)
    }

    /// The transfer's comparison code, or a short wait (``sameCodeLook``) before the next look. A fin the relay refused for
    /// good is thrown (``PairingNotCompleted``: the scan that started it drops it); any other failure of the wait is only
    /// a look again later, never a busy loop.
    private func sasOrLook(_ d: VaultDevice, left: TimeInterval) async throws {
        let sleep = config.transferSleep
        let look = Duration.seconds(min(left, Self.sameCodeLook))
        do {
            _ = try await withThrowingTaskGroup(of: String?.self) { group in
                group.addTask { () async throws -> String? in try await d.awaitPairingSas() }
                group.addTask { try await sleep(look); return nil }
                defer { group.cancelAll() }
                return try await group.next() ?? nil
            }
        } catch let notCompleted as PairingNotCompleted {
            throw notCompleted
        } catch {
            try Task.checkCancellation()
            try await sleep(look)
        }
        try Task.checkCancellation()
    }

    /// (0.88.4) Whether [text] is the code of the transfer to this phone that is open now, by what this phone stored
    /// (``sameCodeOpen(_:_:startedMs:)``; without a session, by the stored code alone). The screen asks it before it
    /// refuses an expired code: the same code, whatever its expiry, goes to ``transferIn(code:)``, which gives the move
    /// back.
    public func isOpenTransferCode(_ text: String) -> Bool {
        guard let id = InviteLinks.transferCodeID(text), let startedMs = record.value.transferStartedMs,
              record.value.transferCode == id else { return false }
        guard let d = session?.device else { return true }
        return sameCodeOpen(d, id, startedMs: startedMs)
    }

    /// How often a scan of the same code looks at the open transfer again while its `hs.resp` is not in.
    nonisolated static let sameCodeLook: TimeInterval = 0.25
}
