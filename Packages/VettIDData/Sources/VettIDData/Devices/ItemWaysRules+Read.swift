import Foundation
import VettIDCrypto

// Reading `leash.item.list`'s and `leash.item.set`'s answers strictly (VAULT-MESSAGING §10.11; ANDROID-PLAN 0.1.137 AA7 "Fail
// closed"), and a read-only page's turn-off. The answers come as their exact bytes (``VaultApi/leashItemList(agentID:itemID:)``)
// and are read with ``StrictJson`` (a duplicate member anywhere is refused). Mirrors vettid-android `ItemWaysRules`.
extension ItemWaysRules {
    /// Reads `leash.item.list`'s answer (`{items: [<item_ways>]}`) strictly. An answer that does not read strictly (a duplicate
    /// member anywhere) is read leniently, and every item in it is read only; an item of another agent than [agentID] too, and
    /// every item when one (agent, item) pair is listed twice (which copy to edit, and to judge a widening against, is unknown).
    /// Nil when the answer is not a list of objects at all (it is never "no items").
    public static func list(_ answer: [UInt8], agentID: String? = nil) -> [ItemWaysRead]? {
        guard let lenient = lenientObject(answer), let listed = lenient["items"] as? [Any] else { return nil }
        var items: [[String: Any]] = []
        for v in listed {
            guard let o = v as? [String: Any] else { return nil }
            items.append(o)
        }
        let strict = (try? StrictJson.parseObject(answer))
            .flatMap { try? $0.array("items") }
            .flatMap { $0.count == items.count ? $0 : nil }
        let reads = items.enumerated().map { i, raw in
            let r = read(raw, strict.flatMap { try? $0[i].asObject() })
            if let agentID, !same(r.agentID, agentID) { return r.asForeign() }
            return r
        }
        var pairs = Set<[UInt8]>()
        let repeated = reads.contains { r in !pairs.insert(Array(r.agentID.utf8) + [0] + Array(r.itemID.utf8)).inserted }
        // Without the strict reading too, as for a duplicate member: no copy's settings can be sent back by a turn-off.
        let readOnly = { (r: ItemWaysRead) in
            ItemWaysRead(agentID: r.agentID, itemID: r.itemID, ways: nil, rawWays: r.rawWays, strict: nil, foreign: r.foreign)
        }
        return repeated ? reads.map(readOnly) : reads
    }

    /// Reads one `<item_ways>` answer (`leash.item.set`'s) strictly, as ``list(_:agentID:)`` reads each item.
    public static func one(_ answer: [UInt8]) -> ItemWaysRead? {
        guard let raw = lenientObject(answer) else { return nil }
        return read(raw, try? StrictJson.parseObject(answer))
    }

    /// The answer as a plain object, a duplicate member allowed (the last wins): what names the item and lists its ways when
    /// the strict reading failed. Nil when it is not an object at all.
    private static func lenientObject(_ answer: [UInt8]) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(answer))) as? [String: Any]
    }

    private static func read(_ raw: [String: Any], _ strict: JsonObject?) -> ItemWaysRead {
        let agent = raw["agent_id"] as? String ?? ""
        let item = raw["item_id"] as? String ?? ""
        let rawWays = (raw["ways"] as? [Any] ?? []).compactMap { $0 as? String }
        // The strict reading counts only when it is of the same item the lenient one names.
        let ways = strict.flatMap { try? parse($0) }.flatMap { same($0.agentID, agent) && same($0.itemID, item) ? $0 : nil }
        let hasFolders = (raw["run"] as? [String: Any])?["folders"] != nil
        return ItemWaysRead(agentID: agent, itemID: item, ways: ways, rawWays: rawWays, strict: strict, answerHasFolders: hasFolders)
    }

    private static let topMembers: Set<[UInt8]> = names("agent_id", "item_id", "version", "ways", "run", "proxy", "updated_at")
    private static let runMembers: Set<[UInt8]> = names("programs", "each", "folders")
    private static let programMembers: Set<[UInt8]> = names("program", "sha256", "path", "env")
    private static let folderMembers: Set<[UInt8]> = names("path", "write")
    private static let proxyMembers: Set<[UInt8]> = names("hosts", "header", "prefix")

    private static func names(_ n: String...) -> Set<[UInt8]> { Set(n.map { Array($0.utf8) }) }

    private struct Unreadable: Error {}

    private static func check(_ ok: Bool) throws {
        if !ok { throw Unreadable() }
    }

    private static func only(_ o: JsonObject, _ names: Set<[UInt8]>) throws {
        try check(o.members.allSatisfy { names.contains(Array($0.name.utf8)) })
    }

    private static func str(_ v: JsonValue) throws -> String { try v.asString() }

    private static func boolMember(_ v: JsonValue?) throws -> Bool {
        guard case .bool(_, let b)? = v else { throw Unreadable() }
        return b
    }

    /// The settings when the app understands all of them (AA7 "Fail closed"), else ``Unreadable``: an unknown member at any
    /// level, a way the app does not know, `run` or `proxy` present without its way or the reverse, a malformed value, and (a
    /// version without AA9) a non-empty `run.folders`.
    private static func parse(_ o: JsonObject) throws -> ItemWays {
        try only(o, topMembers)
        let agent = try o.string("agent_id")
        let item = try o.string("item_id")
        try check(!agent.isEmpty && !item.isEmpty)
        let version = try o.optUint("version", min: 1, max: StrictJson.maxSafeInteger)
        if let updated = try o.optString("updated_at") { try check(OwnerCheckManager.instant(updated) != nil) }
        let wayList = try o.array("ways").map { v -> ItemWay in
            guard let w = ItemWay.of(try str(v)) else { throw Unreadable() }
            return w
        }
        let ways = Set(wayList)
        try check(ways.count == wayList.count && ways.contains(.use))
        try check(o.has("run") == ways.contains(.run) && o.has("proxy") == ways.contains(.proxy))
        let run = try o.optObj("run").map { try runSettings($0) }
        let proxy = try o.optObj("proxy").map { try proxySettings($0) }
        return ItemWays(agentID: agent, itemID: item, version: version.map { Int64($0) }, ways: ways, run: run, proxy: proxy)
    }

    private static func runSettings(_ r: JsonObject) throws -> RunSettings {
        try only(r, runMembers)
        let arr = try r.array("programs")
        try check(arr.count <= maxPrograms)
        let programs = try arr.map { v -> RunProgram in
            let p = try v.asObject()
            try only(p, programMembers)
            let program = try p.string("program")
            try check(programProblem(program) == nil)
            let sha = try p.optString("sha256")
            let path = try p.optString("path")
            try check((sha == nil) == (path == nil))
            if let sha, let path { try check(isSha256(sha) && isAbsolute(path)) }
            let env = try (p.optArray("env") ?? []).map { try str($0) }
            try check(env.count <= maxEnv && env.allSatisfy(envName) && Set(env.map { Array($0.utf8) }).count == env.count)
            return RunProgram(program: program, sha256: sha, path: path, env: env)
        }
        let keys = programs.map { Array(programKey($0.program).utf8) }
        try check(Set(keys).count == keys.count)
        // A bare name equal to an absolute entry's last element (the vault's second rule).
        try check(
            !programs.contains { p in
                isAbsolute(p.program)
                    && programs.contains { !isAbsolute($0.program) && same(programKey($0.program), programKey(lastElement(p.program))) }
            }
        )
        let each = try r.has("each") ? boolMember(r["each"]) : true
        try check(each || !programs.isEmpty)
        let folders = try r.optArray("folders")?.map { v -> RunFolder in
            let f = try v.asObject()
            try only(f, folderMembers)
            return RunFolder(path: try f.string("path"), write: try boolMember(f["write"]))
        }
        // A version without AA9 (ANDROID-PLAN 0.1.137 AA7 "Fail closed"): a folder it can't show is read only; an empty list is
        // sent back as read.
        try check(folders == nil || folders?.isEmpty == true)
        return RunSettings(programs: programs, each: each, folders: folders)
    }

    private static func proxySettings(_ p: JsonObject) throws -> ProxySettings {
        try only(p, proxyMembers)
        let hosts = try p.array("hosts").map { try str($0) }
        try check((1...maxHosts).contains(hosts.count) && hosts.allSatisfy { hostProblem($0) == nil })
        try check(Set(hosts.map { Array(hostKey($0).utf8) }).count == hosts.count)
        let header = try p.string("header")
        try check(headerValid(header))
        let prefix = try p.optString("prefix") ?? ""
        try check(prefixValid(prefix))
        return ProxySettings(hosts: hosts, header: header, prefix: prefix)
    }

    /// A read-only page's save of [way] turned off (AA7 "Fail closed"): the settings exactly as read, with the way taken out of
    /// `ways` and its member removed; every other member, unknown ones included, as its exact source text (a number is sent as it
    /// was written). It only narrows. Nil when [way] can't be turned off: `use`, a way not listed, `ways` that is not a list of
    /// strings, an answer that did not read strictly (a duplicate member: which copy the vault holds is not known), or another
    /// agent's item.
    public static func withoutWay(_ read: ItemWaysRead, _ way: String) -> [UInt8]? {
        guard let o = read.strict, !read.foreign, !same(way, ItemWay.use.wire), let ways = listedWays(o),
              ways.contains(where: { same($0, way) })
        else { return nil }
        let out = JsonBuilder()
        for (name, v) in o.members {
            if same(name, "updated_at") || same(name, way) && ownMember(way) { continue }
            if same(name, "ways") {
                out.raw(name, JsonBuilder.array(ways.filter { !same($0, way) }.map { JsonBuilder.quote($0) }))
            } else {
                out.raw(name, exact(v))
            }
        }
        return out.bytes()
    }

    /// `ways` as a list of strings, or nil when it is not one.
    private static func listedWays(_ o: JsonObject) -> [String]? {
        guard case .array(_, let items)? = o["ways"] else { return nil }
        let names = items.compactMap { v -> String? in
            if case .string(_, let s) = v { s } else { nil }
        }
        return names.count == items.count ? names : nil
    }

    /// The way's own member goes with it (run, proxy, or an unknown way's), never one of the item's own members.
    private static func ownMember(_ way: String) -> Bool {
        !topMembers.contains(Array(way.utf8)) || same(way, ItemWay.run.wire) || same(way, ItemWay.proxy.wire)
    }

    /// [v] as it was written: numbers as their source text (a number written back through a `Double` would turn `1e2` into
    /// `100.0` and round a big integer), strings re-encoded, objects and arrays member by member.
    private static func exact(_ v: JsonValue) -> String {
        switch v {
        case .object(let o):
            "{" + o.members.map { JsonBuilder.quote($0.name) + ":" + exact($0.value) }.joined(separator: ",") + "}"
        case .array(_, let items): JsonBuilder.array(items.map(exact))
        case .string(_, let s): JsonBuilder.quote(s)
        case .bool, .null, .number: v.raw
        }
    }
}
