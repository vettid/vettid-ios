import Foundation
import Observation
import VettIDCrypto
import VettIDVault

/// ``SharingRepository`` over ``SharingOps``. [onItemsChanged] re-reads the item list after a tag change (the items' tags
/// change with it, without `item.changed` notices, §10.8). The registry is in memory only, dropped whenever the vault is
/// not open, held or due, and at a wipe (``clear()``); an answer asked for before a clear is not kept (chosen; not in the
/// spec, as the items). Mirrors vettid-android `SharingManager`.
@MainActor
@Observable
public final class SharingManager: SharingRepository {
    public private(set) var tags: TagRegistry?
    public private(set) var colors: [String: String] = [:]

    @ObservationIgnored let ops: @MainActor () async throws -> any SharingOps
    /// The calls of a read nobody asked for (the colour keeper's): only over the session already open, never opening one.
    @ObservationIgnored let quietOps: @MainActor () async throws -> any SharingOps
    @ObservationIgnored let notes: FailureNotes
    /// How the failures of what the app sends by itself (the colour keeper's reads and writes, the re-read after a change)
    /// are mapped: never noted as the member's requests, so that none raises "This phone can't use your vault"
    /// (IOS-PLAN §4.4 (1)).
    @ObservationIgnored let quietNotes: FailureNotes
    /// Whether the vault is held or due (§3.6.3): no read nobody asked for goes out.
    @ObservationIgnored let gated: @MainActor () -> Bool
    @ObservationIgnored let onItemsChanged: @MainActor () async -> Void
    /// Bumped by every clear: an answer to a read sent before is not kept.
    @ObservationIgnored private(set) var cleared = 0

    nonisolated static let codeBadRequest = "bad_request"
    /// At most this many tags are listed (a vault holds at most 512 registry entries, §10.8, plus the tags of its items).
    nonisolated static let maxTagsListed = 4_096
    /// At most this many colours stored in one go, and conflicts met in it.
    nonisolated static let maxAssigned = 512
    nonisolated static let maxConflicts = 8
    /// At most this many rules are listed (a vault holds at most 512, §10.12).
    nonisolated static let maxRulesListed = 1_024

    /// [ops] the vault's calls, opened when needed; [quietOps] those of the background reads and writes (nil: [ops]);
    /// [notes] how the member's requests' failures reach the vault manager, [quietNotes] those of the app's own; [gated]
    /// whether the vault is held or due; [onItemsChanged] reads the items again after a tag change.
    public init(
        ops: @escaping @MainActor () async throws -> any SharingOps,
        quietOps: (@MainActor () async throws -> any SharingOps)? = nil,
        notes: FailureNotes = .none,
        quietNotes: FailureNotes = .none,
        gated: @escaping @MainActor () -> Bool = { false },
        onItemsChanged: @escaping @MainActor () async -> Void = {}
    ) {
        self.ops = ops
        self.quietOps = quietOps ?? ops
        self.notes = notes
        self.quietNotes = quietNotes
        self.gated = gated
        self.onItemsChanged = onItemsChanged
    }

    /// Forgets the registry and its colours (the vault locked, held or due, or this phone was wiped).
    public func clear() {
        cleared += 1
        tags = nil
        colors = [:]
    }

    private func publish(_ r: TagRegistry) {
        tags = r
        var c: [String: String] = [:]
        for t in r.tags { if let color = t.color { c[t.tag] = color } }
        colors = c
    }

    /// `tag.changed` from another device: the registry is read again when next shown (and at once by the colour keeper,
    /// which keeps the tags' colours current); the colours stay until then.
    public func onEvent(_ m: VaultMessage) {
        if m.type == "sync.event", VaultJSON.string(m.object, "kind") == "tag.changed" { tags = nil }
    }

    func run<T>(_ body: () async throws -> T) async throws -> T { try await notes.run(body) }

    private func runQuietly<T>(_ body: () async throws -> T) async throws -> T { try await quietNotes.run(body) }

    static func badRequest() -> VaultFailure { VaultFailure(.other, code: codeBadRequest) }

    @discardableResult
    public func refreshTags() async throws -> TagRegistry { try await refreshTags(quietly: false) }

    /// Reads the registry; [quietly]: a read nobody asked for (the colour keeper's), only over the session open now and
    /// never while the vault is held or due (nil then).
    @discardableResult
    public func refreshTagsQuietly() async throws -> TagRegistry? {
        guard !gated() else { return nil }
        return try await refreshTags(quietly: true)
    }

    private func refreshTags(quietly: Bool) async throws -> TagRegistry {
        let mark = cleared
        let calls = quietly ? quietOps : ops
        var out: [TagView] = []
        var version: Int64 = 0
        var after: String?
        repeat {
            let page = quietly ? try await runQuietly { try await calls().tagList(after: after) }
                : try await run { try await calls().tagList(after: after) }
            version = page.version
            out += page.tags.map { e in
                TagView(tag: e.tag, items: e.items, rules: e.rules, color: e.color, description: e.description, icon: e.icon)
            }
            after = page.tags.isEmpty ? nil : page.next
        } while after != nil && out.count < Self.maxTagsListed
        let r = TagRegistry(version: version, tags: out)
        if mark == cleared { publish(r) }
        return r
    }

    private func version() async throws -> Int64 {
        if let tags { return tags.version }
        return try await refreshTags().version
    }

    public func setTag(_ tag: String, description: String?, color: String?) async throws {
        guard let n = ItemChecks.normalizeTag(tag, reserved: false) else { throw Self.badRequest() }
        let icon = tags?.tags.first { $0.tag == n }?.icon
        let text = description.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        let mark = cleared
        let v = try await version()
        _ = try await run { try await ops().tagSet(version: v, tag: n, color: color, icon: icon, description: text) }
        await afterWrite(mark)
    }

    /// The registry read again after a write: quietly (never opening a session), and not at all when a clear came since
    /// the write began ([mark]).
    func afterWrite(_ mark: Int) async {
        guard mark == cleared else { return }
        _ = try? await refreshTags(quietly: true)
    }

    public func setTagColor(_ tag: String, color: String) async throws {
        guard !tag.hasPrefix("@") else { throw Self.badRequest() }
        let mark = cleared
        do {
            _ = try await putColor(try await current(), tag, color, quietly: false)
        } catch let e as VaultFailure where e.kind == .conflict {
            let r = try await refreshTags()
            guard mark == cleared else { return }
            _ = try await putColor(r, tag, color, quietly: false)
        }
        await afterWrite(mark)
    }

    private func current() async throws -> TagRegistry {
        if let tags { return tags }
        return try await refreshTags()
    }

    /// `tag.set` of [tag] in [r] with [color], everything else of its entry as stored; the registry's new version.
    /// [quietly]: the colour keeper's write, over the session open now and never noted as the member's request.
    private func putColor(_ r: TagRegistry, _ tag: String, _ color: String, quietly: Bool) async throws -> Int64 {
        let t = r.tags.first { $0.tag == tag } ?? TagView(tag: tag)
        let calls = quietly ? quietOps : ops
        let body = { try await calls().tagSet(version: r.version, tag: tag, color: color, icon: t.icon, description: t.description) }
        return quietly ? try await runQuietly(body) : try await run(body)
    }

    /// The colour keeper's: quiet reads and writes only (never opening a session, never noted as the member's), stopping
    /// at once, and publishing nothing, when a clear came since it began or the vault became held or due.
    public func assignColors(_ next: @escaping ([TagView]) -> (tag: String, color: String)?) async throws -> Int {
        let mark = cleared
        let going = { [weak self] in self.map { $0.cleared == mark && !$0.gated() } ?? false }
        guard going() else { return 0 }
        var r: TagRegistry
        if let tags { r = tags } else { r = try await refreshTags(quietly: true) }
        var count = 0
        var conflicts = 0
        let pick = { (r: TagRegistry) in next(r.tags).flatMap { $0.tag.hasPrefix("@") ? nil : $0 } }
        var step = pick(r)
        while let s = step, count < Self.maxAssigned, going() {
            do {
                let v = try await putColor(r, s.tag, s.color, quietly: true)
                count += 1
                guard going() else { return count }
                if v > 0 {
                    r = TagRegistry(version: v, tags: r.tags.map { t in
                        var c = t
                        if t.tag == s.tag { c.color = s.color }
                        return c
                    })
                    publish(r)
                } else {
                    // Without a version in the answer the registry is read again for the next one.
                    r = try await refreshTags(quietly: true)
                }
            } catch let e as VaultFailure {
                conflicts += 1
                guard e.kind == .conflict, conflicts <= Self.maxConflicts, going() else { return count }
                r = try await refreshTags(quietly: true)
            }
            step = pick(r)
        }
        return count
    }

    public func onTagsUsed(_ tags: [String]) {
        if tags.contains(where: { !$0.hasPrefix("@") && colors[$0] == nil }) { self.tags = nil }
    }

    public func renameTag(_ from: String, into: String, dryRun: Bool) async throws -> TagChange {
        guard let n = ItemChecks.normalizeTag(into, reserved: false), !from.hasPrefix("@") else { throw Self.badRequest() }
        let mark = cleared
        let v = try await version()
        let o = try await run { try await ops().tagMerge(version: v, from: [from], into: n, dryRun: dryRun) }
        if !dryRun { await afterTagChange(mark) }
        return TagChange.of(o)
    }

    public func deleteTag(_ tag: String, dryRun: Bool) async throws -> TagChange {
        guard !tag.hasPrefix("@") else { throw Self.badRequest() }
        let mark = cleared
        let v = try await version()
        let o = try await run { try await ops().tagDelete(version: v, tag: tag, dryRun: dryRun) }
        if !dryRun { await afterTagChange(mark) }
        return TagChange.of(o)
    }

    /// After a rename or a delete: the registry and the items read again (quietly), unless a clear came since [mark].
    private func afterTagChange(_ mark: Int) async {
        guard mark == cleared else { return }
        await afterWrite(mark)
        guard mark == cleared else { return }
        await onItemsChanged()
    }

    public func rules(connectionID: String?) async throws -> [ShareRule] {
        var out: [ShareRule] = []
        var after: String?
        repeat {
            let page = try await run { try await ops().ruleList(connectionID: connectionID, after: after) }
            let list = VaultJSON.objects(page, "rules").compactMap(ShareRule.of)
            out += list
            after = list.isEmpty ? nil : VaultJSON.string(page, "next").flatMap { $0.isEmpty ? nil : $0 }
        } while after != nil && out.count < Self.maxRulesListed
        return out
    }
}
