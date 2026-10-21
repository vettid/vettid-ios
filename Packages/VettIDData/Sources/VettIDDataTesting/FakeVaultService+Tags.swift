#if DEBUG
import Foundation
import VettIDCrypto
import VettIDVault

// Fixtures (JSON bodies of the fake service) stay on one line each.
// swiftlint:disable line_length

/// TEST ONLY. The tag registry and the member's share rules as the fake vault keeps them (VAULT-MESSAGING §10.8, §10.12).
struct FakeTagStore {
    struct Entry: Equatable {
        var color: String?
        var icon: String?
        var description: String?
    }

    struct Rule {
        var id: String
        var connectionID: String
        var tags: [String]
        var mode: String
    }

    var version: Int64 = 1
    var entries: [String: Entry] = [:]
    var rules: [Rule] = []
    /// The types of the tag requests the vault received, with `:dry` for a dry run.
    var seen: [String] = []
}

// TEST ONLY. The tags as vettid-vault answers them (VAULT-MESSAGING §10.8, `features/items/tags.go`): `tag.list` of every
// tag in the registry, on an item or named by a rule, with its items and rules; `tag.set`, `tag.delete` and `tag.merge`
// against the registry's version (`conflict` otherwise), `@` tags refused, a tag a rule names not deleted (`in_use`), dry
// runs that change nothing; and `share.rule.list` of the rules a test adds. Callers of the requests hold ``cond``.
extension FakeVaultService {
    /// A share rule of the member's for [connectionID] naming [tags], as another device made it; returns its id.
    @discardableResult
    public func addShareRule(_ connectionID: String, tags: [String], mode: String = "ask") -> String {
        locked {
            let id = String(format: "01JRULE%019d", tagStore.rules.count + 1)
            tagStore.rules.append(.init(id: id, connectionID: connectionID, tags: tags.sorted(), mode: mode))
            return id
        }
    }

    /// A registry entry as another device stored it, the registry's version moved on.
    public func storeTag(_ tag: String, color: String? = nil, icon: String? = nil, description: String? = nil) {
        locked {
            tagStore.entries[tag] = .init(color: color, icon: icon, description: description)
            tagStore.version += 1
        }
    }

    /// A registry entry as the vault keeps it.
    public struct TagKept: Sendable {
        public let color: String?
        public let icon: String?
        public let description: String?
    }

    /// The registry's entry for [tag]; nil without one.
    public func tagEntry(_ tag: String) -> TagKept? {
        locked { tagStore.entries[tag].map { TagKept(color: $0.color, icon: $0.icon, description: $0.description) } }
    }

    public var tagVersion: Int64 { locked { tagStore.version } }
    public var tagRequests: [String] { locked { tagStore.seen } }

    /// Another device changed the tags: the registry's version moves on and `sync.event{tag.changed}` goes out.
    public func tagsChangedElsewhere() {
        locked {
            tagStore.version += 1
            try? reply("sync.event", #"{"kind":"tag.changed","version":\#(tagStore.version)}"#)
        }
    }

    // MARK: - The requests

    func tagRequest(_ m: Inner, _ body: JsonObject) throws {
        tagStore.seen.append(m.type + ((try? body.bool("dry_run")) == true ? ":dry" : ""))
        do {
            switch m.type {
            case "tag.list": try reply(m.type, tagList(), re: m.id)
            case "tag.set": try reply(m.type, try tagSet(body), re: m.id)
            case "tag.delete": try reply(m.type, try tagDelete(body), re: m.id)
            case "tag.merge": try reply(m.type, try tagMerge(body), re: m.id)
            default: try reply(m.type, ruleList(body), re: m.id)
            }
        } catch let r as ItemRefusal {
            try reply(m.type, r.body, re: m.id, error: r.code)
        } catch is CryptoError {
            try reply(m.type, "{}", re: m.id, error: "bad_request")
        }
    }

    /// Every tag in the registry, on an item or named by a rule, sorted, with its items and rules (one page).
    private func tagList() -> String {
        var all = Set(tagStore.entries.keys)
        for it in items.items.values { all.formUnion(it.tags) }
        for r in tagStore.rules { all.formUnion(r.tags) }
        let tags = all.sorted().map { t -> String in
            let b = JsonBuilder().string("tag", t)
            if let e = tagStore.entries[t] {
                if let c = e.color { b.string("color", c) }
                if let i = e.icon { b.string("icon", i) }
                if let d = e.description { b.string("description", d) }
            }
            b.uint("items", UInt64(items.items.values.count { $0.tags.contains(t) }))
            b.raw("rules", JsonBuilder.array(tagStore.rules.filter { $0.tags.contains(t) }.map { JsonBuilder.quote($0.id) }))
            return b.build()
        }
        return #"{"version":\#(tagStore.version),"tags":[\#(tags.joined(separator: ","))]}"#
    }

    /// The registry's version must be the one sent (`conflict`).
    private func checkVersion(_ body: JsonObject) throws {
        guard let v = try? body.uint("version", min: 0, max: StrictJson.maxSafeInteger), Int64(v) == tagStore.version else {
            throw ItemRefusal(code: "conflict")
        }
    }

    private func tagSet(_ body: JsonObject) throws -> String {
        try checkVersion(body)
        let tag = try ItemSpec.normalizeTag(try body.string("tag"))
        let color = try body.optString("color"), icon = try body.optString("icon"), text = try body.optString("description")
        let hex = Set("0123456789abcdefABCDEF")
        guard color.map({ $0.count == 7 && $0.first == "#" && $0.dropFirst().allSatisfy(hex.contains) }) ?? true,
              icon.map(ItemSpec.isValidTemplate) ?? true, (text?.utf8.count ?? 0) <= 256 else { throw ItemRefusal(code: "bad_request") }
        guard tagStore.entries[tag] != nil || tagStore.entries.count < 512 else { throw ItemRefusal(code: "limit", body: #"{"limit":"tag_registry","max":512}"#) }
        tagStore.entries[tag] = .init(color: color, icon: icon, description: text)
        tagStore.version += 1
        return #"{"version":\#(tagStore.version)}"#
    }

    private func tagDelete(_ body: JsonObject) throws -> String {
        try checkVersion(body)
        let tag = try body.string("tag")
        guard !tag.hasPrefix("@") else { throw ItemRefusal(code: "bad_request") }
        guard !tagStore.rules.contains(where: { $0.tags.contains(tag) }) else { throw ItemRefusal(code: "in_use") }
        let carrying = items.items.values.filter { $0.tags.contains(tag) }.map(\.id)
        if (try? body.bool("dry_run")) == true { return #"{"version":\#(tagStore.version),"items":\#(carrying.count)}"# }
        for id in carrying {
            items.items[id]?.tags.removeAll { $0 == tag }
            items.items[id]?.version += 1
        }
        tagStore.entries[tag] = nil
        tagStore.version += 1
        return #"{"version":\#(tagStore.version),"items":\#(carrying.count)}"#
    }

    /// `tag.merge`: every `from` tag replaced by `into` on the items and in the rules; the items that then newly match a
    /// rule are its `shares`.
    private func tagMerge(_ body: JsonObject) throws -> String {
        try checkVersion(body)
        let from = try body.array("from").map { try $0.asString() }
        let into = try ItemSpec.normalizeTag(try body.string("into"))
        guard (1...16).contains(from.count), !from.contains(where: { $0.hasPrefix("@") }) else { throw ItemRefusal(code: "bad_request") }
        let merged = { (tags: [String]) in Array(Set(tags.map { from.contains($0) ? into : $0 })).sorted() }
        var rules = tagStore.rules
        for i in rules.indices { rules[i].tags = merged(rules[i].tags) }
        var newItems = items.items
        var changed = 0
        for (id, it) in newItems where it.tags.contains(where: from.contains) {
            newItems[id]?.tags = merged(it.tags)
            newItems[id]?.version += 1
            changed += 1
        }
        var shares: [String] = []
        for r in rules {
            for it in newItems.values.sorted(by: { $0.id < $1.id }) where r.tags.contains(where: it.tags.contains) {
                let before = items.items[it.id]?.tags ?? []
                guard !tagStore.rules.contains(where: { $0.id == r.id && $0.tags.contains(where: before.contains) }) else { continue }
                shares.append(#"{"rule_id":"\#(r.id)","item_id":"\#(it.id)","mode":"\#(r.mode)"}"#)
            }
        }
        let rulesChanged = tagStore.rules.indices.count { tagStore.rules[$0].tags != rules[$0].tags }
        let answer = { (v: Int64) in #"{"version":\#(v),"items":\#(changed),"rules":\#(rulesChanged),"shares":[\#(shares.joined(separator: ","))],"shares_total":\#(shares.count)}"# }
        if (try? body.bool("dry_run")) == true { return answer(tagStore.version) }
        let first = from.compactMap { tagStore.entries[$0] }.first
        for f in from { tagStore.entries[f] = nil }
        if tagStore.entries[into] == nil, let first { tagStore.entries[into] = first }
        let text = answer(tagStore.version + 1)
        tagStore.rules = rules
        items.items = newItems
        tagStore.version += 1
        return text
    }

    private func ruleList(_ body: JsonObject) -> String {
        let conn = try? body.optString("connection_id")
        let rules = tagStore.rules.filter { conn == nil || $0.connectionID == conn }.map { r in
            #"{"rule_id":"\#(r.id)","version":1,"subject":{"connection_id":"\#(r.connectionID)"},"tags":\#(JsonBuilder.array(r.tags.map(JsonBuilder.quote))),"match":"any","access":"read","mode":"\#(r.mode)","include_existing":true}"#
        }
        return #"{"rules":[\#(rules.joined(separator: ","))]}"#
    }
}

// swiftlint:enable line_length
#endif
