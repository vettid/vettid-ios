import Foundation
import VettIDData

/// The kind of a failure for a screen: a ``VaultFailure``'s own, else ``FailureKind/other``.
func failureKind(_ e: any Error) -> FailureKind { (e as? VaultFailure)?.kind ?? .other }

/// The end of the wait a failure asks for (`retry_after` of a `429` or a backoff), on the monotonic clock, or nil.
func failureRetryAt(_ e: any Error) -> WaitDeadline? {
    guard let f = e as? VaultFailure, f.kind == .rateLimited || f.kind == .backoff, f.retryAfterSeconds > 0 else { return nil }
    return WaitDeadline(seconds: f.retryAfterSeconds)
}
