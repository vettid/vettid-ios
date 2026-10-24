import Foundation
import VettIDAltChan

/// What the vault client may be used for while a lock is pending. Everything else is refused (``LockGuard/admits(_:)``).
/// Mirrors vettid-android `LockTimeUse`.
public enum LockTimeUse: Sendable {
    /// The lock itself.
    case lock
    /// A `call.end`: the hang-up of a call the lock ends, so that the other member is not left listening.
    case callEnd
    /// (Release L, "Lock it now") One `vault.status`, read to bind the fresh lock to the opening running now. A read; only
    /// its `unlock_id` is used.
    case lockStatus
}

/// What the member API said to a lock request. **For a lock made as before release L none of these is proof that the vault
/// locked** (VAULT-LOCK §2 F8). For a bound lock (release L) the slot's [code] is the host's word, which the app takes
/// (VAULT-LOCK L6): `locked` and `not_running` confirm, `stale` ends the lock. Mirrors vettid-android `MemberLock`.
public enum MemberLock: Equatable, Sendable {
    /// The request's slot was answered, and whether as "done". A release before L reports "done" also when its lock failed,
    /// and with no [code]; from release L "done" carries `locked`, `not_running` or `stale`.
    case answered(done: Bool, code: String? = nil)
    /// Still queued when the wait was over, or not sent at all (no network).
    case noAnswer
    /// `429`: no lock is to be asked of the member API again before [retryAfter] has passed.
    case limited(retryAfter: Duration)
}

/// The vault's own answer to `vault.lock` over the relay. Mirrors vettid-android `RelayLock`.
public enum RelayLock: Equatable, Sendable {
    /// `{}`: the vault locks (after the batch).
    case locked
    /// (Release L) `stale_lock`: the unlock named is not the vault's current one; nothing was done.
    case stale
    /// No answer in time, or an error that says nothing of the lock.
    case noAnswer
}

/// The three ways the app reaches the vault for a lock. None of them throws for a vault that cannot be reached.
/// Mirrors vettid-android `LockPorts`.
@MainActor
public protocol LockPorts: AnyObject {
    /// How long the vault may act on a relay lock after it was sent (its `exp`).
    var relayValidFor: Duration { get }

    /// Sends `vault.lock` over the relay, once: with [unlockID] a bound lock (release L, `vault.lock {unlock_id}`), without
    /// the lock of a vault before L.
    func relayLock(unlockID: String?) async -> RelayLock

    /// Asks the member API to have the vault locked ([unlockID]: bound, release L), and waits a bounded time for its answer.
    func memberLock(unlockID: String?) async -> MemberLock

    /// The member API's status of the vault: true "unlocked", false anything else or no vault, nil not readable.
    func unlocked() async -> Bool?
}

/// The rules of a pending lock, in one place and behind ``LockPorts``, so that they can be tested. Mirrors vettid-android
/// `LockGuard`:
///
/// 1. **What confirms a lock** (``attempt(first:unlockID:)``): the vault's own answer to the relay lock, or a status that
///    does not say "unlocked". For a lock made as before release L the member API's answer to a lock request never does,
///    whatever it says. For a lock bound to its unlock (release L, VAULT-MESSAGING §10.2 "Locks") also the slot's `locked`
///    and `not_running`; and the vault's `stale_lock` or the slot's `stale` end the lock **without confirming it** (the
///    vault was opened again since), unless a status read then says it is locked after all.
/// 2. **While a lock is pending this phone is locked whatever the status says** (``lockedWhatever(unlocked:since:)``).
/// 3. **While a lock is pending nothing is sent to the vault** but the lock, a pending `call.end` and (release L, "Lock it
///    now") the one `vault.status` that names the opening the fresh lock is bound to (``admits(_:)``).
/// 4. **While a lock is pending nothing the vault sends is taken into the app's lists** (``takesEvents()``).
@MainActor
public final class LockGuard {
    /// After the member API answered a lock request: the status is read this often, ``statusReadEvery`` apart.
    public nonisolated static let statusReadsAfterAnswer = 3
    public nonisolated static let statusReadEvery: Duration = .seconds(1)
    /// After a `429` without a usable `retry_after`.
    public nonisolated static let limitedAtLeast: Duration = .seconds(60)
    /// (Release L) A bound lock's slot codes that confirm it: the host says the vault is locked, or was not running.
    public nonisolated static let confirmingCodes: Set<String> = [Slot.codeLocked, Slot.codeNotRunning]

    /// The lock's state, record and retries.
    public private(set) var keeper: LockKeeper!
    private let ports: any LockPorts
    private let now: @Sendable () -> Date
    private let sleep: LockSleep
    private var noMemberLockBefore: Date = .distantPast

    /// [newKeeper] builds the keeper with the attempt this guard makes.
    public init(
        ports: any LockPorts,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping LockSleep = realLockSleep,
        newKeeper: (@escaping LockAttempt) -> LockKeeper
    ) {
        self.ports = ports
        self.now = now
        self.sleep = sleep
        keeper = newKeeper { [weak self] first, unlockID in await self?.attempt(first: first, unlockID: unlockID) ?? .unconfirmed }
    }

    public var pending: Bool { keeper.pending }

    /// This phone is locked whatever the status says: a lock is pending, or one ended because the vault was opened again
    /// since (``LockKeeper/holdsPhone``).
    public var holdsPhone: Bool { keeper.holdsPhone }

    /// One try, for a lock bound to [unlockID] (release L) or, with nil, made as before L (vettid-android #127):
    ///
    /// - **Before L** (and for a phone that does not hold the value of a vault that announced one, VAULT-LOCK Q3): the relay
    ///   lock is sent by the first attempt alone (a request that expires, never from the outbox: a retry must not leave lock
    ///   requests on their way that could reach a vault opened again), and is recorded first so that the next unlock waits
    ///   it out. Every attempt asks the member API, unbound, unless it said `429` and its time is not over, and then reads
    ///   the status, which decides. The member API's answer never confirms.
    /// - **Bound:** the relay lock names the unlock and is sent by every attempt (a late copy is answered `stale_lock`, so
    ///   nothing is recorded and no unlock waits for it; §8.6); the member API's lock names it too, and its slot's code is
    ///   read.
    public func attempt(first: Bool, unlockID: String? = nil) async -> LockOutcome {
        let bound = unlockID != nil
        if bound || first, let outcome = await relayStep(unlockID) { return outcome }
        var reads = 1
        if now() >= noMemberLockBefore {
            let step = await memberStep(unlockID)
            if let outcome = step.settled { return outcome }
            reads = step.reads
        }
        for n in 0..<reads {
            if n > 0 { try? await sleep(Self.statusReadEvery) }
            if await ports.unlocked() == false { return .locked }
        }
        return .unconfirmed
    }

    /// The member API's lock of one attempt: what it settles (a bound lock's `locked`, `not_running` or `stale`), else how often
    /// the status is read after it.
    private func memberStep(_ unlockID: String?) async -> (settled: LockOutcome?, reads: Int) {
        let bound = unlockID != nil
        switch await ports.memberLock(unlockID: unlockID) {
        case .limited(let after):
            let wait = max(after, Self.limitedAtLeast)
            noMemberLockBefore = now().addingTimeInterval(Double(wait.milliseconds) / 1000)
            return (nil, 1)
        case .answered(let done, let code):
            guard bound, done, let code else { return (nil, Self.statusReadsAfterAnswer) }
            if Self.confirmingCodes.contains(code) { return (.locked, 0) }
            if code == Slot.codeStale { return (await afterStale(), 0) }
            // An answered request without a code that decides: the status may take a moment to follow.
            return (nil, Self.statusReadsAfterAnswer)
        case .noAnswer:
            return (nil, 1)
        }
    }

    /// The relay lock of one attempt: what it settles (the vault's `{}`, or a `stale_lock` to a bound lock), nil when it settles
    /// nothing.
    private func relayStep(_ unlockID: String?) async -> LockOutcome? {
        let bound = unlockID != nil
        if !bound { keeper.relayLockSent(validFor: ports.relayValidFor) }
        switch await ports.relayLock(unlockID: unlockID) {
        case .locked:
            if !bound { keeper.relayLockAnswered() }
            return .locked
        // Only a bound lock can be stale; to an unbound one the answer is not the vault's word on it.
        case .stale where bound:
            return await afterStale()
        case .stale, .noAnswer:
            return nil
        }
    }

    /// The unlock the lock was for is over (the vault was opened again since): the lock is finished, and the status says what
    /// is true now. Not "unlocked" (locked since, or no vault running): confirmed. Otherwise it is not known to be locked and
    /// the member is told so (``LockNotice/openedAgain``).
    private func afterStale() async -> LockOutcome {
        await ports.unlocked() == false ? .locked : .openedAgain
    }

    /// For the phase: true when this phone is locked **whatever the status says** (a lock is pending, or one ended because the
    /// vault was opened again since, ``LockKeeper/holdsPhone``). A status that does not say "unlocked" ([unlocked] false)
    /// confirms a pending lock on the way; one that could not be read (nil) confirms nothing. [since]: the keeper's
    /// ``LockKeeper/evidenceMark`` taken before the status was read; a status read across an unlock confirms nothing.
    public func lockedWhatever(unlocked: Bool?, since: Int? = nil) -> Bool {
        guard keeper.holdsPhone else { return false }
        // A pending lock confirmed, or (release L) "opened again" replaced by "locked" once the status says so.
        if unlocked == false { keeper.confirmed(since: since) }
        return true
    }

    /// Whether the vault client may be used: for an operation on the open vault ([use] nil) only while this phone is not held
    /// locked (``LockKeeper/holdsPhone``); for a ``LockTimeUse`` always.
    public func admits(_ use: LockTimeUse? = nil) -> Bool { use != nil || !keeper.holdsPhone }

    /// Whether what the vault sends is taken into the app's lists: not while this phone is held locked.
    public func takesEvents() -> Bool { !keeper.holdsPhone }
}
