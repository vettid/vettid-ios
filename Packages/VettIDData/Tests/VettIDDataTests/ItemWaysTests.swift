import Foundation
import Testing
import VettIDCrypto
@testable import VettIDData

// Test data: long literal rows are clearer than wrapped ones.
// swiftlint:disable line_length

private func obj(_ bytes: [UInt8]) throws -> JsonObject { try StrictJson.parseObject(bytes) }

private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

private func item(_ body: String) -> String { #"{"agent_id":"a1","item_id":"i1",\#(body)}"# }

private let sha = String(repeating: "ab", count: 32)

private func bound(_ p: RunProgram..., each: Bool = true) -> ItemWays {
    ItemWays(agentID: "a1", itemID: "i1", version: 1, ways: [.use, .run], run: RunSettings(programs: p, each: each))
}

private func rules() -> ItemWays { ItemWays(agentID: "a1", itemID: "i1") }

/// ANDROID-PLAN 0.1.137 AA7: item_ways read strictly, checked as the vault checks them, compared for a widening. Mirrors
/// vettid-android `ItemWaysTest`.
@Suite struct ItemWaysTests {
    let full = item(
        #""version":3,"ways":["use","run","proxy","reveal"],"run":{"programs":[{"program":"git","sha256":"\#(sha)","path":"/usr/bin/git","env":["GH_HOST"]},"#
            + #"{"program":"/usr/bin/gh","env":[]}],"each":false,"folders":[]},"proxy":{"hosts":["api.example.com","b.example.org:8443"],"#
            + #""header":"Authorization","prefix":"Bearer "},"updated_at":"2026-11-22T10:00:00Z""#
    )

    @Test func readsEverySettingAndSendsItBackAsRead() throws {
        let r = try #require(ItemWaysRules.one(bytes(full)))
        let w = try #require(r.ways)
        #expect(!r.readOnly)
        #expect(r.foldersKnown)
        #expect(w.version == 3)
        #expect(w.ways == [.use, .run, .proxy, .reveal])
        #expect(w.run?.programs[0] == RunProgram(program: "git", sha256: sha, path: "/usr/bin/git", env: ["GH_HOST"]))
        #expect(w.run?.each == false)
        #expect(w.proxy == ProxySettings(hosts: ["api.example.com", "b.example.org:8443"], header: "Authorization", prefix: "Bearer "))
        // Round trip: the body the app sends reads back to the same settings.
        let body = w.setBody()
        let back = try #require(ItemWaysRules.one(body)?.ways)
        #expect(back == w)
        let o = try obj(body)
        #expect(o["updated_at"] == nil)
        #expect(o["ways"]?.raw == #"["use","run","proxy","reveal"]"#)
    }

    @Test func anItemWithNoSettingsIsUseOnly() throws {
        let r = try #require(ItemWaysRules.one(bytes(item(#""ways":["use"]"#))))
        #expect(r.ways == rules())
        let body = try obj(try #require(r.ways).setBody())
        #expect(body["version"] == nil)
        #expect(!r.foldersKnown)
        // A run binding from a vault before 0.93.0 (no folders): sent back without them.
        let old = try #require(ItemWaysRules.one(bytes(item(#""ways":["use","run"],"run":{"programs":[],"each":true}"#))))
        #expect(!old.foldersKnown)
        let oldRun = try obj(try #require(old.ways).setBody()).obj("run")
        #expect(oldRun["folders"] == nil)
    }

    /// AA7 "Fail closed": each of these makes the page read only.
    @Test func whatTheAppDoesNotUnderstandIsReadOnly() throws {
        let cases: [(String, String)] = [
            ("unknown top", item(#""ways":["use"],"extra":1"#)),
            ("unknown way", item(#""ways":["use","teleport"]"#)),
            ("no use", item(#""ways":["run"],"run":{"programs":[],"each":true}"#)),
            ("duplicate way", item(#""ways":["use","use"]"#)),
            ("run without way", item(#""ways":["use"],"run":{"programs":[],"each":true}"#)),
            ("way without run", item(#""ways":["use","run"]"#)),
            ("proxy without way", item(#""ways":["use"],"proxy":{"hosts":["a.example.com"],"header":"X"}"#)),
            ("unknown run member", item(#""ways":["use","run"],"run":{"programs":[],"each":true,"x":1}"#)),
            ("unknown program member", item(#""ways":["use","run"],"run":{"programs":[{"program":"git","x":1}],"each":true}"#)),
            // Any folder is read only until AA9, so this row can't yet be told from the next one.
            ("unknown folder member", item(#""ways":["use","run"],"run":{"programs":[],"each":true,"folders":[{"path":"/a/b","write":false,"x":1}]}"#)),
            ("unknown proxy member", item(#""ways":["use","proxy"],"proxy":{"hosts":["a.example.com"],"header":"X","x":1}"#)),
            ("folders (no AA9 yet)", item(#""ways":["use","run"],"run":{"programs":[],"each":true,"folders":[{"path":"/a/b","write":false}]}"#)),
            ("sha without path", item(#""ways":["use","run"],"run":{"programs":[{"program":"git","sha256":"\#(sha)"}],"each":true}"#)),
            ("capital sha", item(#""ways":["use","run"],"run":{"programs":[{"program":"git","sha256":"\#(sha.uppercased())","path":"/usr/bin/git"}],"each":true}"#)),
            ("63-digit sha", item(#""ways":["use","run"],"run":{"programs":[{"program":"git","sha256":"\#(sha.dropFirst())","path":"/usr/bin/git"}],"each":true}"#)),
            ("each false unbound", item(#""ways":["use","run"],"run":{"programs":[],"each":false}"#)),
            ("string each", item(#""ways":["use","run"],"run":{"programs":[],"each":"true"}"#)),
            ("bad program", item(#""ways":["use","run"],"run":{"programs":[{"program":"a/b"}],"each":true}"#)),
            ("duplicate programs", item(#""ways":["use","run"],"run":{"programs":[{"program":"git"},{"program":"GIT.exe"}],"each":true}"#)),
            ("bad env", item(#""ways":["use","run"],"run":{"programs":[{"program":"git","env":["lower"]}],"each":true}"#)),
            ("no hosts", item(#""ways":["use","proxy"],"proxy":{"hosts":[],"header":"X"}"#)),
            ("IP host", item(#""ways":["use","proxy"],"proxy":{"hosts":["10.0.0.1"],"header":"X"}"#)),
            ("bad header", item(#""ways":["use","proxy"],"proxy":{"hosts":["a.example.com"],"header":"Host"}"#)),
            ("bad prefix", item(#""ways":["use","proxy"],"proxy":{"hosts":["a.example.com"],"header":"X","prefix":"\#(String(repeating: "x", count: 33))"}"#)),
            ("version 0", item(#""version":0,"ways":["use"]"#)),
            ("string version", item(#""version":"1","ways":["use"]"#)),
            ("duplicate member", #"{"agent_id":"a1","item_id":"i1","ways":["use"],"ways":["use"]}"#),
            ("duplicate hosts", item(#""ways":["use","proxy"],"proxy":{"hosts":["a.example.com","a.example.com:443"],"header":"X"}"#)),
            ("duplicate variables", item(#""ways":["use","run"],"run":{"programs":[{"program":"git","env":["A","A"]}],"each":true}"#)),
            ("empty agent", #"{"agent_id":"","item_id":"i1","ways":["use"]}"#),
            ("empty item", #"{"agent_id":"a1","item_id":"","ways":["use"]}"#),
            ("malformed updated_at", item(#""ways":["use"],"updated_at":"yesterday""#)),
            ("pin path not absolute", item(#""ways":["use","run"],"run":{"programs":[{"program":"git","sha256":"\#(sha)","path":"bin/git"}],"each":true}"#)),
            ("17 programs", item(#""ways":["use","run"],"run":{"programs":[\#((1...17).map { "{\"program\":\"p\($0)\"}" }.joined(separator: ","))],"each":true}"#)),
        ]
        for (name, json) in cases {
            let r = ItemWaysRules.one(bytes(json))
            #expect(r != nil, Comment(rawValue: name))
            #expect(r?.readOnly == true, Comment(rawValue: "\(name) is editable"))
        }
    }

    /// A read-only page turns a way off: the rest exactly as read, unknown members included; never `use`.
    @Test func aReadOnlyPageTurnsAWayOffAndSendsTheRestAsRead() throws {
        let r = try #require(ItemWaysRules.one(bytes(item(#""version":2,"ways":["use","run","reveal"],"run":{"programs":[],"each":true,"folders":[{"path":"/a/b","write":true}]},"extra":{"k":1}"#))))
        #expect(r.readOnly)
        let body = try obj(try #require(ItemWaysRules.withoutWay(r, "run")))
        #expect(body["ways"]?.raw == #"["use","reveal"]"#)
        #expect(body["run"] == nil)
        #expect(body["extra"]?.raw == #"{"k":1}"#)
        #expect(body["version"]?.raw == "2")
        #expect(ItemWaysRules.withoutWay(r, "use") == nil)
        #expect(ItemWaysRules.withoutWay(r, "proxy") == nil)
    }

    /// Unknown members go back as their exact source text: a number as written, a big integer whole.
    @Test func aTurnOffSendsUnknownValuesAsWritten() throws {
        let r = try #require(ItemWaysRules.one(bytes(item(#""version":2,"ways":["use","reveal","x_way"],"x_way":{"n":1e2,"big":123456789012345678901234567890,"f":0.10}"#))))
        let sent = String(bytes: try #require(ItemWaysRules.withoutWay(r, "reveal")), encoding: .utf8) ?? ""
        #expect(sent.contains(#""n":1e2"#) && sent.contains(#""big":123456789012345678901234567890"#) && sent.contains(#""f":0.10"#), Comment(rawValue: "a number was not sent as written"))
        #expect(sent.contains(#""ways":["use","x_way"]"#))
    }

    /// No turn-off when the vault's copy is not known (a duplicate member) or the item is another agent's.
    @Test func noTurnOffWithoutAStrictReadingOrForAnotherAgent() throws {
        let dup = try #require(ItemWaysRules.one(bytes(item(#""ways":["use","run"],"run":{"programs":[],"each":true},"run":{"programs":[{"program":"git"}],"each":false}"#))))
        #expect(dup.readOnly)
        #expect(ItemWaysRules.withoutWay(dup, "run") == nil)
        let foreign = try #require(ItemWaysRules.list(bytes(#"{"items":[{"agent_id":"a2","item_id":"i1","ways":["use","reveal"]}]}"#), agentID: "a1")?.first)
        #expect(foreign.foreign && foreign.readOnly)
        #expect(ItemWaysRules.withoutWay(foreign, "reveal") == nil)
    }

    /// `ways` that is not a list of strings can't be turned off.
    @Test func noTurnOffWhenWaysIsNotAListOfStrings() throws {
        let r = try #require(ItemWaysRules.one(bytes(item(#""ways":["use",7,"reveal"]"#))))
        #expect(r.readOnly)
        #expect(ItemWaysRules.withoutWay(r, "reveal") == nil)
    }

    /// AA9's widenings, as the vault's: a folder added, or its write turned on.
    @Test func foldersWiden() {
        var cur = bound(RunProgram(program: "git"))
        cur.run?.folders = [RunFolder(path: "/a", write: false)]
        func with(_ f: RunFolder...) -> ItemWays {
            var n = cur
            n.run?.folders = f
            return n
        }
        #expect(ItemWaysRules.widens(cur, with(RunFolder(path: "/a", write: false), RunFolder(path: "/b", write: false))))
        #expect(ItemWaysRules.widens(cur, with(RunFolder(path: "/a", write: true))))
        #expect(!ItemWaysRules.widens(cur, with()))
        #expect(!ItemWaysRules.widens(with(RunFolder(path: "/a", write: true)), cur))
    }

    @Test func aListThatDoesNotReadStrictlyIsReadOnlyThroughout() throws {
        let list = try #require(ItemWaysRules.list(bytes(#"{"items":[{"agent_id":"a1","item_id":"i1","ways":["use"]},{"agent_id":"a1","item_id":"i2","ways":["use"],"ways":["use"]}]}"#)))
        #expect(list.count == 2)
        #expect(list.allSatisfy { $0.readOnly })
        let ok = try #require(ItemWaysRules.list(bytes(#"{"items":[{"agent_id":"a1","item_id":"i1","ways":["use"]}]}"#)))
        #expect(try #require(ok.first).readOnly == false)
        // Another agent's item is read only.
        #expect(try #require(ItemWaysRules.list(bytes(#"{"items":[{"agent_id":"a2","item_id":"i1","ways":["use"]}]}"#), agentID: "a1")?.first).readOnly)
    }

    /// One (agent, item) pair listed twice: every item is read only, the other items included (which copy to edit is unknown).
    @Test func aPairListedTwiceMakesTheListReadOnly() throws {
        let twice = #"{"items":[{"agent_id":"a1","item_id":"i1","version":1,"ways":["use"]},{"agent_id":"a1","item_id":"i1","version":2,"ways":["use","reveal"]},{"agent_id":"a1","item_id":"i2","version":1,"ways":["use"]}]}"#
        let all = try #require(ItemWaysRules.list(bytes(twice), agentID: "a1"))
        #expect(all.count == 3 && all.allSatisfy(\.readOnly))
        // No copy can be turned off either: that would send its settings, which may be wider than the vault's.
        #expect(all.allSatisfy { ItemWaysRules.withoutWay($0, "reveal") == nil })
        // The same item id for another agent is another pair.
        let two = #"{"items":[{"agent_id":"a1","item_id":"i1","version":1,"ways":["use"]},{"agent_id":"a2","item_id":"i1","version":1,"ways":["use"]}]}"#
        let read = try #require(ItemWaysRules.list(bytes(two)))
        #expect(read.allSatisfy { !$0.readOnly })
    }

    /// A `null` where settings, `each` or the version belong is read only (never read as absent).
    @Test func aNullSettingIsReadOnly() throws {
        for body in [
            #""version":1,"ways":["use","run"],"run":null"#,
            #""version":1,"ways":["use","proxy"],"proxy":null"#,
            #""version":1,"ways":["use","run"],"run":{"programs":[],"each":null}"#,
            #""version":null,"ways":["use"]"#,
            #""version":1,"ways":["use"],"run":null"#,
        ] {
            let r = try #require(ItemWaysRules.one(bytes(item(body))), Comment(rawValue: body))
            #expect(r.readOnly, Comment(rawValue: body))
        }
    }

    /// One item's settings are never shown under another item's name.
    @Test func anEntryThatIsNotAnObjectMakesTheAnswerUnreadable() throws {
        let shifted = #"{"items":[null,{"agent_id":"a1","item_id":"B","ways":["use"]},{"agent_id":"a1","item_id":"C","version":5,"ways":["use","reveal"]}]}"#
        #expect(ItemWaysRules.list(bytes(shifted)) == nil)
        for bad in ["{}", #"{"items":{}}"#, "[]", "not json", #"{"items":[1]}"#, ""] { #expect(ItemWaysRules.list(bytes(bad)) == nil, Comment(rawValue: bad)) }
        #expect(ItemWaysRules.list(bytes(#"{"items":[]}"#))?.isEmpty == true)
        // Every strict reading is of the item the lenient reading names.
        let two = try #require(ItemWaysRules.list(bytes(#"{"items":[{"agent_id":"a1","item_id":"B","ways":["use"]},{"agent_id":"a1","item_id":"C","version":5,"ways":["use","reveal"]}]}"#)))
        #expect(two.map { $0.ways?.itemID } == ["B", "C"])
        #expect(two[1].ways?.version == 5)
    }

    @Test func programKeysLowerCaseRuneByRuneAsTheVaultDoes() {
        // Go's strings.ToLower: no final sigma, İ one rune.
        #expect(ItemWaysRules.programKey("ΑΣ") == "ασ")
        #expect(ItemWaysRules.programKey("ασ") == ItemWaysRules.programKey("ΑΣ"))
        #expect(ItemWaysRules.duplicates(["ασ"], "ΑΣ"))
        #expect(!ItemWaysRules.duplicates(["ας"], "ΑΣ"))
        #expect(ItemWaysRules.programKey("gİt").unicodeScalars.count == 3)
        #expect(ItemWaysRules.programKey("gİt") == "git")
    }

    @Test func aBareNameAndAPathEndingInItAreReadOnlyAsTheVaultRefusesThem() throws {
        let r = try #require(ItemWaysRules.one(bytes(item(#""ways":["use","run"],"run":{"programs":[{"program":"git"},{"program":"/usr/bin/Git.exe"}],"each":true}"#))))
        #expect(r.readOnly)
    }

    @Test func turningOffAnUnknownWayKeepsTheItemsOwnMembers() throws {
        let r = try #require(ItemWaysRules.one(bytes(item(#""version":2,"ways":["use","teleport","version"],"teleport":{"k":1},"other":{"k":2},"updated_at":"2026-11-22T10:00:00Z""#))))
        #expect(r.readOnly)
        let off = try obj(try #require(ItemWaysRules.withoutWay(r, "teleport")))
        #expect(off["teleport"] == nil)
        #expect(off["other"]?.raw == #"{"k":2}"#)
        #expect(off["updated_at"] == nil)
        // A way named after one of the item's own members leaves that member alone.
        let version = try obj(try #require(ItemWaysRules.withoutWay(r, "version")))
        #expect(version["version"]?.raw == "2")
    }

    /// A pin the vault recorded is sent only as read; a program without one sends none.
    @Test func aForgottenPinNarrowsAndIsNotSent() throws {
        let cur = bound(RunProgram(program: "git", sha256: sha, path: "/usr/bin/git"))
        let next = bound(RunProgram(program: "git"))
        #expect(!ItemWaysRules.widens(cur, next))
        let p = try #require(try obj(next.setBody()).obj("run").array("programs").first?.asObject())
        #expect(p["sha256"] == nil)
        #expect(p["path"] == nil)
    }

    @Test func programChecks() {
        let ok = ["git", "git.exe", "/usr/bin/git", "C:\\Program Files\\Git\\cmd\\git.exe", "C:/x/y.exe", "my tool"]
        for p in ok { #expect(ItemWaysRules.programProblem(p) == nil, Comment(rawValue: p)) }
        let bad: [(String, ProgramProblem)] = [
            ("", .notPathOrName),
            ("bin/git", .notPathOrName),
            ("bin\\git", .notPathOrName),
            ("...", .notPathOrName),
            (" . ", .notPathOrName),
            ("/usr/bin/. ", .notPathOrName),
            ("git\u{1}", .characters),
            ("gi\u{200B}t", .characters),
            ("/" + String(repeating: "a", count: 4096), .tooLong),
            ("/usr//bin/git", .pathParts),
            ("/usr/bin/../git", .pathParts),
            ("/usr/bin/./git", .pathParts),
            ("/usr/bin/", .pathParts),
            ("C:/x/git.exe::$DATA", .pathParts),
            ("C:git", .pathParts),
            ("//server/share/git", .networkPath),
            ("\\\\server\\share\\git.exe", .networkPath),
            ("C:\\PROGRA~1\\BASH~1.EXE", .tilde),
        ]
        for (p, want) in bad { #expect(ItemWaysRules.programProblem(p) == want, Comment(rawValue: p)) }
        // The no-two-match rule: case, .exe, trailing dots and spaces, / for \ in a drive path, a name against a path's last part.
        let listed = [RunProgram(program: "/usr/bin/git"), RunProgram(program: "C:\\x\\tool.exe")]
        for p in ["/usr/bin/GIT", "/usr/bin/git.exe", "git", "Git.EXE", "C:/x/TOOL", "tool", "C:\\x\\tool. "] {
            #expect(ItemWaysRules.addProgramProblem(listed, p) == .duplicate, Comment(rawValue: p))
        }
        #expect(ItemWaysRules.addProgramProblem(listed, "/usr/local/bin/gh") == nil)
        #expect(ItemWaysRules.addProgramProblem((1...16).map { RunProgram(program: "p\($0)") }, "q") == .tooMany)
        #expect(ItemWaysRules.addProgramProblem((1...15).map { RunProgram(program: "p\($0)") }, "q") == nil)
    }

    @Test func variableChecks() {
        #expect(ItemWaysRules.variableProblem([], "GH_HOST") == nil)
        #expect(ItemWaysRules.variableProblem([], "_A1") == nil)
        #expect(ItemWaysRules.variableProblem([], "A" + String(repeating: "B", count: 63)) == nil)
        for n in ["", "lower", "1ABC", "A-B", "A B", "A" + String(repeating: "B", count: 64), "A\n"] {
            #expect(ItemWaysRules.variableProblem([], n) == .form, Comment(rawValue: n))
        }
        // The names the vault refuses by name are not the app's to list: they pass the form.
        #expect(ItemWaysRules.variableProblem([], "VETTID_IN") == nil)
        let full = (1...32).map { "V\($0)" }
        #expect(ItemWaysRules.variableProblem(full, "W") == .tooMany)
        #expect(ItemWaysRules.variableProblem(full, "V1") == nil)
    }

    @Test func hostChecks() {
        for h in ["api.example.com", "a.b.example.org:8443", "x-y.example.com", "printer.local"] { #expect(ItemWaysRules.hostProblem(h) == nil, Comment(rawValue: h)) }
        let bad: [(String, HostProblem)] = [
            ("*.example.com", .wildcard),
            ("10.0.0.1", .ipAddress),
            ("10.0.0.1:443", .ipAddress),
            ("[::1]", .ipAddress),
            ("::1", .ipAddress),
            ("1.2.3", .ipAddress),
            ("a.0x7f", .ipAddress),
            ("localhost", .local),
            ("api.localhost", .local),
            ("intranet", .local),
            ("api.example.com:0", .notAHost),
            ("api.example.com:65536", .notAHost),
            ("api.example.com:", .notAHost),
            ("-a.example.com", .notAHost),
            ("a..example.com", .notAHost),
            ("a_b.example.com", .notAHost),
            ("", .notAHost),
        ]
        for (h, want) in bad { #expect(ItemWaysRules.hostProblem(h) == want, Comment(rawValue: h)) }
        #expect(ItemWaysRules.normalizeHost(" API.Example.COM ") == "api.example.com")
        #expect(ItemWaysRules.addHostProblem(["api.example.com"], "api.example.com:443") == .duplicate)
        #expect(ItemWaysRules.addHostProblem((1...8).map { "h\($0).example.com" }, "x.example.com") == .tooMany)
    }

    @Test func headerAndPrefixChecks() {
        for h in ["Authorization", "X-Api-Key", "x_token", String(repeating: "a", count: 64)] { #expect(ItemWaysRules.headerValid(h), Comment(rawValue: h)) }
        for h in ["", String(repeating: "a", count: 65), "Host", "content-length", "Transfer-Encoding", "Cookie", "Connection", "X Key", "X:Key"] {
            #expect(!ItemWaysRules.headerValid(h), Comment(rawValue: h))
        }
        for p in ["", "Bearer ", "Token ", String(repeating: " ", count: 32)] { #expect(ItemWaysRules.prefixValid(p), Comment(rawValue: p)) }
        for p in [String(repeating: "x", count: 33), "Bé ", "a\tb"] { #expect(!ItemWaysRules.prefixValid(p), Comment(rawValue: p)) }
    }

    /// AA7 "Saving": what widens asks for the password; what narrows does not.
    @Test func wideningAndNarrowing() throws {
        var cur = bound(RunProgram(program: "git", env: ["GH_HOST"]), RunProgram(program: "/usr/bin/gh"), each: false)
        cur.ways = [.use, .run, .proxy]
        cur.proxy = ProxySettings(hosts: ["api.example.com"], header: "Authorization", prefix: "Bearer ")
        func with(_ change: (inout ItemWays) -> Void) -> ItemWays {
            var n = cur
            change(&n)
            return n
        }
        let widen: [(String, ItemWays)] = [
            ("a way", with { $0.ways.insert(.reveal) }),
            ("a program", with { $0.run?.programs.append(RunProgram(program: "curl")) }),
            ("programs emptied", with { $0.run = RunSettings(programs: [], each: true) }),
            ("a variable", with { $0.run?.programs = [RunProgram(program: "git", env: ["GH_HOST", "GH_REPO"]), RunProgram(program: "/usr/bin/gh")] }),
            ("a host", with { $0.proxy?.hosts = ["api.example.com", "b.example.com"] }),
            ("the header", with { $0.proxy?.header = "X-Api-Key" }),
            ("a changed program", with { $0.run?.programs = [RunProgram(program: "git2", env: ["GH_HOST"]), RunProgram(program: "/usr/bin/gh")] }),
            ("a changed host", with { $0.proxy?.hosts = ["api.example.net"] }),
            ("a host's port", with { $0.proxy?.hosts = ["api.example.com:8443"] }),
        ]
        for (name, next) in widen { #expect(ItemWaysRules.widens(cur, next), Comment(rawValue: name)) }
        // The proxy added to an item that had none.
        var noProxy = cur
        noProxy.ways.remove(.proxy)
        noProxy.proxy = nil
        #expect(ItemWaysRules.widens(noProxy, cur), "proxy added")
        let askAgain = with { $0.run?.each = true }
        #expect(ItemWaysRules.widens(askAgain, cur), "each off")
        let narrow: [(String, ItemWays)] = [
            ("a way removed", with { $0.ways.remove(.proxy); $0.proxy = nil }),
            ("a program removed", with { $0.run?.programs = Array(cur.run?.programs.prefix(1) ?? []) }),
            ("a variable removed", with { $0.run?.programs = [RunProgram(program: "git"), RunProgram(program: "/usr/bin/gh")] }),
            ("each on", askAgain),
            ("a host removed", with { $0.proxy?.hosts = ["api.example.com"] }),
            ("the header's case", with { $0.proxy?.header = "authorization" }),
            ("the prefix", with { $0.proxy?.prefix = "Token " }),
            ("a path for the name", with { $0.run?.programs = [RunProgram(program: "/usr/bin/git", env: ["GH_HOST"]), RunProgram(program: "/usr/bin/gh")] }),
        ]
        for (name, next) in narrow { #expect(!ItemWaysRules.widens(cur, next), Comment(rawValue: name)) }
        // A path that replaces a name widens when its last part is not exactly the name, or it adds a variable.
        #expect(ItemWaysRules.widens(cur, with { $0.run?.programs = [RunProgram(program: "/usr/bin/GIT", env: ["GH_HOST"]), RunProgram(program: "/usr/bin/gh")] }))
        #expect(ItemWaysRules.widens(cur, with { $0.run?.programs = [RunProgram(program: "/usr/bin/git", env: ["GH_HOST", "X"]), RunProgram(program: "/usr/bin/gh")] }))
        // Binding an unbound item narrows, unless a variable is listed or each is off.
        let unbound = bound()
        #expect(!ItemWaysRules.widens(unbound, bound(RunProgram(program: "git"))))
        #expect(ItemWaysRules.widens(unbound, bound(RunProgram(program: "git", env: ["A"]))))
        #expect(ItemWaysRules.widens(unbound, bound(RunProgram(program: "git"), each: false)))
        // From no settings: any way but use widens.
        #expect(ItemWaysRules.widens(nil, bound()))
        #expect(!ItemWaysRules.widens(nil, rules()))
    }

    // MARK: Swift only

    /// The vault compares bytes: a program renamed to a canonically equivalent spelling is another program, so a widening
    /// (Swift's own `==` would call the two equal).
    @Test func anEquivalentSpellingIsAnotherProgram() {
        let composed = "caf\u{E9}"
        let decomposed = "cafe\u{301}"
        #expect(composed == decomposed)
        let cur = bound(RunProgram(program: composed))
        #expect(ItemWaysRules.widens(cur, bound(RunProgram(program: decomposed))))
        #expect(ItemWaysRules.widens(cur, bound(RunProgram(program: composed, env: ["A"]))))
        #expect(!ItemWaysRules.duplicates([composed], decomposed))
        // A variable and a host too.
        let withVar = bound(RunProgram(program: "git", env: ["A\u{212A}"]))
        #expect(ItemWaysRules.widens(bound(RunProgram(program: "git", env: ["AK"])), withVar))
    }

    /// A header changed to a non-ASCII spelling of a letter is a change (the direction that asks for the password).
    @Test func aNonAsciiHeaderLetterIsAChange() {
        var cur = bound()
        cur.ways = [.use, .proxy]
        cur.run = nil
        cur.proxy = ProxySettings(hosts: ["api.example.com"], header: "Authorization")
        var next = cur
        next.proxy?.header = "Authorızation"
        #expect(ItemWaysRules.widens(cur, next))
    }

    @Test func theValuesAreNeverPrinted() {
        let w = ItemWays(agentID: "a1", itemID: "secret-item", ways: [.use, .run], run: RunSettings(programs: [RunProgram(program: "secret-prog")]))
        for s in ["\(w)", "\(String(reflecting: w))", "\(RunProgram(program: "secret-prog"))", "\(ProxySettings(hosts: ["secret.example.com"], header: "H"))"] {
            #expect(!s.contains("secret"), Comment(rawValue: s))
        }
        let r = ItemWaysRules.one(bytes(item(#""ways":["use"]"#)))
        #expect("\(String(describing: r))".contains("a1") == false)
    }
}

// swiftlint:enable line_length
