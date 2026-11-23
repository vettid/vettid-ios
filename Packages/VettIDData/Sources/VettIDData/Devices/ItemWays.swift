import Foundation
import VettIDCrypto

// How an agent may use an item (VAULT-MESSAGING §10.11 "Ways to use a secret"; ANDROID-PLAN 0.1.137 AA7): the settings
// `leash.item.list` and `leash.item.set` carry (`item_ways`), read strictly, checked as the vault checks them, and compared
// for a widening. Memory only; prints no values. Mirrors vettid-android `ItemWays.kt`.
//
// Strings are compared by their UTF-8 bytes throughout (``same(_:_:)``), never with Swift's `==`, which treats canonically
// equivalent strings as equal: the vault compares bytes, and a program renamed to an equivalent spelling is a different
// program there (a widening here too).

/// A way an agent may use an item.
public enum ItemWay: String, CaseIterable, Sendable {
    case use
    case run
    case proxy
    case reveal

    public var wire: String { rawValue }

    public static func of(_ wire: String) -> ItemWay? { allCases.first { same($0.rawValue, wire) } }
}

/// Whether [a] and [b] are the same bytes (not merely canonically equivalent).
func same(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }

/// One program of a run binding: as typed ([program]), the pin the vault recorded ([sha256], [path]: both or neither), its
/// variables.
public struct RunProgram: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var program: String
    public var sha256: String?
    public var path: String?
    public var env: [String]

    public init(program: String, sha256: String? = nil, path: String? = nil, env: [String] = []) {
        self.program = program
        self.sha256 = sha256
        self.path = path
        self.env = env
    }

    public var description: String { "RunProgram" }
    public var debugDescription: String { "RunProgram" }
}

/// A member folder a run may use (AA9): read only unless [write].
public struct RunFolder: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var path: String
    public var write: Bool

    public init(path: String, write: Bool) {
        self.path = path
        self.write = write
    }

    public var description: String { "RunFolder" }
    public var debugDescription: String { "RunFolder" }
}

/// The run settings. [folders] is what the vault returned (VAULT-MESSAGING 0.93.0: an empty list when none), nil when the
/// answer had no `run.folders` (a vault before 0.93.0): it is sent back as read.
public struct RunSettings: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var programs: [RunProgram]
    public var each: Bool
    public var folders: [RunFolder]?

    public init(programs: [RunProgram] = [], each: Bool = true, folders: [RunFolder]? = nil) {
        self.programs = programs
        self.each = each
        self.folders = folders
    }

    public var description: String { "RunSettings" }
    public var debugDescription: String { "RunSettings" }
}

/// The API settings: 1–8 hosts, the header's name and what goes before the key.
public struct ProxySettings: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var hosts: [String]
    public var header: String
    public var prefix: String

    public init(hosts: [String], header: String, prefix: String = "") {
        self.hosts = hosts
        self.header = header
        self.prefix = prefix
    }

    public var description: String { "ProxySettings" }
    public var debugDescription: String { "ProxySettings" }
}

/// One item's settings for one agent, as the app understands them. [version] is absent for an item with no settings
/// (`["use"]` only, VAULT-MESSAGING 0.91.0 "Versions"). [run] is set exactly when [ways] holds run, [proxy] likewise.
public struct ItemWays: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var agentID: String
    public var itemID: String
    public var version: Int64?
    public var ways: Set<ItemWay>
    public var run: RunSettings?
    public var proxy: ProxySettings?

    public init(
        agentID: String, itemID: String, version: Int64? = nil, ways: Set<ItemWay> = [.use], run: RunSettings? = nil,
        proxy: ProxySettings? = nil
    ) {
        self.agentID = agentID
        self.itemID = itemID
        self.version = version
        self.ways = ways
        self.run = run
        self.proxy = proxy
    }

    public var description: String { "ItemWays" }
    public var debugDescription: String { "ItemWays" }

    /// The `leash.item.set` body for these settings (AA7 "Saving"): `version` as read (absent when the item had none), ways
    /// in wire order, a program's pin only as it was read (the vault records pins, never the app), folders as read.
    public func setBody() -> [UInt8] {
        let b = JsonBuilder().string("agent_id", agentID).string("item_id", itemID)
        if let version, version >= 0 { b.uint("version", UInt64(version)) }
        b.raw("ways", JsonBuilder.array(ItemWay.allCases.filter { ways.contains($0) }.map { JsonBuilder.quote($0.wire) }))
        if let run { b.raw("run", Self.runJSON(run)) }
        if let proxy {
            let p = JsonBuilder()
                .raw("hosts", JsonBuilder.array(proxy.hosts.map { JsonBuilder.quote($0) }))
                .string("header", proxy.header)
                .string("prefix", proxy.prefix)
            b.raw("proxy", p.build())
        }
        return b.bytes()
    }

    private static func runJSON(_ r: RunSettings) -> String {
        let programs = r.programs.map { p -> String in
            let o = JsonBuilder().string("program", p.program)
            if let sha = p.sha256, let path = p.path {
                o.string("sha256", sha)
                o.string("path", path)
            }
            o.raw("env", JsonBuilder.array(p.env.map { JsonBuilder.quote($0) }))
            return o.build()
        }
        let o = JsonBuilder().raw("programs", JsonBuilder.array(programs)).bool("each", r.each)
        if let fs = r.folders {
            o.raw("folders", JsonBuilder.array(fs.map { JsonBuilder().string("path", $0.path).bool("write", $0.write).build() }))
        }
        return o.build()
    }
}

/// An `item_ways` as read. [ways] is set when the app understands all of it, which is when it may be edited (AA7 "Fail
/// closed"); read only otherwise. [rawWays] are the ways it lists, as wire strings, so that a read-only page can still offer
/// to turn each off. A read-only page's narrowing save sends the strict reading back with one way taken out
/// (``ItemWaysRules/withoutWay(_:_:)``).
public struct ItemWaysRead: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let agentID: String
    public let itemID: String
    public let ways: ItemWays?
    public let rawWays: [String]
    /// The strict reading of the answer, nil when it did not read strictly (a duplicate member): nothing is turned off then.
    public let strict: JsonObject?
    /// Listed for another agent than the one asked about: read only, and never turned off from this agent's page.
    public let foreign: Bool
    /// The answer carries `run.folders`, read or not (a read-only page's "Stop runs" text says the folders go too).
    public let answerHasFolders: Bool

    public init(
        agentID: String, itemID: String, ways: ItemWays?, rawWays: [String], strict: JsonObject? = nil, foreign: Bool = false,
        answerHasFolders: Bool = false
    ) {
        self.agentID = agentID
        self.itemID = itemID
        self.ways = ways
        self.rawWays = rawWays
        self.strict = strict
        self.foreign = foreign
        self.answerHasFolders = answerHasFolders
    }

    public var readOnly: Bool { ways == nil }

    /// The vault's answer held `run.folders` (VAULT-MESSAGING 0.93.0): AA9's folders settings may be shown.
    public var foldersKnown: Bool { ways?.run?.folders != nil }

    public var description: String { "ItemWaysRead" }
    public var debugDescription: String { "ItemWaysRead" }

    /// The same read, listed for another agent than the one asked about: read only.
    public func asForeign() -> ItemWaysRead { with(ways: nil, foreign: true) }

    func with(ways: ItemWays?, foreign: Bool) -> ItemWaysRead {
        ItemWaysRead(
            agentID: agentID, itemID: itemID, ways: ways, rawWays: rawWays, strict: strict, foreign: foreign,
            answerHasFolders: answerHasFolders
        )
    }
}

/// Why a program can't be added (AA7 "Add a program"), each with its own text.
public enum ProgramProblem: Sendable {
    case notPathOrName, characters, tooLong, pathParts, networkPath, tilde, duplicate, tooMany
}

/// Why a variable name can't be added (AA7 "Add a variable").
public enum VariableProblem: Sendable { case form, tooMany }

/// Why a host can't be added (AA7 "Add a host").
public enum HostProblem: Sendable { case notAHost, ipAddress, local, wildcard, duplicate, tooMany }
