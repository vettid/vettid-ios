#if DEBUG
import Foundation
import VettIDCrypto

// Fixtures (JSON bodies of the fake vault) stay on one line each.
// swiftlint:disable line_length

/// TEST ONLY. The fake vault's asks from connections and its member's decisions (VAULT-MESSAGING §10.4, §10.4.1,
/// §10.12, §10.13), answered with the shapes, codes and events of vettid-vault `features/grants`, `features/critical`,
/// `features/items` (`share.decide`) and `features/connauth`: each ask reaches every owner device as its `.pending`
/// event and a feed item; a decision answers the connection (recorded here) and writes the audit entries. The connections
/// are emulated (FakeVaultService+Peer.swift).
struct FakeAsks {
    struct Grant {
        var id: String
        var connectionID: String
        var json: String
    }

    struct Critical {
        var id: String
        var connectionID: String
        var payload: [UInt8]
        var name: String
    }

    var grants: [String: Grant] = [:]
    var critical: [String: Critical] = [:]
    /// Authentication challenges waiting, by request id: the connection.
    var challenges: [String: String] = [:]
    /// The share rules' questions waiting, by rule id: the items.
    var shares: [String: [String]] = [:]
    /// The connection each of those rules is for.
    var shareSubjects: [String: String] = [:]
    /// What the connections were answered, in order: `<type>:<request id>:<outcome>`.
    var answered: [String] = []
    /// An open ask of the kinds `pending.list` repeats (VAULT-MESSAGING 0.70.0 §10.4.2): its `kind`, id, `exp` and the body
    /// of its event.
    struct Open {
        var kind: String
        var id: String
        var exp: Date
        var body: String

        /// The cursor naming this ask's position: `exp`, then id.
        var cursor: String { "\(Timestamps.formatMillis(exp))|\(id)" }
    }

    /// The open asks of those kinds (authentication, desktop session and approval requests).
    var open: [Open] = []
    /// `pending.list` answers `unsupported_type` (a vault before 0.70.0).
    var pendingListUnsupported = false
    /// The pages of `pending.list` answered.
    var pendingListPages = 0
}

extension FakeVaultService {
    /// The approval requests; `unsupported_type` for any other. Callers hold ``cond``.
    func approvalsRequest(_ m: Inner, _ body: JsonObject) throws { // swiftlint:disable:this cyclomatic_complexity
        let id = (try? body.string("request_id")) ?? ""
        switch m.type {
        case "grant.list":
            let pending = activity.asks.grants.values.sorted { $0.id < $1.id }.map(\.json)
            let g = grants
            try reply(m.type, #"{"given":\#(JsonBuilder.array(g.given.map { $0.json("given") })),"received":\#(JsonBuilder.array(g.received.map { $0.json("received") })),"pending":\#(JsonBuilder.array(pending)),"requested":\#(JsonBuilder.array(g.requested.map(\.json)))}"#, re: m.id)
        case "grant.decide": try grantDecide(m, body, id)
        case "critical-secret-use.list":
            let incoming = activity.asks.critical.values.sorted { $0.id < $1.id }.map { criticalJSON($0, payload: false) }
            try reply(m.type, #"{"incoming":\#(JsonBuilder.array(incoming)),"outgoing":[]}"#, re: m.id)
        case "critical-secret-use.get":
            guard let c = activity.asks.critical[id] else { return try reply(m.type, "{}", re: m.id, error: "not_found") }
            try reply(m.type, criticalJSON(c, payload: true), re: m.id)
        case "critical-secret-use.approve": try criticalApprove(m, body)
        case "critical-secret-use.deny":
            guard let c = activity.asks.critical.removeValue(forKey: id) else { return try reply(m.type, "{}", re: m.id, error: "not_found") }
            answered("critical-secret.result", id, "denied", kind: "critical-secret.use.denied", connectionID: c.connectionID)
            try reply(m.type, "{}", re: m.id)
        case "connection.authenticate.approve", "connection.authenticate.deny": try authenticateDecide(m, id)
        case "share.decide": try shareDecide(m, body)
        case "pending.list": try pendingList(m, body)
        case "share.rule.set", "share.rule.delete", "share.pending.list", "grant.request", "grant.revoke", "grant.fetch":
            try sharingRequest(m, body)
        // vettid-vault lists the app itself with an empty name; another device of the owner here has one.
        case "device.list": try reply(m.type, #"{"devices":[{"id":"dev-1","kind":"app","state":"active","name":""},{"id":"dev-2","kind":"desktop","state":"active","name":"Work laptop"}]}"#, re: m.id)
        default: try reply(m.type, "{}", re: m.id, error: "unsupported_type")
        }
    }

    private func answered(_ type: String, _ id: String, _ outcome: String, kind: String, connectionID: String?) {
        activity.asks.answered.append("\(type):\(id):\(outcome)")
        record(kind, connectionID: connectionID, ref: id, direction: "out")
    }

    /// `grant.decide` as vettid-vault's `decide`: a denial answers `data.decided{approved: false}`; an approval grants the
    /// named, available entries asked for (`bad_request` when none).
    private func grantDecide(_ m: Inner, _ body: JsonObject, _ id: String) throws {
        guard let approve = try? body.bool("approve") else { return try reply(m.type, "{}", re: m.id, error: "bad_request") }
        guard let g = activity.asks.grants[id] else { return try reply(m.type, "{}", re: m.id, error: "not_found") }
        guard approve else {
            activity.asks.grants[id] = nil
            answered("data.decided", id, "denied", kind: "grant.denied", connectionID: g.connectionID)
            return try reply(m.type, #"{"grants":[]}"#, re: m.id)
        }
        let entries = VaultJSONLite.objects(try StrictJson.parseObject(Array(g.json.utf8)), "items")
        let indexes: [Int] = if case .array(_, let items)? = body["items"] { items.compactMap { (try? $0.asUint(min: 0, max: 63)).map(Int.init) } } else { Array(entries.indices) }
        let made = indexes.filter { $0 < entries.count && (try? entries[$0].string("kind")) == "item" && (try? entries[$0].bool("available")) == true }
        guard !made.isEmpty else { return try reply(m.type, "{}", re: m.id, error: "bad_request") }
        activity.asks.grants[id] = nil
        answered("data.decided", id, "approved:\(made.map(String.init).joined(separator: ","))", kind: "grant.issued", connectionID: g.connectionID)
        let grants = made.map { JsonBuilder().string("grant_id", Ulid.new()).string("kind", "item").string("ref", (try? entries[$0].string("ref")) ?? "").build() }
        try reply(m.type, #"{"grants":\#(JsonBuilder.array(grants))}"#, re: m.id)
    }

    private func criticalJSON(_ c: FakeAsks.Critical, payload: Bool) -> String {
        var b = JsonBuilder().string("request_id", c.id).string("connection_id", c.connectionID).string("item_id", "01JITEM000000000000000000C").string("field_id", "secret").string("name", c.name).string("label", "Key").string("kind", "password").string("operation", "sign")
        if payload { b = b.base64("payload", c.payload) }
        return b.base64("payload_sha256", Bytes.sha256(c.payload)).string("exp", Timestamps.formatMillis(Date().addingTimeInterval(600))).build()
    }

    /// `critical-secret-use.approve`, a credential operation: the UTK, the blob, the password, then the payload's hash
    /// and the request bound in the sealed payload (`bad_request` otherwise); the CEK rotates.
    private func criticalApprove(_ m: Inner, _ body: JsonObject) throws {
        // An unknown request is refused before the password is tried (its UTK is already spent).
        guard let outer = try? body.string("request_id"), activity.asks.critical[outer] != nil else { return try reply(m.type, "{}", re: m.id, error: "not_found") }
        guard let p = try opened(m, body) else { return }
        guard try checkBlob(m, try body.optString("credential")) else { return }
        guard (try? p.string("password")) == vaultPassword else {
            passwordFailures += 1
            return try reply(m.type, "{}", re: m.id, error: "bad_password")
        }
        let id = (try? p.string("request_id")) ?? ""
        guard let c = activity.asks.critical[id] else { return try reply(m.type, "{}", re: m.id, error: "not_found") }
        guard (try? p.string("payload_sha256")) == Base64s.encodeStd(Bytes.sha256(c.payload)), (try? body.string("request_id")) == id else {
            return try reply(m.type, "{}", re: m.id, error: "bad_request")
        }
        activity.asks.critical[id] = nil
        answered("critical-secret.result", id, "ok", kind: "critical-secret.used", connectionID: c.connectionID)
        try reply(m.type, try rotated() + #","request_id":"\#(id)","status":"ok"}"#, re: m.id)
    }

    /// `connection.authenticate.approve` signs with the credential key: refused (`credential_locked`) outside the unlock
    /// window; `.deny` answers `denied`.
    private func authenticateDecide(_ m: Inner, _ id: String) throws {
        guard let conn = activity.asks.challenges[id] else { return try reply(m.type, "{}", re: m.id, error: "not_found") }
        if m.type == "connection.authenticate.approve" {
            guard let w = windowUntil, vaultNow < w else { return try reply(m.type, "{}", re: m.id, error: "credential_locked") }
            answered("connection.authenticate.response", id, "signed", kind: "connection.authenticate.signed", connectionID: conn)
        } else {
            answered("connection.authenticate.response", id, "denied", kind: "connection.authenticate.denied", connectionID: conn)
        }
        activity.asks.challenges[id] = nil
        activity.asks.open.removeAll { $0.id == id }
        try reply(m.type, "{}", re: m.id)
    }

    /// `pending.list` (0.70.0 §10.4.2): the open asks, soonest `exp` first, then by id; `limit` 1-100 (default 50) and at most
    /// 131,072 bytes a page, one entry at least; `next` names the position after the last entry, and a cursor that is not
    /// one starts again from the beginning. Refused while held like the other lists (``holdAllows(_:)``).
    private func pendingList(_ m: Inner, _ body: JsonObject) throws {
        guard !activity.asks.pendingListUnsupported else { return try reply(m.type, "{}", re: m.id, error: "unsupported_type") }
        var limit = 50
        if body.has("limit") {
            guard let l = try? body.uint("limit", min: 1, max: 100) else { return try reply(m.type, "{}", re: m.id, error: "bad_request") }
            limit = Int(l)
        }
        activity.asks.pendingListPages += 1
        let now = Date()
        var rest = activity.asks.open.filter { $0.exp > now }.sorted { $0.cursor < $1.cursor }
        if let after = try? body.optString("after"), after.contains("|") { rest = rest.filter { $0.cursor > after } }
        var page: [FakeAsks.Open] = []
        var bytes = 0
        for a in rest.prefix(limit) {
            let size = a.body.utf8.count + 64
            if !page.isEmpty, bytes + size > 131_072 { break }
            page.append(a)
            bytes += size
        }
        let entries = page.map { JsonBuilder().string("kind", $0.kind).raw("body", $0.body).build() }
        var out = JsonBuilder().raw("asks", JsonBuilder.array(entries))
        if page.count < rest.count, let last = page.last { out = out.string("next", last.cursor) }
        try reply(m.type, out.build(), re: m.id)
    }

    /// `share.decide` as vettid-vault's `decide`: `{items, approve}` or (0.21.0) `{include?, decline?}`, mixing the forms
    /// `bad_request`, 1–500 distinct items; items not waiting are ignored (`bad_request` when none is); answers
    /// `{included, declined}` and audits `share.included` / `share.declined`.
    private func shareDecide(_ m: Inner, _ body: JsonObject) throws {
        let old = body.has("items") || body.has("approve"), new = body.has("include") || body.has("decline")
        guard let rule = try? body.string("rule_id"), old != new else { return try reply(m.type, "{}", re: m.id, error: "bad_request") }
        let approve = (try? body.bool("approve")) ?? false
        let include = old ? (approve ? VaultJSONLite.strings(body, "items") : []) : VaultJSONLite.strings(body, "include")
        let decline = old ? (approve ? [] : VaultJSONLite.strings(body, "items")) : VaultJSONLite.strings(body, "decline")
        let all = include + decline
        guard !all.isEmpty, all.count <= 500, Set(all).count == all.count, !old || body.has("approve") else { return try reply(m.type, "{}", re: m.id, error: "bad_request") }
        guard let waiting = activity.asks.shares[rule] else { return try reply(m.type, "{}", re: m.id, error: "not_found") }
        let included = include.filter(waiting.contains), declined = decline.filter(waiting.contains)
        guard !included.isEmpty || !declined.isEmpty else { return try reply(m.type, "{}", re: m.id, error: "bad_request") }
        let left = waiting.filter { !included.contains($0) && !declined.contains($0) }
        activity.asks.shares[rule] = left.isEmpty ? nil : left
        for i in included { record("share.included", ref: i) }
        for i in declined { record("share.declined", ref: i) }
        shareDecided(rule, included: included, declined: declined)
        let list = { (ids: [String]) in JsonBuilder.array(ids.map(JsonBuilder.quote)) }
        try reply(m.type, #"{"included":\#(list(included)),"declined":\#(list(declined))}"#, re: m.id)
    }

    // MARK: - The connections ask, and the owner's other devices decide

    /// The connection asks for items (`data.request`, §10.12): every device gets `grant.pending` and a `grant.request`
    /// feed item. Returns the request id.
    @discardableResult
    public func peerAsksForItems(_ connectionID: String, _ items: [AskedItem], reason: String? = nil) throws -> String {
        try locked {
            let id = Ulid.new()
            let entries = items.map { i in
                var b = JsonBuilder().string("kind", i.kind).string("ref", i.ref).string("label", i.label).bool("available", i.available)
                if i.available { b = b.string("name", i.label).string("category", "other").raw("labels", #"[{"field_id":"f1","label":"Number","kind":"text"}]"#) }
                return b.build()
            }
            var b = JsonBuilder().string("request_id", id).string("connection_id", connectionID).raw("items", JsonBuilder.array(entries)).uint("uses", 1).uint("expires_in", 3_600)
            if let reason { b = b.string("reason", reason) }
            let json = b.string("exp", Timestamps.formatMillis(Date().addingTimeInterval(7 * 86_400))).build()
            activity.asks.grants[id] = FakeAsks.Grant(id: id, connectionID: connectionID, json: json)
            record("grant.requested", connectionID: connectionID, ref: id, direction: "in")
            try reply("grant.pending", json)
            try addFeedItem("grant.request", connectionID: connectionID, ref: id)
            return id
        }
    }

    /// The connection asks to use a critical item once (`critical-secret.use`, §10.13): every device gets
    /// `critical-secret-use.pending` (with the payload) and a feed item. Returns the request id.
    @discardableResult
    public func peerAsksCriticalUse(_ connectionID: String, payload: [UInt8], itemName: String = "Signing key") throws -> String {
        try locked {
            let c = FakeAsks.Critical(id: Ulid.new(), connectionID: connectionID, payload: payload, name: itemName)
            activity.asks.critical[c.id] = c
            record("critical-secret.use.requested", connectionID: connectionID, ref: c.id, direction: "in")
            try reply("critical-secret-use.pending", criticalJSON(c, payload: true))
            try addFeedItem("critical-secret.use.request", connectionID: connectionID, ref: c.id)
            return c.id
        }
    }

    /// The connection asks the member to prove presence (§10.4), with a `purpose` (0.65.0) when given. Returns the request id.
    @discardableResult
    public func peerAsksAuthentication(_ connectionID: String, context: String = "Sign in", purpose: String? = nil) throws -> String {
        try locked {
            let id = Ulid.new()
            activity.asks.challenges[id] = connectionID
            record("connection.authenticate.requested", connectionID: connectionID, ref: id, direction: "in")
            var body = JsonBuilder().string("request_id", id).string("connection_id", connectionID).string("context", context)
            if let purpose { body = body.string("purpose", purpose) }
            let exp = Date().addingTimeInterval(600)
            let json = body.string("exp", Timestamps.formatMillis(exp)).build()
            activity.asks.open.append(FakeAsks.Open(kind: "authenticate", id: id, exp: exp, body: json))
            try reply("connection.authenticate.pending", json)
            try addFeedItem("connection.authenticate.requested", connectionID: connectionID, ref: id)
            return id
        }
    }

    /// A desktop or agent asks for the member's approval (`approval.pending`, §6.8). Returns the approval id.
    @discardableResult
    public func deviceAsksApproval(deviceID: String = "dev-2", name: String = "Work laptop", type: String = "item.reveal") throws -> String {
        try locked {
            let id = Ulid.new(), exp = Date().addingTimeInterval(600)
            let json = JsonBuilder().string("approval_id", id).string("device_id", deviceID).string("role", "desktop").string("name", name).string("type", type).raw("body", "{}").string("exp", Timestamps.formatMillis(exp)).build()
            activity.asks.open.append(FakeAsks.Open(kind: "approval", id: id, exp: exp, body: json))
            try reply("approval.pending", json)
            return id
        }
    }

    /// A desktop or agent asks for an access session (`device.session.pending`, §6.8); a device has one request at most.
    /// Returns the request id.
    @discardableResult
    public func deviceAsksSession(deviceID: String = "dev-2", name: String = "Work laptop") throws -> String {
        try locked {
            let id = Ulid.new(), exp = Date().addingTimeInterval(600)
            let json = JsonBuilder().string("request_id", id).string("device_id", deviceID).string("role", "desktop").string("name", name).uint("seconds", 3_600).string("exp", Timestamps.formatMillis(exp)).build()
            activity.asks.open.removeAll { $0.kind == "session" && (try? StrictJson.parseObject(Array($0.body.utf8)).string("device_id")) == deviceID }
            activity.asks.open.append(FakeAsks.Open(kind: "session", id: id, exp: exp, body: json))
            try reply("device.session.pending", json)
            return id
        }
    }

    /// Another device of the owner decided the ask [id] (a member authentication or an approval): this phone gets the
    /// `sync.event`, and `pending.list` no longer holds it.
    public func otherDeviceDecidesOpenAsk(_ id: String, approved: Bool = true) throws {
        try locked {
            guard let ask = activity.asks.open.first(where: { $0.id == id }) else { return }
            activity.asks.open.removeAll { $0.id == id }
            activity.asks.challenges[id] = nil
            let b = JsonBuilder()
            switch ask.kind {
            case "authenticate": b.string("kind", "connection.authenticate.decided").string("request_id", id)
            case "approval": b.string("kind", "approval.decided").string("approval_id", id)
            default:
                let device = (try? StrictJson.parseObject(Array(ask.body.utf8)).string("device_id")) ?? ""
                b.string("kind", "device.session").string("device_id", device)
                if approved { b.string("expires_at", Timestamps.formatMillis(Date().addingTimeInterval(3_600))) }
                return try reply("sync.event", b.build())
            }
            try reply("sync.event", b.bool("approved", approved).build())
        }
    }

    /// The challenger withdrew the open member authentication [id] (VAULT-MESSAGING 0.80.0 §10.4): `pending.list` no longer
    /// holds it, a later approve or deny is answered `not_found`, and this phone gets `sync.event{connection.authenticate
    /// .decided, approved: false, withdrawn: true}`.
    public func challengerWithdraws(_ id: String) throws {
        try locked {
            guard activity.asks.open.contains(where: { $0.id == id && $0.kind == "authenticate" }) else { return }
            activity.asks.open.removeAll { $0.id == id }
            record("connection.authenticate.withdrawn", connectionID: activity.asks.challenges[id], ref: id, direction: "in")
            activity.asks.challenges[id] = nil
            let body = JsonBuilder().string("kind", "connection.authenticate.decided").string("request_id", id).bool("approved", false)
                .bool("withdrawn", true).build()
            try reply("sync.event", body)
        }
    }

    /// The open ask [id] expired or was withdrawn: `pending.list` no longer holds it, and no event says so.
    public func openAskGoes(_ id: String) {
        locked {
            activity.asks.open.removeAll { $0.id == id }
            activity.asks.challenges[id] = nil
        }
    }

    /// Whether `pending.list` is known (a vault from 0.70.0); false: it answers `unsupported_type`.
    public func setPendingListSupported(_ on: Bool) { locked { activity.asks.pendingListUnsupported = !on } }

    /// The pages of `pending.list` answered.
    public var pendingListPagesAnswered: Int { locked { activity.asks.pendingListPages } }

    /// One of the member's share rules asks about [items] for the connection (`share.pending`, §10.12); a later batch of
    /// the same rule adds to its question.
    public func shareRuleAsks(_ ruleID: String, _ connectionID: String, items: [String]) throws {
        try locked {
            let known = activity.asks.shares[ruleID] ?? []
            activity.asks.shares[ruleID] = known + items.filter { !known.contains($0) }
            activity.asks.shareSubjects[ruleID] = connectionID
            let list = items.map { JsonBuilder().string("item_id", $0).string("name", "Item \($0.suffix(2))").string("category", "other").string("sensitivity", "data").build() }
            try reply("share.pending", #"{"rule_id":"\#(ruleID)","subject":{"connection_id":"\#(connectionID)"},"items":\#(JsonBuilder.array(list))}"#)
            try addFeedItem("share.pending", connectionID: connectionID, ref: ruleID)
        }
    }

    /// Another device of the owner decided the grant request: this phone gets `sync.event{grant.request.decided}`.
    public func otherDeviceDecidesGrant(_ requestID: String, approved: Bool) throws {
        try locked {
            activity.asks.grants[requestID] = nil
            try reply("sync.event", JsonBuilder().string("kind", "grant.request.decided").string("request_id", requestID).bool("approved", approved).build())
        }
    }

    /// What the connections were answered, in order: `<type>:<request id>:<outcome>`.
    public var asksAnswered: [String] { locked { activity.asks.answered } }

    /// The items still waiting in the rule's question.
    public func shareQuestion(_ ruleID: String) -> [String]? { locked { activity.asks.shares[ruleID] } }
}

/// TEST ONLY. An entry of a grant request the fake's connection sends: an `item` it names (with whether this vault has
/// it) or a `category`.
public struct AskedItem: Sendable {
    public var kind: String
    public var ref: String
    public var label: String
    public var available: Bool

    public init(kind: String = "item", ref: String, label: String, available: Bool = true) {
        self.kind = kind
        self.ref = ref
        self.label = label
        self.available = available
    }
}

extension VaultJSONLite {
    static func objects(_ o: JsonObject, _ k: String) -> [JsonObject] {
        guard case .array(_, let items)? = o[k] else { return [] }
        return items.compactMap { try? $0.asObject() }
    }

    static func strings(_ o: JsonObject, _ k: String) -> [String] {
        guard case .array(_, let items)? = o[k] else { return [] }
        return items.compactMap { try? $0.asString() }
    }
}

// swiftlint:enable line_length
#endif
