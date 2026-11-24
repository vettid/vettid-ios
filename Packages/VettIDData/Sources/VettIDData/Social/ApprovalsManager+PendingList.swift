import Foundation
import VettIDCrypto
import VettIDVault

/// The asks that arrive only as events, read back with `pending.list` (VAULT-MESSAGING 0.70.0 §10.4.2). The app reads every
/// page after the unlock and after a passed owner check, and replaces its kept events of the kinds it handles with the list.
/// The `action` and `location` entries are not handled on this phone (it has no screen for either): they are skipped, never
/// parsed and never a failure.
extension ApprovalsManager {
    static let sessionType = "device.session.pending"

    /// The event type each `pending.list` kind repeats, for the kinds this app handles.
    static let pendingKinds: [String: String] = [
        "authenticate": "connection.authenticate.pending", "session": sessionType, "approval": "approval.pending",
    ]

    /// The event types of those kinds.
    static let pendingTypes = Set(pendingKinds.values)

    /// At most this many pages are read in one go (chosen; not in the spec): the vault's limits keep the whole list far
    /// below it, and a vault that never ends its cursor does not hold the read.
    static let maxPendingPages = 100

    /// At most this many ignored creation events are kept for a read on its way (chosen; not in the spec).
    static let maxIgnoredDuringRead = 256

    /// The `sync.event` kinds that close an ask of those kinds (VAULT-MESSAGING 0.70.0 §10.4.2).
    static let pendingClosing: Set<String> = ["connection.authenticate.decided", "approval.decided", "device.session"]

    /// The asks of a list that can be taken: in its order, by key, with the device of each session request.
    struct ListedAsks {
        var order: [String]
        var byKey: [String: OpenAsk]
        var deviceOf: [String: String]
    }

    /// A creation event ignored for being no later than the list's time.
    struct IgnoredEvent {
        var type: String
        var body: JsonObject
        var ts: Date
        /// ``changes`` when it was ignored: a drop made after it is not undone by the replay.
        var mark: Int
    }

    /// Whether the creation event [ts] of [type] is ignored: as old as the list read, or older (VAULT-MESSAGING 0.70.0
    /// §10.4.2, §8.4). While a read is on its way it is kept for the end of the read, in case that read does not merge.
    func ignoredByPendingList(_ type: String, _ o: JsonObject, ts: Date?) -> Bool {
        guard let ts, let cut = pendingListTs, Self.pendingTypes.contains(type), ts <= cut else { return false }
        if !pendingReadTs.isEmpty {
            ignoredDuringRead.append(IgnoredEvent(type: type, body: o, ts: ts, mark: changes))
            if ignoredDuringRead.count > Self.maxIgnoredDuringRead { ignoredDuringRead.removeFirst() }
        }
        return true
    }

    /// An entry of the list: the event type it repeats and its `body` exactly as received.
    struct OpenAsk: Equatable {
        var type: String
        var body: String
    }

    /// What a read of `pending.list` did (``onOpenAsksRead``).
    enum OpenAsksRead: Equatable {
        /// Every page read and merged: the approval keys it listed, and the read's stamp (``readsBegun`` when it began).
        case merged(Set<String>, stamp: Int)
        /// `unsupported_type` (a vault before 0.70.0, or one known as such): there are no open asks to read.
        case unsupported
        /// A page failed, or an answer read later was merged first: nothing merged.
        case failed
    }

    /// [read] merged when it answered (``mergePendingAsks(_:readTs:at:since:changed:)``), and what it did.
    func merged(_ read: PendingRead, at t: Date, since: Int, changed: (String) -> Bool, stamp: Int) -> OpenAsksRead {
        switch read {
        case .answered(let asks, let readTs):
            mergePendingAsks(asks, readTs: readTs, at: t, since: since, changed: changed).map { .merged($0, stamp: stamp) } ?? .failed
        case .unsupported: .unsupported
        case .failed: .failed
        }
    }

    /// What the read of `pending.list` found.
    enum PendingRead {
        /// Every page was read; [ts] is the first page's `ts`.
        case answered([OpenAsk], ts: Date)
        /// Not asked, or the vault answered `unsupported_type`: nothing is covered and nothing dropped.
        case unsupported
        /// A page failed (the network, `owner_check_required` while held, ...), or the listing never ended or restarted
        /// twice: nothing is merged, what is known stays, and the next refresh tries again. [kind] is what the screen says.
        case failed(FailureKind)
    }

    /// A read and its number, for ``finishPendingRead(_:generation:)``.
    struct PendingReading {
        var id: Int?
        var result: PendingRead
    }

    /// How one pass over the pages ended.
    private enum PagesEnd {
        case complete([OpenAsk], ts: Date)
        /// A stale cursor started the listing again from the beginning (VAULT-MESSAGING 0.70.0 §10.4.2): an ask came twice.
        case restarted
        /// `next` repeated the cursor asked for, or the pages never ended: the list is partial.
        case incomplete
    }

    /// The vault was opened (an unlock, not a passed owner check after a hold, which only drops and reads again): a vault
    /// that did not know `pending.list` is asked again (VAULT-MESSAGING 0.70.0 §10.4.2 "Older vaults").
    public func vaultOpened() { pendingListUnsupported = false }

    /// Reads every page of `pending.list` ([g] the generation the read began in). The first page's `ts` counts from then on
    /// (``pendingListTs``), so that events processed during the read are judged by it too, until the read ends
    /// (``finishPendingRead(_:generation:)``): a read that does not merge leaves no cut behind. A list is merged only when
    /// it is complete: `next` absent or empty. A cursor gone stale starts the listing again, which shows as an ask listed
    /// twice; the read then starts once more with a fresh first page, and fails if that is not complete either.
    func readPendingAsks(_ o: any ApprovalOps, generation g: Int) async -> PendingReading {
        guard !pendingListUnsupported else { return PendingReading(id: nil, result: .unsupported) }
        pendingReadCount += 1
        let id = pendingReadCount
        do {
            for _ in 0..<2 {
                switch try await readPendingPages(o, id: id, generation: g) {
                case .complete(let asks, let ts): return PendingReading(id: id, result: .answered(asks, ts: ts))
                case .restarted: continue
                case .incomplete: return PendingReading(id: id, result: .failed(.other))
                }
            }
            return PendingReading(id: id, result: .failed(.other))
        } catch {
            let kind = (VaultFailures.map(error) as? VaultFailure)?.kind ?? .other
            guard g == generation, kind == .notSupported else { return PendingReading(id: id, result: .failed(kind)) }
            pendingListUnsupported = true
            return PendingReading(id: id, result: .unsupported)
        }
    }

    private func readPendingPages(_ o: any ApprovalOps, id: Int, generation g: Int) async throws -> PagesEnd {
        var asks: [OpenAsk] = []
        var seen = Set<String>()
        var after: String?
        var first = Date.distantPast
        for page in 0..<Self.maxPendingPages {
            let answer = try await o.pendingListPage(after: after, limit: nil)
            if page == 0 {
                first = answer.ts
                if g == generation { pendingReadTs[id] = answer.ts }
            }
            let (entries, next) = Self.entries(of: answer)
            for (kind, body) in entries {
                // An ask's id is unique: one listed twice means the listing started again.
                let ask = ["approval_id", "request_id", "invocation_id"].lazy.compactMap { VaultJSON.string(body, $0) }.first
                if let ask, !seen.insert("\(kind):\(ask)").inserted { return .restarted }
                // Other kinds (`action`, `location`, and any a later release adds) are skipped.
                if let type = Self.pendingKinds[kind] { asks.append(OpenAsk(type: type, body: body.raw)) }
            }
            guard let next, !next.isEmpty else { return .complete(asks, ts: first) }
            if next == after { return .incomplete }
            after = next
        }
        return .incomplete
    }

    /// The entries `{kind, body}` of a page and its `next`. An answer that did not read strictly (a duplicate member somewhere) is
    /// read leniently, and every `approval` in it is deny only (ANDROID-PLAN 0.1.138 AA8 "Fail closed"; ``ApprovalParser/denyOnly(_:)``).
    static func entries(of answer: PendingListPage) -> (entries: [(kind: String, body: JsonObject)], next: String?) {
        if answer.strict {
            let all = VaultJSON.objects(answer.body, "asks").compactMap { e in
                VaultJSON.obj(e, "body").map { (kind: VaultJSON.string(e, "kind") ?? "", body: $0) }
            }
            return (all, VaultJSON.string(answer.body, "next"))
        }
        guard let top = (try? JSONSerialization.jsonObject(with: Data(answer.bytes))) as? [String: Any] else { return ([], nil) }
        let all = (top["asks"] as? [Any] ?? []).compactMap { e -> (kind: String, body: JsonObject)? in
            guard let e = e as? [String: Any], let body = e["body"] as? [String: Any] else { return nil }
            let kind = e["kind"] as? String ?? ""
            let strict = kind == "approval" ? ApprovalParser.denyOnly(body) : ApprovalParser.reencoded(body)
            return strict.map { (kind: kind, body: $0) }
        }
        return (all, top["next"] as? String)
    }

    /// The end of a read (merged or not): its cut goes unless a list was merged with it, and when no read is left on its
    /// way the creation events ignored meanwhile are applied again; any that the cut still covers are ignored again.
    func finishPendingRead(_ reading: PendingReading, generation g: Int) {
        guard g == generation, let id = reading.id else { return }
        pendingReadTs.removeValue(forKey: id)
        guard pendingReadTs.isEmpty else { return }
        let replay = ignoredDuringRead
        ignoredDuringRead = []
        for e in replay where !closedSince(e) { keep(e.type, e.body, ts: e.ts) }
    }

    /// Whether the ask of [e] was decided, dropped or closed after it was ignored (here or on another device).
    private func closedSince(_ e: IgnoredEvent) -> Bool {
        guard let p = ApprovalParser.parse(e.type, e.body, at: now()) else { return true }
        if (droppedAt[p.key] ?? 0) > e.mark { return true }
        guard case .device(let d) = p, let id = d.deviceID, let closed = sessionClosedAt[id] else { return false }
        return closed.change > e.mark && closed.ts >= e.ts
    }

    /// Replaces the kept events of the listed kinds with [asks], the list of the read whose first page had [readTs],
    /// merging by the ask's key: an ask the list does not hold is gone (decided elsewhere, expired or withdrawn), one it
    /// holds that is not kept comes back (received now, since the list does not say when; chosen; not in the spec), and
    /// what changed since [since] (an event later than [readTs] that arrived, a decision or a closing) is not undone. A
    /// list older than one merged before is not merged (chosen; not in the spec). A device has one session request at most.
    /// The approval keys `pending.list` listed, or nil when an answer read later was merged before this one (nothing
    /// merged).
    @discardableResult
    func mergePendingAsks(_ asks: [OpenAsk], readTs: Date, at t: Date, since: Int, changed: (String) -> Bool) -> Set<String>? {
        if let merged = mergedListTs, readTs < merged { return nil }
        mergedListTs = readTs
        // An event as old as the list, processed before its first page answered, is for the list to judge.
        func changedAfter(_ key: String, _ ts: Date?) -> Bool { changed(key) && !(ts.map { $0 <= readTs } ?? false) }
        let listed = listedAsks(asks, readTs: readTs, at: t, since: since)
        let (order, byKey, deviceOf) = (listed.order, listed.byKey, listed.deviceOf)
        pendingListAnswered = true
        noteMismatches(byKey)
        noteReplaced(byKey)
        // Closes no later than the list are for the list to judge now (and creations that old are ignored).
        closedAsks.removeAll { ($0.ts ?? .distantFuture) <= readTs }
        sessionClosedAt = sessionClosedAt.filter { $0.value.ts > readTs }
        edit { events in
            var kept: [StoredEvent] = []
            var have = Set<String>()
            var sessionDevices = Set<String>()
            for e in events {
                guard Self.pendingTypes.contains(e.type), let p = parsed(e) else {
                    kept.append(e)
                    continue
                }
                if replaced.contains(p.key) { continue }
                let listed = byKey[p.key]
                if changedAfter(p.key, e.ts) {
                    kept.append(e)
                } else if let listed {
                    // The list's body is the vault's current one (a renamed device); the time it was first received stays.
                    kept.append(StoredEvent(type: listed.type, body: listed.body, at: e.at, ts: e.ts))
                } else {
                    continue
                }
                have.insert(p.key)
                if case .device(let d) = p, d.type == Self.sessionType, let id = d.deviceID { sessionDevices.insert(id) }
            }
            for key in order where !have.contains(key) && !changed(key) && !replaced.contains(key) {
                guard let ask = byKey[key] else { continue }
                if let id = deviceOf[key], !sessionDevices.insert(id).inserted { continue }
                kept.append(StoredEvent(type: ask.type, body: ask.body, at: t))
            }
            events = kept
        }
        return Set(byKey.keys).subtracting(replaced)
    }

    /// AA8: an approval whose `pending.list` entry reads otherwise than the event kept for the same `approval_id` (what it asks,
    /// its flags, `previous_*`, `replaces` or `proxy`, its name, role, type or device) is deny only, while the vault holds it.
    private func noteMismatches(_ listed: [String: OpenAsk]) {
        var differ = Set<String>()
        for e in stored where e.type == Self.approvalType {
            guard case .device(let old)? = parsed(e), let ask = listed[PendingApproval.device(old).key] else { continue }
            guard let o = try? StrictJson.parseObject(Array(ask.body.utf8)),
                  case .device(let new)? = ApprovalParser.parse(ask.type, o, at: now()),
                  new.asksSame(as: old) else {
                differ.insert(PendingApproval.device(old).key)
                continue
            }
        }
        mismatched.formUnion(differ)
    }

    /// The approvals the listed ones replace, remembered as gone (their feed items read).
    private func noteReplaced(_ listed: [String: OpenAsk]) {
        for ask in listed.values {
            guard let o = try? StrictJson.parseObject(Array(ask.body.utf8)), let p = ApprovalParser.parse(ask.type, o, at: now()),
                  let r = Self.replacedKey(p), replaced.insert(r).inserted else { continue }
            changes += 1
            changedAt[r] = changes
            decided(r)
        }
    }

    /// The listed asks that can be taken, in the list's order, by key, with the device of each session request: expired
    /// ones are left out, and a session request whose device's session closed after the list was read.
    private func listedAsks(_ asks: [OpenAsk], readTs: Date, at t: Date, since: Int)
        -> ListedAsks {
        var order: [String] = []
        var byKey: [String: OpenAsk] = [:]
        var deviceOf: [String: String] = [:]
        for ask in asks {
            guard let o = try? StrictJson.parseObject(Array(ask.body.utf8)), let p = ApprovalParser.parse(ask.type, o, at: t),
                  (p.exp ?? .distantFuture) > t else { continue }
            if case .device(let d) = p, d.type == Self.sessionType, let id = d.deviceID {
                if let closed = sessionClosedAt[id], closed.change > since, closed.ts > readTs { continue }
                deviceOf[p.key] = id
            }
            if byKey.updateValue(ask, forKey: p.key) == nil { order.append(p.key) }
        }
        return ListedAsks(order: order, byKey: byKey, deviceOf: deviceOf)
    }
}
