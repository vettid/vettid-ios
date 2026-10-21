import Foundation
import Observation
import VettIDData

/// TEST ONLY. An in-memory vault of items for view-model tests: [stored] holds every item with its values; calls are
/// recorded in [calls]; [fail] makes the next call of a name throw; [password] is the credential password critical
/// operations need (a wrong one is `bad_password`). `get` reports each item's `size` (VAULT-MESSAGING 0.21.0) unless
/// [reportSize] is off (an older vault); an update keeps the stored value of a kept field and the kept notes, and the last
/// draft sent is [lastDraft]. [effect] is what ``shareEffect(_:version:sensitivity:tags:)`` answers. Observable, as
/// ``ItemsManager`` is. Mirrors vettid-android `FakeItems`.
@MainActor
@Observable
public final class FakeItems: ItemsRepository {
    public var calls: [String] = []
    /// A failure the next call of that name throws (once).
    public var fail: [String: VaultFailure] = [:]
    public var password = "correct horse"
    /// Every item with its values, in the order added.
    public private(set) var stored: [ItemDetail] = []
    public var reportSize = true
    public var lastDraft: ItemDraft?
    public var effect = ShareEffect()
    public var effectAsked: [[String]] = []
    public private(set) var items: [ItemSummary] = []
    public var load: ListLoad = .notLoaded
    public private(set) var cleared = 0
    /// When set, the reveals wait for it (a request on its way).
    public var revealGate: TestDeferred<Void>?
    private var next = 1

    public init() {}

    public func add(_ d: ItemDetail) {
        stored.removeAll { $0.itemID == d.itemID }
        stored.append(d)
        publish()
    }

    /// The vault locked, held or due: what a screen holds is dropped.
    public func clear() {
        cleared += 1
        items = []
        load = .notLoaded
    }

    private func publish() { items = stored.map(\.summary) }

    private func call(_ name: String) throws {
        calls.append(name)
        if let f = fail.removeValue(forKey: name) { throw f }
    }

    private func checkPassword(_ pw: String?) throws {
        if pw != password { throw VaultFailure(.badPassword, code: "bad_password") }
    }

    private func find(_ id: String) throws -> ItemDetail {
        guard let d = stored.first(where: { $0.itemID == id }) else { throw VaultFailure(.notFound, code: "not_found") }
        return d
    }

    private func put(_ d: ItemDetail) {
        if let i = stored.firstIndex(where: { $0.itemID == d.itemID }) { stored[i] = d } else { stored.append(d) }
        publish()
    }

    public func refresh() async throws {
        try call("refresh")
        load = .loaded
        publish()
    }

    /// At once (a failure set in [fail] leaves the list unread).
    public func refreshQuietly() {
        guard (try? call("refreshQuietly")) != nil else { return }
        load = .loaded
        publish()
    }

    public func get(_ itemID: String) async throws -> ItemDetail {
        try call("get")
        let d = try find(itemID)
        var shown = d
        shown.revealed = true
        var h = d.hidden()
        h.size = reportSize ? ItemChecks.check(ItemDraft.of(shown)).size : nil
        return h
    }

    public func reveal(_ itemID: String) async throws -> ItemDetail {
        try call("reveal")
        if let revealGate { try await revealGate.value() }
        var d = try find(itemID)
        d.revealed = true
        return d
    }

    public func revealCritical(_ itemID: String, password: String) async throws -> ItemDetail {
        try call("revealCritical")
        if let revealGate { try await revealGate.value() }
        try checkPassword(password)
        var d = try find(itemID)
        d.revealed = true
        return d
    }

    private func detail(_ id: String, _ version: Int64, _ d: ItemDraft) -> ItemDetail {
        ItemDetail(
            itemID: id, version: version, name: d.name.trimmingCharacters(in: .whitespacesAndNewlines), category: d.category,
            sensitivity: d.sensitivity, template: d.template, tags: ItemChecks.normalizeTags(d.tags) ?? [],
            fields: d.fields.enumerated().map { i, f in
                ItemFieldView(
                    fieldID: f.fieldID ?? "f\(i + 1)", label: f.label.trimmingCharacters(in: .whitespacesAndNewlines), kind: f.kind,
                    value: f.value
                )
            },
            notes: d.notes.isEmpty ? nil : d.notes, revealed: true
        )
    }

    public func create(_ draft: ItemDraft) async throws -> String {
        try call("create")
        lastDraft = draft
        let id = String(format: "01ITEM%d", next)
        next += 1
        put(detail(id, 1, draft))
        return id
    }

    public func createCritical(_ draft: ItemDraft, password: String) async throws -> String {
        try call("createCritical")
        lastDraft = draft
        try checkPassword(password)
        let id = String(format: "01CRIT%d", next)
        next += 1
        var d = draft
        d.sensitivity = .critical
        put(detail(id, 1, d))
        return id
    }

    public func update(_ itemID: String, version: Int64, draft: ItemDraft) async throws -> Int64 {
        try call("update")
        lastDraft = draft
        let cur = try find(itemID)
        guard cur.version == version else { throw VaultFailure(.conflict, code: "conflict") }
        var merged = ItemsManager.merged(draft, cur)
        merged.sensitivity = cur.sensitivity
        put(detail(itemID, version + 1, merged))
        return version + 1
    }

    public func updateCritical(_ itemID: String, version: Int64, draft: ItemDraft, password: String) async throws -> Int64 {
        try call("updateCritical")
        lastDraft = draft
        try checkPassword(password)
        let cur = try find(itemID)
        guard cur.version == version else { throw VaultFailure(.conflict, code: "conflict") }
        var merged = ItemsManager.merged(draft, cur)
        merged.sensitivity = .critical
        put(detail(itemID, version + 1, merged))
        return version + 1
    }

    public func delete(_ itemID: String, sensitivity: Sensitivity, password: String?) async throws {
        try call("delete")
        if sensitivity == .critical { try checkPassword(password) }
        _ = try find(itemID)
        stored.removeAll { $0.itemID == itemID }
        publish()
    }

    public func setTags(_ itemID: String, version: Int64, tags: [String]) async throws -> Int64 {
        try call("setTags")
        var cur = try find(itemID)
        cur.version = version + 1
        cur.tags = ItemChecks.normalizeTags(tags) ?? cur.tags
        put(cur)
        return version + 1
    }

    public func setSensitivity(
        _ itemID: String, version: Int64, from: Sensitivity, to: Sensitivity, password: String?
    ) async throws -> Int64 {
        try call("setSensitivity")
        if from == .critical || to == .critical { try checkPassword(password) }
        var cur = try find(itemID)
        cur.version = version + 1
        cur.sensitivity = to
        put(cur)
        return version + 1
    }

    public func shareEffect(_ itemID: String?, version: Int64?, sensitivity: Sensitivity, tags: [String]) async throws -> ShareEffect {
        try call("shareEffect")
        effectAsked.append(ItemChecks.normalizeTags(tags) ?? tags)
        return effect
    }

    /// A sample item with string values (`text` fields).
    public static func item(
        _ id: String, _ name: String, sensitivity: Sensitivity = .data, tags: [String] = [], category: String = "other",
        fields: [(String, String)] = [("Number", "123")]
    ) -> ItemDetail {
        ItemDetail(
            itemID: id, version: 1, name: name, category: category, sensitivity: sensitivity, tags: tags,
            fields: fields.enumerated().map { i, f in ItemFieldView(fieldID: "f\(i + 1)", label: f.0, kind: "text", value: .text(f.1)) },
            revealed: true
        )
    }
}
