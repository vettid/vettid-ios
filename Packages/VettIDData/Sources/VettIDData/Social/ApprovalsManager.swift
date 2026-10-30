import Foundation
import Observation
import VettIDCrypto
import VettIDVault

/// The approvals on this device (VAULT-MESSAGING §10.4, §10.12, §10.13, §6.8; ANDROID-PLAN §4 Approvals), over the vault
/// client. What the vault lists (grant and critical-item requests, `grant.list` and `critical-secret-use.list`) is read
/// again when it opens. What arrives only as events (member authentication, share decisions, desktop and agent requests)
/// and what the lists leave out (a critical-item request's payload) is kept as the vault sent it until it is decided,
/// expires, or a list shows it gone. All of it lives in memory only, like every other vault content (IOS-PLAN §6.9):
/// nothing is written to the phone, and it is dropped when the vault locks, at a hold and at a wipe
/// (``forgetOpenVault()``). An approval that arrived only as an event and was not decided before then is read back by
/// `pending.list` (VAULT-MESSAGING 0.70.0 §10.4.2, ``readPendingAsks(_:generation:)``) when the vault answers it; from a
/// vault before it, it is not shown again (no other vault list names it). The connection requests are the
/// ``ConnectionsManager``'s, listed here with the others.
/// Nothing here touches transport or crypto beyond the typed calls. Mirrors the approvals part of vettid-android
/// `SocialManager`.
@MainActor
@Observable
public final class ApprovalsManager: ApprovalsRepository {
    /// An approval event as the vault sent it, kept in memory.
    struct StoredEvent: Codable, Equatable {
        var type: String
        var body: String
        var at: Date
        /// The event's inner `ts` (the vault's time), nil for a body read from a request (VAULT-MESSAGING 0.70.0 §10.4.2).
        var ts: Date?
    }

    @ObservationIgnored var stored: [StoredEvent] = []
    /// The grant and critical-item requests the vault listed.
    var listed: [PendingApproval] = []
    /// Bumped on every change of the stored events, so that ``approvals`` is observed to change.
    private var storedVersion = 0
    public private(set) var forgetCount = 0

    @ObservationIgnored let connections: ConnectionsManager
    @ObservationIgnored let ops: @MainActor () async throws -> any ApprovalOps
    @ObservationIgnored let quietOps: @MainActor () async throws -> any ApprovalOps
    @ObservationIgnored let openUnlockWindow: @MainActor (String) async throws -> Void
    @ObservationIgnored let now: @Sendable () -> Date
    /// The items by id, to name what a vault before 0.21.0 asks about (``SharePending``); empty when not known.
    @ObservationIgnored let itemNames: @MainActor () -> [String: ShareItem]
    /// Bumped whenever what was read from the open vault is dropped: a list read before is not published.
    @ObservationIgnored var generation = 0
    /// Counts the approvals that arrived or left (decided here or on another device), and when each did: a list read
    /// before that neither brings back one that left nor drops one that arrived (chosen; not in the spec).
    @ObservationIgnored var changes = 0
    @ObservationIgnored private var changedAt: [String: Int] = [:]
    /// The approvals that arrived as events since the approvals were last dropped (``mayHaveBeenDropped(_:)``).
    @ObservationIgnored private var arrivedSinceForget: Set<String> = []
    /// The first page's `ts` of each `pending.list` read on its way, by read (``readPendingAsks(_:generation:)``).
    @ObservationIgnored var pendingReadTs: [Int: Date] = [:]
    /// The first page's `ts` of the newest list merged since the vault was last forgotten.
    @ObservationIgnored var mergedListTs: Date?
    @ObservationIgnored var pendingReadCount = 0
    /// Creation events ignored for being no later than the list's time while a read was on its way: if that read does not
    /// merge, they are applied after all (``finishPendingRead(_:generation:)``).
    @ObservationIgnored var ignoredDuringRead: [IgnoredEvent] = []
    /// The time an event of the kinds `pending.list` returns must be later than to be applied: the newest first page's
    /// `ts` of the lists merged or on their way (never lowered by a read that fails), VAULT-MESSAGING 0.70.0 §10.4.2.
    /// Nil: no list read, every event is applied.
    var pendingListTs: Date? { ([mergedListTs] + pendingReadTs.values.map { Optional($0) }).compactMap { $0 }.max() }
    /// Whether `pending.list` has been read through since the vault was last forgotten (``mayHaveBeenDropped(_:)``).
    /// Observed: a screen showing a dropped ask is told when the read ends (``mayHaveBeenDropped(_:)``).
    var pendingListAnswered = false
    /// The vault answered `unsupported_type` to `pending.list`: it is not asked again until the next unlock
    /// (``vaultOpened()``), not after a passed owner check (§10.4.2 "Older vaults").
    @ObservationIgnored var pendingListUnsupported = false
    /// The change at which each device's session request was closed (`sync.event` `device.session`): a `pending.list` read
    /// before it does not bring the request back.
    @ObservationIgnored var sessionClosedAt: [String: (change: Int, ts: Date)] = [:]
    /// When each approval was dropped (decided, or `not_found` on a decision): a share question dropped during a read is
    /// not taken from its list (VAULT-MESSAGING 0.55.7 §10.12 rule 3).
    @ObservationIgnored var droppedAt: [String: Int] = [:]
    /// The asks of the kinds `pending.list` returns that were closed or decided, with the close's `ts` (nil: decided here),
    /// so that a creation event that arrives after its close (events come in no order, §8.4) is not kept. An ask's id is
    /// unique, so a close is final within a generation (VAULT-MESSAGING 0.70.0 §10.4.2); the oldest go past
    /// ``maxClosedAsks``, and a merged list takes those it already judges.
    @ObservationIgnored var closedAsks: [ClosedAsk] = []
    /// Why the last `pending.list` read failed, nil when it was answered (or the vault does not know it): the Approvals
    /// screen says so, with Retry; ``FailureKind/ownerCheckRequired`` is a vault held, not a failure
    /// (VAULT-MESSAGING 0.70.0 §10.4.2). Cleared at a drop.
    public private(set) var openAsksError: FailureKind?
    /// The share items decided, and at which change: a list read before does not bring them back.
    @ObservationIgnored private var decidedLog: [ShareDecidedMark] = []
    /// The `share.pending` batches, and at which change: a list read before keeps them, and only them.
    @ObservationIgnored private var batchLog: [ShareBatch] = []
    /// Where the reads on their way began.
    @ObservationIgnored private var readSinces: [Int] = []

    struct ClosedAsk {
        var key: String
        var ts: Date?
    }

    static let maxClosedAsks = 512

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
    // Desktops' and agents' access sessions, for a renewal request (VAULT-MESSAGING 0.78.0 §6.8 step 3): memory only,
    // dropped with the vault (ApprovalsManager+Sessions.swift; ``ApprovalsRepository`` says what each one is).
    public internal(set) var deviceSessions: [String: Date] = [:]
    public internal(set) var deviceSessionsKnown = false
    public internal(set) var deviceSessionReads = 0
    public internal(set) var deviceSessionsVersion = 0
    /// A screen asked for the sessions since the vault was last forgotten: a `device.session` event reads them again.
    @ObservationIgnored var deviceSessionsWanted = false
    @ObservationIgnored let held: @MainActor () -> Bool

    /// [ops] the vault's calls, opened when needed; [quietOps] those of the background reads (nil: [ops]);
    /// [openUnlockWindow] the credential's `credential.unlock` with the password (§3.5.3).
    public init(
        connections: ConnectionsManager,
        ops: @escaping @MainActor () async throws -> any ApprovalOps,
        quietOps: (@MainActor () async throws -> any ApprovalOps)? = nil,
        openUnlockWindow: @escaping @MainActor (String) async throws -> Void = { _ in },
        now: @escaping @Sendable () -> Date = { Date() },
        itemNames: @escaping @MainActor () -> [String: ShareItem] = { [:] },
        held: @escaping @MainActor () -> Bool = { false }
    ) {
        self.itemNames = itemNames
        self.held = held
        self.connections = connections
        self.ops = ops
        self.quietOps = quietOps ?? ops
        self.openUnlockWindow = openUnlockWindow
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

    /// Changes the kept events (in memory only).
    func edit(_ f: (inout [StoredEvent]) -> Void) {
        var next = stored
        f(&next)
        guard next != stored else { return }
        stored = next
        storedVersion += 1
    }

    /// The vault is no longer open on this phone (locked, or a lock was asked for), or it is held or due (§3.6.3): every
    /// approval is dropped from memory, the events kept as well as the lists; an unlock, or a passed owner check, reads
    /// the lists again. A read on its way is not published.
    public func forgetOpenVault() {
        generation += 1
        forgetCount += 1
        arrivedSinceForget = []
        pendingReadTs = [:]
        mergedListTs = nil
        closedAsks = []
        openAsksError = nil
        ignoredDuringRead = []
        pendingListAnswered = false
        sessionClosedAt = [:]
        listed = []
        if !stored.isEmpty {
            stored = []
            storedVersion += 1
        }
        decidedLog = []
        batchLog = []
        forgetDeviceSessions()
    }

    public func mayHaveBeenDropped(_ key: String) -> Bool {
        // Once `pending.list` has been read through since the last drop, an ask it does not list was decided, expired or
        // withdrawn, not lost (VAULT-MESSAGING 0.70.0 §10.4.2); every event-only ask is of the kinds it lists.
        PendingApproval.eventOnly(key: key) && !arrivedSinceForget.contains(key) && !pendingListAnswered
    }

    /// Forgets everything (a wipe, or a deleted vault).
    public func clear() { forgetOpenVault() }

    // MARK: - Events

    /// One event of the vault (§9.1): an approval to keep, or another device's decision.
    public func onEvent(_ m: VaultMessage) {
        if ApprovalParser.types.contains(m.type) {
            keep(m.type, m.object, ts: m.ts)
        } else if m.type == "sync.event" {
            onSync(m.object, ts: m.ts)
        }
    }

    /// Whether the creation of [p] came after its close: an ask closed or decided is final (its id is unique), and a
    /// session request is refused when its device's session request was closed at or after it (VAULT-MESSAGING 0.70.0 §10.4.2).
    private func closedAsk(_ p: PendingApproval, ts: Date?) -> Bool {
        guard Self.isOpenAskKey(p.key) else { return false }
        if closedAsks.contains(where: { $0.key == p.key }) { return true }
        guard case .device(let d) = p, d.type == Self.sessionType, let id = d.deviceID, let ts, let closed = sessionClosedAt[id]
        else { return false }
        return closed.ts >= ts
    }

    /// Whether [key] is an ask of the kinds `pending.list` returns.
    static func isOpenAskKey(_ key: String) -> Bool {
        key.hasPrefix("auth:") || key.hasPrefix("device:\(approvalType):") || key.hasPrefix("device:\(sessionType):")
    }

    static let approvalType = "approval.pending"

    /// Whether [p] is a session request older than one kept for the same device: a device has at most one, and an older
    /// one that arrives after a newer one is dropped (§6.8).
    private func supersededSession(_ p: PendingApproval, ts: Date?) -> Bool {
        guard case .device(let d) = p, d.type == Self.sessionType, let id = d.deviceID, let ts else { return false }
        return stored.contains { e in
            guard case .device(let o)? = parsed(e) else { return false }
            return o.type == Self.sessionType && o.deviceID == id && (e.ts ?? .distantPast) > ts
        }
    }

    /// Removes the kept session requests of the device of [p], a session request.
    private func removeSessions(ofSameDeviceAs p: PendingApproval, from events: inout [StoredEvent]) {
        guard case .device(let d) = p, d.type == Self.sessionType, let id = d.deviceID else { return }
        events.removeAll { e in
            guard case .device(let o)? = parsed(e) else { return false }
            return o.type == Self.sessionType && o.deviceID == id
        }
    }

    /// [ts] the event's inner `ts`; nil for a body read from a request. This and ``onSync(_:ts:)``, the merge and the replay
    /// run on the main actor with no `await` between a decision on the cut or a close and the write it allows, so nothing can
    /// move the cut or prune in between.
    func keep(_ type: String, _ o: JsonObject, ts: Date? = nil) {
        if ignoredByPendingList(type, o, ts: ts) { return }
        guard let p = ApprovalParser.parse(type, o, at: now()) else { return }
        if closedAsk(p, ts: ts) || supersededSession(p, ts: ts) { return }
        let at = now()
        changes += 1
        changedAt[p.key] = changes
        arrivedSinceForget.insert(p.key)
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
            // A device has at most one session request, and a newer one replaces the older (§6.8).
            removeSessions(ofSameDeviceAs: p, from: &events)
            // Several `share.pending` batches of one rule add up (§10.12).
            let body = if case .share = p, let old { Self.mergedShare(old.body, o) } else { o.raw }
            events.append(StoredEvent(type: type, body: body, at: at, ts: ts))
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
    private func onSync(_ o: JsonObject, ts: Date) {
        let kind = VaultJSON.string(o, "kind") ?? ""
        // A closing event no later than the list read is ignored too: the list already says whether the ask is open
        // (VAULT-MESSAGING 0.70.0 §10.4.2).
        // Only against a list already merged, not a read on its way: that read may still fail, and a close applied is
        // protected by the merge (``mergePendingAsks``), not undone by it.
        // What the event says of the device's session holds whatever the list says of its request (0.78.0 §6.8 step 3).
        if kind == "device.session", let device = VaultJSON.string(o, "device_id") {
            deviceSessionEvent(device, expiresAt: ApprovalParser.instant(VaultJSON.string(o, "expires_at")))
        }
        if let cut = mergedListTs, Self.pendingClosing.contains(kind), ts <= cut { return }
        if kind == "share.decided", let id = VaultJSON.string(o, "rule_id") {
            return shareDecided(id, VaultJSON.strings(o, "included") + VaultJSON.strings(o, "declined"))
        }
        if kind == "device.session", let device = VaultJSON.string(o, "device_id") { return sessionClosed(device, ts: ts) }
        guard let (prefix, member) = Self.decidedKinds[kind], let id = VaultJSON.string(o, member) else { return }
        drop(prefix + id, closedAt: ts)
    }

    /// The `sync.event` kinds of another device's decision: the approval key's prefix and the member naming the request.
    static let decidedKinds: [String: (String, String)] = [
        "connection.authenticate.decided": ("auth:", "request_id"), "grant.request.decided": ("grant:", "request_id"),
        "critical-secret-use.decided": ("critical:", "request_id"), "approval.decided": ("device:approval.pending:", "approval_id"),
    ]

    /// `sync.event` `device.session`: the device's session request is closed (granted, denied or ended, §6.8); a device has at
    /// most one. Held or not, the read in progress is told (VAULT-MESSAGING 0.70.0 §10.4.2).
    private func sessionClosed(_ deviceID: String, ts: Date) {
        changes += 1
        sessionClosedAt[deviceID] = (changes, ts)
        // Only a request made no later than the close: a newer one of the device (made after it ended) stays.
        for e in stored where e.type == Self.sessionType && (e.ts ?? .distantPast) <= ts {
            if case .device(let d)? = parsed(e), d.deviceID == deviceID { drop(PendingApproval.device(d).key) }
        }
    }

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
        removeShareItems(gone, where: applies)
    }

    /// The items [gone] leave the share questions [applies] picks, in the list and the kept events; a question left empty
    /// goes.
    func removeShareItems(_ gone: Set<String>, where applies: (ShareDecision) -> Bool) {
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

    /// The keys of the share questions held (listed or kept) for the subject of rule [ruleID], that rule's own included.
    func shareKeys(subjectOf ruleID: String) -> Set<String> {
        var subject = "rule:\(ruleID)"
        if case .share(let d)? = find("share:\(ruleID)") { subject = Self.subjectKey(d) }
        let all = listed + stored.compactMap(parsed)
        var keys: Set<String> = ["share:\(ruleID)"]
        for case .share(let d) in all where Self.subjectKey(d) == subject { keys.insert(PendingApproval.share(d).key) }
        return keys
    }

    /// Whether the approval [key] is still held, listed or kept.
    func holds(_ key: String) -> Bool { listed.contains { $0.key == key } || stored.contains { parsed($0)?.key == key } }

    /// Drops the approval [key] from the kept events and the lists.
    func drop(_ key: String, closedAt ts: Date? = nil) {
        if Self.isOpenAskKey(key) {
            closedAsks.append(ClosedAsk(key: key, ts: ts))
            if closedAsks.count > Self.maxClosedAsks { closedAsks.removeFirst() }
        }
        changes += 1
        changedAt[key] = changes
        droppedAt[key] = changes
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
        let pending = await readPendingAsks(o, generation: g)
        defer { finishPendingRead(pending, generation: g) }
        guard g == generation else { return }
        switch pending.result {
        case .failed(let kind): openAsksError = kind
        case .answered, .unsupported: openAsksError = nil
        }
        let changed = { (key: String) in (self.changedAt[key] ?? 0) > since }
        // A list the vault did not answer covers nothing: what was known of it stays (VAULT-MESSAGING 0.55.7 §10.12).
        let next = mergedWithChanges(lists.approvals(at: t), since: since, changed: changed) + listed.filter { !lists.covers($0) }
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
        if case .answered(let asks, let readTs) = pending.result {
            mergePendingAsks(asks, readTs: readTs, at: t, since: since, changed: changed)
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
    /// the read and were not decided after (VAULT-MESSAGING 0.55.7 §10.12, rules 1 and 2). The kept event adds up every
    /// batch, older ones too: an item the vault no longer lists does not come back from it.
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
                // Dropped during the read with no batch since: gone. A decision that emptied a batch's event is not a drop.
                if (droppedAt[a.key] ?? 0) > since, !events.contains(where: { $0.key == a.key }) { return nil }
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
        // An answer from before a lock, a hold or a wipe is not kept.
        guard g == generation else { return }
        // Kept as the event would have been; the payload is shown only if it matches the listed hash.
        keep("critical-secret-use.pending", body)
    }
}
