import Foundation
import Observation
import VettIDCrypto
import VettIDVault

/// ``ItemsRepository`` over ``ItemOps``. The list (metadata of every item, at most 2,000) is kept in memory while the vault
/// is open and re-read when another device changes an item (`sync.event` `item.changed`, `item.deleted`, `tag.changed`,
/// §10.1). Values are never kept here: an edit leaves the stored ones in the vault (§10.7 Kept values), and a reveal hands
/// them to its screen only if no clear came while it was on its way. Mirrors vettid-android `ItemsManager`.
@MainActor
@Observable
public final class ItemsManager: ItemsRepository {
    public private(set) var items: [ItemSummary] = []
    public private(set) var load: ListLoad = .notLoaded
    public private(set) var cleared = 0

    @ObservationIgnored let ops: @MainActor () async throws -> any ItemOps
    /// The calls of a read nobody asked for (the vault opening, another device's change): only over the session already
    /// open, never opening one.
    @ObservationIgnored let quietOps: @MainActor () async throws -> any ItemOps
    @ObservationIgnored let notes: FailureNotes
    @ObservationIgnored let debounce: Duration
    @ObservationIgnored private var pending: Task<Void, Never>?

    /// `item.list`'s largest page (§10.7: 1–500).
    nonisolated static let page = 500
    nonisolated static let codeBadRequest = "bad_request"
    /// An answer asked for before a clear (a lock, the hold, a wipe): nothing of it is handed out.
    public nonisolated static let codeUnavailable = "unavailable"
    nonisolated static let codePasswordRequired = "password_required"
    nonisolated static let codeUnreadableValues = "unreadable_values"

    /// [ops] the vault's calls, opened when needed; [quietOps] those of the background reads (nil: [ops]); [notes] how a
    /// failure reaches the vault manager; [debounce] how long a burst of another device's changes is waited out.
    public init(
        ops: @escaping @MainActor () async throws -> any ItemOps,
        quietOps: (@MainActor () async throws -> any ItemOps)? = nil,
        notes: FailureNotes = .none,
        debounce: Duration = .milliseconds(400)
    ) {
        self.ops = ops
        self.quietOps = quietOps ?? ops
        self.notes = notes
        self.debounce = debounce
    }

    // MARK: - Lifecycle

    /// Forgets the list and ends every answer on its way (the vault locked, held or due, or this phone was wiped).
    public func clear() {
        cleared += 1
        pending?.cancel()
        pending = nil
        items = []
        load = .notLoaded
    }

    /// The vault opened: the list is read in the background.
    public func refreshQuietly() {
        Task { [weak self] in try? await self?.refresh(quietly: true) }
    }

    /// Follows the owner's other devices (§10.1): a change of an item or of the tags re-reads the list, once per burst.
    public func onEvent(_ m: VaultMessage) {
        guard m.type == "sync.event" else { return }
        let o = m.object
        switch VaultJSON.string(o, "kind") {
        case "item.deleted":
            if let id = VaultJSON.string(o, "item_id") { items.removeAll { $0.itemID == id } }
            rereadSoon()
        case "item.changed", "tag.changed":
            rereadSoon()
        default:
            break
        }
    }

    private func rereadSoon() {
        pending?.cancel()
        pending = Task { [weak self, debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            try? await self?.refresh(quietly: true)
        }
    }

    /// Runs [body] and turns every failure into a ``VaultFailure`` (a cancellation stays one), noted for the vault manager.
    private func run<T>(_ body: () async throws -> T) async throws -> T { try await notes.run(body) }

    /// Throws when a clear came since [mark]: what was asked for before is not handed out.
    private func still(_ mark: Int) throws {
        guard mark == cleared else { throw VaultFailure(.other, code: Self.codeUnavailable) }
    }

    // MARK: - ItemsRepository

    public func refresh() async throws { try await refresh(quietly: false) }

    /// Reads the whole list; [quietly]: a read nobody asked for, only over the session open now.
    public func refresh(quietly: Bool) async throws {
        let mark = cleared
        let calls = quietly ? quietOps : ops
        load = .loading
        do {
            var out: [ItemSummary] = []
            var after: String?
            repeat {
                let page = try await run { try await calls().list(after: after, limit: Self.page) }
                out += page.items.map(Self.summary)
                after = page.items.isEmpty ? nil : page.next
            } while after != nil && out.count <= ItemChecks.maxItems
            guard mark == cleared else { return }
            items = out
            load = .loaded
        } catch {
            if mark == cleared { load = .failed }
            throw error
        }
    }

    public func get(_ itemID: String) async throws -> ItemDetail {
        let mark = cleared
        let d = Self.detail(try await run { try await ops().get(itemID) })
        try still(mark)
        remember(d)
        return d
    }

    public func reveal(_ itemID: String) async throws -> ItemDetail {
        let mark = cleared
        var d = Self.detail(try await run { try await ops().reveal(itemID) })
        try still(mark)
        d.revealed = true
        return d
    }

    public func revealCritical(_ itemID: String, password: String) async throws -> ItemDetail {
        let mark = cleared
        // The metadata (names, labels, kinds) first: the values come only as {field_id, value}.
        let meta = Self.detail(try await run { try await ops().get(itemID) })
        var plaintext = try await run { try await ops().revealCritical(password: password, itemID: itemID) }
        defer { Bytes.wipe(&plaintext) }
        try still(mark)
        return try Self.openValues(meta, plaintext)
    }

    public func create(_ draft: ItemDraft) async throws -> String {
        guard draft.sensitivity != .critical else { throw VaultFailure(.badPassword, code: Self.codePasswordRequired) }
        let (content, tags) = try Self.content(draft)
        let ref = try await run { try await ops().put(content, sensitivity: draft.sensitivity.wire, tags: tags, itemID: nil, version: nil) }
        await afterWrite()
        return ref.itemID
    }

    public func createCritical(_ draft: ItemDraft, password: String) async throws -> String {
        var d = draft
        d.sensitivity = .critical
        let (content, tags) = try Self.content(d)
        let ref = try await run { try await ops().putCritical(password: password, content: content, tags: tags, itemID: nil, version: nil) }
        await afterWrite()
        return ref.itemID
    }

    public func update(_ itemID: String, version: Int64, draft: ItemDraft) async throws -> Int64 {
        // Every `item.get` of a secret item from a 0.21.0 vault has `size`: without it, the vault keeps no values.
        var d = draft
        if draft.keeps, draft.base?.bytes == nil {
            d = Self.merged(draft, Self.detail(try await run { try await ops().reveal(itemID) }))
        }
        let (content, tags) = try Self.content(d)
        let ref = try await run { try await ops().put(content, sensitivity: nil, tags: tags, itemID: itemID, version: version) }
        await afterWrite()
        return ref.version
    }

    public func updateCritical(_ itemID: String, version: Int64, draft: ItemDraft, password: String) async throws -> Int64 {
        var d = draft
        d.sensitivity = .critical
        // A critical item without `size` is kept by an older vault, or not written since the upgrade. Notes kept without a
        // kept field would pass an older vault, which ignores `keep_notes`, and lose them: the values are opened first.
        let unsure = d.keeps && d.base?.bytes == nil
        if unsure, !d.fields.contains(where: \.kept) { return try await putCriticalMerged(itemID, version, d, password) }
        let (content, tags) = try Self.content(d)
        let ref: ItemRef
        do {
            ref = try await run {
                try await ops().putCritical(password: password, content: content, tags: tags, itemID: itemID, version: version)
            }
        } catch let e as VaultFailure where unsure && e.code == Self.codeBadRequest {
            return try await putCriticalMerged(itemID, version, d, password)
        }
        await afterWrite()
        return ref.version
    }

    /// For a vault before 0.21.0: the stored values opened with the same password, merged, and sent in full.
    private func putCriticalMerged(_ itemID: String, _ version: Int64, _ d: ItemDraft, _ password: String) async throws -> Int64 {
        let full = Self.merged(d, try await revealCritical(itemID, password: password))
        let (content, tags) = try Self.content(full)
        let ref = try await run {
            try await ops().putCritical(password: password, content: content, tags: tags, itemID: itemID, version: version)
        }
        await afterWrite()
        return ref.version
    }

    public func delete(_ itemID: String, sensitivity: Sensitivity, password: String?) async throws {
        let critical = sensitivity == .critical
        if critical, password == nil { throw VaultFailure(.badPassword, code: Self.codePasswordRequired) }
        try await run { try await ops().delete(itemID, password: critical ? password : nil) }
        items.removeAll { $0.itemID == itemID }
    }

    public func setTags(_ itemID: String, version: Int64, tags: [String]) async throws -> Int64 {
        guard let n = ItemChecks.normalizeTags(tags) else { throw VaultFailure(.other, code: Self.codeBadRequest) }
        let v = try await run { try await ops().tag(itemID, version: version, tags: n) }
        await afterWrite()
        return v
    }

    public func setSensitivity(
        _ itemID: String, version: Int64, from: Sensitivity, to: Sensitivity, password: String?
    ) async throws -> Int64 {
        let credential = from == .critical || to == .critical
        if credential, password == nil { throw VaultFailure(.badPassword, code: Self.codePasswordRequired) }
        let v = try await run {
            try await ops().sensitivity(itemID, version: version, sensitivity: to.wire, password: credential ? password : nil)
        }
        await afterWrite()
        return v
    }

    public func shareEffect(_ itemID: String?, version: Int64?, sensitivity: Sensitivity, tags: [String]) async throws -> ShareEffect {
        guard let n = ItemChecks.normalizeTags(tags) else { throw VaultFailure(.other, code: Self.codeBadRequest) }
        let o = try await run {
            try await ops().putDryRun(
                itemID: itemID, version: itemID == nil ? nil : version, sensitivity: itemID == nil ? sensitivity.wire : nil, tags: n
            )
        }
        return ShareEffect.of(o)
    }

    /// A detail read updates its row (the list may be older).
    private func remember(_ d: ItemDetail) {
        guard let i = items.firstIndex(where: { $0.itemID == d.itemID }), items[i].version <= d.version else { return }
        items[i] = d.summary
    }

    private func afterWrite() async { try? await refresh() }
}
