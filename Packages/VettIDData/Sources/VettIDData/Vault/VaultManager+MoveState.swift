import Foundation
import Observation
import VettIDVault

/// What the shell observes of the move to another phone (VAULT-MESSAGING §6.7.1, §11.14.10). Observable on its own, so
/// that the manager's forwarding properties are tracked through it.
@MainActor
@Observable
final class MoveFlags {
    /// The bookkeeping of a transfer, in memory only (not observed), and the runner of "Finish the move" made at its first
    /// use.
    @ObservationIgnored let book = MoveBook()
    @ObservationIgnored var runner: FinishMoveRunner?
    var changeCheck: ChangeCheck?
    var rotateOffered = false // (release R) ``LocalAccount/rotateOffer``
    var movedIn = false
    var finishMovePending = false
    var transferKeptSince: Date?
    var keptCheckPending = false
    var movedBack = false
    var movedAway = false
    var finishMoveHold: FailureKind?
}

/// How the end of a transfer to this phone was settled (``VaultManager/settleTransfer(_:collect:guid:)``).
enum TransferSettled {
    /// The move is paired and the credential taken over; the member's `user_guid` if the vault sent one.
    case completed(guid: String?)
    /// Nothing was approved: the handshake, the attested key and the epoch-1 secret are dropped.
    case dropped
    /// Paired, but the take-over did not complete: nothing is dropped; the next start does it again.
    case failed(any Error)
}

/// The bookkeeping of a transfer, in memory only.
@MainActor
final class MoveBook {
    /// The transfer this (old) phone opened last, to cancel it when a new one is asked for.
    var openTransferID: String?
    /// The one task that settles the end of a transfer to this phone (a take-over, or a drop): every caller joins it.
    var settling: Task<TransferSettled, Never>?
    /// The wait of a transfer found waiting at a start (before its deadline), and whether the start was looked at.
    var transferWaiter: Task<Void, Never>?
    var transferResumed = false
    /// How many day-7 checks ended (any result): what a test awaits instead of a fixed time.
    var keptChecksFinished = 0
    /// The timer to the end of a kept transfer, and whether its end is being decided now.
    var keptTimer: Task<Void, Never>?
    var keptEnding = false
    /// The pending lock found at the start was taken up (once, after the first-run cleanup and the record).
    var lockResumed = false
    /// The earlier identity's unlock is being tried now (``VaultManager/pairEarlierIdentity(pin:)``): not a trial to settle.
    var trialRunning = false
    /// Identities are being switched for the rule now (a status read of the rule waits).
    var ruleSwitching = 0
    /// The kept transfer of the record was looked at (once per process, at the start; then at each return to the foreground).
    var keptResumed = false
    /// Bumped by every move to the foreground and to the background: a check that saw it change was interrupted.
    var lifecycle = 0
    /// The wipe that runs now is an old phone's at the end of a kept transfer (it says so on the welcome screen).
    var wipeMovedAway = false
}

extension VaultManager {
    /// (Release R, ANDROID-PLAN "Transfer") The offer to rotate the vault's keys after a PIN or password change.
    public internal(set) var rotateOffered: Bool {
        get { moveFlags.rotateOffered }
        set { moveFlags.rotateOffered = newValue }
    }

    /// (VAULT-MESSAGING §11.14.9 "A lost answer") Where the decision of a change whose answer was lost stands. Every change
    /// of it moves ``finishMoveHold`` too (it is the hold's text: checking, or unreachable).
    public internal(set) var changeCheck: ChangeCheck? {
        get { moveFlags.changeCheck }
        set {
            moveFlags.changeCheck = newValue
            refreshFinishMoveHold()
        }
    }

    /// "Finish the move" (VAULT-MESSAGING §11.14.10 step 4): once asked for, it completes (``FinishMoveRunner``).
    var finishMoveRunner: FinishMoveRunner {
        if let r = moveFlags.runner { return r }
        let r = makeFinishMoveRunner()
        moveFlags.runner = r
        return r
    }

    /// This phone received its vault by a direct transfer and has not left onboarding yet (``LocalAccount/movedIn``).
    public internal(set) var movedIn: Bool {
        get { moveFlags.movedIn }
        set { moveFlags.movedIn = newValue }
    }

    /// This new phone has not yet finished the move (``LocalAccount/finishMovePending``).
    public internal(set) var finishMovePending: Bool {
        get { moveFlags.finishMovePending }
        set { moveFlags.finishMovePending = newValue }
    }

    /// When this old phone approved a transfer it still keeps the keys for; nil otherwise (``checkKeptTransfer()``).
    public internal(set) var transferKeptSince: Date? {
        get { moveFlags.transferKeptSince }
        set { moveFlags.transferKeptSince = newValue }
    }

    /// The 7 days of a kept transfer are over and the vault has not given a definite answer yet (owner decision,
    /// 2026-10-23): this phone keeps its keys and checks again at each start and foreground. The shell shows a plain notice.
    public internal(set) var keptCheckPending: Bool {
        get { moveFlags.keptCheckPending }
        set { moveFlags.keptCheckPending = newValue }
    }

    /// This old phone opened the vault with its own keys after approving a transfer: it is the vault's phone again.
    public internal(set) var movedBack: Bool {
        get { moveFlags.movedBack }
        set { moveFlags.movedBack = newValue }
    }

    /// This old phone removed its keys at the end of a kept transfer (``LocalWipe/movedAway``).
    public internal(set) var movedAway: Bool {
        get { moveFlags.movedAway }
        set { moveFlags.movedAway = newValue }
    }

    /// (VAULT-MESSAGING 0.45.0 §11.14.9 step 2) Why "Finish the move" is held: a PIN or password change is being decided
    /// or the PIN is uncertain (the gate's failure kind); nil when the move can be finished. Observable: updated wherever a
    /// change starts or ends, or the PIN becomes uncertain or settles (``refreshFinishMoveHold()``).
    public internal(set) var finishMoveHold: FailureKind? {
        get { moveFlags.finishMoveHold }
        set { moveFlags.finishMoveHold = newValue }
    }

    var openTransferID: String? {
        get { moveFlags.book.openTransferID }
        set { moveFlags.book.openTransferID = newValue }
    }

    var keptTimer: Task<Void, Never>? {
        get { moveFlags.book.keptTimer }
        set { moveFlags.book.keptTimer = newValue }
    }

    var keptEnding: Bool {
        get { moveFlags.book.keptEnding }
        set { moveFlags.book.keptEnding = newValue }
    }

    var wipeMovedAway: Bool {
        get { moveFlags.book.wipeMovedAway }
        set { moveFlags.book.wipeMovedAway = newValue }
    }

    /// The account record changed: what it says of the move and of the rotate offer reaches the observed properties.
    func recordChanged(_ a: LocalAccount) {
        if rotateOffered != a.rotateOffer { rotateOffered = a.rotateOffer }
        if movedIn != a.movedIn { movedIn = a.movedIn }
        if finishMovePending != a.finishMovePending { finishMovePending = a.finishMovePending }
    }

    /// At the start (once, after the first-run cleanup): the wipe's notice is read, and the 7 days of a kept transfer
    /// (release R, §11.14.10) are checked.
    func resumeMoveState() {
        guard !moveFlags.book.keptResumed else { return }
        moveFlags.book.keptResumed = true
        movedAway = wiper?.movedAway ?? false
        settleTrial()
        resumeKeptTransfer()
    }

    func makeFinishMoveRunner() -> FinishMoveRunner {
        let ref = ManagerRef()
        ref.manager = self
        return Self.finishMoveRunner(ref, hold: config.finishMoveHold, sleep: config.lockTiming.sleep)
    }
}
