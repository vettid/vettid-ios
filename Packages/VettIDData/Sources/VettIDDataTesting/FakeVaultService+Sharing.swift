#if DEBUG
import Foundation
import VettIDCrypto
import VettIDVault

// Fixtures (JSON bodies of the fake vault) stay on one line each.
// swiftlint:disable line_length

/// TEST ONLY. One grant as the fake vault keeps it (VAULT-MESSAGING §10.12): one connection may read one item. A grant
/// given is one a share rule of the member's issued; a received one is what a connection shared with the member, with the
/// content its vault would seal to a fetch.
struct FakeGrant {
    var id: String
    var connectionID: String
    var ref: String
    var name: String
    var category = "other"
    var ruleID: String?
    var uses: Int?
    var used = 0
    var state = "active"
    var expiresAt: String?
    var perHour: Int?
    var perDay: Int?
    /// A received grant's `labels` (JSON) and the content its connection's vault seals to a fetch (JSON).
    var labels = "[]"
    var content = "{}"
    /// A refusal the connection's vault answers the fetches with, and its `retry_after`.
    var refusal: String?
    var retryAfter: Int?

    func json(_ direction: String) -> String {
        let b = JsonBuilder().string("grant_id", id).string("connection_id", connectionID).string("direction", direction).string("kind", "item").string("ref", ref)
        if let ruleID { b.string("rule_id", ruleID) }
        b.string("name", name).string("category", category)
        if direction == "received" { b.raw("labels", labels) }
        if let uses { b.uint("uses", UInt64(uses)) }
        b.uint("used", UInt64(used))
        if perHour != nil || perDay != nil {
            let l = JsonBuilder()
            if let perHour { l.uint("per_hour", UInt64(perHour)) }
            if let perDay { l.uint("per_day", UInt64(perDay)) }
            b.raw("limits", l.build())
        }
        if let expiresAt { b.string("expires_at", expiresAt) }
        return b.string("state", state).string("created_at", "2026-10-21T12:00:00Z").build()
    }
}

/// TEST ONLY. A request this vault made of a connection (`grant.request`): its entries exactly as sent.
struct FakeGrantAsk {
    var id: String
    var connectionID: String
    var items: [String]
    var state = "pending"

    var json: String {
        JsonBuilder().string("request_id", id).string("connection_id", connectionID).raw("items", JsonBuilder.array(items)).string("state", state).build()
    }
}

/// TEST ONLY. The grants and the requests of the fake vault.
struct FakeGrantStore {
    var given: [FakeGrant] = []
    var received: [FakeGrant] = []
    var requested: [FakeGrantAsk] = []
    var nextRule = 1_000
    /// The types of the sharing requests the vault received, with `:dry` for a dry run.
    var seen: [String] = []
}

// TEST ONLY. Share rules and grants as vettid-vault answers them (VAULT-MESSAGING §10.12, `features/items`,
// `features/grants`): `share.rule.set` with its checks (1–16 tags none reserved, `match`, `access: read`, `mode`, `uses`,
// `per_hour`, `per_day`, an end in the future and at most 3,650 days ahead, `status_ttl` refused for a connection, the
// limits of 64 rules per subject and 512 in all, `conflict` on a stale `version`) and its dry run (`matches` with
// `state`, `outcome` and `ask_rule_id`); a saved rule includes or asks about the items that match it, `ask` winning over
// `auto` for one subject, and withdraws what stopped matching; `share.rule.delete`; `share.pending.list`;
// `grant.request` and `grant.revoke`; and `grant.fetch`, whose `grant.value` is sealed to the request's `reply_key` with
// the spec's grant seal. A connection's own vault is emulated by ``peerSharesItem(_:ref:name:category:fields:notes:uses:perHour:perDay:)``
// and the switches below. Callers of the requests hold ``cond``.
extension FakeVaultService {
    private static let maxRulesPerSubject = 64
    private static let maxRules = 512
    private static let at = "2026-10-21T12:00:00Z"

    // MARK: - The connections' side, and what the vault kept

    /// A connection shares an item with the member (`data.shared`, §10.12): a received grant, `grant.event{shared}` and a
    /// feed item. Returns the grant's id. [fields] are the granted fields' labels and values.
    @discardableResult
    public func peerSharesItem(
        _ connectionID: String, ref: String, name: String, category: String = "other", fields: [ItemFieldSeed] = [], notes: String? = nil,
        uses: Int? = nil, perHour: Int? = nil, perDay: Int? = nil
    ) throws -> String {
        try locked {
            let id = Ulid.new()
            let list = fields.enumerated().map { i, f -> (String, String) in
                let id = "f\(i + 1)"
                let value = f.kind == "address" ? f.value : JsonBuilder.quote(f.value)
                return (JsonBuilder().string("field_id", id).string("label", f.label).string("kind", f.kind).build(),
                        JsonBuilder().string("field_id", id).string("label", f.label).string("kind", f.kind).raw("value", value).build())
            }
            let content = JsonBuilder().string("item_id", ref).uint("version", 1).string("name", name).string("category", category).raw("fields", JsonBuilder.array(list.map(\.1)))
            if let notes { content.string("notes", notes) }
            var g = FakeGrant(id: id, connectionID: connectionID, ref: ref, name: name, category: category, uses: uses, perHour: perHour, perDay: perDay)
            g.labels = JsonBuilder.array(list.map(\.0))
            g.content = content.build()
            grants.received.append(g)
            record("grant.received", connectionID: connectionID, ref: id, direction: "in")
            try reply("grant.event", JsonBuilder().string("connection_id", connectionID).string("event", "shared").raw("grants", JsonBuilder.array([g.json("received")])).build())
            try addFeedItem("grant.shared", connectionID: connectionID, ref: id)
            return id
        }
    }

    /// The connection's vault refuses the fetches of a received grant with [error] (and `retry_after` for `rate_limited`).
    public func peerRefusesFetches(of grantID: String, with error: String?, retryAfter: Int? = nil) {
        locked {
            guard let i = grants.received.firstIndex(where: { $0.id == grantID }) else { return }
            grants.received[i].refusal = error
            grants.received[i].retryAfter = retryAfter
        }
    }

    /// The connection answers a request this vault made (`grant.event{granted | denied}`), and its state follows.
    public func peerAnswersRequest(_ requestID: String, granted: Bool) throws {
        try locked {
            guard let i = grants.requested.firstIndex(where: { $0.id == requestID }) else { return }
            grants.requested[i].state = granted ? "granted" : "denied"
            try reply("grant.event", JsonBuilder().string("connection_id", grants.requested[i].connectionID).string("event", granted ? "granted" : "denied").string("request_id", requestID).build())
        }
    }

    /// The types of the sharing requests the vault received, with `:dry` for a dry run.
    public var sharingRequests: [String] { locked { grants.seen } }

    /// The items of a rule by state.
    public struct RuleItems: Equatable, Sendable {
        public let included: [String]
        public let pending: [String]
        public let declined: [String]
    }

    /// The items a rule includes, asks about and has declined; nil without the rule.
    public func ruleItems(_ ruleID: String) -> RuleItems? {
        locked {
            tagStore.rules.first { $0.id == ruleID }.map { RuleItems(included: $0.included, pending: activity.asks.shares[ruleID] ?? [], declined: $0.declined) }
        }
    }

    /// The state of a grant given or received; nil without it.
    public func grantState(_ grantID: String) -> String? {
        locked { (grants.given + grants.received).first { $0.id == grantID }?.state }
    }

    /// The grants a rule issued: item and state.
    public func ruleGrants(_ ruleID: String) -> [(item: String, state: String)] {
        locked { grants.given.filter { $0.ruleID == ruleID }.map { ($0.ref, $0.state) } }
    }

    // MARK: - The requests

    func sharingRequest(_ m: Inner, _ body: JsonObject) throws {
        grants.seen.append(m.type + ((try? body.bool("dry_run")) == true ? ":dry" : ""))
        do {
            switch m.type {
            case "share.rule.set": try ruleSet(m, body)
            case "share.rule.delete": try ruleDelete(m, body)
            case "share.pending.list": try pendingList(m, body)
            case "grant.request": try grantRequest(m, body)
            case "grant.revoke": try grantRevoke(m, body)
            default: try grantFetch(m, body)
            }
        } catch let r as ItemRefusal {
            try reply(m.type, r.body, re: m.id, error: r.code)
        } catch is CryptoError {
            try reply(m.type, "{}", re: m.id, error: "bad_request")
        }
    }

    // MARK: - Rules

    private func items(of r: FakeTagStore.Rule) -> [FakeStoredItem] {
        items.items.values.filter { r.matches($0.tags) }.sorted { $0.id < $1.id }
    }

    /// What an item gaining [r] becomes (§10.12 Overlapping rules): an `ask` rule asks; an `auto` rule includes unless an
    /// `ask` rule of the subject covers the item and does not include it (the lowest `rule_id` is named).
    private func gain(_ item: FakeStoredItem, in r: FakeTagStore.Rule) -> (outcome: String, askRule: String?) {
        guard r.mode == "auto" else { return ("ask", nil) }
        let holders = tagStore.rules.filter { $0.id != r.id && $0.connectionID == r.connectionID && $0.mode == "ask" && $0.matches(item.tags) && !$0.included.contains(item.id) }
        if let first = holders.map(\.id).min() { return ("ask", first) }
        return ("include", nil)
    }

    private func ruleSet(_ m: Inner, _ body: JsonObject) throws { // swiftlint:disable:this cyclomatic_complexity function_body_length
        let dry = (try? body.bool("dry_run")) == true
        let subject = try body.obj("subject")
        // An agent's rule needs the credential key (§10.11): the fake has no agents.
        guard !subject.has("agent_id"), !body.has("status_ttl") else { throw ItemRefusal(code: "bad_request") }
        let conn = try subject.string("connection_id")
        guard social.connections[conn] != nil else { throw ItemRefusal(code: "not_found") }
        var tags: [String] = []
        for v in try body.array("tags") {
            let t = try ItemSpec.normalizeTag(try v.asString())
            if !tags.contains(t) { tags.append(t) }
        }
        let match = try body.optString("match") ?? "any", mode = try body.optString("mode") ?? "ask"
        guard (1...16).contains(tags.count), ["any", "all"].contains(match), ["ask", "auto"].contains(mode), try body.optString("access") ?? "read" == "read" else {
            throw ItemRefusal(code: "bad_request")
        }
        let uses = try body.optUint("uses", min: 1, max: 10_000), perHour = try body.optUint("per_hour", min: 1, max: 3_600), perDay = try body.optUint("per_day", min: 1, max: 86_400)
        let endText = try body.optString("expires_at")
        if let endText {
            let end = try Timestamps.parseMillis(endText)
            guard end > vaultNow, end < vaultNow.addingTimeInterval(3_650 * 86_400) else { throw ItemRefusal(code: "bad_request") }
        }
        let includeExisting = body.has("include_existing") ? try body.bool("include_existing") : true
        var old: FakeTagStore.Rule?
        if let ruleID = try body.optString("rule_id") {
            guard let o = tagStore.rules.first(where: { $0.id == ruleID }) else { throw ItemRefusal(code: "not_found") }
            guard let v = try body.optUint("version", min: 0, max: StrictJson.maxSafeInteger) else { throw ItemRefusal(code: "bad_request") }
            guard Int64(v) == o.version else { throw ItemRefusal(code: "conflict") }
            guard o.connectionID == conn else { throw ItemRefusal(code: "bad_request") }
            old = o
        } else if !dry {
            guard tagStore.rules.count { $0.connectionID == conn } < Self.maxRulesPerSubject else { throw ItemRefusal(code: "limit", body: #"{"limit":"share_rules_subject","max":64}"#) }
            guard tagStore.rules.count < Self.maxRules else { throw ItemRefusal(code: "limit", body: #"{"limit":"share_rules","max":512}"#) }
        }
        let id = old?.id ?? String(format: "01JRULE%019d", grants.nextRule)
        var rule = FakeTagStore.Rule(
            id: id, connectionID: conn, tags: tags, mode: mode, version: (old?.version ?? 0) + 1, match: match, uses: uses.map(Int.init),
            perHour: perHour.map(Int.init), perDay: perDay.map(Int.init), expiresAt: endText, includeExisting: includeExisting
        )
        let oldPending = Set(old.map { activity.asks.shares[$0.id] ?? [] } ?? [])
        let matching = items(of: rule)
        let state = { (item: String) -> String? in
            guard let old else { return nil }
            return old.included.contains(item) ? "included" : oldPending.contains(item) ? "pending" : old.declined.contains(item) ? "declined" : nil
        }
        // What saving does to each item: new gains (with `include_existing`), and a pending item an `ask` rule held that the
        // rule, now `auto`, includes.
        let outcomes = matching.filter { $0.sensitivity != "critical" }.reduce(into: [String: (String, String?)]()) { out, it in
            switch state(it.id) {
            case nil where includeExisting: out[it.id] = gain(it, in: rule)
            case "pending"? where old?.mode == "ask" && mode == "auto":
                let g = gain(it, in: rule)
                if g.outcome == "include" { out[it.id] = g }
            default: break
            }
        }
        if dry {
            let entries = matching.map { it -> String in
                let b = JsonBuilder().string("item_id", it.id).string("name", it.name).string("category", it.category).string("sensitivity", it.sensitivity)
                if let s = state(it.id) { b.string("state", s) }
                if let o = outcomes[it.id] {
                    b.string("outcome", o.0)
                    if let a = o.1 { b.string("ask_rule_id", a) }
                }
                return b.build()
            }
            return try reply(m.type, #"{"matches":\#(JsonBuilder.array(entries)),"total":\#(entries.count)}"#, re: m.id)
        }
        if old == nil { grants.nextRule += 1 }
        let ids = Set(matching.filter { $0.sensitivity != "critical" }.map(\.id))
        if let old {
            // An included item that stopped matching is withdrawn, its grant revoked; a pending one is dropped.
            rule.included = old.included.filter(ids.contains)
            rule.declined = old.declined.filter(ids.contains)
            for gone in old.included where !ids.contains(gone) { revokeGiven(rule: id, item: gone) }
        }
        var pending = oldPending.filter(ids.contains).sorted()
        var asking: [(String, String?)] = []
        for it in matching where outcomes[it.id] != nil {
            let (outcome, askRule) = outcomes[it.id]!
            if outcome == "include" {
                rule.included.append(it.id)
                pending.removeAll { $0 == it.id }
                issue(rule, it)
            } else {
                pending.append(it.id)
                asking.append((it.id, askRule))
            }
        }
        if let i = tagStore.rules.firstIndex(where: { $0.id == id }) { tagStore.rules[i] = rule } else { tagStore.rules.append(rule) }
        activity.asks.shares[id] = pending.isEmpty ? nil : pending
        activity.asks.shareSubjects[id] = conn
        record(old == nil ? "share.rule.created" : "share.rule.updated", ref: id)
        try reply(m.type, rule.json(pending: pending), re: m.id)
        if !asking.isEmpty {
            let list = asking.compactMap { a in items.items[a.0].map { Self.pendingItem($0, askRule: a.1, shared: false) } }
            try reply("share.pending", JsonBuilder().string("rule_id", id).raw("subject", JsonBuilder().string("connection_id", conn).build()).raw("items", JsonBuilder.array(list)).string("reason", "rule").build())
            try addFeedItem("share.pending", connectionID: conn, ref: id)
        }
    }

    private static func pendingItem(_ it: FakeStoredItem, askRule: String?, shared: Bool) -> String {
        let b = JsonBuilder().string("item_id", it.id).string("name", it.name).string("category", it.category).string("sensitivity", it.sensitivity)
        if let askRule { b.string("ask_rule_id", askRule) }
        if shared { b.bool("shared", true) }
        return b.build()
    }

    /// A rule includes an item: its grant (§10.12: one per included readable item, carrying the rule's `uses`, end and limits).
    private func issue(_ r: FakeTagStore.Rule, _ item: FakeStoredItem) {
        guard !grants.given.contains(where: { $0.ruleID == r.id && $0.ref == item.id && $0.state == "active" }) else { return }
        grants.given.append(FakeGrant(id: Ulid.new(), connectionID: r.connectionID, ref: item.id, name: item.name, category: item.category, ruleID: r.id, uses: r.uses, expiresAt: r.expiresAt, perHour: r.perHour, perDay: r.perDay))
        record("grant.issued", connectionID: r.connectionID, ref: item.id, direction: "out")
    }

    private func revokeGiven(rule: String, item: String) {
        for i in grants.given.indices where grants.given[i].ruleID == rule && grants.given[i].ref == item && grants.given[i].state == "active" {
            grants.given[i].state = "revoked"
            record("grant.revoked", connectionID: grants.given[i].connectionID, ref: grants.given[i].id, direction: "out")
        }
    }

    /// A decision on [ruleID]'s question (§10.12 One answer per item and subject): an inclusion also includes the item in
    /// every rule of the subject where it waits; a decline also declines it where it waits or is included (the grant
    /// revoked). Callers hold ``cond``.
    func shareDecided(_ ruleID: String, included: [String], declined: [String]) { // swiftlint:disable:this cyclomatic_complexity
        guard let r = tagStore.rules.first(where: { $0.id == ruleID }) else { return }
        for item in included {
            for i in tagStore.rules.indices where tagStore.rules[i].connectionID == r.connectionID {
                let id = tagStore.rules[i].id
                guard id == ruleID || (activity.asks.shares[id] ?? []).contains(item) else { continue }
                if let rest = activity.asks.shares[id]?.filter({ $0 != item }) { activity.asks.shares[id] = rest.isEmpty ? nil : rest }
                if !tagStore.rules[i].included.contains(item) { tagStore.rules[i].included.append(item) }
                if let it = items.items[item] { issue(tagStore.rules[i], it) }
            }
        }
        for item in declined {
            for i in tagStore.rules.indices where tagStore.rules[i].connectionID == r.connectionID {
                let id = tagStore.rules[i].id
                let waits = (activity.asks.shares[id] ?? []).contains(item), has = tagStore.rules[i].included.contains(item)
                guard id == ruleID || waits || has else { continue }
                if let rest = activity.asks.shares[id]?.filter({ $0 != item }) { activity.asks.shares[id] = rest.isEmpty ? nil : rest }
                tagStore.rules[i].included.removeAll { $0 == item }
                if !tagStore.rules[i].declined.contains(item) { tagStore.rules[i].declined.append(item) }
                revokeGiven(rule: id, item: item)
            }
        }
    }

    private func ruleDelete(_ m: Inner, _ body: JsonObject) throws {
        let id = try body.string("rule_id")
        guard tagStore.rules.contains(where: { $0.id == id }) else { throw ItemRefusal(code: "not_found") }
        for i in grants.given.indices where grants.given[i].ruleID == id && grants.given[i].state == "active" { grants.given[i].state = "revoked" }
        tagStore.rules.removeAll { $0.id == id }
        activity.asks.shares[id] = nil
        record("share.rule.deleted", ref: id)
        try reply(m.type, "{}", re: m.id)
    }

    /// `share.pending.list` (0.21.0): one entry per rule and item, sorted by rule then item; an `auto` rule's entry names the
    /// `ask` rule that holds it (`ask_rule_id`) and an item another rule of the subject already includes says `shared`.
    private func pendingList(_ m: Inner, _ body: JsonObject) throws {
        let rule = try body.optString("rule_id"), conn = try body.optString("connection_id"), agent = try body.optString("agent_id")
        guard [rule, conn, agent].compactMap({ $0 }).count <= 1 else { throw ItemRefusal(code: "bad_request") }
        let limit = Int(try body.optUint("limit", min: 1, max: 500) ?? 100)
        let after = try body.optString("after")
        var entries: [(key: String, json: String)] = []
        for r in activity.asks.shares.keys.sorted() where rule == nil || rule == r {
            let subject = activity.asks.shareSubjects[r] ?? tagStore.rules.first { $0.id == r }?.connectionID
            guard conn == nil || conn == subject, agent == nil else { continue }
            let this = tagStore.rules.first { $0.id == r }
            for item in (activity.asks.shares[r] ?? []).sorted() {
                let it = items.items[item] ?? FakeStoredItem(id: item, name: "Item \(item.suffix(2))")
                let others = tagStore.rules.filter { $0.id != r && $0.connectionID == subject }
                let askRule = this?.mode == "auto" ? others.filter { $0.mode == "ask" && $0.matches(it.tags) && !$0.included.contains(item) }.map(\.id).min() : nil
                let b = JsonBuilder().string("rule_id", r).raw("subject", JsonBuilder().string("connection_id", subject ?? "").build()).string("item_id", item)
                    .string("name", it.name).string("category", it.category).string("sensitivity", it.sensitivity).string("at", Self.at)
                if let askRule { b.string("ask_rule_id", askRule) }
                if others.contains(where: { $0.included.contains(item) }) { b.bool("shared", true) }
                entries.append(("\(r)|\(item)", b.build()))
            }
        }
        if let after { entries = entries.filter { $0.key > after } }
        let page = Array(entries.prefix(limit))
        var answer = JsonBuilder().raw("pending", JsonBuilder.array(page.map(\.json)))
        if entries.count > page.count, let last = page.last { answer = answer.string("next", last.key) }
        try reply(m.type, answer.build(), re: m.id)
    }

    // MARK: - Grants

    private func grantRequest(_ m: Inner, _ body: JsonObject) throws {
        let conn = try body.string("connection_id")
        let entries = try body.array("items")
        let reason = try body.optString("reason")
        _ = try body.optUint("uses", min: 1, max: 100)
        _ = try body.optUint("expires_in", min: 60, max: 31_536_000)
        guard (1...16).contains(entries.count), (reason?.utf8.count ?? 0) <= 256 else { throw ItemRefusal(code: "bad_request") }
        for v in entries {
            let e = try v.asObject()
            let kind = try e.string("kind"), ref = try e.string("ref")
            guard ["item", "category"].contains(kind), !ref.isEmpty, kind == "item" || ItemSpec.isValidCategory(ref), (try e.optString("label")?.utf8.count ?? 0) <= 128 else {
                throw ItemRefusal(code: "bad_request")
            }
        }
        guard social.connections[conn] != nil else { throw ItemRefusal(code: "not_found") }
        let id = Ulid.new()
        grants.requested.append(FakeGrantAsk(id: id, connectionID: conn, items: entries.map(\.raw)))
        record("grant.requested", connectionID: conn, ref: id, direction: "out")
        try reply(m.type, JsonBuilder().string("request_id", id).build(), re: m.id)
    }

    private func grantRevoke(_ m: Inner, _ body: JsonObject) throws {
        let id = try body.string("grant_id")
        if let i = grants.given.firstIndex(where: { $0.id == id }) {
            if grants.given[i].state == "active" { grants.given[i].state = "revoked" }
        } else if let i = grants.received.firstIndex(where: { $0.id == id }) {
            if grants.received[i].state == "active" { grants.received[i].state = "revoked" }
        } else {
            throw ItemRefusal(code: "not_found")
        }
        record("grant.revoked", ref: id)
        try reply(m.type, "{}", re: m.id)
    }

    /// `grant.fetch`: the `fetch_id` first, then `grant.value` to this device: sealed content and `uses_left`, or the
    /// connection's refusal (`revoked`, `expired`, `exhausted`, the test's own, with `retry_after` for `rate_limited`).
    private func grantFetch(_ m: Inner, _ body: JsonObject) throws {
        let id = try body.string("grant_id")
        let reply = try KemPublicKey.parse(try body.base64("reply_key", 1_216))
        guard let i = grants.received.firstIndex(where: { $0.id == id }) else { throw ItemRefusal(code: "not_found") }
        let fetchID = Ulid.new()
        try self.reply(m.type, JsonBuilder().string("fetch_id", fetchID).build(), re: m.id)
        var g = grants.received[i]
        let ended = g.expiresAt.flatMap { try? Timestamps.parseMillis($0) }.map { $0 < vaultNow } ?? false
        let error = g.refusal ?? (g.state == "revoked" ? "revoked" : ended ? "expired" : (g.uses.map { g.used >= $0 } ?? false) ? "exhausted" : nil)
        let head = JsonBuilder().string("connection_id", g.connectionID).string("fetch_id", fetchID).string("grant_id", id)
        if let error {
            head.string("error", error)
            if let r = g.retryAfter { head.uint("retry_after", UInt64(r)) }
            return try self.reply("grant.value", head.build())
        }
        g.used += 1
        if let u = g.uses, g.used >= u { g.state = "used" }
        grants.received[i] = g
        let sealed = try GrantSeal.sealValue(reply: reply, grantID: id, fetchID: fetchID, value: Array(g.content.utf8))
        head.base64("value_sealed", sealed)
        if let u = g.uses { head.uint("uses_left", UInt64(max(0, u - g.used))) }
        try self.reply("grant.value", head.build())
    }
}

// swiftlint:enable line_length
#endif
