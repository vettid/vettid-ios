#if DEBUG
import Foundation
import VettIDCrypto
import VettIDTesting
import VettIDVault

// Fixtures (JSON bodies of the fake service) stay on one line each.
// swiftlint:disable line_length

/// TEST ONLY. One item as the fake vault keeps it (VAULT-MESSAGING §10.7): every value as its canonical JSON, a critical
/// item's too (the fake holds no item keys: what it checks is that the values only leave sealed to a reply key).
struct FakeStoredItem {
    struct Field {
        var id: String
        var label: String
        var kind: String
        var value: String
    }

    var id: String
    var version: Int64 = 1
    var name: String
    var category = "other"
    var sensitivity = "data"
    var template: String?
    var tags: [String] = []
    var fields: [Field] = []
    var notes = ""
    var nextField = 1

    /// §10.7 Size (0.21.0): the content encoding without the members the vault assigns.
    var size: Int {
        let b = JsonBuilder().string("name", name).string("category", category).string("sensitivity", sensitivity)
        if let template { b.string("template", template) }
        b.raw("tags", JsonBuilder.array(tags.map(JsonBuilder.quote)))
        b.raw("fields", JsonBuilder.array(fields.map { JsonBuilder().string("label", $0.label).string("kind", $0.kind).raw("value", $0.value).build() }))
        if !notes.isEmpty { b.string("notes", notes) }
        return b.bytes().count
    }

    /// The item as `item.get`, `item.reveal` or `item.list` give it: [values] with the fields' values and the notes
    /// ([only] narrowing the fields, without notes), else `has_notes`; [size] for `item.get`.
    func json(values: Bool, only: Set<String>? = nil, size withSize: Bool = false) -> String {
        let b = JsonBuilder().string("item_id", id).uint("version", UInt64(version)).string("name", name).string("category", category).string("sensitivity", sensitivity)
        if let template { b.string("template", template) }
        b.raw("tags", JsonBuilder.array(tags.map(JsonBuilder.quote)))
        let shown = fields.filter { only == nil || only?.contains($0.id) == true }
        b.raw("fields", JsonBuilder.array(shown.map { f in
            let fb = JsonBuilder().string("field_id", f.id).string("label", f.label).string("kind", f.kind)
            if values { fb.raw("value", f.value) }
            return fb.build()
        }))
        if values, only == nil, !notes.isEmpty { b.string("notes", notes) }
        if !values { b.bool("has_notes", !notes.isEmpty) }
        b.string("created_at", "2026-10-20T12:00:00Z").string("updated_at", "2026-10-21T12:00:00Z")
        if withSize { b.uint("size", UInt64(size)) }
        return b.build()
    }

    /// A critical item's `values_sealed` plaintext: `{"fields": [{field_id, value}], "notes"?}`.
    var valuesJSON: String {
        let b = JsonBuilder().raw("fields", JsonBuilder.array(fields.map { JsonBuilder().string("field_id", $0.id).raw("value", $0.value).build() }))
        if !notes.isEmpty { b.string("notes", notes) }
        return b.build()
    }
}

/// TEST ONLY. The member's items in the fake vault.
struct FakeItemStore {
    var items: [String: FakeStoredItem] = [:]
    var next = 1
    /// A vault before 0.21.0: no `size` in `item.get`, and a field without `value` is `bad_request`.
    var keepsNoValues = false
    /// What a dry run answers (`{version?, shares, withdrawals}` without the version).
    var effectJSON = #""shares":[],"withdrawals":[]"#
    /// The passwords the critical forms carried, in order.
    var passwords: [String] = []
    /// The types of the item requests the vault received, with `:critical` for a credential form.
    var seen: [String] = []
}

/// The refusal of a request (its code, and the `limit` body).
struct ItemRefusal: Error {
    let code: String
    var body = "{}"
}

// TEST ONLY. The items as vettid-vault answers them (VAULT-MESSAGING §10.7, `features/items`): `item.list`, `.get`,
// `.reveal`, `.put` (and its dry run), `.tag`, `.sensitivity` and `.delete`, each critical form a credential operation (the
// UTK spent and its payload opened, the holder's blob checked, then the password under its backoff; the CEK rotated and
// the new blob answered as `credential` and `credential_version`) whose values leave only sealed to the request's reply
// key. The shape checks are `ItemSpec`'s; the kept values of 0.21.0; the tags normalised with `@profile` on `data` items
// only.
extension FakeVaultService {
    /// A field of ``addItem(name:sensitivity:category:tags:fields:notes:)``: its value as typed (an address as its JSON
    /// object).
    public struct ItemFieldSeed: Sendable {
        public let label: String
        public let kind: String
        public let value: String

        public init(_ label: String, kind: String = "text", _ value: String) {
            self.label = label
            self.kind = kind
            self.value = value
        }
    }

    /// What the vault keeps of an item: each value's exact JSON by label, the notes, the version, the sensitivity, the tags.
    public struct ItemKept: Sendable {
        public let values: [String: String]
        public let notes: String
        public let version: Int64
        public let sensitivity: String
        public let tags: [String]
    }

    /// Adds an item as another device would have; returns its id.
    @discardableResult
    public func addItem(
        name: String, sensitivity: String = "data", category: String = "other", tags: [String] = [], fields: [ItemFieldSeed] = [],
        notes: String = ""
    ) -> String {
        locked {
            let id = newItemID()
            var it = FakeStoredItem(id: id, name: name, category: category, sensitivity: sensitivity, tags: tags.sorted(), notes: notes)
            for f in fields {
                let v = f.kind == "address" ? f.value : JsonBuilder.quote(f.value)
                it.fields.append(.init(id: "f\(it.nextField)", label: f.label, kind: f.kind, value: v))
                it.nextField += 1
            }
            items.items[id] = it
            return id
        }
    }

    /// What the vault keeps for an item; nil once it is gone.
    public func itemValues(_ id: String) -> ItemKept? {
        locked {
            guard let it = items.items[id] else { return nil }
            let values = Dictionary(it.fields.map { ($0.label, $0.value) }, uniquingKeysWith: { a, _ in a })
            return ItemKept(values: values, notes: it.notes, version: it.version, sensitivity: it.sensitivity, tags: it.tags)
        }
    }

    public var itemCount: Int { locked { items.items.count } }
    public var itemPasswords: [String] { locked { items.passwords } }
    public var itemRequests: [String] { locked { items.seen } }

    /// Whether the vault is one before 0.21.0 (no `size`, no kept values).
    public var itemsKeepNoValues: Bool {
        get { locked { items.keepsNoValues } }
        set { locked { items.keepsNoValues = newValue } }
    }

    /// What a dry run answers: the members `shares` and `withdrawals` (and the item's version, added by the vault).
    public func itemEffect(_ membersJSON: String) { locked { items.effectJSON = membersJSON } }

    /// Another device changed or deleted an item: `sync.event{item.changed}` or `{item.deleted}`.
    public func itemChangedElsewhere(_ id: String, name: String? = nil, delete: Bool = false) {
        locked {
            if delete {
                items.items[id] = nil
                try? reply("sync.event", #"{"kind":"item.deleted","item_id":"\#(id)"}"#)
            } else if var it = items.items[id] {
                if let name { it.name = name }
                it.version += 1
                items.items[id] = it
                try? reply("sync.event", #"{"kind":"item.changed","item_id":"\#(id)","version":\#(it.version)}"#)
            }
        }
    }

    func newItemID() -> String {
        defer { items.next += 1 }
        return String(format: "01JITEM%019d", items.next)
    }

    // MARK: - The requests (callers hold ``cond``)

    func itemRequest(_ m: Inner, _ body: JsonObject) throws { // swiftlint:disable:this cyclomatic_complexity
        let critical = body.has("sealed") || body.has("utk_id")
        items.seen.append(m.type + (critical ? ":critical" : ""))
        do {
            switch m.type {
            case "item.list": try reply(m.type, itemList(body), re: m.id)
            case "item.get": try reply(m.type, try stored(body).json(values: try stored(body).sensitivity == "data", size: !items.keepsNoValues), re: m.id)
            case "item.reveal" where critical: try revealCritical(m, body)
            case "item.reveal": try reply(m.type, try revealed(body), re: m.id)
            case "item.put" where critical: try putCritical(m, body)
            case "item.put": try reply(m.type, try put(body), re: m.id)
            case "item.tag": try reply(m.type, try tag(body), re: m.id)
            case "item.sensitivity": try sensitivity(m, body, critical: critical)
            default: try itemDelete(m, body, critical: critical)
            }
        } catch let r as ItemRefusal {
            try reply(m.type, r.body, re: m.id, error: r.code)
        } catch is CryptoError {
            try reply(m.type, "{}", re: m.id, error: "bad_request")
        }
    }

    private func itemList(_ body: JsonObject) -> String {
        let sensitivity = VaultJSON.string(body, "sensitivity")
        let category = VaultJSON.string(body, "category")
        let tags = (try? body.optArray("tags"))?.compactMap { try? $0.asString() } ?? []
        let all = VaultJSON.string(body, "match") == "all"
        var listed = items.items.values.sorted { $0.id < $1.id }.filter { it in
            (sensitivity == nil || it.sensitivity == sensitivity) && (category == nil || it.category == category)
                && (tags.isEmpty || (all ? tags.allSatisfy(it.tags.contains) : tags.contains(where: it.tags.contains)))
        }.map { $0.json(values: false) }
        // The critical items the credential screen counts (``criticalItems``), without content.
        if sensitivity == nil || sensitivity == "critical" {
            listed += (0..<criticalItemsValue).map { #"{"item_id":"item-\#($0)","version":1,"name":"Critical \#($0)","sensitivity":"critical"}"# }
        }
        return #"{"items":[\#(listed.joined(separator: ","))],"next":null}"#
    }

    private func stored(_ body: JsonObject) throws -> FakeStoredItem {
        guard let id = try? body.string("item_id"), let it = items.items[id] else { throw ItemRefusal(code: "not_found") }
        return it
    }

    private func revealed(_ body: JsonObject) throws -> String {
        let it = try stored(body)
        guard it.sensitivity != "critical" else { throw ItemRefusal(code: "bad_request") }
        let only = (try? body.optArray("fields"))?.compactMap { try? $0.asString() }
        return it.json(values: true, only: only.map(Set.init))
    }

    /// A critical form's payload, its UTK spent; then the blob and the password (`backoff`, `bad_password`). Nil when
    /// refused (answered).
    func openedChecked(_ m: Inner, _ body: JsonObject) throws -> JsonObject? {
        guard let p = try opened(m, body) else { return nil }
        let password = (try? p.string("password")) ?? ""
        items.passwords.append(password)
        guard try checkBlob(m, try body.optString("credential")) else { return nil }
        if let b = passwordNotBefore, vaultNow < b {
            try reply(m.type, #"{"retry_after":\#(max(Int(b.timeIntervalSince(vaultNow).rounded(.up)), 1))}"#, re: m.id, error: "backoff")
            return nil
        }
        guard password == vaultPassword else {
            passwordFailures += 1
            try reply(m.type, "{}", re: m.id, error: "bad_password")
            return nil
        }
        passwordFailures = 0
        return p
    }

    /// The rotated CEK's members of an item operation (`credential`, `credential_version`, `utks`), with a leading comma.
    func rotatedForItem() throws -> String {
        credentialVersion += 1
        return #","credential":"\#(currentBlob)","credential_version":\#(credentialVersion),"utks":\#(try issueUTKs(2))"#
    }

    /// The payload's `item_id` must name the item of the outer request (§10.7: a session attacker cannot redirect it).
    private func criticalItem(_ p: JsonObject, _ body: JsonObject) throws -> FakeStoredItem {
        let it = try stored(p)
        guard it.sensitivity == "critical", (try? body.string("item_id")) == it.id else { throw ItemRefusal(code: "bad_request") }
        return it
    }

    private func revealCritical(_ m: Inner, _ body: JsonObject) throws {
        guard let p = try openedChecked(m, body) else { return }
        let it = try criticalItem(p, body)
        let reply = try KemPublicKey.parse(try p.base64("reply_key"))
        let sealed = try CredentialSeal.sealValue(reply: reply, vaultID: vaultID, innerID: m.id, value: Array(it.valuesJSON.utf8))
        try self.reply(m.type, #"{"item_id":"\#(it.id)","version":\#(it.version),"values_sealed":"\#(Base64s.encodeStd(sealed))""# + (try rotatedForItem()) + "}", re: m.id)
    }

    private func putCritical(_ m: Inner, _ body: JsonObject) throws {
        guard (try? body.string("sensitivity")) == "critical" else { throw ItemRefusal(code: "bad_request") }
        guard let p = try openedChecked(m, body) else { return }
        let content = try p.obj("item")
        let id = try p.optString("item_id")
        let version = try body.optUint("version", min: 1, max: StrictJson.maxSafeInteger).map { Int64($0) }
        let it = try write(content, sensitivity: "critical", tags: try body.optArray("tags"), id: id, version: version)
        try reply(m.type, #"{"item_id":"\#(it.id)","version":\#(it.version),"updated_at":"2026-10-21T12:00:00Z""# + (try rotatedForItem()) + "}", re: m.id)
    }

    private func put(_ body: JsonObject) throws -> String {
        let id = try body.optString("item_id")
        let version = try body.optUint("version", min: 1, max: StrictJson.maxSafeInteger).map { Int64($0) }
        if (try? body.bool("dry_run")) == true {
            guard (id == nil) == (version == nil) else { throw ItemRefusal(code: "bad_request") }
            if let id {
                guard let it = items.items[id] else { throw ItemRefusal(code: "not_found") }
                guard it.version == version else { throw ItemRefusal(code: "conflict") }
            }
            return "{" + (id.flatMap { items.items[$0] }.map { #""version":\#($0.version),"# } ?? "") + items.effectJSON + "}"
        }
        let sensitivity = try body.optString("sensitivity")
        guard sensitivity != "critical" else { throw ItemRefusal(code: "bad_request") }
        let it = try write(body, sensitivity: sensitivity, tags: try body.optArray("tags"), id: id, version: version)
        return #"{"item_id":"\#(it.id)","version":\#(it.version),"updated_at":"2026-10-21T12:00:00Z"}"#
    }
}

// swiftlint:enable line_length
#endif
