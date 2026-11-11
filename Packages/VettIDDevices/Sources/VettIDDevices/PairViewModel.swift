import Foundation
import Observation
import os
import VettIDData

/// Owners of pairing screens: each screen has its own, for the whole process.
private let ownerCounter = OSAllocatedUnfairLock(initialState: 0)

/// The first access offered when a pairing is approved (ANDROID-PLAN 0.1.53 AA2 step 3, decision 5): every choice is a whole number
/// of seconds the vault takes (60 to 86,400), or none. Mirrors vettid-android `SessionChoice`.
public enum SessionChoice: CaseIterable, Sendable {
    case none, minutes15, hour1, hours4, hours8, hours24

    public var seconds: Int? {
        switch self {
        case .none: nil
        case .minutes15: 15 * 60
        case .hour1: 60 * 60
        case .hours4: 4 * 60 * 60
        case .hours8: 8 * 60 * 60
        case .hours24: 24 * 60 * 60
        }
    }
}

/// The pairing screens' state: the pairing's own, and what the screen adds. Holds the code, the digits and the name of a device:
/// nothing but the type is printed. Mirrors vettid-android `PairUiState`.
public struct PairState: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var pairing = PairingState()
    /// Opened from the feed item "A device asks to pair": with no pairing held, the phone can't check it any more.
    public var held = false
    /// The sheet "Allow access now?" is open (only over the very comparison it was opened for).
    public var sheet = false
    /// A pairing was shown and the state returned to nothing by itself (a lock, a hold): it was interrupted, nothing paired.
    public var interrupted = false
    public var session = SessionChoice.hour1
    /// The code was copied: the button says so.
    public var copied = false

    public init() {}

    public var stage: PairingStage { pairing.stage }

    public var description: String { "PairState" }
    public var debugDescription: String { "PairState" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Pairing an agent (ANDROID-PLAN 0.1.53 AA2) or a desktop (owner decision 2026-11-05). The pairing itself lives in
/// ``PairingRepository`` (memory only); this holds what the screen adds. Leaving the screen (the model going) with a pairing not
/// approved rejects it: an abandoned pairing grants nothing. Mirrors vettid-android `PairViewModel`.
@MainActor
@Observable
public final class PairViewModel {
    @ObservationIgnored private let repo: any PairingRepository
    @ObservationIgnored private let ownerChecks: (any OwnerCheckRepository)?
    @ObservationIgnored private let work = Work()
    @ObservationIgnored private let follows = TaskBag()
    @ObservationIgnored private let held: Bool
    @ObservationIgnored private let role: PairRole
    /// This screen, as the pairing's owner (``PairingRepository/start(_:owner:)``).
    @ObservationIgnored private let owner = ownerCounter.withLock { n -> Int in
        n += 1
        return n
    }

    public private(set) var state = PairState()

    private var local = PairState()
    /// The pairing the repository last said.
    @ObservationIgnored private var snapshot = PairingState()
    /// The pairing the sheet was opened for.
    @ObservationIgnored private var sheetFor: String?
    /// The role of the last pairing seen that was not nothing: a held screen (opened from a feed item) has no route role, and a
    /// cleared state (a lock, a hold) says agent whatever was held, so "New code" never takes its role from the repository.
    @ObservationIgnored private var seenRole: PairRole
    /// A stage other than nothing was seen, and the screen is not being closed.
    @ObservationIgnored private var sawStage = false
    @ObservationIgnored private var closing = false
    /// The pairing this screen saw (``PairingState/token``): read by `deinit`, which is not on the main actor.
    @ObservationIgnored private let own = OSAllocatedUnfairLock(initialState: Own())

    private struct Own {
        var token: Int?
    }

    /// [held]: opened from the feed item (what is held, never a new code; the held pairing says its own role). [desktop]: "Pair a
    /// desktop" rather than "Pair an agent". [ownerChecks]: the daily check passing clears a refused approval.
    public init(held: Bool = false, desktop: Bool = false, repo: any PairingRepository, ownerChecks: (any OwnerCheckRepository)? = nil) {
        self.held = held
        self.role = desktop ? .desktop : .agent
        self.seenRole = desktop ? .desktop : .agent
        self.repo = repo
        self.ownerChecks = ownerChecks
        local.held = held
        state.held = held
        // From the feed item the pairing is whatever is held; from the button, a new code (an unfinished one is kept).
        if !held {
            // A final stage or a failure of an earlier pairing is cleared; an expired code is left alone (a start rejects it).
            repo.acknowledge()
            // A pairing held for the other role is rejected and replaced by the repository in this one call.
            let (role, owner) = (role, owner)
            work.launch {
                // Not for a start whose screen is already gone (cancelled before it ran).
                guard !Task.isCancelled else { return }
                await repo.start(role, owner: owner)
            }
        } else {
            // The feed item's screen takes over what is held: the screen it came from can no longer end it.
            repo.claim(owner: owner)
        }
        follows.add(follow(self, read: { $0.repo.state }, apply: { $0.onPairing($1) }))
        // The daily check passed: a refused approval may be sent again.
        if ownerChecks != nil {
            follows.add(follow(self, read: { $0.ownerChecks?.ownerCheck?.state }, apply: { $0.onOwnerCheck($1) }))
        }
    }

    deinit {
        work.cancelAll()
        follows.cancelAll()
        // The screen is gone: a code not used or a comparison not answered is rejected (best effort), never kept.
        // Always leave the pairing this screen saw, whatever done() or cancel() did (some stages are not ended by them: a comparison
        // with an approval in flight, a code still being made), but only that one: a screen released late must not reach the pairing
        // of a newer one (the member leaves and opens Pair again).
        // A screen released before it saw any state still ends what it started (its owner alone decides then).
        let (repo, mine, owner) = (repo, own.withLock { $0.token }, owner)
        Task { @MainActor in Self.finish(repo, token: mine, owner: owner, leaving: true) }
    }

    /// What a new code is made for: the button's role, or for a held screen the role of what it last showed.
    private var codeRole: PairRole { held ? seenRole : role }

    private func onPairing(_ p: PairingState) {
        snapshot = p
        if p.stage != .idle {
            sawStage = true
            seenRole = p.role
        }
        // A pairing of this screen's: a stage of one, or a failure of its code.
        if p.stage != .idle || p.error != nil { own.withLock { $0.token = p.token } }
        recompute()
    }

    /// The state from the pairing, what the screen adds, the sheet and whether the screen is closing.
    private func recompute() {
        let p = snapshot
        var s = local
        // The screens say the role of what was shown, also once it was taken away (the lock's "This pairing has ended").
        s.pairing = p
        if p.stage == .idle { s.pairing.role = codeRole }
        if case .compare(let c) = p.stage, sheetFor == c.pairingID { s.sheet = true } else { s.sheet = false }
        s.interrupted = sawStage && !closing && p.stage == .idle && p.error == nil && !p.busy
        if s != state { state = s }
    }

    private func onOwnerCheck(_ check: OwnerCheckState?) {
        guard check == .ok, repo.state.error == .ownerCheckRequired, let token = own.withLock({ $0.token }) else { return }
        repo.acknowledge(token: token, owner: owner)
    }

    /// "New code", or "Try again" after a code could not be made.
    public func newCode() {
        local.copied = false
        sheetFor = nil
        sawStage = false
        recompute()
        let (repo, role, owner) = (repo, codeRole, owner)
        let token = own.withLock { $0.token }
        work.launch {
            // What the screen read of its last pairing is cleared, an expired code excepted: ``PairingRepository/start(_:owner:)``
            // rejects that one (clearing it first would leave nothing to reject).
            if let token, !Self.isExpired(repo.state.stage) { repo.acknowledge(token: token, owner: owner) }
            await repo.start(role, owner: owner)
        }
    }

    public func copied() {
        local.copied = true
        recompute()
    }

    /// Cancel on the code screen: the vault is told, nothing is held.
    public func cancel() {
        closing = true
        recompute()
        repo.leave(token: own.withLock { $0.token }, owner: owner)
    }

    /// **The codes match** for the comparison [pairingID] the screen shows: the sheet opens for that one, and only while it is the one
    /// held.
    public func codesMatch(pairingID: String) {
        if case .compare(let c) = repo.state.stage, c.pairingID == pairingID { sheetFor = pairingID } else { sheetFor = nil }
        recompute()
    }

    public func closeSheet() {
        sheetFor = nil
        recompute()
    }

    public func choose(_ c: SessionChoice) {
        local.session = c
        recompute()
    }

    public func pair() {
        // Only the comparison the sheet was opened for: a sheet of an older one never approves the new one.
        guard case .compare(let c) = repo.state.stage, sheetFor == c.pairingID else { return }
        let (repo, seconds) = (repo, local.session.seconds)
        let id = c.pairingID
        work.launch { await repo.approve(pairingID: id, sessionSeconds: seconds) }
    }

    /// "They don't match", and Reject for a pairing that cannot be compared.
    public func reject(pairingID: String) {
        sheetFor = nil
        recompute()
        let repo = repo
        work.launch { await repo.reject(pairingID: pairingID) }
    }

    /// A final stage was read.
    public func done() {
        closing = true
        recompute()
        Self.finish(repo, token: own.withLock { $0.token }, owner: owner, leaving: false)
    }

    /// The screen's end. A code that expired is still taken for a late answer for a minute, and the vault is told it is not wanted:
    /// that rejection (``PairingRepository/leave(token:owner:)``) is asked for before anything else, since acknowledging first would leave nothing
    /// held to reject. A pairing that was approved, rejected or ended is never rejected (nothing is held then: ``PairingRepository/leave(token:owner:)`` does nothing
    /// for it); a comparison or a live code is rejected when [leaving] (the model going), by the repository.
    private static func finish(_ repo: any PairingRepository, token: Int?, owner: Int, leaving: Bool) {
        // No state seen: only the owner can say what is this screen's.
        guard let token else {
            repo.leave(token: nil, owner: owner)
            return
        }
        switch repo.state.stage {
        // Not left to the model going: a screen that is popped is released late.
        case .codeExpired, .code, .compare, .creating:
            repo.leave(token: token, owner: owner)
            return
        default:
            break
        }
        if leaving { repo.leave(token: token, owner: owner) }
        repo.acknowledge(token: token, owner: owner)
    }

    private static func isExpired(_ stage: PairingStage) -> Bool {
        if case .codeExpired = stage { true } else { false }
    }

    /// TEST ONLY: returns once the work started so far has run.
    func settle() async { await work.settle() }
}
