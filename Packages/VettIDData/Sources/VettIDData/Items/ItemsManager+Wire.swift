import Foundation
import VettIDCrypto
import VettIDVault

// Between the vault's items (VettIDVault's `Item`, VAULT-MESSAGING §10.7) and the app's: what is read, what is sent, and
// the values of a critical item opened. Mirrors the companion of vettid-android `ItemsManager`.
extension ItemsManager {
    /// A field value from the vault (its exact JSON): a string, or an address object; anything else is shown as its JSON.
    public nonisolated static func fieldValue(_ kind: String, _ json: String?) -> FieldValue? {
        guard let json else { return nil }
        guard let v = try? StrictJson.parseObject(#"{"v":\#(json)}"#)["v"] else { return .text(json) }
        switch v {
        case .string(_, let s): return .text(s)
        case .object(let o) where kind == FieldKinds.address:
            var parts: [String: String] = [:]
            for m in o.members { if case .string(_, let s) = m.value { parts[m.name] = s } }
            return .address(AddressValue.of(parts))
        default: return .text(v.raw)
        }
    }

    public nonisolated static func summary(_ i: Item) -> ItemSummary {
        ItemSummary(
            itemID: i.itemID, version: i.version, name: i.name, category: i.category, sensitivity: Sensitivity.of(i.sensitivity),
            template: i.template, tags: i.tags, labels: i.fields.map(\.label), updatedAt: OwnerCheckManager.instant(i.updatedAt)
        )
    }

    public nonisolated static func detail(_ i: Item) -> ItemDetail {
        let s = Sensitivity.of(i.sensitivity)
        let hasValues = s == .data || i.fields.contains { $0.valueJSON != nil } || i.notes != nil
        return ItemDetail(
            itemID: i.itemID, version: i.version, name: i.name, category: i.category, sensitivity: s, template: i.template,
            tags: i.tags,
            fields: i.fields.map { f in
                ItemFieldView(fieldID: f.fieldID, label: f.label, kind: f.kind, value: fieldValue(f.kind, f.valueJSON))
            },
            notes: i.notes, hasNotes: i.hasNotes || !(i.notes ?? "").isEmpty, createdAt: OwnerCheckManager.instant(i.createdAt),
            updatedAt: OwnerCheckManager.instant(i.updatedAt), revealed: hasValues,
            size: i.size.flatMap { (0...Int64(Int.max)).contains($0) ? Int($0) : nil }
        )
    }

    /// [d] with its kept values taken from [revealed] (the item's values, opened), for a vault that keeps none (before
    /// 0.21.0). A field the item no longer has keeps "" (or `{}`), as the vault would.
    public nonisolated static func merged(_ d: ItemDraft, _ revealed: ItemDetail) -> ItemDraft {
        var values: [String: FieldValue] = [:]
        for f in revealed.fields { if let id = f.fieldID, let v = f.value { values[id] = v } }
        var out = d
        out.fields = d.fields.map { f in
            guard f.kept else { return f }
            var m = f
            m.kept = false
            switch f.fieldID.flatMap({ values[$0] }) {
            case .address(let a)?: m.address = a
            case .text(let t)?: m.text = t
            case nil: break
            }
            return m
        }
        out.notes = d.keepNotes ? (revealed.notes ?? "") : d.notes
        out.keepNotes = false
        out.base = nil
        return out
    }

    /// Merges a critical item's opened values (`{"fields": [{field_id, value}], "notes"?}`, §10.7) into its metadata.
    public nonisolated static func openValues(_ meta: ItemDetail, _ plaintext: [UInt8]) throws -> ItemDetail {
        guard let o = try? StrictJson.parseObject(plaintext) else { throw VaultFailure(.other, code: codeUnreadableValues) }
        var values: [String: String] = [:]
        for f in VaultJSON.objects(o, "fields") {
            if let id = VaultJSON.string(f, "field_id"), let v = f["value"] { values[id] = v.raw }
        }
        var d = meta
        d.fields = meta.fields.map { f in
            var v = f
            v.value = fieldValue(f.kind, f.fieldID.flatMap { values[$0] }) ?? .text("")
            return v
        }
        d.notes = VaultJSON.string(o, "notes")
        d.revealed = true
        return d
    }

    /// The content and tags `item.put` sends (§10.7): names trimmed, tags normalised, a kept field without `value` and kept
    /// notes as `keep_notes` (0.21.0); refused here (`bad_request`, nothing sent) if the vault would refuse it.
    nonisolated static func content(_ d: ItemDraft) throws -> (ItemContent, [String]) {
        let check = ItemChecks.check(d)
        guard check.ok else { throw VaultFailure(.other, code: codeBadRequest) }
        let fields = d.fields.map { f in
            let kept = f.kept && f.fieldID != nil
            let value = kept ? nil : ItemChecks.valueJSON(f.value)
            return ItemField(fieldID: f.fieldID, label: f.label.itemTrimmed, kind: f.kind, valueJSON: value)
        }
        let content = ItemContent(
            name: d.name.itemTrimmed, category: d.category, template: d.template, fields: fields,
            notes: d.notes.isEmpty || d.keepNotes ? nil : d.notes, keepNotes: d.keepNotes
        )
        return (content, check.tags ?? [])
    }
}
