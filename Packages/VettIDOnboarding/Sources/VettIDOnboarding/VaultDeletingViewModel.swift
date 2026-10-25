import Foundation
import Observation
import VettIDData

/// What Check again last found (IOS-PLAN §4.2 texts).
public enum DeletionCheckNote: Equatable, Sendable {
    /// The vault is still listed: "Not finished yet. Try again later."
    case still
    /// The member API could not be reached.
    case unreachable
    /// The member API answered, but this phone cannot confirm that the deletion is finished (`{vault: null}`, a `401` or a
    /// `403`).
    case cannotConfirm
    /// As ``cannotConfirm``, for a `401` that is the phone's clock: the date and time hint is added.
    case cannotConfirmClock
}

/// The "being deleted" screen's state: the deletion (its bound passed or not), Check again on its way, what it found.
public struct VaultDeletingState: Equatable, Sendable {
    public var slow = false
    public var checking = false
    public var note: DeletionCheckNote?
    /// The member asked to remove VettID from this phone and is asked to confirm (offered only past the bound).
    public var removeConfirm = false
    /// The confirmed removal runs.
    public var removing = false

    public init(
        slow: Bool = false, checking: Bool = false, note: DeletionCheckNote? = nil, removeConfirm: Bool = false, removing: Bool = false
    ) {
        self.slow = slow
        self.checking = checking
        self.note = note
        self.removeConfirm = removeConfirm
        self.removing = removing
    }
}

/// A vault being deleted (IOS-PLAN §4.2): nothing that changes the vault or this phone's keys; after the bound, Check
/// again (one read; a second tap waits for the first) and "Remove from this phone". Nothing here erases by itself: a vault
/// is left only by a definite signal (none yet) or by the member's confirmed removal (owner decision, 2026-10-24; mirrors
/// vettid-android #192). The vault gone, the root follows the phase to "no vault".
@MainActor
@Observable
public final class VaultDeletingViewModel {
    public private(set) var state = VaultDeletingState()

    @ObservationIgnored private let account: any AccountRepository
    @ObservationIgnored private let followers = TaskBag()
    @ObservationIgnored private var check: Task<Void, Never>?
    @ObservationIgnored private var removal: Task<Void, Never>?

    public init(account: any AccountRepository) {
        self.account = account
        followers.add(follow(self, read: { $0.account.deletion?.slow ?? false }, apply: { $0.state.slow = $1 }))
    }

    deinit {
        followers.cancelAll()
        check?.cancel()
    }

    /// Check again: one read of the member API's status; nothing while one is on its way.
    public func checkAgain() {
        guard !state.checking else { return }
        state.checking = true
        state.note = nil
        check = Task { [weak self] in
            guard let self else { return }
            let r = await account.checkDeletionAgain()
            state.checking = false
            state.note = switch r {
            case .listed: .still
            case .unreachable: .unreachable
            case .unconfirmed: .cannotConfirm
            case .unconfirmedClock: .cannotConfirmClock
            case .gone: nil
            }
        }
    }

    /// "Remove from this phone", past the bound: asks for the confirmation.
    public func askRemove() {
        if state.slow { state.removeConfirm = true }
    }

    public func dismissRemove() { state.removeConfirm = false }

    /// The confirmed removal: the existing local erase (``AccountRepository/eraseThisPhone()``). Not before the bound.
    public func confirmRemove() {
        guard !state.removing, state.slow else { return }
        state.removeConfirm = false
        state.removing = true
        removal = Task { [weak self] in
            guard let self else { return }
            try? await account.eraseThisPhone()
            state.removing = false
        }
    }

    /// TEST ONLY: returns once the removal has ended.
    func settleRemoval() async { await removal?.value }

    /// TEST ONLY: returns once Check again has ended.
    func settle() async { await check?.value }
}
