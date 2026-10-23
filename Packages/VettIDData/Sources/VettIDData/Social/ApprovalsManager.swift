import Foundation
import Observation
import VettIDCrypto
import VettIDVault

/// The approvals on this device (VAULT-MESSAGING §10.4, §10.12, §10.13, §6.8; ANDROID-PLAN §4 Approvals), over the vault
/// client. What the vault lists (grant and critical-item requests, `grant.list` and `critical-secret-use.list`) is read
/// again when it opens and kept in memory only. What arrives only as events (member authentication, share decisions,
/// desktop and agent requests) and what the lists leave out (a critical-item request's payload) is kept, as the vault sent
/// it, in an encrypted file through [load] and [persist], as vettid-android keeps it, until it is decided, expires, or a
/// list shows it gone. The connection requests are the ``ConnectionsManager``'s, listed here with the others. Nothing
/// here touches transport or crypto beyond the typed calls. Mirrors the approvals part of vettid-android `SocialManager`.
@MainActor
@Observable
public final class ApprovalsManager: ApprovalsRepository {
    /// What the file keeps: approval events as the vault sent them.
    struct StoredEvent: Codable, Equatable {
        var type: String
        var body: String
        var at: Date
    }

    @ObservationIgnored var stored: [StoredEvent] = []
    /// The grant and critical-item requests the vault listed.
    var listed: [PendingApproval] = []
    /// Bumped on every change of the stored events, so that ``approvals`` is observed to change.
    private var storedVersion = 0

    @ObservationIgnored let connections: ConnectionsManager
    @ObservationIgnored let ops: @MainActor () async throws -> any ApprovalOps
    @ObservationIgnored let quietOps: @MainActor () async throws -> any ApprovalOps
    @ObservationIgnored let openUnlockWindow: @MainActor (String) async throws -> Void
    @ObservationIgnored private let load: @MainActor () throws -> [UInt8]?
    @ObservationIgnored private let persist: @MainActor ([UInt8]) throws -> Void
    @ObservationIgnored let now: @Sendable () -> Date
    /// The items by id, to name what a vault before 0.21.0 asks about (``SharePending``); empty when not known.
    @ObservationIgnored let itemNames: @MainActor () -> [String: ShareItem]
    @ObservationIgnored private var loaded = false
    /// Bumped whenever what was read from the open vault is dropped: a list read before is not published.
    @ObservationIgnored private var generation = 0
    /// Counts the approvals that arrived or left (decided here or on another device), and when each did: a list read
    /// before that neither brings back one that left nor drops one that arrived (chosen; not in the spec).
    @ObservationIgnored private var changes = 0
    @ObservationIgnored private var changedAt: [String: Int] = [:]
    /// The share items decided, and at which change: a list read before does not bring them back.
    @ObservationIgnored private var decidedLog: [ShareDecidedMark] = []
    /// The `share.pending` batches, and at which change: a list read before keeps them, and only them.
    @ObservationIgnored private var batchLog: [ShareBatch] = []
    /// Where the reads on their way began.
    @ObservationIgnored private var readSinces: [Int] = []

    /// Share items decided for one subject, and at which change.
    struct ShareDecidedMark {
        var at: Int
        var subject: String
        var ruleID: String
        var ids: Set<String>
    }

    /// A `share.pending` batch for one question, and at which change.
    struct ShareBatch {
        var at: Int
        var key: String
        var items: [ShareItem]
    }

    /// The subject a share question is for; a rule of no known subject is its own.
    static func subjectKey(_ d: ShareDecision) -> String { ShareQuestions.subject(d) ?? "rule:\(d.ruleID)" }
    /// Told of each decided ask, with its feed item's kinds and `ref` (``FeedAsks``): the item is marked read.
    @ObservationIgnored public var onDecided: @MainActor (_ kinds: Set<String>, _ ref: String) -> Void = { _, _ in }

    /// [ops] the vault's calls, opened when needed; [quietOps] those of the background reads (nil: [ops]);
    /// [openUnlockWindow] the credential's `credential.unlock` with the password (§3.5.3); [load] and [persist] the
    /// encrypted file (an empty write clears it).
    public init(
        connections: ConnectionsManager,
        ops: @escaping @MainActor () async throws -> any ApprovalOps,
        quietOps: (@MainActor () async throws -> any ApprovalOps)? = nil,
        openUnlockWindow: @escaping @MainActor (String) async throws -> Void = { _ in },
        load: @escaping @MainActor () throws -> [UInt8]? = { nil },
        persist: @escaping @MainActor ([UInt8]) throws -> Void = { _ in },
        now: @escaping @Sendable () -> Date = { Date() },
        itemNames: @escaping @MainActor () -> [String: ShareItem] = { [:] }
    ) {
        self.itemNames = itemNames
        self.connections = connections
        self.ops = ops
        self.quietOps = quietOps ?? ops
        self.openUnlockWindow = openUnlockWindow
        self.load = load
        self.persist = persist
        self.now = now
    }

    // MARK: - The list

    public var approvals: [PendingApproval] {
        _ = storedVersion
        let t = now()
        // Events carry what lists leave out (a critical request's payload): they win for the same key. A share decision's
        // event names its items; the list says which are still pending, with the rule's tags and the subject's rules.
        let fromEvents = Self.enriched(stored.compactMap(parsed), by: listed)
        let keys = Set(fromEvents.map(\.key))
        var seen = Set<String>()
        let all = (fromEvents + listed.filter { !keys.contains($0.key) } + connections.requests.map(PendingApproval.connection))
            .filter { ($0.exp ?? .distantFuture) > t && seen.insert($0.key).inserted }
        // One question per item and subject (0.23.0 §10.12).
        return ShareQuestions.dedupe(all).sorted { $0.receivedAt > $1.receivedAt }
    }

    /// A share decision kept from events, with what the list knows of it: the list's items (named by the event where the
    /// list has no name), the rule's tags and the subject's rules (chosen as vettid-android's merge).
    static func enriched(_ events: [PendingApproval], by listed: [PendingApproval]) -> [PendingApproval] {
        var shares: [String: ShareDecision] = [:]
        for case .share(let s) in listed { shares[PendingApproval.share(s).key] = s }
        guard !shares.isEmpty else { return events }
        return events.map { e in
            guard case .share(var d) = e, let l = shares[e.key] else { return e }
            let named = Dictionary(d.items.map { ($0.itemID, $0) }, uniquingKeysWith: { a, _ in a })
            d.items = l.items.map { li in
                guard let ev = named[li.itemID] else { return li }
                var i = li
                if i.name.isEmpty { i.name = ev.name }
                i.askRuleID = li.askRuleID ?? ev.askRuleID
                i.shared = li.shared || ev.shared
                return i
            }
            d.tags = l.tags
            d.rules = l.rules
            return .share(d)
        }
    }

    func parsed(_ e: StoredEvent) -> PendingApproval? {
        guard let o = try? StrictJson.parseObject(Array(e.body.utf8)) else { return nil }
        return ApprovalParser.parse(e.type, o, at: e.at)
    }

    private func find(_ key: String) -> PendingApproval? {
        stored.compactMap(parsed).first { $0.key == key } ?? listed.first { $0.key == key }
    }

    // MARK: - Local state

    /// Reads the file once (after the first-run cleanup); a file that cannot be read is an empty state.
    public func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        if let b = try? load(), !b.isEmpty, let s = try? JSONDecoder().decode([StoredEvent].self, from: Data(b)) {
            stored = s
            storedVersion += 1
        }
    }

    /// Changes the kept events and writes them (kept in memory when the write fails; the next one retries).
    private func edit(_ f: (inout [StoredEvent]) -> Void) {
        loadIfNeeded()
        var next = stored
        f(&next)
        guard next != stored else { return }
        stored = next
        storedVersion += 1
        if let b = try? JSONEncoder().encode(next) { try? persist(Array(b)) }
    }

    /// The vault is no longer open on this phone: the lists read from it are dropped. The events kept by design stay.
    public func forgetOpenVault() {
        generation += 1
        listed = []
    }

    /// Forgets everything (a wipe, or a deleted vault).
    public func clear() {
        generation += 1
        stored = []
        storedVersion += 1
        loaded = true
        try? persist([])
        listed = []
    }

    // MARK: - Events

    /// One event of the vault (§9.1): an approval to keep, or another device's decision.
    public func onEvent(_ m: VaultMessage) {
        if ApprovalParser.types.contains(m.type) {
            keep(m.type, m.object)
        } else if m.type == "sync.event" {
            onSync(m.object)
        }
    }

    private func keep(_ type: String, _ o: JsonObject) {
        guard let p = ApprovalParser.parse(type, o, at: now()) else { return }
        let at = now()
        changes += 1
        changedAt[p.key] = changes
        if case .share(let s) = p, !readSinces.isEmpty {
            batchLog.append(ShareBatch(at: changes, key: p.key, items: s.items))
            if batchLog.count > Self.maxDecidedLog { batchLog.removeFirst(batchLog.count - Self.maxDecidedLog) }
        }
        // A batch for a question the list holds adds to it at once, not at the next read.
        if case .share(let s) = p, let i = listed.firstIndex(where: { $0.key == p.key }), case .share(var d) = listed[i] {
            let before = Dictionary(d.items.map { ($0.itemID, $0) }, uniquingKeysWith: { a, _ in a })
            let added = s.items.map { n -> ShareItem in
                guard let old = before[n.itemID] else { return n }
                var i = n
                if i.name.isEmpty { i.name = old.name }
                i.askRuleID = n.askRuleID ?? old.askRuleID
                i.shared = n.shared || old.shared
                return i
            }
            let named = Set(s.items.map(\.itemID))
            d.items = d.items.filter { !named.contains($0.itemID) } + added
            listed[i] = .share(d)
        }
        edit { events in
            let old = events.first { parsed($0)?.key == p.key }
            events.removeAll { parsed($0)?.key == p.key }
            // Several `share.pending` batches of one rule add up (§10.12).
            let body = if case .share = p, let old { Self.mergedShare(old.body, o) } else { o.raw }
            events.append(StoredEvent(type: type, body: body, at: at))
        }
    }

    /// [o] with the items of [old] it does not name added (by `item_id`).
    static func mergedShare(_ old: String, _ o: JsonObject) -> String {
        guard let prev = try? StrictJson.parseObject(Array(old.utf8)) else { return o.raw }
        let newItems = VaultJSON.objects(o, "items")
        let named = Set(newItems.compactMap { VaultJSON.string($0, "item_id") })
        let kept = VaultJSON.objects(prev, "items").filter { !named.contains(VaultJSON.string($0, "item_id") ?? "") }
        let b = JsonBuilder()
        for (name, value) in o.members where name != "items" { b.raw(name, value.raw) }
        b.raw("items", JsonBuilder.array((kept + newItems).map(\.raw)))
        return b.build()
    }

    /// `sync.event`: another device decided (§10.1).
    private func onSync(_ o: JsonObject) {
        let kind = VaultJSON.string(o, "kind") ?? ""
        if kind == "share.decided", let id = VaultJSON.string(o, "rule_id") {
            return shareDecided(id, VaultJSON.strings(o, "included") + VaultJSON.strings(o, "declined"))
        }
        guard let (prefix, member) = Self.decidedKinds[kind], let id = VaultJSON.string(o, member) else { return }
        drop(prefix + id)
    }

    /// The `sync.event` kinds of another device's decision: the approval key's prefix and the member naming the request.
    static let decidedKinds: [String: (String, String)] = [
        "connection.authenticate.decided": ("auth:", "request_id"), "grant.request.decided": ("grant:", "request_id"),
        "critical-secret-use.decided": ("critical:", "request_id"), "approval.decided": ("device:approval.pending:", "approval_id"),
    ]

    /// The items decided (here or on another device) leave the questions of the rule and of the subject's other rules, where
    /// they wait too (one answer per item and subject, §10.12); a question with none left goes. Kept events and the list.
    func shareDecided(_ ruleID: String, _ done: [String]) {
        let gone = Set(done)
        guard !gone.isEmpty else { return }
        var subject = "rule:\(ruleID)"
        if case .share(let d)? = find("share:\(ruleID)") { subject = Self.subjectKey(d) }
        let applies = { (d: ShareDecision) in d.ruleID == ruleID || Self.subjectKey(d) == subject }
        changes += 1
        if !readSinces.isEmpty { decidedLog.append(ShareDecidedMark(at: changes, subject: subject, ruleID: ruleID, ids: gone)) }
        if decidedLog.count > Self.maxDecidedLog { decidedLog.removeFirst(decidedLog.count - Self.maxDecidedLog) }
        listed = listed.compactMap { a in
            guard case .share(var d) = a, applies(d) else { return a }
            d.items.removeAll { gone.contains($0.itemID) }
            return d.items.isEmpty ? nil : .share(d)
        }
        edit { events in
            events = events.compactMap { e in
                guard case .share(let d)? = parsed(e), applies(d), let o = try? StrictJson.parseObject(Array(e.body.utf8)) else { return e }
                let left = VaultJSON.objects(o, "items").filter { !gone.contains(VaultJSON.string($0, "item_id") ?? "") }
                if left.isEmpty { return nil }
                let b = JsonBuilder()
                for (name, value) in o.members where name != "items" { b.raw(name, value.raw) }
                return StoredEvent(type: e.type, body: b.raw("items", JsonBuilder.array(left.map(\.raw))).build(), at: e.at)
            }
        }
    }

    /// Drops the approval [key] from the file and the lists.
    func drop(_ key: String) {
        changes += 1
        changedAt[key] = changes
        // A batch before this does not come back to a read on its way.
        batchLog.removeAll { $0.key == key }
        edit { $0.removeAll { parsed($0)?.key == key } }
        listed.removeAll { $0.key == key }
    }

    // MARK: - Reads

    public func refreshApprovals() async throws { try await refreshApprovals(quietly: false) }

    /// [requests] false: the connection requests are read by the caller.
    func refreshApprovals(quietly: Bool, requests: Bool = true) async throws {
        let g = generation
        let since = changes
        let t = now()
        // Reads may overlap (the quiet one and the screen's): what was decided stays marked until no read that began before
        // it is on its way.
        readSinces.append(since)
        defer {
            if let i = readSinces.firstIndex(of: since) { readSinces.remove(at: i) }
            let floor = readSinces.min() ?? Int.max
            decidedLog.removeAll { $0.at <= floor }
            batchLog.removeAll { $0.at <= floor }
        }
        if requests { try? await connections.refreshRequests(quietly: quietly) }
        let o = try await guarded { quietly ? try await quietOps() : try await ops() }
        let lists = await readLists(o, at: t)
        guard g == generation else { return }
        let changed = { (key: String) in (self.changedAt[key] ?? 0) > since }
        let next = mergedWithChanges(lists.approvals(at: t), since: since, changed: changed)
        listed = next
        // The lists are authoritative for what they cover: decided or expired requests kept from events are dropped.
        let keys = Set(next.map(\.key))
        let batched = batchedItems(since: since)
        edit { events in
            events = events.compactMap { e in
                guard let p = parsed(e), (p.exp ?? .distantFuture) > t else { return nil }
                guard lists.covers(p), !keys.contains(p.key) else { return e }
                guard changed(p.key) else { return nil }
                // A share question the read does not list keeps only the items of the batches that arrived during it.
                guard case .share = p else { return e }
                return Self.withItems(e, batched[p.key] ?? [])
            }
        }
    }

    /// The ids of the items each share question's batches brought after change [since].
    private func batchedItems(since: Int) -> [String: Set<String>] {
        batchLog.filter { $0.at > since }.reduce(into: [:]) { $0[$1.key, default: []].formUnion($1.items.map(\.itemID)) }
    }

    /// [e] with only the items [ids] names, or nil when it names none of them.
    static func withItems(_ e: StoredEvent, _ ids: Set<String>) -> StoredEvent? {
        guard let o = try? StrictJson.parseObject(Array(e.body.utf8)) else { return nil }
        let left = VaultJSON.objects(o, "items").filter { ids.contains(VaultJSON.string($0, "item_id") ?? "") }
        if left.isEmpty { return nil }
        let b = JsonBuilder()
        for (name, value) in o.members where name != "items" { b.raw(name, value.raw) }
        return StoredEvent(type: e.type, body: b.raw("items", JsonBuilder.array(left.map(\.raw))).build(), at: e.at)
    }

    /// What the vault listed: grant requests, critical-item requests and share decisions, each nil when the vault did not
    /// answer (an older release without the list: nothing listed for it, and nothing dropped by it).
    struct Lists {
        var grants: JsonObject?
        var critical: JsonObject?
        var shares: [ShareDecision]?

        func approvals(at t: Date) -> [PendingApproval] {
            var out: [PendingApproval] = shares.map { $0.map(PendingApproval.share) } ?? []
            if let grants {
                out += VaultJSON.objects(grants, "pending").compactMap { ApprovalParser.grant($0, at: t) }
                    .map(PendingApproval.grant)
            }
            if let critical {
                out += VaultJSON.objects(critical, "incoming").compactMap { ApprovalParser.critical($0, at: t) }
                    .map(PendingApproval.critical)
            }
            return out
        }

        /// Whether a list that was read says which requests of [p]'s kind are still waiting.
        func covers(_ p: PendingApproval) -> Bool {
            switch p {
            case .grant: grants != nil
            case .critical: critical != nil
            case .share: shares != nil
            default: false
            }
        }
    }

    private func readLists(_ o: any ApprovalOps, at t: Date) async -> Lists {
        let names = itemNames()
        // The share decisions (§10.12): nil when the vault answered neither list.
        let shares = try? await SharePending.decisions(
            pendingPage: { try await o.sharePendingPage(after: $0, limit: SharePending.page) },
            rulePage: { try await o.shareRulePage(after: $0) }, names: names, at: t
        )
        return Lists(grants: try? await o.grantList(), critical: try? await o.criticalUseList(), shares: shares)
    }

    /// At most this many share decisions, and as many batches, are remembered for reads on their way: past that, the
    /// oldest are forgotten, and a read on its way may show a decided item again, or miss a batch's item, until the next.
    static let maxDecidedLog = 64

    /// [next], as a read that began at change [since] listed it, with what changed during the read: the items decided for a
    /// subject leave every share question of that subject; any other request that changed is not taken from the list,
    /// except a share question a batch arrived for, whose items stay, with the items of the batches that arrived during
    /// the read and were not decided after (§10.12; chosen; not in the spec). The kept event adds up every batch, older
    /// ones too: an item the vault no longer lists does not come back from it.
    private func mergedWithChanges(_ next: [PendingApproval], since: Int, changed: (String) -> Bool) -> [PendingApproval] {
        let marks = decidedLog.filter { $0.at > since }
        let batches = batchLog.filter { $0.at > since }
        let events = stored.compactMap(parsed)
        return next.compactMap { a in
            guard case .share(var d) = a else { return changed(a.key) ? nil : a }
            let mine = marks.filter { $0.ruleID == d.ruleID || $0.subject == Self.subjectKey(d) }
            let gone = mine.reduce(into: Set<String>()) { $0.formUnion($1.ids) }
            d.items.removeAll { gone.contains($0.itemID) }
            if changed(a.key) {
                guard events.contains(where: { $0.key == a.key }) else { return nil }
                var have = Set(d.items.map(\.itemID))
                for b in batches where b.key == a.key {
                    let later = mine.filter { $0.at > b.at }.reduce(into: Set<String>()) { $0.formUnion($1.ids) }
                    d.items += b.items.filter { !later.contains($0.itemID) && have.insert($0.itemID).inserted }
                }
            }
            return d.items.isEmpty ? nil : .share(d)
        }
    }

    /// Runs [body] and turns every failure into a ``VaultFailure`` (a cancellation stays one).
    func guarded<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            throw VaultFailures.map(error)
        }
    }

    public func loadCriticalUse(_ requestID: String) async throws {
        let key = "critical:\(requestID)"
        let g = generation
        let body: JsonObject
        do {
            body = try await guarded { try await ops().criticalUseGet(requestID) }
        } catch let f as VaultFailure where f.kind == .notFound {
            if g == generation { drop(key) }
            throw f
        }
        // An answer from before a lock or a wipe is not kept (the file is not written again).
        guard g == generation else { return }
        // Kept as the event would have been; the payload is shown only if it matches the listed hash.
        keep("critical-secret-use.pending", body)
    }
}
