import Foundation
import Observation
import VettIDData

/// TEST ONLY. Tags and share rules in memory for view-model tests: calls are recorded in ``calls``; ``fail`` makes the next
/// call of a name throw; tags a rule names refuse deletion as the vault does (`in_use`). Observable, as
/// ``SharingManager`` is. Mirrors vettid-android `FakeSharing` (its tags and the read of the rules).
@MainActor
@Observable
public final class FakeSharing: SharingRepository {
    public var calls: [String] = []
    /// A failure the next call of that name throws (once).
    public var fail: [String: VaultFailure] = [:]
    public var registry = TagRegistry(version: 1, tags: [])
    public var rulesStored: [ShareRule] = []
    /// What a rename or a delete answers.
    public var change = TagChange(version: 1, items: 0)
    /// When set, a dry run waits for it (a request on its way).
    public var dryRunGate: TestDeferred<Void>?
    public var tags: TagRegistry?
    public var colors: [String: String] = [:]
    /// Tags passed to ``onTagsUsed(_:)``.
    public var used: [[String]] = []

    public init() {}

    private func publish() {
        tags = registry
        var c: [String: String] = [:]
        for t in registry.tags { if let color = t.color { c[t.tag] = color } }
        colors = c
    }

    private func call(_ n: String) throws {
        calls.append(n)
        if let f = fail.removeValue(forKey: n) { throw f }
    }

    private func replaced(_ tag: String, _ change: (inout TagView) -> Void) -> [TagView] {
        registry.tags.map { t in
            var c = t
            if t.tag == tag { change(&c) }
            return c
        }
    }

    @discardableResult
    public func refreshTags() async throws -> TagRegistry {
        try call("refreshTags")
        publish()
        return registry
    }

    public func setTag(_ tag: String, description: String?, color: String?) async throws {
        try call("setTag:\(tag)")
        let icon = registry.tags.first { $0.tag == tag }?.icon
        let entry = TagView(tag: tag, color: color, description: description, icon: icon)
        registry = TagRegistry(version: registry.version + 1, tags: registry.tags.filter { $0.tag != tag } + [entry])
        publish()
    }

    public func setTagColor(_ tag: String, color: String) async throws {
        try call("setTagColor:\(tag):\(color)")
        if tag.hasPrefix("@") { throw VaultFailure(.other, code: "bad_request") }
        if !registry.tags.contains(where: { $0.tag == tag }) { registry.tags.append(TagView(tag: tag)) }
        registry = TagRegistry(version: registry.version + 1, tags: replaced(tag) { $0.color = color })
        publish()
    }

    public func assignColors(_ next: @escaping ([TagView]) -> (tag: String, color: String)?) async throws -> Int {
        try call("assignColors")
        var n = 0
        while let step = next(registry.tags), n < 1_000 {
            registry = TagRegistry(version: registry.version + 1, tags: replaced(step.tag) { $0.color = step.color })
            n += 1
        }
        publish()
        return n
    }

    public func onTagsUsed(_ tags: [String]) { used.append(tags) }

    public func renameTag(_ from: String, into: String, dryRun: Bool) async throws -> TagChange {
        try call(dryRun ? "renameDry:\(from)>\(into)" : "rename:\(from)>\(into)")
        if dryRun, let dryRunGate { try await dryRunGate.value() }
        if !dryRun {
            registry.tags = replaced(from) { $0.tag = into }
            tags = registry
        }
        return change
    }

    public func deleteTag(_ tag: String, dryRun: Bool) async throws -> TagChange {
        try call(dryRun ? "deleteDry:\(tag)" : "delete:\(tag)")
        if dryRun, let dryRunGate { try await dryRunGate.value() }
        if registry.tags.first(where: { $0.tag == tag })?.rules.isEmpty == false { throw VaultFailure(.inUse, code: "in_use") }
        if !dryRun {
            registry.tags.removeAll { $0.tag == tag }
            tags = registry
        }
        return change
    }

    public func rules(connectionID: String?) async throws -> [ShareRule] {
        try call("rules")
        return rulesStored.filter { connectionID == nil || $0.connectionID == connectionID }
    }
}
