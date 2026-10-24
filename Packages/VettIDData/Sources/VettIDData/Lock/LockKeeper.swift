import Foundation
import Observation

/// What the phone keeps, durably, about the member's lock. Mirrors vettid-android `LockRecord`.
///
/// - [pendingSinceMs]: a lock was asked for and the vault has not confirmed it. Written **before anything else happens**
///   for the lock (before the hooks that run ahead of it, before the first attempt) and removed only when the lock is
///   confirmed or an unlock made after it succeeded: a process that dies in between starts locked and goes on trying.
/// - [relayLockUntilMs]: a `vault.lock` was sent over the relay, got no answer, and may be acted on by the vault until
///   then (its `exp`, plus a margin). It outlives the confirmation of the lock: the request may still be waiting in the
///   mailbox of the vault, which collects again at the next unlock. No unlock is sent before it.
///   (Release L) Only for a lock not bound to its unlock: a bound one that arrives late is answered `stale_lock`.
/// - [unlockID] (VAULT-MESSAGING 0.56.4 §10.2 "Locks", release L): the unlock the pending lock ends, from the vault's own
///   word (the enroll, unlock or recovery-open result, or `vault.status`). With it the lock is **bound**: every attempt names
///   it, over the relay and through the member API, and a process started later goes on with the same bound lock. Nil: a
///   vault before L, or a phone that did not hold the value; the lock is then made as before L.
/// - [held] (release L): the last lock ended because the vault was opened again since (``LockNotice/openedAgain``): the
///   phone stays locked, also in a later process, until an unlock on this phone succeeds (or the vault is no longer this
///   phone's). [heldConfirmed]: held, and since confirmed locked after all (``LockNotice/confirmedLate``): a new process
///   says nothing new.
public struct LockRecord: Equatable, Sendable {
    public var pendingSinceMs: Int64?
    public var relayLockUntilMs: Int64?
    public var unlockID: String?
    public var held: Bool
    public var heldConfirmed: Bool

    public init(
        pendingSinceMs: Int64? = nil, relayLockUntilMs: Int64? = nil, unlockID: String? = nil, held: Bool = false,
        heldConfirmed: Bool = false
    ) {
        self.pendingSinceMs = pendingSinceMs
        self.relayLockUntilMs = relayLockUntilMs
        self.unlockID = unlockID
        self.held = held
        self.heldConfirmed = heldConfirmed
    }
}

/// Where ``LockRecord`` is kept (``LockRecordFile`` in the app).
@MainActor
public protocol LockRecordStore: AnyObject {
    func load() -> LockRecord

    /// Writes [record]. Durable when it returns.
    func save(_ record: LockRecord) throws
}

/// What one try to lock the vault found out.
public enum LockOutcome: Equatable, Sendable {
    /// The vault is known to be locked: the lock is confirmed.
    case locked
    /// (Release L) The vault runs under a newer unlock than the one the lock was for: the lock is over, not confirmed.
    case openedAgain
    /// Nothing that decides: the lock stays pending and is tried again.
    case unconfirmed
}

/// One try to lock the vault: tells the vault to lock and says what is **known** now. [first] is the attempt made at once
/// when the member asked; later ones are retries. [unlockID]: the unlock the lock is bound to (``LockRecord/unlockID``), nil
/// for a lock made as before release L. A throw is an attempt that did not confirm.
public typealias LockAttempt = @MainActor (_ first: Bool, _ unlockID: String?) async throws -> LockOutcome

/// The member's lock, made to **fail secure** (owner decision 2026-10-12, VAULT-LOCK §2 F13): the phone is locked from
/// the moment the member asks, in every outcome; the vault is *known* locked only on evidence; until then the lock is
/// pending, durably, and is tried again until it is confirmed. Mirrors vettid-android `LockKeeper`.
///
/// - ``begin()`` makes the lock pending, durably, before anything else is done for it. ``ask(_:)`` then makes the first
///   attempt and starts the retries if it did not confirm, in a task of its own: a caller that goes away does not stop
///   it.
/// - ``resume()`` is for a process start: a record found means the phone starts locked and the retries start at once.
/// - ``confirmed()`` is for evidence from elsewhere (the vault's own `vault.locking`, a status read).
/// - ``unlocking(opened:_:)`` is the only way to unlock while this class is in use. Lock attempts and unlocks never
///   overlap, and after an unlock that succeeded no attempt of a lock asked for before it is ever made. An unlock that
///   fails leaves the pending lock as it was, and so does one that succeeds after a **newer** lock was asked for.
/// - An unlock first waits out an unanswered relay lock (``relayLockSent(validFor:)``), pending or not.
///
/// Retries: [backoff] after each failed attempt, and at once on ``retryNow()`` (the member's "Try again"), honoured once
/// in [retryNowEvery] at most. **A record that cannot be saved never stops a lock**: the failure is only reported
/// ([onSaveFailed]). **Retries live in this process**; ``resume()`` goes on after a restart, bound to the same unlock as before
/// (``LockRecord/unlockID``).
@MainActor
@Observable
public final class LockKeeper {
    /// Added to a relay lock's validity before an unlock may follow it: the clocks of phone and vault differ.
    public nonisolated static let relayMargin: Duration = .seconds(10)
    /// The longest an unlock waits for an unanswered relay lock (a clock set back must not hold it longer).
    public nonisolated static let settleMax: Duration = .seconds(60)
    /// The member's "Try again" starts a try once in this time at most.
    public nonisolated static let retryNowEvery: Duration = .seconds(10)

    /// What to tell the member; ``LockNotice/unconfirmed(askedAt:attempts:)`` exactly while a lock is pending.
    public private(set) var notice: LockNotice = .none

    @ObservationIgnored private let store: any LockRecordStore
    @ObservationIgnored private let attempt: LockAttempt
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let backoff: @Sendable (Int) -> Duration
    @ObservationIgnored private let retryEvery: Duration
    @ObservationIgnored private let margin: Duration
    @ObservationIgnored private let sleep: LockSleep
    @ObservationIgnored private let onSaveFailed: @MainActor (any Error) -> Void
    @ObservationIgnored private let onOpenedAgain: @MainActor (String?) -> Void
    @ObservationIgnored private let gate = AsyncGate()
    @ObservationIgnored private let kick = KickableWait()
    @ObservationIgnored private var retries: Task<Void, Never>?
    @ObservationIgnored private var kickedAt: Date?
    /// The number of the lock that is pending; changed by every begin, every confirmation and every superseding unlock.
    @ObservationIgnored private var epoch = 0
    /// An unanswered relay lock's time, kept here too: a record that could not be saved still holds an unlock.
    @ObservationIgnored private var relayUntilMs: Int64?
    /// How many locks were asked for: an unlock supersedes only those asked for before it began.
    @ObservationIgnored private var asks = 0
    /// The unlock the pending lock is bound to (``LockRecord/unlockID``); kept here too, beside the record.
    @ObservationIgnored private var boundTo: String?
    /// (Release L) The lock ended as ``LockNotice/openedAgain``: this phone stays locked until an unlock here.
    @ObservationIgnored private var held = false
    /// (Release L) The opening the last lock was bound to when the vault said it was over (`stale_lock`, slot `stale`): a
    /// `vault.locking` naming it is an old opening's and confirms nothing (``deadUnlockID``). Ends with the next unlock here.
    @ObservationIgnored private var dead: String?
    /// When an attempt (or the retries' first one) last began, and whether one runs: the foreground does not start a second.
    @ObservationIgnored private var attemptRunning = false
    @ObservationIgnored private var attemptBeganAt: Date?
    /// While an unlock runs: ``asks`` when it began. Evidence from elsewhere does not confirm a lock asked after that:
    /// every unlock first locks a running vault (VAULT-MESSAGING §11.4), so its `vault.locking` and a status read during
    /// it say "locked" about the lock the unlock itself makes, which the unlock then opens again.
    @ObservationIgnored private var unlockBeganAt: Int?
    /// Bumped when an unlock begins and when it ends: evidence read before a change of it (``evidenceMark``) is not used.
    @ObservationIgnored private var unlockChanges = 0
    /// A lock begun whose first attempt has not ended yet (the app's background task waits for it), and who waits.
    @ObservationIgnored private var firstOutstanding = false
    @ObservationIgnored private var firstWaiters: [KickableWait] = []

    public init(
        store: any LockRecordStore,
        attempt: @escaping LockAttempt,
        now: @escaping @Sendable () -> Date = { Date() },
        backoff: @escaping @Sendable (Int) -> Duration = LockKeeper.defaultBackoff,
        retryNowEvery: Duration = LockKeeper.retryNowEvery,
        relayMargin: Duration = LockKeeper.relayMargin,
        sleep: @escaping LockSleep = realLockSleep,
        onSaveFailed: @escaping @MainActor (any Error) -> Void = { _ in },
        onOpenedAgain: @escaping @MainActor (String?) -> Void = { _ in }
    ) {
        self.onOpenedAgain = onOpenedAgain
        self.store = store
        self.attempt = attempt
        self.now = now
        self.backoff = backoff
        retryEvery = retryNowEvery
        margin = relayMargin
        self.sleep = sleep
        self.onSaveFailed = onSaveFailed
    }

    /// A lock was asked for and is not confirmed: the vault must be treated as locked, and may be open.
    public var pending: Bool {
        if case .unconfirmed = notice { return true }
        return false
    }

    /// This phone is to stay locked whatever the vault's status says: a lock is ``pending``, or (release L) one ended because
    /// the vault was opened again since (``LockNotice/openedAgain``; until an unlock on this phone succeeds, whether or not
    /// the member dismissed the notice). Kept on the phone (``LockRecord/held``): a new process starts held too.
    public var holdsPhone: Bool { pending || held }

    /// The unlock the pending lock is bound to; nil without a pending lock, or for one made as before release L.
    public var boundUnlockID: String? { pending ? boundTo : nil }

    /// (Release L) The unlock the last lock was bound to when it ended as ``LockNotice/openedAgain``, until an unlock here
    /// succeeds: the vault is no longer under it.
    public var deadUnlockID: String? { dead }

    /// (Release L) The last lock ended as ``LockNotice/openedAgain``, and no unlock here followed: not known locked.
    public var openedAgain: Bool { held }

    private var nowMs: Int64 { Int64((now().timeIntervalSince1970 * 1000).rounded(.down)) }

    /// At a process start: a lock that was pending when the process ended is pending now, and is tried again at once. It
    /// is shown as in doubt from the start: it was not confirmed for as long as the process was gone.
    public func resume() {
        let r = store.load()
        // (Release L) A lock that ended as "opened again": this phone is still locked, whatever the status says, and the
        // member is told again (the unlock screen's card).
        if r.held {
            held = true
            if !pending && !r.heldConfirmed { notice = .openedAgain }
        }
        guard let since = r.pendingSinceMs, !pending else { return }
        epoch += 1
        asks += 1
        // The retries' first attempt starts at once: the foreground return of the same start does not make another.
        attemptBeganAt = now()
        boundTo = r.unlockID
        notice = .unconfirmed(askedAt: Date(timeIntervalSince1970: Double(since) / 1000), attempts: 1)
        startRetries(epoch, atOnce: true)
    }

    /// The member asks for a lock: pending from here on, in this process and then durably, before anything is sent and
    /// before anything else is done for the lock. Returns the lock's number, for ``ask(_:)``. [unlockID] (release L): the
    /// vault's current unlock as this phone knows it, to which the lock is bound; nil makes the lock as before L.
    @discardableResult
    public func begin(unlockID: String? = nil) -> Int {
        retries?.cancel()
        retries = nil
        let t = now()
        boundTo = unlockID
        notice = .unconfirmed(askedAt: t, attempts: 0)
        asks += 1
        epoch += 1
        firstOutstanding = true
        let ms = nowMs
        write { r in
            var r = r
            r.pendingSinceMs = ms
            r.unlockID = unlockID
            return r
        }
        return epoch
    }

    /// (Release L, "Lock it now") Binds the lock [mine], begun unbound, to [unlockID] before its first attempt; nothing if
    /// another lock or an unlock took its place meanwhile. Nil leaves it unbound (as before L). [since]: the ``evidenceMark``
    /// taken before the opening was read; an unlock that began or ended since, or is running, names the opening itself
    /// (``unlocking(opened:unlockIDOf:_:)`` binds a lock asked meanwhile to it), and a value read before it is not used.
    public func rebind(_ mine: Int, to unlockID: String?, since: Int? = nil) {
        guard epoch == mine, pending, let unlockID else { return }
        if let since, since != unlockChanges { return }
        if unlockBeganAt != nil { return }
        boundTo = unlockID
        write { r in
            var r = r
            r.unlockID = unlockID
            return r
        }
    }

    /// The first attempt of the lock [mine] that ``begin()`` made pending (nil: begins now), in a task of its own. True
    /// when the vault is known to be locked after it; otherwise the lock stays pending and is tried again.
    @discardableResult
    public func ask(_ mine: Int? = nil) async -> Bool {
        let m = mine ?? begin()
        let task = Task { @MainActor [self] in
            let over = await tryOnce(m, first: true)
            if !over, epoch == m, pending { startRetries(m, atOnce: false) }
            // Over because the vault was opened again since: not locked.
            return over && !held
        }
        let ok = await task.value
        firstAttemptEnded()
        return ok
    }

    private func firstAttemptEnded() {
        firstOutstanding = false
        for w in firstWaiters { w.kick() }
        firstWaiters = []
    }

    /// Waits for the first attempt of the last lock asked for, if one runs (IOS-PLAN §6.6: a lock request is finished
    /// before the app leaves the foreground). The caller bounds the wait.
    public func firstAttemptDone() async {
        guard firstOutstanding else { return }
        let w = KickableWait()
        firstWaiters.append(w)
        await w.wait(.seconds(3600), sleep: sleep)
    }

    /// Evidence from elsewhere that the vault is locked (its `vault.locking`, a status read): a pending lock is confirmed.
    /// The mark to take before awaiting evidence (a status read) and to pass to ``confirmed(since:)``.
    public var evidenceMark: Int { unlockChanges }

    /// [since]: the ``evidenceMark`` taken before the evidence was awaited. Evidence produced while an unlock ran, or
    /// across one, is not used: it may be that unlock's own lock, and its answer may arrive after the unlock ended.
    public func confirmed(since: Int? = nil) {
        if let since, since != unlockChanges { return }
        // A lock asked while an unlock runs: what says "locked" now is that unlock's own lock (see ``unlockBeganAt``).
        if let began = unlockBeganAt, asks > began { return }
        if case .unconfirmed(_, let n) = notice {
            confirm(late: n > 0)
        } else if held, notice == .openedAgain {
            // (Release L) Held after "opened again", and now locked after all: said so. The phone stays held (an unlock here
            // ends that), and the record keeps it.
            notice = .confirmedLate
            write { r in
                var r = r
                r.heldConfirmed = true
                return r
            }
        }
    }

    /// Tries again now (the member's "Try again"). Nothing happens without a pending lock, and nothing more than once in
    /// [retryNowEvery]. Returns whether a try was started.
    @discardableResult
    public func retryNow() -> Bool {
        retry(consuming: true)
    }

    /// The return to the foreground (and the start of the process): a pending lock is tried at once, unless an attempt runs or
    /// began less than [retryNowEvery] ago, and without using up the member's "Try again" (``retryNow()``).
    @discardableResult
    public func retryOnForeground() -> Bool {
        if attemptRunning { return false }
        if let began = attemptBeganAt, now().timeIntervalSince(began) < Double(retryEvery.milliseconds) / 1000 { return false }
        return retry(consuming: false)
    }

    private func retry(consuming: Bool) -> Bool {
        let t = now()
        if !pending { return false }
        if let last = kickedAt, t.timeIntervalSince(last) < Double(retryEvery.milliseconds) / 1000 { return false }
        if consuming { kickedAt = t }
        kick.kick()
        return true
    }

    /// A `vault.lock` goes out over the relay now and may be acted on for [validFor]: recorded durably **before** it is
    /// sent, with the margin added, so that no unlock is sent while it could still reach the vault.
    public func relayLockSent(validFor: Duration) {
        let until = nowMs + validFor.milliseconds + margin.milliseconds
        relayUntilMs = until
        write { r in
            var r = r
            r.relayLockUntilMs = until
            return r
        }
    }

    /// The vault answered the relay lock: it has acted on it, nothing of it is on its way any more.
    public func relayLockAnswered() {
        relayUntilMs = nil
        write { r in
            var r = r
            r.relayLockUntilMs = nil
            return r
        }
    }

    /// The vault is no longer this phone's (erased, deleted, forgotten): the pending lock, its record and its notice go.
    public func abandon() {
        firstAttemptEnded()
        epoch += 1
        retries?.cancel()
        retries = nil
        boundTo = nil
        held = false
        dead = nil
        relayUntilMs = nil
        write { $0 != LockRecord() ? LockRecord() : nil }
        notice = .none
    }

    /// The member has read ``LockNotice/confirmedLate`` or ``LockNotice/openedAgain``. The phone stays locked after the
    /// second all the same (``holdsPhone``): only an unlock here ends that.
    public func dismissConfirmed() {
        if notice == .confirmedLate || notice == .openedAgain { notice = .none }
    }

    /// Runs an unlock. No lock attempt runs beside it. Before it, an unanswered relay lock is waited out, pending or not.
    /// If [opened] says the unlock succeeded, a lock asked for before it began is over and none of its attempts will
    /// ever be made.
    /// [unlockIDOf] (release L) names the opening a successful unlock made: a lock asked for while it was on its way is bound
    /// to that one, never to the one the unlock ended (a lock bound to it would be answered `stale_lock` and leave this
    /// opening open).
    public func unlocking<T>(
        opened: (T) -> Bool, unlockIDOf: (T) -> String? = { _ in nil }, _ unlock: @MainActor () async throws -> T
    ) async rethrows -> T {
        try await gate.withLock {
            let before = asks
            unlockBeganAt = before
            unlockChanges += 1
            defer {
                unlockBeganAt = nil
                unlockChanges += 1
            }
            let wait = settle()
            if wait > 0 { try? await sleep(.milliseconds(wait)) }
            let result = try await unlock()
            // A lock asked for while this unlock was on its way is newer than it: it stays, and is tried next.
            if opened(result) {
                dead = nil
                if asks == before {
                    epoch += 1
                    retries?.cancel()
                    retries = nil
                    boundTo = nil
                    held = false
                    relayUntilMs = nil
                    write { $0 != LockRecord() ? LockRecord() : nil }
                    notice = .none
                } else if pending {
                    let id = unlockIDOf(result)
                    boundTo = id
                    held = false
                    write { r in
                        var r = r
                        r.unlockID = id
                        r.held = false
                        r.heldConfirmed = false
                        return r
                    }
                }
            }
            return result
        }
    }

    /// How long an unanswered relay lock may still be acted on, in ms (never more than ``settleMax``).
    private func settle() -> Int64 {
        let until = [store.load().relayLockUntilMs, relayUntilMs].compactMap { $0 }.max()
        guard let until else { return 0 }
        return min(max(until - nowMs, 0), Self.settleMax.milliseconds)
    }

    /// One attempt of lock [mine], unless it is no longer the pending one. True when the lock is over: confirmed, or (release
    /// L) ended because the vault was opened again since (``LockNotice/openedAgain``).
    private func tryOnce(_ mine: Int, first: Bool) async -> Bool {
        await gate.withLock {
            if epoch != mine || !pending { return !pending }
            let bound = boundTo
            attemptRunning = true
            attemptBeganAt = now()
            defer { attemptRunning = false }
            let outcome: LockOutcome
            do {
                outcome = try await attempt(first, bound)
            } catch {
                outcome = .unconfirmed
            }
            if Task.isCancelled && outcome == .unconfirmed { return !pending }
            guard epoch == mine, case .unconfirmed(let at, let n) = notice else { return !pending }
            switch outcome {
            // Confirmed before anything failed: the member was never told otherwise.
            case .locked: confirm(late: n > 0)
            case .openedAgain:
                end(.openedAgain)
                // The opening this lock was bound to is over: forgotten by the device, and its late notices confirm nothing.
                dead = bound
                onOpenedAgain(bound)
            case .unconfirmed: notice = .unconfirmed(askedAt: at, attempts: n + 1)
            }
            return outcome != .unconfirmed
        }
    }

    private func confirm(late: Bool) { end(late ? .confirmedLate : .none) }

    /// The pending lock is over with [notice]; nothing of it is tried again.
    private func end(_ notice: LockNotice) {
        epoch += 1
        retries?.cancel()
        retries = nil
        boundTo = nil
        held = notice == .openedAgain
        let kept = held
        // The relay lock's time stays: its request may still be waiting for the vault. Held is kept on the phone too.
        write { r in
            var r = r
            r.pendingSinceMs = nil
            r.unlockID = nil
            r.held = kept
            r.heldConfirmed = false
            return r
        }
        self.notice = notice
    }

    /// Saves [change] of the record (nil: nothing to save); a failure is reported, never thrown: the lock goes on.
    private func write(_ change: (LockRecord) -> LockRecord?) {
        do {
            if let r = change(store.load()) { try store.save(r) }
        } catch {
            onSaveFailed(error)
        }
    }

    /// Tries until confirmed or replaced: [atOnce] (a process start) or after the first backoff (a failed first attempt).
    private func startRetries(_ mine: Int, atOnce: Bool) {
        retries?.cancel()
        kick.reset()
        retries = Task { @MainActor [weak self] in
            var n = 0
            var wait = !atOnce
            while !Task.isCancelled {
                guard let self else { return }
                if wait { await kick.wait(backoff(n), sleep: sleep) }
                if Task.isCancelled { return }
                wait = true
                if await tryOnce(mine, first: false) { return }
                if epoch != mine { return }
                n += 1
            }
        }
    }

    // MARK: - Backoff

    private nonisolated static let quick: [Int64] = [1, 2, 5, 10]
    private nonisolated static let slowSeconds: Int64 = 30
    private nonisolated static let slowTimes = 4
    private nonisolated static let steadySeconds: Int64 = 60
    private nonisolated static let jitter = 0.2

    /// The wait before retry number [attempts], without jitter: 1, 2, 5, 10 s, four times 30 s, then every 60 s.
    public nonisolated static func backoffBase(_ attempts: Int) -> Duration {
        if attempts < quick.count { return .seconds(quick[attempts]) }
        return .seconds(attempts < quick.count + slowTimes ? slowSeconds : steadySeconds)
    }

    /// ``backoffBase(_:)``, each wait up to a fifth longer so that phones do not retry in step. Every retry is one
    /// `POST /api/vault/lock`, which the member API allows 30 times in 15 minutes per member: this makes at most 21 in
    /// the first 15 minutes and 15 in every 15 minutes after.
    public nonisolated static func defaultBackoff(_ attempts: Int) -> Duration {
        let base = backoffBase(attempts).milliseconds
        return .milliseconds(base + Int64(Double(base) * jitter * Double.random(in: 0..<1)))
    }
}
