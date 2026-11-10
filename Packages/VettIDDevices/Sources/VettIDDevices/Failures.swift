import Foundation
import VettIDData

/// The kind of a failure for a screen: a ``VaultFailure``'s own, else ``FailureKind/other``.
func failureKind(_ e: any Error) -> FailureKind { (e as? VaultFailure)?.kind ?? .other }

/// Whether a failure is work cut off by a lock or by the app leaving, which is silent: a ``CancellationError``, any failure that
/// arrives in a task that was cancelled, and a transport's `URLError.cancelled` that a failure carries.
func isSilent(_ e: any Error) -> Bool {
    e is CancellationError || Task.isCancelled || ((e as? VaultFailure)?.cause as? URLError)?.code == .cancelled
}
