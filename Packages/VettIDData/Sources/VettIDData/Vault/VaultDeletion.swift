import Foundation
import VettIDAltChan

/// (IOS-PLAN §4.2) A vault being deleted, as the screens see it: since when (the `device.unlinked{vault_deleted}`, or
/// the answer to this phone's own `vault.delete`, that started it), the bound until which the app re-reads the member
/// API's status on its own, and whether the bound has passed ("Still finishing", with Check again). Mirrors
/// ANDROID-PLAN §4 "A vault being deleted".
public struct VaultDeletion: Equatable, Sendable {
    public var since: Date
    public var until: Date
    /// The bound passed with the vault still listed: the neutral "still finishing" text and Check again.
    public var slow: Bool

    public init(since: Date, until: Date, slow: Bool = false) {
        self.since = since
        self.until = until
        self.slow = slow
    }
}

/// What one read of `GET /api/vault/status` says of a vault being deleted (IOS-PLAN §4.2 point 3).
public enum DeletionRead: Equatable, Sendable {
    /// A definite word that the vault is gone. Nothing reads it yet (owner decision, 2026-10-24): neither `{vault: null}`
    /// (advisory) nor a bare `401` (the member API gives the same one for the timestamp, nonce, signature and other
    /// faults) is definite. The `410 vault_deleted` of MEMBER-API "Vault deletion" is meant for this; it is not read yet.
    case gone
    /// The vault is still listed, whatever its `state`.
    case listed
    /// The member API answered, but not definitely: `{vault: null}` (advisory), a `401` of any kind or a `403`. This
    /// phone cannot tell a deleted vault from a clock, nonce, signature or key fault, so nothing is erased.
    case unconfirmed
    /// As ``unconfirmed``, and the `401` was for the phone's clock (a date and time hint is shown). Never erases.
    case unconfirmedClock
    /// The member API could not be reached (network, timeout, 5xx, paused, or anything else): nothing is concluded.
    case unreachable

    /// What an answer of the status says: a listed vault is listed, `{vault: null}` is unconfirmed, and a paused
    /// service concludes nothing. Never ``gone``.
    static func of(vaultListed: Bool, servicePaused: Bool) -> DeletionRead {
        if servicePaused { return .unreachable }
        return vaultListed ? .listed : .unconfirmed
    }

    /// What a failed read says: nothing definite. A `401` of any kind (``MemberApiError/unauthorized``, and
    /// ``MemberApiError/clockSkew``, a `401` for the clock) and a `403` are unconfirmed; the rest (network, timeout, 5xx,
    /// 429) is unreachable. Never ``gone``.
    static func of(failure error: Error) -> DeletionRead {
        guard let e = error as? MemberApiError else { return .unreachable }
        if e.code == MemberApiError.clockSkew { return .unconfirmedClock }
        if e.status == 401 || e.status == 403 || e.code == MemberApiError.unauthorized { return .unconfirmed }
        return .unreachable
    }
}

extension VaultDeletion {
    /// A step back of the clock up to this (an NTP correction) does not count.
    static let clockTolerance: TimeInterval = 60

    /// Whether a deletion begun at [since] is past its bound at [now]. A clock that went back before [since] is past it
    /// too (the wall clock cannot be trusted to count down), so Check again and "Remove from this phone" are never hidden
    /// by it.
    static func pastBound(since: Date, until: Date, now: Date) -> Bool {
        now >= until || now < since.addingTimeInterval(-clockTolerance)
    }
}

/// The non-secret marker of a vault being deleted (IOS-PLAN §4.2 point 2): kept with the account record, so that a new
/// process starts in "being deleted" before it reads anything else, and erased with it. Times in Unix ms.
struct DeletingMarker: Codable, Equatable, Sendable {
    var vaultID: String
    var sinceMs: Int64
    var untilMs: Int64

    enum CodingKeys: String, CodingKey {
        case vaultID = "vault_id"
        case sinceMs = "since_ms"
        case untilMs = "until_ms"
    }

    init(vaultID: String, since: Date, until: Date) {
        self.vaultID = vaultID
        sinceMs = Int64((since.timeIntervalSince1970 * 1000).rounded(.down))
        untilMs = Int64((until.timeIntervalSince1970 * 1000).rounded(.down))
    }

    var since: Date { Date(timeIntervalSince1970: Double(sinceMs) / 1000) }
    var until: Date { Date(timeIntervalSince1970: Double(untilMs) / 1000) }
}

/// The re-reads of a vault being deleted (IOS-PLAN §4.2 points 3 and 4): after 5, 10 and 30 s, then every 60 s (each
/// wait after the read before it), the last wait cut short so that a read falls on the bound; at the bound, with the
/// vault still listed, [onSlow], and no timer after it. A start and a return to the foreground read once more
/// (``readOnce()``), and so does Check again; reads never overlap (a second waits for the first). The first `gone` runs
/// [onGone] once, in a task of its own.
@MainActor
final class DeletionWatch {
    /// The schedule, in one place: the gaps between reads, each counted from the read before it (reads at 5, 15 and 45 s;
    /// the owner's decision of 2026-10-20, as vettid-android does), then one read every `then` seconds until the bound.
    nonisolated static let schedule: (gaps: [TimeInterval], then: TimeInterval) = ([5, 10, 30], 60)

    private let now: @Sendable () -> Date
    private let sleep: LockSleep
    private let read: @MainActor () async -> DeletionRead
    private let onGone: @MainActor () async -> Void
    private let onSlow: @MainActor () -> Void
    private var loop: Task<Void, Never>?
    private var inFlight: Task<DeletionRead, Never>?
    private var goneSeen = false

    init(
        now: @escaping @Sendable () -> Date, sleep: @escaping LockSleep, read: @escaping @MainActor () async -> DeletionRead,
        onGone: @escaping @MainActor () async -> Void, onSlow: @escaping @MainActor () -> Void
    ) {
        self.now = now
        self.sleep = sleep
        self.read = read
        self.onGone = onGone
        self.onSlow = onSlow
    }

    /// The wait before read [index] (0-based) of the schedule.
    nonisolated static func wait(_ index: Int) -> TimeInterval {
        index < schedule.gaps.count ? schedule.gaps[index] : schedule.then
    }

    /// Starts the schedule towards [until] (an earlier one stops). [readFirst]: a start of the process, which reads at
    /// once.
    func start(since: Date, until: Date, readFirst: Bool) {
        loop?.cancel()
        goneSeen = false
        loop = Task { @MainActor [weak self] in
            if readFirst, await self?.readOnce() == .gone { return }
            var i = 0
            while !Task.isCancelled, let self {
                let at = now()
                guard !VaultDeletion.pastBound(since: since, until: until, now: at) else {
                    onSlow()
                    return
                }
                // Capped: a clock that moved back must not make the wait as long as the move.
                let left = min(max(until.timeIntervalSince(at), 0), Self.schedule.then)
                do {
                    try await sleep(.milliseconds(Int64((min(Self.wait(i), left) * 1000).rounded(.up))))
                } catch {
                    return
                }
                if Task.isCancelled { return }
                i += 1
                if await readOnce() == .gone { return }
            }
        }
    }

    /// One read now, or the one already on its way.
    @discardableResult
    func readOnce() async -> DeletionRead {
        if let inFlight { return await inFlight.value }
        let task = Task { @MainActor [read] in await read() }
        inFlight = task
        let r = await task.value
        inFlight = nil
        if r == .gone, !goneSeen {
            goneSeen = true
            loop?.cancel()
            let gone = onGone
            await Task { @MainActor in await gone() }.value
        }
        return r
    }

    /// No more reads (the vault is gone, or this phone was wiped).
    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// TEST ONLY: returns once the schedule has ended.
    func settle() async { await loop?.value }
}
