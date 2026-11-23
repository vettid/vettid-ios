import Foundation
import Observation
import VettIDVault

/// The vault calls behind ``ItemWaysManager``: the answers as their exact bytes, for the strict reader.
public protocol ItemWaysOps: Sendable {
    /// `leash.item.list{agent_id, item_id?}`.
    func list(_ agentID: String, _ itemID: String?) async throws -> [UInt8]
    /// `leash.item.set`: [body] as built by ``ItemWays/setBody()`` or ``ItemWaysRules/withoutWay(_:_:)``.
    func set(_ body: [UInt8]) async throws -> [UInt8]
}

/// ``ItemWaysOps`` over the vault client. Mirrors vettid-android `VaultItemWaysOps`.
struct VaultItemWaysOps: ItemWaysOps {
    let api: VaultApi

    func list(_ agentID: String, _ itemID: String?) async throws -> [UInt8] {
        try await api.leashItemList(agentID: agentID, itemID: itemID)
    }
    func set(_ body: [UInt8]) async throws -> [UInt8] { try await api.leashItemSet(body) }
}

/// What a save came to (ANDROID-PLAN 0.1.137 AA7 "Saving"), each with its own text on the item's page. Prints only its case:
/// the vault's text and the settings are never in a log.
public enum ItemWaysSave: Sendable, CustomStringConvertible {
    /// "Saved": the page shows the read, the vault's answer, never its own copy.
    case saved(ItemWaysRead)
    /// The save widens and no password was given: the unlock window prompt comes first.
    case needsPassword
    /// `credential_locked` to a save the app judged narrowing: the prompt, then the same request once.
    case credentialLocked
    /// A second `credential_locked`: "Your credential locked again before the settings were saved. Try again."
    case lockedAgain
    /// `credential_locked` to a read-only page's narrowing save: nothing is resent ("…so it was not saved. Update VettID…").
    case readOnlyLocked
    /// `conflict`: "Another device changed these settings. Here are the current ones." (the page reloads).
    case conflict
    /// `not_found`: "<agent> can no longer use this item: none of its rules includes it."
    case notIncluded
    /// `bad_request`: "These settings could not be saved. Your vault answered: <error text>." The vault's text may carry vault
    /// data: never in a log (the owner's rule, 2026-10-23).
    case badRequest(String)
    /// `owner_check_required`: the owner-check screen.
    case ownerCheck
    /// An open credential alarm (the unlock's `credential_frozen` / `rotation_required`): "Settings can't be widened…".
    case alarmOpen
    /// The prompt's own refusals (a wrong password, a backoff): shown on the prompt, which stays.
    case passwordRefused(VaultFailure)
    /// Any other failure, with its error text.
    case failed(VaultFailure)

    public var description: String {
        switch self {
        case .saved: "Saved"
        case .needsPassword: "NeedsPassword"
        case .credentialLocked: "CredentialLocked"
        case .lockedAgain: "LockedAgain"
        case .readOnlyLocked: "ReadOnlyLocked"
        case .conflict: "Conflict"
        case .notIncluded: "NotIncluded"
        case .badRequest: "BadRequest"
        case .ownerCheck: "OwnerCheck"
        case .alarmOpen: "AlarmOpen"
        case .passwordRefused: "PasswordRefused"
        case .failed: "Failed"
        }
    }
}

/// How an agent may use its items (ANDROID-PLAN 0.1.137 AA7; VAULT-MESSAGING §10.11): `leash.item.list` and `leash.item.set`.
/// The list is held in memory only, per agent, and cleared at lock and at the hold (``clear()``). A save that widens
/// (``ItemWaysRules/widens(_:_:)``) asks for the password every time and opens the unlock window with it (decision 4, as for
/// permissions), and the window is locked again after the save when the prompt opened it; a narrowing save is sent without it.
/// Mirrors vettid-android `ItemWaysManager`.
@MainActor
@Observable
public final class ItemWaysManager {
    /// The items each agent's rules include, as last read (agent id to its list).
    public private(set) var items: [String: [ItemWaysRead]] = [:]
    /// A save opened the window and could not lock it again (the votes' notice, with **Close it now**).
    public private(set) var windowNotClosed: WindowNotClosed?

    @ObservationIgnored private let ops: @MainActor () async throws -> any ItemWaysOps
    /// The credential's unlock window: until when it is open, as this app opened it.
    @ObservationIgnored private let windowUntil: @MainActor () -> Date?
    @ObservationIgnored private let openWindow: @MainActor (String) async throws -> Void
    @ObservationIgnored private let closeWindow: @MainActor () async throws -> Void
    /// The window's length, for the notice of a lock that failed.
    @ObservationIgnored private let unlockTtl: @MainActor () async -> Int?
    @ObservationIgnored private let now: @MainActor () -> Date
    /// Bumped by ``clear()``: an answer to a request sent before it is not kept.
    @ObservationIgnored private var generation = 0

    /// The unlock window counts as open for a save only when it has more than this left (the phone's clock may be off).
    static let windowMarginSeconds: TimeInterval = 30
    static let codeBadRequest = "bad_request"
    static let codeUnreadable = "unreadable_settings"
    static let codeVoided = "voided_by_lock"

    /// A failure that says the vault did not open the window (it refused); any other may have followed the opening.
    private static let definiteRefusals: Set<FailureKind> = [
        .badPassword, .backoff, .credentialFrozen, .rotationRequired, .ownerCheckRequired, .credentialUnsettled,
    ]

    public init(
        ops: @escaping @MainActor () async throws -> any ItemWaysOps,
        windowUntil: @escaping @MainActor () -> Date? = { nil },
        openWindow: @escaping @MainActor (String) async throws -> Void = { _ in },
        closeWindow: @escaping @MainActor () async throws -> Void = {},
        unlockTtl: @escaping @MainActor () async -> Int? = { nil },
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.ops = ops
        self.windowUntil = windowUntil
        self.openWindow = openWindow
        self.closeWindow = closeWindow
        self.unlockTtl = unlockTtl
        self.now = now
    }

    private static func unreadable() -> VaultFailure { VaultFailure(.other, code: codeUnreadable) }

    /// At lock, the hold and a wipe: nothing is kept, and nothing read before it is kept after it.
    public func clear() {
        generation += 1
        items = [:]
    }

    /// **Close it now**: locks the window; the notice goes only when that went through.
    public func closeWindowNow() async throws {
        let close = closeWindow
        try await Task { @MainActor in try await close() }.value
        windowNotClosed = nil
    }

    /// Reads the items [agentID]'s rules include (`leash.item.list{agent_id}`) and holds them.
    public func list(_ agentID: String) async throws -> [ItemWaysRead] {
        let gen = generation
        let answer = try await Self.guarded { [self] in try await ops().list(agentID, nil) }
        guard let read = ItemWaysRules.list(answer, agentID: agentID) else { throw Self.unreadable() }
        guard gen == generation else { throw VaultFailure(.other, code: Self.codeVoided) }
        items[agentID] = read
        return read
    }

    /// Reads one item's settings (`leash.item.list{agent_id, item_id}`): nil when no rule of the agent includes it.
    public func read(_ agentID: String, _ itemID: String) async throws -> ItemWaysRead? {
        let gen = generation
        let answer = try await Self.guarded { [self] in try await ops().list(agentID, itemID) }
        guard let all = ItemWaysRules.list(answer, agentID: agentID) else { throw Self.unreadable() }
        let read = all.first { same($0.itemID, itemID) }
        guard gen == generation else { throw VaultFailure(.other, code: Self.codeVoided) }
        if let held = items[agentID] {
            items[agentID] = held.compactMap { same($0.itemID, itemID) && same($0.agentID, agentID) ? read : $0 }
        }
        return read
    }

    /// Saves [next] over [cur] (AA7 "Saving"). A widening needs [password] (``ItemWaysSave/needsPassword`` without it); a
    /// narrowing is sent without one. [resent] is true when this request follows one prompt after `credential_locked`. Throws
    /// only a cancellation; the window this save opened is locked also then.
    public func save(_ cur: ItemWaysRead, _ next: ItemWays, password: String?, resent: Bool = false) async throws -> ItemWaysSave {
        // A read-only page saves only through turnOff: nothing is sent.
        guard let base = cur.ways else { return .failed(Self.unreadable()) }
        // Settings of another item, or of another version than the one read, can't be compared with these: judged a widening
        // (AA7: when the app cannot tell).
        let sameItem = same(next.agentID, base.agentID) && same(next.itemID, base.itemID) && next.version == base.version
        if password == nil, !sameItem || ItemWaysRules.widens(base, next) { return .needsPassword }
        // Open only with a margin (clock skew): a borderline window may end before the save, which then opens its own.
        var opened = password != nil && windowUntil().map { $0 > now().addingTimeInterval(Self.windowMarginSeconds) } != true
        let result: ItemWaysSave
        do {
            if let password, let refusal = try await unlock(password, opened: &opened) {
                result = refusal
            } else {
                result = try await send(next.setBody(), (next.agentID, next.itemID), resent: resent, readOnly: false)
            }
        } catch {
            if opened { await closeOpenedWindow() }
            throw error
        }
        if opened { await closeOpenedWindow() }
        return result
    }

    /// Opens the window with [password]; the refusal to show when the vault refused it. [opened] is cleared when the refusal is a
    /// definite one (nothing was opened to lock); any other failure may have come after the vault opened the window.
    private func unlock(_ password: String, opened: inout Bool) async throws -> ItemWaysSave? {
        do {
            try await openWindow(password)
            return nil
        } catch {
            let mapped = VaultFailures.map(error)
            guard let f = mapped as? VaultFailure else { throw mapped }
            if Self.definiteRefusals.contains(f.kind) { opened = false }
            return unlockRefused(f)
        }
    }

    /// Locks the window a save opened, to its end even when the caller was cancelled; a lock that failed is told
    /// (``windowNotClosed``).
    private func closeOpenedWindow() async {
        let close = closeWindow
        let ttl = unlockTtl
        let seconds: Int?? = await Task { @MainActor in
            do {
                try await close()
                return Int??.none
            } catch {
                return Int??.some(await ttl())
            }
        }.value
        if let seconds { windowNotClosed = WindowNotClosed(ttlSeconds: seconds) }
    }

    /// A read-only page's save (AA7 "Fail closed"): [way] turned off, everything else as read. It only narrows, so it is never
    /// followed by the password prompt: `credential_locked` is ``ItemWaysSave/readOnlyLocked`` and nothing is resent.
    public func turnOff(_ cur: ItemWaysRead, _ way: String) async throws -> ItemWaysSave {
        guard let body = ItemWaysRules.withoutWay(cur, way) else { return .failed(Self.unreadable()) }
        return try await send(body, (cur.agentID, cur.itemID), resent: false, readOnly: true)
    }

    /// Sends [body]; an answer that is not the settings of [sent] (agent, item) is not taken as saved.
    private func send(_ body: [UInt8], _ sent: (String, String), resent: Bool, readOnly: Bool) async throws -> ItemWaysSave {
        let gen = generation
        let answer: [UInt8]
        do {
            answer = try await Self.guarded { [self] in try await ops().set(body) }
        } catch let e as VaultFailure {
            return refused(e, resent: resent, readOnly: readOnly)
        }
        guard let read = ItemWaysRules.one(answer), same(read.agentID, sent.0), same(read.itemID, sent.1) else {
            return .failed(Self.unreadable())
        }
        // Saved either way (the vault answered); only the list held from before a clear is not touched.
        if gen == generation, let list = items[read.agentID] {
            items[read.agentID] = list.map { same($0.itemID, read.itemID) && same($0.agentID, read.agentID) ? read : $0 }
        }
        return .saved(read)
    }

    private func refused(_ e: VaultFailure, resent: Bool, readOnly: Bool) -> ItemWaysSave {
        if e.code == Self.codeBadRequest { return .badRequest((e.cause as? VaultOpError)?.detail ?? "") }
        switch e.kind {
        case .credentialLocked: return readOnly ? .readOnlyLocked : resent ? .lockedAgain : .credentialLocked
        case .conflict: return .conflict
        case .notFound: return .notIncluded
        case .ownerCheckRequired: return .ownerCheck
        default: return .failed(e)
        }
    }

    private func unlockRefused(_ e: VaultFailure) -> ItemWaysSave {
        switch e.kind {
        case .credentialFrozen, .rotationRequired: .alarmOpen
        case .ownerCheckRequired: .ownerCheck
        case .badPassword, .backoff: .passwordRefused(e)
        default: .failed(e)
        }
    }

    /// Turns every failure of [body] into a ``VaultFailure`` (a cancellation stays one).
    private static func guarded<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            throw VaultFailures.map(error)
        }
    }
}
