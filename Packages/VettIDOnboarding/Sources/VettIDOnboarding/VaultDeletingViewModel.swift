import Foundation
import Observation
import VettIDData

/// What Check again last found (IOS-PLAN §4.2 texts).
public enum DeletionCheckNote: Equatable, Sendable {
    /// The vault is still listed: "Not finished yet. Try again later."
    case still
    /// The member API could not be reached.
    case unreachable
}

/// The "being deleted" screen's state: the deletion (its bound passed or not), Check again on its way, what it found.
public struct VaultDeletingState: Equatable, Sendable {
    public var slow = false
    public var checking = false
    public var note: DeletionCheckNote?

    public init(slow: Bool = false, checking: Bool = false, note: DeletionCheckNote? = nil) {
        self.slow = slow
        self.checking = checking
        self.note = note
    }
}

/// A vault being deleted (IOS-PLAN §4.2): nothing that changes the vault or this phone's keys; after the bound, Check
/// again (one read; a second tap waits for the first). The vault gone, the root follows the phase to "no vault".
@MainActor
@Observable
public final class VaultDeletingViewModel {
    public private(set) var state = VaultDeletingState()

    @ObservationIgnored private let account: any AccountRepository
    @ObservationIgnored private let followers = TaskBag()
    @ObservationIgnored private var check: Task<Void, Never>?

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
            case .gone: nil
            }
        }
    }

    /// TEST ONLY: returns once Check again has ended.
    func settle() async { await check?.value }
}
