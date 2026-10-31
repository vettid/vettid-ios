import Foundation
import Observation
import VettIDCrypto
import VettIDVault

/// Whether the vault has the votes feature (VAULT-MESSAGING §10.19.1): learned from `vote.list`, asked again after an
/// unlock.
public enum VotesAvailability: Sendable {
    case unknown, available, unsupported
}

/// The lock after a cast failed; [ttlSeconds] is the vault's `credential.unlock_ttl_seconds` (30–3,600), when the app
/// knows it.
public struct WindowNotClosed: Equatable, Sendable {
    public let ttlSeconds: Int?

    public init(ttlSeconds: Int?) { self.ttlSeconds = ttlSeconds }
}

/// What the app knows about a vote that the vault's list does not say (memory only).
public struct VoteHint: Equatable, Sendable {
    /// Why the app's last attempt at the results failed (a `gave_up` check says which of two things).
    public var gaveUp: GaveUpWhy?
    /// The app found a problem in the site's results (they could not be checked); kept until the next attempt.
    public var resultsProblem = false
    /// The site's results are larger than the vault could ever take: no retry will help.
    public var resultsTooLarge = false
    /// When the app first saw the vote missing from the public site.
    public var notListedSince: Date?

    public init(gaveUp: GaveUpWhy? = nil, resultsProblem: Bool = false, resultsTooLarge: Bool = false, notListedSince: Date? = nil) {
        self.gaveUp = gaveUp
        self.resultsProblem = resultsProblem
        self.resultsTooLarge = resultsTooLarge
        self.notListedSince = notListedSince
    }

    /// `vote_not_listed_late`: missing from the site for ``lateAfter`` or more.
    public func notListedLate(_ now: Date) -> Bool { notListedSince.map { now.timeIntervalSince($0) >= Self.lateAfter } == true }

    public static let lateAfter: TimeInterval = 10 * 60
}

/// The member's votes (IOS-PLAN §4.16; VAULT-MESSAGING 0.81.3 §10.19.8). Every failure is a ``VaultFailure``; a vote is
/// identified by the pair (`connection_id`, `proposal_id`) throughout (0.81.2). Mirrors vettid-android
/// `VotesRepository` (the public site and the results come with the work on the site).
@MainActor
public protocol VotesRepository: AnyObject, Observable, Sendable {
    /// The vault's list in its order; empty until read and after a lock. Never carries a choice.
    var votes: [VoteSummary] { get }
    var reconnect: [ReconnectEntry] { get }
    var dropped: [DroppedNotice] { get }
    var problems: [ProblemsNotice] { get }
    var availability: VotesAvailability { get }
    var load: ListLoad { get }
    /// What the app itself knows of each vote.
    var hints: [VoteKey: VoteHint] { get }
    /// The lock of the unlock window a cast opened failed: the window stays open until it closes by itself. Told once.
    var windowNotClosed: WindowNotClosed? { get }
    /// The sidebar entry and its badge (``VoteRules/entry(_:reconnect:availability:)``).
    var entry: VotesEntry { get }

    /// **Close it now**: locks the window; the notice goes only when that went through, else the failure is thrown.
    func closeWindowNow() async throws
    /// Reads `vote.list`. Throws the vault's failure.
    func refresh() async throws
    func refreshQuietly()
    func get(_ key: VoteKey) async throws -> VoteDetail
    /// `vote.cast`: [password] opens the unlock window first when it is closed (and the app closes it again afterwards).
    /// Returns the ballot's state. Refused before anything is sent while a restore waits for ``confirm(_:mine:)``.
    func cast(_ key: VoteKey, choiceID: String, password: String?) async throws -> BallotState
    /// Whether the credential's unlock window is open now.
    func windowOpen() -> Bool
    func check(_ key: VoteKey) async throws
    func confirm(_ key: VoteKey, mine: Bool) async throws -> BallotState
    /// `vote.evidence`: the vault's evidence as JSON text, exactly as the vault sent it. Held by the caller until the
    /// member saves it, then dropped.
    func evidence(_ key: VoteKey) async throws -> String
    func release(_ key: VoteKey, pin: String) async throws
    /// The `dropped` notice of these connections was shown: sent as `ack_dropped` with the next list.
    func acknowledgeDropped(_ connectionIDs: [String])
    /// The title of a vote as the list has it, for a notification or History row; nil when not known.
    func titleOf(_ key: VoteKey) -> String?
}

/// The vault calls behind ``VotesManager``, so that it can be tested without a vault.
public protocol VoteOps: Sendable {
    func voteList(after: String?, ack: [String]) async throws -> JsonObject
    func voteGet(_ key: VoteKey) async throws -> JsonObject
    func voteCast(_ key: VoteKey, choiceID: String) async throws -> JsonObject
    func voteCheck(_ key: VoteKey) async throws
    func voteConfirm(_ key: VoteKey, mine: Bool) async throws -> JsonObject
    func voteEvidence(_ key: VoteKey) async throws -> JsonObject
    func voteRelease(_ key: VoteKey, pin: String) async throws
}

extension VaultApi: VoteOps {
    public func voteList(after: String?, ack: [String]) async throws -> JsonObject {
        try await voteList(state: "all", after: after, limit: VotesManager.page, ackDropped: ack)
    }

    public func voteGet(_ key: VoteKey) async throws -> JsonObject {
        try await voteGet(connectionID: key.connectionID, proposalID: key.proposalID)
    }

    public func voteCast(_ key: VoteKey, choiceID: String) async throws -> JsonObject {
        try await voteCast(connectionID: key.connectionID, proposalID: key.proposalID, choiceID: choiceID)
    }

    public func voteCheck(_ key: VoteKey) async throws {
        try await voteCheck(connectionID: key.connectionID, proposalID: key.proposalID)
    }

    public func voteConfirm(_ key: VoteKey, mine: Bool) async throws -> JsonObject {
        try await voteConfirm(connectionID: key.connectionID, proposalID: key.proposalID, mine: mine)
    }

    public func voteEvidence(_ key: VoteKey) async throws -> JsonObject {
        try await voteEvidence(connectionID: key.connectionID, proposalID: key.proposalID)
    }

    public func voteRelease(_ key: VoteKey, pin: String) async throws {
        try await voteRelease(connectionID: key.connectionID, proposalID: key.proposalID, pin: pin)
    }
}

/// ``VotesRepository`` over ``VoteOps``. Held in memory only, while the vault is open: cleared at a lock, at the hold, on a
/// wipe and with the process (IOS-PLAN §6.9, ANDROID-PLAN 0.1.102). The list is read when the vault opens, after an owner
/// check, and again after a `vote.event`; while the vault is held or due nothing is read (VAULT-MESSAGING §3.6.3: the
/// vault answers `owner_check_required`). A vault without the feature is asked again only after the next opening.
/// Mirrors vettid-android `VotesManager`.
@MainActor
@Observable
public final class VotesManager: VotesRepository {
    /// `vote.list`'s largest page (§10.19.8).
    public nonisolated static let page = 100
    static let maxPages = 5
    /// The most connections one `vote.list` acknowledges (vettid-vault refuses a longer `ack_dropped`); the rest wait for
    /// the next read (chosen; not in the spec: VAULT-MESSAGING §10.19.8 states no bound).
    public nonisolated static let maxAcks = 128
    /// A failure that says the vault did not open the window (it refused); any other may have followed the opening.
    static let definiteRefusals: Set<FailureKind> = [
        .badPassword, .backoff, .credentialFrozen, .rotationRequired, .ownerCheckRequired, .credentialUnsettled,
    ]

    public private(set) var votes: [VoteSummary] = []
    public private(set) var reconnect: [ReconnectEntry] = []
    public private(set) var dropped: [DroppedNotice] = []
    public private(set) var problems: [ProblemsNotice] = []
    public private(set) var availability: VotesAvailability = .unknown
    public private(set) var load: ListLoad = .notLoaded
    public private(set) var hints: [VoteKey: VoteHint] = [:]
    public private(set) var windowNotClosed: WindowNotClosed?

    public var entry: VotesEntry { VoteRules.entry(votes, reconnect: reconnect, availability: availability) }

    /// The service list the vault holds (`list_version`, `list_sha256`), for the work with the public site.
    @ObservationIgnored public private(set) var listVersion: Int64?
    @ObservationIgnored public private(set) var listSha256: String?

    /// Bumped by ``clear()``: a read that started before it is not applied after it.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var reading: Task<Void, any Error>?
    @ObservationIgnored private var queued = false
    /// `dropped` notices shown and not yet acknowledged to the vault.
    @ObservationIgnored private var pendingAck: [String] = []
    /// The lock of the window a cast opened, running on its own (tests wait for it).
    @ObservationIgnored private(set) var windowLock: Task<Void, Never>?
    /// Locks of a cast's window not yet ended: the window counts as closed meanwhile (it is about to be).
    @ObservationIgnored private var locksPending = 0

    @ObservationIgnored let ops: @MainActor () async throws -> any VoteOps
    /// The calls of a read nobody asked for (the opening, an event): only over the session already open.
    @ObservationIgnored let quietOps: @MainActor () async throws -> any VoteOps
    /// True while the vault is held or due (VAULT-MESSAGING §3.6.3): nothing is read.
    @ObservationIgnored private let gated: @MainActor () -> Bool
    /// The credential's unlock window (§3.5.3): until when it is open, as this app opened it.
    @ObservationIgnored private let windowUntil: @MainActor () -> Date?
    @ObservationIgnored private let openWindow: @MainActor (String) async throws -> Void
    @ObservationIgnored private let closeWindow: @MainActor () async throws -> Void
    /// The vault setting `credential.unlock_ttl_seconds` alone; nil when it can't be read. Asked only after a lock failed.
    @ObservationIgnored private let unlockTtl: @MainActor () async -> Int?
    @ObservationIgnored let now: @Sendable () -> Date

    public init(
        ops: @escaping @MainActor () async throws -> any VoteOps,
        quietOps: (@MainActor () async throws -> any VoteOps)? = nil,
        gated: @escaping @MainActor () -> Bool = { false },
        windowUntil: @escaping @MainActor () -> Date? = { nil },
        openWindow: @escaping @MainActor (String) async throws -> Void = { _ in },
        closeWindow: @escaping @MainActor () async throws -> Void = {},
        unlockTtl: @escaping @MainActor () async -> Int? = { nil },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.ops = ops
        self.quietOps = quietOps ?? ops
        self.gated = gated
        self.windowUntil = windowUntil
        self.openWindow = openWindow
        self.closeWindow = closeWindow
        self.unlockTtl = unlockTtl
        self.now = now
    }

    /// Forgets everything: the vault locked, was held or wiped. The feature is asked about again at the next read.
    public func clear() {
        generation += 1
        queued = false
        load = .notLoaded
        availability = .unknown
        votes = []
        reconnect = []
        dropped = []
        problems = []
        hints = [:]
        windowNotClosed = nil
        pendingAck = []
        listVersion = nil
        listSha256 = nil
    }

    /// `vote.event` (§10.19.8, the app only): a change of any vote re-reads the list. The event carries no choice.
    public func onEvent(_ m: VaultMessage) {
        guard m.type == VaultApi.typeVoteEvent, !gated() else { return }
        refreshQuietly()
    }

    /// The vault opened or a check passed: the list is read in the background, over the session already open.
    public func openNow() async { try? await read(quietly: true) }

    public func refreshQuietly() {
        guard !queued, availability != .unsupported else { return }
        queued = true
        Task { [weak self] in try? await self?.read(quietly: true, queued: true) }
    }

    public func refresh() async throws { try await read(quietly: false) }

    /// One read after the reads before it.
    private func read(quietly: Bool, queued fromQueue: Bool = false) async throws {
        let before = reading
        let task = Task { @MainActor [weak self] in
            _ = await before?.result
            guard let self else { return }
            if fromQueue { queued = false }
            try await readNow(quietly: quietly)
        }
        reading = task
        try await task.value
    }

    private func readNow(quietly: Bool) async throws {
        // A vault without the feature is asked again only after the next opening (§10.19.8); held or due: nothing is read.
        guard availability != .unsupported, !gated() else { return }
        let g = generation
        if votes.isEmpty { load = .loading }
        let acks = Array(pendingAck.prefix(Self.maxAcks))
        do {
            let o = quietly ? quietOps : ops
            var all: [VoteSummary] = []
            var head: VoteListing?
            var after: String?
            for n in 0..<Self.maxPages {
                let page = VoteWire.listing(try await o().voteList(after: after, ack: n == 0 ? acks : []))
                if head == nil { head = page }
                all += page.votes
                guard let next = page.next else { break }
                after = next
            }
            guard g == generation, let head else { return }
            var seen = Set<VoteKey>()
            let shown = all.filter { seen.insert($0.key).inserted }
            votes = shown
            reconnect = head.reconnect
            // A notice acknowledged while this read was on its way stays acknowledged.
            dropped = head.dropped.filter { !pendingAck.contains($0.connectionID) }
            problems = head.problems
            listVersion = head.listVersion
            listSha256 = head.listSha256
            pendingAck.removeAll { acks.contains($0) }
            // More than one read can carry: the rest go with the next read now.
            if !pendingAck.isEmpty { refreshQuietly() }
            availability = .available
            load = .loaded
            hints = hintsFor(shown, hints)
        } catch {
            let f = VaultFailures.map(error)
            if g == generation {
                if (f as? VaultFailure)?.kind == .notSupported {
                    availability = .unsupported
                    load = .loaded
                } else {
                    load = .failed
                }
            }
            throw f
        }
    }

    /// The hints of the votes now held: those of a vote that is gone go; a vote seen missing from the site is stamped once.
    private func hintsFor(_ list: [VoteSummary], _ old: [VoteKey: VoteHint]) -> [VoteKey: VoteHint] {
        let at = now()
        var out: [VoteKey: VoteHint] = [:]
        for v in list {
            var h = old[v.key] ?? VoteHint()
            if v.site == .notListed {
                h.notListedSince = h.notListedSince ?? at
            } else {
                h.notListedSince = nil
            }
            if h != VoteHint() { out[v.key] = h }
        }
        return out
    }

    /// Changes the app's own hint of [key] (the work with the site's results).
    func hint(_ key: VoteKey, _ change: (inout VoteHint) -> Void) {
        var h = hints[key] ?? VoteHint()
        change(&h)
        hints[key] = h == VoteHint() ? nil : h
    }

    public func get(_ key: VoteKey) async throws -> VoteDetail {
        let body = try await guarded { try await self.ops().voteGet(key) }
        guard let d = VoteWire.detail(body) else { throw VaultFailure(.other, code: "unreadable") }
        return d
    }

    /// False while the lock of a window a cast opened is on its way: a screen asks for the password again rather than
    /// rely on a window about to close.
    public func windowOpen() -> Bool { locksPending == 0 && windowUntil().map { $0 > now() } == true }

    public func cast(_ key: VoteKey, choiceID: String, password: String?) async throws -> BallotState {
        // Fail secure: a vote that waits on "Is this your vote?" is never cast, whatever the screen thought.
        if votes.first(where: { $0.key == key })?.confirmPending == true { throw VaultFailure(.other, code: "checking") }
        // A lock of an earlier cast's window ends first: this cast opens its own window rather than lose it to that lock.
        await windowLock?.value
        // Set before the unlock is sent: an unlock whose answer was lost may still have opened the window, so it is locked.
        var toLock = password != nil && !windowOpen()
        do {
            if let password, toLock {
                do {
                    try await openWindow(password)
                } catch {
                    // Only a definite refusal opened nothing. Any other failure (no answer, an answer that did not read…)
                    // may have come after the vault opened the window, so it is locked.
                    if let f = VaultFailures.map(error) as? VaultFailure, Self.definiteRefusals.contains(f.kind) { toLock = false }
                    throw VaultFailures.map(error)
                }
            }
            // Sent once: never repeated after an answer or a failure (§10.19.8); the device's own re-sends keep the same id.
            let body = try await guarded { try await self.ops().voteCast(key, choiceID: choiceID) }
            refreshQuietly()
            // The ballot's state is the member's at once; the lock does not hold it back.
            if toLock { lockOpenedWindow() }
            return VoteWire.ballotState(body)
        } catch {
            // A window this prompt opened does not stay open for its full length; one that was open is left as it was.
            if toLock { lockOpenedWindow() }
            throw error
        }
    }

    /// The lock after a cast, on its own task: it runs to its end even when the caller was cancelled (a screen that left)
    /// and never delays the cast's answer. A lock that failed is not swallowed: the member is told that the window stays
    /// open until it closes by itself (``windowNotClosed``).
    private func lockOpenedWindow() {
        let close = closeWindow
        let ttl = unlockTtl
        let before = windowLock
        let g = generation
        locksPending += 1
        windowLock = Task { @MainActor [weak self] in
            await before?.value
            do {
                try await close()
                self?.locksPending -= 1
            } catch {
                let seconds = await ttl()
                guard let self else { return }
                locksPending -= 1
                // Not after a lock, a hold or a wipe (``clear()``), nor once the window closed some other way.
                if g == generation, windowOpen() { windowNotClosed = WindowNotClosed(ttlSeconds: seconds) }
            }
        }
    }

    public func closeWindowNow() async throws {
        // The notice goes only when the lock went through; a failure is the caller's to show.
        let close = closeWindow
        try await Task { @MainActor in try await close() }.value
        windowNotClosed = nil
    }

    public func check(_ key: VoteKey) async throws {
        try await guarded { try await self.ops().voteCheck(key) }
        refreshQuietly()
    }

    public func confirm(_ key: VoteKey, mine: Bool) async throws -> BallotState {
        let body = try await guarded { try await self.ops().voteConfirm(key, mine: mine) }
        refreshQuietly()
        return VoteWire.ballotState(body)
    }

    public func evidence(_ key: VoteKey) async throws -> String {
        let body = try await guarded { try await self.ops().voteEvidence(key) }
        guard case .object(let e)? = body["evidence"] else { throw VaultFailure(.other, code: "unreadable") }
        // The vault's bytes, unchanged (ANDROID-PLAN 0.1.108: Save the proof writes the vault's evidence unchanged).
        return e.raw
    }

    public func release(_ key: VoteKey, pin: String) async throws {
        try await guarded { try await self.ops().voteRelease(key, pin: pin) }
        refreshQuietly()
    }

    public func acknowledgeDropped(_ connectionIDs: [String]) {
        guard !connectionIDs.isEmpty else { return }
        for c in connectionIDs where !pendingAck.contains(c) { pendingAck.append(c) }
        dropped.removeAll { connectionIDs.contains($0.connectionID) }
        // The acknowledgement goes with the next list read.
        refreshQuietly()
    }

    public func titleOf(_ key: VoteKey) -> String? {
        votes.first { $0.key == key }.flatMap { $0.title.isEmpty ? nil : $0.title }
    }

    private func guarded<T: Sendable>(_ body: @MainActor () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            throw VaultFailures.map(error)
        }
    }
}
