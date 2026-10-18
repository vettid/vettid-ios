import Foundation

/// What the vault client may be used for while a lock is pending. Everything else is refused (``LockGuard/admits(_:)``).
/// Mirrors vettid-android `LockTimeUse`.
public enum LockTimeUse: Sendable {
    /// The lock itself.
    case lock
    /// A `call.end`: the hang-up of a call the lock ends, so that the other member is not left listening.
    case callEnd
}

/// What the member API said to a lock request. **None of these is proof that the vault locked** (VAULT-LOCK §2 F8).
/// Mirrors vettid-android `MemberLock`.
public enum MemberLock: Equatable, Sendable {
    /// The request's slot was answered, and whether as "done". The enclave reports "done" also when its lock failed.
    case answered(done: Bool)
    /// Still queued when the wait was over, or not sent at all (no network).
    case noAnswer
    /// `429`: no lock is to be asked of the member API again before [retryAfter] has passed.
    case limited(retryAfter: Duration)
}

/// The three ways the app reaches the vault for a lock. None of them throws for a vault that cannot be reached.
/// Mirrors vettid-android `LockPorts`.
@MainActor
public protocol LockPorts: AnyObject {
    /// How long the vault may act on a relay lock after it was sent (its `exp`).
    var relayValidFor: Duration { get }

    /// Sends `vault.lock` over the relay, once. True when the vault answered: it has locked.
    func relayLock() async -> Bool

    /// Asks the member API to have the vault locked, and waits a bounded time for its answer.
    func memberLock() async -> MemberLock

    /// The member API's status of the vault: true "unlocked", false anything else or no vault, nil not readable.
    func unlocked() async -> Bool?
}

/// The rules of a pending lock, in one place and behind ``LockPorts``, so that they can be tested. Mirrors vettid-android
/// `LockGuard`:
///
/// 1. **What confirms a lock** (``attempt(first:)``): the vault's own answer to the relay lock, or a status that does not
///    say "unlocked". The member API's answer to a lock request never does, whatever it says.
/// 2. **While a lock is pending this phone is locked whatever the status says** (``lockedWhatever(unlocked:)``).
/// 3. **While a lock is pending nothing is sent to the vault** but the lock and a pending `call.end` (``admits(_:)``).
/// 4. **While a lock is pending nothing the vault sends is taken into the app's lists** (``takesEvents()``).
@MainActor
public final class LockGuard {
    /// After the member API answered a lock request: the status is read this often, ``statusReadEvery`` apart.
    public nonisolated static let statusReadsAfterAnswer = 3
    public nonisolated static let statusReadEvery: Duration = .seconds(1)
    /// After a `429` without a usable `retry_after`.
    public nonisolated static let limitedAtLeast: Duration = .seconds(60)

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
        keeper = newKeeper { [weak self] first in await self?.attempt(first: first) ?? false }
    }

    public var pending: Bool { keeper.pending }

    /// One try. The relay lock is sent by the first attempt alone (a request that expires, never from the outbox: a
    /// retry must not leave lock requests on their way that could reach a vault opened again). Every attempt asks the
    /// member API, unless it said `429` and its time is not over, and then reads the status, which decides.
    public func attempt(first: Bool) async -> Bool {
        if first {
            keeper.relayLockSent(validFor: ports.relayValidFor)
            if await ports.relayLock() {
                keeper.relayLockAnswered()
                return true
            }
        }
        var reads = 1
        if now() >= noMemberLockBefore {
            switch await ports.memberLock() {
            case .limited(let after):
                let wait = max(after, Self.limitedAtLeast)
                noMemberLockBefore = now().addingTimeInterval(Double(wait.milliseconds) / 1000)
            case .answered:
                // An answered request: the status may take a moment to follow.
                reads = Self.statusReadsAfterAnswer
            case .noAnswer:
                break
            }
        }
        for n in 0..<reads {
            if n > 0 { try? await sleep(Self.statusReadEvery) }
            if await ports.unlocked() == false { return true }
        }
        return false
    }

    /// For the phase: true when this phone is locked **whatever the status says** (a lock is pending). A status that does
    /// not say "unlocked" ([unlocked] false) confirms the lock on the way; one that could not be read (nil) confirms
    /// nothing. [since]: the keeper's ``LockKeeper/evidenceMark`` taken before the status was read; a status read across an
    /// unlock confirms nothing.
    public func lockedWhatever(unlocked: Bool?, since: Int? = nil) -> Bool {
        guard keeper.pending else { return false }
        if unlocked == false { keeper.confirmed(since: since) }
        return true
    }

    /// Whether the vault client may be used: for an operation on the open vault ([use] nil) only while no lock is
    /// pending; for a ``LockTimeUse`` always.
    public func admits(_ use: LockTimeUse? = nil) -> Bool { use != nil || !keeper.pending }

    /// Whether what the vault sends is taken into the app's lists: not while a lock is pending.
    public func takesEvents() -> Bool { !keeper.pending }
}
