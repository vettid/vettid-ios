import Foundation

/// Why "Return to release N" did not start, before anything was sent (a local refusal).
public enum ReturnRefusal: Equatable, Sendable {
    /// An update (or the way back) is running.
    case updateRunning
    /// The daily owner check is due and comes first.
    case ownerCheckFirst
    /// A change of the PIN or password is held undecided.
    case changeHeld
    /// There is no failed move to return from any more.
    case nothingToReturnTo
}

public extension VaultRepository {
    func returnToPreviousRelease(pin: String) -> Bool { false }
    func returnToPreviousReleaseRefusal() -> ReturnRefusal? { nil }
}
