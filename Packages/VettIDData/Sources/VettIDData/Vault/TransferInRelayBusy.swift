import Foundation

/// Whether this phone's pairing `hs.fin` is held by a relay quota while it waits for the old phone's approval (VAULT-MESSAGING
/// 0.88.8 §8.6 `quota_exceeded`): the comparison code is shown meanwhile, and the vault has not got the fin (chosen; not in the
/// spec). Part of ``MoveRepository``.
@MainActor
public protocol TransferInRelayBusy: AnyObject {
    /// The current value first, then each change. Without a transfer, one `false`, and the stream ends.
    func transferInRelayBusyUpdates() -> AsyncStream<Bool>
}

extension TransferInRelayBusy {
    /// Nothing holds the fin: one `false`.
    public func transferInRelayBusyUpdates() -> AsyncStream<Bool> {
        AsyncStream { c in
            c.yield(false)
            c.finish()
        }
    }
}

extension VaultManager {
    /// The pairing fin's relay quota hold, from the session's device, or the transfer's while the session is put aside (a
    /// background); with neither, one `false`.
    public func transferInRelayBusyUpdates() -> AsyncStream<Bool> {
        guard let d = session?.device ?? moveFlags.book.transferSession?.device else {
            return AsyncStream { c in
                c.yield(false)
                c.finish()
            }
        }
        return d.pairingHeldUpdates()
    }
}
