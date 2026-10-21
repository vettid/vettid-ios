#if DEBUG
import Foundation
import VettIDCrypto
import VettIDVault

// Fixtures (JSON bodies of the fake service) stay on one line each.
// swiftlint:disable line_length

// TEST ONLY. The writes of the fake vault's items (VAULT-MESSAGING §10.7): a creation or a replacement checked as
// vettid-vault checks it (the version, the shape of every member and value, the field ids, the kept values of 0.21.0, the
// tags, the size), `item.tag`, `item.sensitivity` and `item.delete`. Callers hold ``cond``.
extension FakeVaultService {
    /// The item [c] makes: a new one ([id] nil), or the replacement of [id] at [version] keeping its sensitivity.
    func write(_ c: JsonObject, sensitivity: String?, tags: [JsonValue]?, id: String?, version: Int64?) throws -> FakeStoredItem {
        var it = try base(sensitivity: sensitivity, id: id, version: version)
        let name = try c.string("name")
        let category = try c.optString("category") ?? "other"
        let template = try c.optString("template")
        guard ItemSpec.isValidName(name), ItemSpec.isValidCategory(category), template.map(ItemSpec.isValidTemplate) ?? true else {
            throw ItemRefusal(code: "bad_request")
        }
        let cur = id.flatMap { items.items[$0] }
        it.fields = try fields(c, of: &it, current: cur)
        it.notes = try notes(c, current: cur)
        it.name = name
        it.category = category
        it.template = template
        if let tags { it.tags = try ItemSpec.normalizeTags(try tags.map { try $0.asString() }, reserved: true) }
        if it.tags.contains(ItemSpec.profileTag), it.sensitivity != ItemSpec.data { throw ItemRefusal(code: "bad_request") }
        let max = it.sensitivity == ItemSpec.critical ? ItemSpec.maxCriticalBytes : ItemSpec.maxItemBytes
        if it.size > max { throw ItemRefusal(code: "limit", body: #"{"limit":"item_size","max":\#(max),"size":\#(it.size)}"#) }
        it.version += 1
        items.items[it.id] = it
        return it
    }

    private func base(sensitivity: String?, id: String?, version: Int64?) throws -> FakeStoredItem {
        guard let id else {
            guard version == nil, ItemSpec.isValidSensitivity(sensitivity ?? ItemSpec.data) else { throw ItemRefusal(code: "bad_request") }
            guard items.items.count < 2_000 else { throw ItemRefusal(code: "limit", body: #"{"limit":"items","max":2000}"#) }
            var it = FakeStoredItem(id: newItemID(), name: "", sensitivity: sensitivity ?? ItemSpec.data)
            it.version = 0
            return it
        }
        guard let version else { throw ItemRefusal(code: "bad_request") }
        guard let it = items.items[id] else { throw ItemRefusal(code: "not_found") }
        guard it.version == version else { throw ItemRefusal(code: "conflict") }
        guard sensitivity == nil || sensitivity == it.sensitivity else { throw ItemRefusal(code: "bad_request") }
        return it
    }

    /// The fields of [c]: a named field keeps its id (relabelled, moved, its value kept when absent and of the same kind);
    /// a new one gets the next id and needs a value. A vault before 0.21.0 keeps none.
    private func fields(_ c: JsonObject, of it: inout FakeStoredItem, current: FakeStoredItem?) throws -> [FakeStoredItem.Field] {
        let given = try c.optArray("fields") ?? []
        guard given.count <= ItemSpec.maxFields else { throw ItemRefusal(code: "bad_request") }
        var out: [FakeStoredItem.Field] = []
        for v in given {
            let f = try v.asObject()
            let label = try f.string("label")
            let kind = try f.string("kind")
            guard ItemSpec.isValidLabel(label), ItemSpec.isValidKind(kind) else { throw ItemRefusal(code: "bad_request") }
            let fid = try f.optString("field_id")
            let old = try fid.map { id in
                guard let o = current?.fields.first(where: { $0.id == id }), !out.contains(where: { $0.id == id }) else { throw ItemRefusal(code: "bad_request") }
                return o
            }
            guard let value = f["value"] else {
                guard let old, old.kind == kind, !items.keepsNoValues else { throw ItemRefusal(code: "bad_request") }
                out.append(.init(id: old.id, label: label, kind: kind, value: old.value))
                continue
            }
            let canonical = try ItemSpec.canonicalValue(kind, value)
            if let old {
                out.append(.init(id: old.id, label: label, kind: kind, value: canonical))
            } else {
                out.append(.init(id: "f\(it.nextField)", label: label, kind: kind, value: canonical))
                it.nextField += 1
            }
        }
        return out
    }

    /// `notes`, or with `keep_notes` the stored ones (never both, never on a new item). A vault before 0.21.0 ignores
    /// `keep_notes`: the notes are removed.
    private func notes(_ c: JsonObject, current: FakeStoredItem?) throws -> String {
        let keep = try c.has("keep_notes") ? c.bool("keep_notes") : false
        let notes = try c.optString("notes")
        guard !(keep && c.has("notes")), notes.map(ItemSpec.isValidNotes) ?? true else { throw ItemRefusal(code: "bad_request") }
        guard keep, !items.keepsNoValues else { return notes ?? "" }
        guard let current else { throw ItemRefusal(code: "bad_request") }
        return current.notes
    }

    /// `item.tag{item_id, version, tags, dry_run?}`, for every sensitivity.
    func tag(_ body: JsonObject) throws -> String {
        guard let id = try? body.string("item_id"), var it = items.items[id] else { throw ItemRefusal(code: "not_found") }
        guard let v = try? body.uint("version", min: 1, max: StrictJson.maxSafeInteger), Int64(v) == it.version else { throw ItemRefusal(code: "conflict") }
        let tags = try ItemSpec.normalizeTags(try body.array("tags").map { try $0.asString() }, reserved: true)
        if tags.contains(ItemSpec.profileTag), it.sensitivity != ItemSpec.data { throw ItemRefusal(code: "bad_request") }
        if (try? body.bool("dry_run")) == true { return #"{"version":\#(it.version),"# + items.effectJSON + "}" }
        it.tags = tags
        it.version += 1
        items.items[id] = it
        return #"{"version":\#(it.version)}"#
    }

    /// `item.sensitivity`: `data` ↔ `secret` as metadata; to or from `critical` only in the credential form.
    func sensitivity(_ m: Inner, _ body: JsonObject, critical: Bool) throws {
        guard let id = try? body.string("item_id"), var it = items.items[id] else { throw ItemRefusal(code: "not_found") }
        let to = try body.string("sensitivity")
        guard ItemSpec.isValidSensitivity(to) else { throw ItemRefusal(code: "bad_request") }
        guard let v = try? body.uint("version", min: 1, max: StrictJson.maxSafeInteger), Int64(v) == it.version else { throw ItemRefusal(code: "conflict") }
        let moves = to == ItemSpec.critical || it.sensitivity == ItemSpec.critical
        guard moves == critical, !it.tags.contains(ItemSpec.profileTag) || to == ItemSpec.data else { throw ItemRefusal(code: "bad_request") }
        var rotated = ""
        if critical {
            guard let p = try openedChecked(m, body) else { return }
            guard (try? p.string("item_id")) == id else { throw ItemRefusal(code: "bad_request") }
            rotated = try rotatedForItem()
        }
        it.sensitivity = to
        it.version += 1
        items.items[id] = it
        try reply(m.type, #"{"version":\#(it.version)"# + rotated + "}", re: m.id)
    }

    /// `item.delete`; a critical item only in the credential form.
    func itemDelete(_ m: Inner, _ body: JsonObject, critical: Bool) throws {
        guard let id = try? body.string("item_id"), let it = items.items[id] else { throw ItemRefusal(code: "not_found") }
        guard (it.sensitivity == ItemSpec.critical) == critical else { throw ItemRefusal(code: "bad_request") }
        var rotated = ""
        if critical {
            guard let p = try openedChecked(m, body) else { return }
            guard (try? p.string("item_id")) == id else { throw ItemRefusal(code: "bad_request") }
            rotated = try rotatedForItem()
        }
        items.items[id] = nil
        try reply(m.type, rotated.isEmpty ? "{}" : "{" + rotated.dropFirst() + "}", re: m.id)
    }
}

// swiftlint:enable line_length
#endif
