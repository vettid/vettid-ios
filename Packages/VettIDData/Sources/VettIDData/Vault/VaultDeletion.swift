import Foundation

/// (IOS-PLAN §4.2) A vault being deleted, as the screens see it: since when (the `device.unlinked{vault_deleted}` that
/// started it), the bound until which the app re-reads the member API's status on its own, and whether the bound has
/// passed ("Still finishing", with Check again). Mirrors ANDROID-PLAN §4 "A vault being deleted".
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
    /// `{vault: null}`, or `401 unauthorized` to the app key: the vault is gone.
    case gone
    /// The vault is still listed, whatever its `state`.
    case listed
    /// The member API could not be reached (or answered anything else).
    case unreachable
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
    /// The waits between reads, then ``every`` until the bound.
    nonisolated static let waits: [TimeInterval] = [5, 10, 30]
    nonisolated static let every: TimeInterval = 60

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
    nonisolated static func wait(_ index: Int) -> TimeInterval { index < waits.count ? waits[index] : every }

    /// Starts the schedule towards [until] (an earlier one stops). [readFirst]: a start of the process, which reads at
    /// once.
    func start(until: Date, readFirst: Bool) {
        loop?.cancel()
        goneSeen = false
        loop = Task { @MainActor [weak self] in
            if readFirst, await self?.readOnce() == .gone { return }
            var i = 0
            while !Task.isCancelled, let self {
                let left = until.timeIntervalSince(now())
                guard left > 0 else {
                    onSlow()
                    return
                }
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
