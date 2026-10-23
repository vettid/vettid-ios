import Foundation
import VettIDData

/// The steps of a direct transfer on the new phone (VAULT-MESSAGING §6.7.1). Mirrors vettid-android `TransferInStep`.
public enum TransferInStep: Equatable, Sendable {
    case intro
    case scan
    case paste
    /// `hs.init` sent; waiting for the vault's `hs.resp`.
    case connecting
    /// The SAS is shown; waiting for the old phone's approval (`device.paired`) until 10 minutes after `hs.init`, then
    /// fetching the credential (`credential.get`, `credential.ack`, `credential.utk.get`).
    case compare
    case done
    /// `device.pair.rejected` (0.10.5): "Rejected on your phone".
    case rejected
    /// 10 minutes without approval.
    case timedOut
    /// No `hs.resp` within 60 seconds (§6.7.1 step 2, 0.10.6): the code may have been used already, or this phone could not
    /// be verified (a dropped `hs.init` is never answered). A new code is offered.
    case notAnswered
}

/// The state of the transfer on the new phone. The pasted code is the member's own text and is not printed. Mirrors
/// vettid-android `TransferInUiState` (`errorShown` is not needed: an unknown vault code is already
/// ``FailureKind/vaultCode(_:)``).
public struct TransferInState: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var step: TransferInStep = .intro
    /// (Release R) This phone made a phone key for the transfer: "Finish the move" follows the approval.
    public var phoneSecret = false
    public var input = ""
    /// Why the scanned or pasted text is not used: ``FailureKind/inviteInvalid`` or ``FailureKind/inviteExpired``.
    public var inputProblem: FailureKind?
    public var sas: String?
    /// 10 minutes after `hs.init` (§6.7, 0.10.4).
    public var deadline: Date?
    public var secondsLeft: Int64 = 0
    public var busy = false
    public var error: FailureKind?
    public var errorCode: String?
    /// ``TransferInStep/done``: the vault gave this phone the member's `user_guid` (§6.7.1, 0.17.0), so it unlocks later.
    /// False after a transfer from a vault release before 0.17.0: the screen says it cannot unlock yet.
    public var canUnlockLater = true

    public init(step: TransferInStep = .intro) {
        self.step = step
    }

    public var description: String {
        "TransferInState(step: \(step), busy: \(busy), error: \(error.map { "\($0)" } ?? "nil"), canUnlockLater: \(canUnlockLater))"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// What the transfer screens on the new phone can ask for: ``TransferInViewModel``, or ``NoTransferInActions`` in previews
/// and the screen catalog. Mirrors vettid-android `TransferInActions`.
@MainActor
public protocol TransferInActions: AnyObject, Sendable {
    func scan()
    func paste()
    @discardableResult func back() -> Bool
    func scanned(_ text: String)
    func setInput(_ v: String)
    func submitInput()
    func cancel()
    func again()
    func finish()
}

/// Actions that do nothing: the screens rendered with sample states (previews, the screen catalog).
@MainActor
public final class NoTransferInActions: TransferInActions {
    public init() {}

    public func scan() {}
    public func paste() {}
    public func back() -> Bool { false }
    public func scanned(_ text: String) {}
    public func setInput(_ v: String) {}
    public func submitInput() {}
    public func cancel() {}
    public func again() {}
    public func finish() {}
}
