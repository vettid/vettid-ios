import Foundation
import VettIDData

/// The kind of a failure for a screen: a ``VaultFailure``'s own, else ``FailureKind/other``.
func failureKind(_ e: any Error) -> FailureKind { (e as? VaultFailure)?.kind ?? .other }
