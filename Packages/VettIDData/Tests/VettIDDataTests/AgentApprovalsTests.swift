import Foundation
import Testing
import VettIDCrypto
@testable import VettIDData

// Event bodies and fixtures stay on one line each.
// swiftlint:disable line_length

private let sha = String(repeating: "1a2b3c4d5e6f7a8b", count: 4)
private let sha2 = String(repeating: "9f8e7d6c5b4a3928", count: 4)
private let runBody = #"{"op":"item.run","item_id":"i1","field_id":"f1","program":"/usr/bin/git","sha256":"\#(sha)","argv":["git","push","origin"],"how":"env","name":"GH_TOKEN","env":{"GIT_DIR":"/tmp/x","A":"b"}}"#
private let proxyBody = #"{"op":"item.proxy","item_id":"i1","field_id":"f1","host":"api.example.com","seconds":3600}"#
private let proxyNote = #","proxy":{"host":"api.example.com","header":"Authorization","prefix":"Bearer "}"#

private func approval(_ body: String, top: String = "", role: String = "agent", type: String = "agent.request") throws -> JsonObject {
    try StrictJson.parseObject(Array(#"{"approval_id":"h1","device_id":"A","role":"\#(role)","name":"Bot","type":"\#(type)","body":\#(body),"exp":"2026-11-02T12:05:00.000Z"\#(top)}"#.utf8))
}

private func device(_ body: String, top: String = "", role: String = "agent", type: String = "agent.request") throws -> DeviceRequest {
    guard case .device(let d)? = ApprovalParser.parse("approval.pending", try approval(body, top: top, role: role, type: type), at: Date()) else {
        throw CocoaError(.featureUnsupported)
    }
    return d
}

private func held(_ body: String, top: String = "") throws -> HeldApproval { try #require(try device(body, top: top).held) }

private func run(_ change: (String) -> String = { $0 }, top: String = "") throws -> HeldApproval { try held(change(runBody), top: top) }

private func use(_ data: String) -> String { #"{"op":"item.use","item_id":"i1","field_id":"f1","action":"hmac-sha256","data":"\#(data)"}"# }

private func itemRun(_ h: HeldApproval) throws -> ItemRun {
    guard case .itemRun(let r) = h else { throw CocoaError(.featureUnsupported) }
    return r
}

private func itemProxy(_ h: HeldApproval) throws -> ItemProxy {
    guard case .itemProxy(let p) = h else { throw CocoaError(.featureUnsupported) }
    return p
}

/// ANDROID-PLAN 0.1.138 AA8 "Fail closed": an agent's approval read strictly, each rule of the list one case. Mirrors
/// vettid-android `HeldRequestsTest`. A duplicate member cannot reach these (the strict parser refuses it): see
/// ``AgentApprovalsFlowTests``.
@Suite struct AgentApprovalsTests {
    @Test func anItemUseReadsWithItsDataBytes() throws {
        #expect(try held(use("AAEC")) == .itemUse(itemID: "i1", fieldID: "f1", data: [0, 1, 2]))
        #expect(try held(use("AAEC"), top: #","later":1"#) == .itemUse(itemID: "i1", fieldID: "f1", data: [0, 1, 2]), "an unknown member is ignored (§6.8)")
    }

    @Test func anItemUseThatDoesNotReadInFullIsNeverApprovable() throws {
        #expect(try held(use("")) == .unshown)
        #expect(try held(use("!!")) == .unshown)
        #expect(try held(use("AAEC").replacingOccurrences(of: "hmac-sha256", with: "hmac-sha512")) == .unshown)
        #expect(try held(use("AAEC").replacingOccurrences(of: #""item_id":"i1","#, with: "")) == .unshown)
        #expect(try held(use(Data(repeating: 1, count: HeldApprovals.maxData + 1).base64EncodedString())) == .unshown)
        #expect(try held(use(Data(repeating: 1, count: HeldApprovals.maxData).base64EncodedString())).approvable)
    }

    @Test func anItemGetNamesItsFieldsOrAllOfThem() throws {
        #expect(try held(#"{"op":"item.get","item_id":"i1","fields":["f1","f2"]}"#) == .itemGet(itemID: "i1", fieldIDs: ["f1", "f2"]))
        #expect(try held(#"{"op":"item.get","item_id":"i1"}"#) == .itemGet(itemID: "i1", fieldIDs: nil))
        for fields in ["[]", #"["f1","f1"]"#, #""f1""#, "[1]", "[" + (0...64).map { "\"f\($0)\"" }.joined(separator: ",") + "]"] {
            #expect(try held(#"{"op":"item.get","item_id":"i1","fields":\#(fields)}"#) == .unshown, Comment(rawValue: fields))
        }
    }

    @Test func theCatalogIsApprovableAndRunAndProxyAreReadButNotYetApprovable() throws {
        #expect(try held(#"{"op":"catalog"}"#) == .catalog)
        #expect(try !run().approvable)
        #expect(try !held(proxyBody, top: proxyNote).approvable)
    }

    @Test func anItemGetWithoutItsStrictEnvelopeIsDenyOnly() throws {
        let get = #"{"op":"item.get","item_id":"i1"}"#
        #expect(HeldApprovals.of(role: "agent", type: "agent.request", body: try StrictJson.parseObject(Array(get.utf8)), pending: nil) == .unshown)
        for top in [#","flags":["shell"]"#, #","replaces":"a0""#, proxyNote, #","what":1"#, #","previous_sha256":"\#(sha2)""#, #","previous_path":"/x""#, #","folders":{}"#] {
            #expect(try held(get, top: top) == .unshown, Comment(rawValue: top))
        }
        #expect(try held(#"{"op":"item.get","item_id":"i1","extra":1}"#) == .itemGet(itemID: "i1", fieldIDs: nil), "a body member is not judged for a reveal")
        #expect(try held(get, top: #","flags":["history"]"#) == .itemGet(itemID: "i1", fieldIDs: nil))
        #expect(try held(get, top: #","flags":["history","history"]"#) == .unshown)
    }

    @Test func aDesktopsStepUpAndAnythingElseAreDenyOnly() throws {
        func of(_ role: String?, _ type: String?, _ body: String?) throws -> HeldApproval {
            let o = try StrictJson.parseObject(Array("{}".utf8))
            return HeldApprovals.of(role: role, type: type, body: try body.map { try StrictJson.parseObject(Array($0.utf8)) }, pending: o)
        }
        #expect(try of("desktop", "item.put", #"{"x":1}"#) == .desktopStepUp)
        #expect(try of("agent", "message.send", #"{"text":"hi"}"#) == .unshown)
        #expect(try of("agent", "agent.request", #"{"op":"item.delete"}"#) == .unshown)
        #expect(try of("agent", "agent.request", nil) == .unshown)
        #expect(try of(nil, "agent.request", #"{"op":"catalog"}"#) == .unshown)
        #expect(try of("app", "agent.request", #"{"op":"catalog"}"#) == .unshown)
        #expect(!HeldApproval.desktopStepUp.approvable && !HeldApproval.unshown.approvable)
    }

    @Test func nothingTheAgentSentIsPrinted() throws {
        let h = try held(use(Data("SECRETISH-CHALLENGE".utf8).base64EncodedString()))
        #expect(!"\(h)\(String(reflecting: h))".contains("SECRET"))
        #expect(try !"\(held(#"{"op":"item.get","item_id":"i-private","fields":["f-private"]}"#))".contains("private"))
        let r = try itemRun(run()), p = try itemProxy(held(proxyBody, top: proxyNote))
        #expect("\(r)" == "ItemRun" && String(reflecting: r) == "ItemRun" && "\(p)" == "ItemProxy")
    }

    @Test func aRunReadsEveryMemberAsTheVaultSentIt() throws {
        let r = try itemRun(run(top: #","flags":["shell","program_changed"],"previous_sha256":"\#(sha2)","previous_path":"/opt/git","replaces":"a0""#))
        #expect(r.itemID == "i1" && r.fieldID == "f1" && r.program == "/usr/bin/git" && r.sha256 == sha)
        #expect(r.argv == ["git", "push", "origin"] && r.how == .env && r.name == "GH_TOKEN")
        #expect(r.env == [.init(name: "GIT_DIR", value: "/tmp/x"), .init(name: "A", value: "b")], "in the body's order")
        #expect(r.flags == [.shell, .programChanged] && r.previousSha256 == sha2 && r.previousPath == "/opt/git" && r.replaces == "a0")
        #expect(r.cwd == nil && !r.hasCwd)
        let d = try device(runBody, top: #","replaces":"a0""#)
        #expect(d.replaces == "a0")
    }

    @Test func aRunWithStdinNeedsNoNameAndACwdIsMarked() throws {
        let r = try itemRun(run { $0.replacingOccurrences(of: #""how":"env","name":"GH_TOKEN""#, with: #""how":"stdin","cwd":"/home/me""#) })
        #expect(r.how == .stdin && r.name == nil && r.cwd == "/home/me" && r.hasCwd)
        #expect(try itemRun(run { $0.replacingOccurrences(of: #""how":"env""#, with: #""how":"file""#) }).how == .file)
    }

    /// One case per rule of AA8 "Fail closed" for a run.
    @Test func aRunIsDenyOnlyForEveryFailClosedCase() throws {
        let cases: [(String, HeldApproval)] = try [
            ("an unknown top-level member", run(top: #","later":1"#)),
            ("an unknown flag", run(top: #","flags":["new_flag"]"#)),
            ("history on a run", run(top: #","flags":["history"]"#)),
            ("a repeated flag", run(top: #","flags":["shell","shell"]"#)),
            ("flags not a list of strings", run(top: #","flags":[1]"#)),
            ("flags not a list", run(top: #","flags":"shell""#)),
            ("unbound with unrecorded", run(top: #","flags":["unbound_program","program_unrecorded"]"#)),
            ("unbound with changed", run(top: #","flags":["unbound_program","program_changed"],"previous_sha256":"\#(sha2)","previous_path":"/x""#)),
            ("unrecorded with changed", run(top: #","flags":["program_unrecorded","program_changed"],"previous_sha256":"\#(sha2)","previous_path":"/x""#)),
            ("no program", run { $0.replacingOccurrences(of: #""program":"/usr/bin/git","#, with: "") }),
            ("no sha256", run { $0.replacingOccurrences(of: #""sha256":"\#(sha)","#, with: "") }),
            ("no argv", run { $0.replacingOccurrences(of: #""argv":["git","push","origin"],"#, with: "") }),
            ("an empty argv", run { $0.replacingOccurrences(of: #"["git","push","origin"]"#, with: "[]") }),
            ("a number in argv", run { $0.replacingOccurrences(of: #"["git","push","origin"]"#, with: #"["git",1]"#) }),
            ("env not an object", run { $0.replacingOccurrences(of: #"{"GIT_DIR":"/tmp/x","A":"b"}"#, with: #"["x"]"#) }),
            ("a number in env", run { $0.replacingOccurrences(of: #""A":"b""#, with: #""A":1"#) }),
            ("cwd not a string", run { $0.replacingOccurrences(of: #""how":"env""#, with: #""cwd":1,"how":"env""#) }),
            ("an unknown how", run { $0.replacingOccurrences(of: #""how":"env""#, with: #""how":"pipe""#) }),
            ("no name for env", run { $0.replacingOccurrences(of: #","name":"GH_TOKEN""#, with: "") }),
            ("no name for file", run { $0.replacingOccurrences(of: #""how":"env","name":"GH_TOKEN""#, with: #""how":"file""#) }),
            ("an unknown body member", run { $0.replacingOccurrences(of: #""how":"env""#, with: #""how":"env","shell":true"#) }),
            ("sha256 in capitals", run { $0.replacingOccurrences(of: sha, with: sha.uppercased()) }),
            ("sha256 of 63 digits", run { $0.replacingOccurrences(of: sha, with: String(sha.dropFirst())) }),
            ("previous_sha256 not hex", run(top: #","flags":["program_changed"],"previous_sha256":"\#(sha2.uppercased())","previous_path":"/x""#)),
            ("program_changed alone", run(top: #","flags":["program_changed"]"#)),
            ("program_changed without previous_path", run(top: #","flags":["program_changed"],"previous_sha256":"\#(sha2)""#)),
            ("program_changed without previous_sha256", run(top: #","flags":["program_changed"],"previous_path":"/opt/git""#)),
            ("member_folder alone", run(top: #","flags":["member_folder"]"#)),
            ("member_files alone", run(top: #","flags":["member_files"]"#)),
            ("previous_* without program_changed", run(top: #","previous_sha256":"\#(sha2)","previous_path":"/x""#)),
            ("previous_sha256 alone", run(top: #","previous_sha256":"\#(sha2)""#)),
            ("member_folder (AA9 not built)", run(top: #","flags":["member_folder"],"folders":{"cwd":{"path":"/home","write":false}}"#)),
            ("member_files (AA9 not built)", run({ $0.replacingOccurrences(of: #""how":"env""#, with: #""inputs":[{"path":"/a"}],"how":"env""#) }, top: #","flags":["member_files"],"folders":{}"#)),
            ("folders without a flag", run(top: #","folders":{}"#)),
            ("inputs without member_files", run { $0.replacingOccurrences(of: #""how":"env""#, with: #""inputs":[],"how":"env""#) }),
            ("output without member_files", run { $0.replacingOccurrences(of: #""how":"env""#, with: #""output":{"names":["a"]},"how":"env""#) }),
            ("proxy on a run", run(top: proxyNote)),
            ("an empty replaces", run(top: #","replaces":"""#)),
            ("a replaces that is not a string", run(top: #","replaces":1"#)),
            ("an empty item_id", run { $0.replacingOccurrences(of: #""item_id":"i1""#, with: #""item_id":"""#) }),
            ("an empty field_id", run { $0.replacingOccurrences(of: #""field_id":"f1""#, with: #""field_id":"""#) }),
            ("no body object", held(#"[1]"#)),
        ]
        for (why, h) in cases { #expect(h == .unshown, Comment(rawValue: why)) }
        #expect(cases.count > 40)
    }

    @Test func aProxyIsShownOnlyFromItsNote() throws {
        let p = try itemProxy(held(proxyBody, top: proxyNote + #","replaces":"a0""#))
        #expect(p.host == "api.example.com" && p.header == "Authorization" && p.prefix == "Bearer " && p.seconds == 3_600 && p.replaces == "a0")
        #expect(try itemProxy(held(proxyBody.replacingOccurrences(of: #","seconds":3600"#, with: ""), top: proxyNote)).seconds == 900)
        #expect(try itemProxy(held(proxyBody.replacingOccurrences(of: #""seconds":3600"#, with: #""seconds":60"#), top: proxyNote)).seconds == 60)
        #expect(try itemProxy(held(proxyBody, top: proxyNote.replacingOccurrences(of: #""prefix":"Bearer ""#, with: #""prefix":"""#))).prefix == "")
        #expect(try device(proxyBody, top: proxyNote + #","replaces":"a0""#).replaces == "a0")
    }

    /// One case per rule of AA8 "Fail closed" for a proxy.
    @Test func aProxyIsDenyOnlyForEveryFailClosedCase() throws {
        func p(_ body: String = proxyBody, _ top: String = proxyNote) throws -> HeldApproval { try held(body, top: top) }
        let cases: [(String, HeldApproval)] = try [
            ("no proxy note", p(proxyBody, "")),
            ("a note member this version does not know", p(proxyBody, proxyNote.replacingOccurrences(of: "}", with: #","port":443}"#))),
            ("a note without its prefix", p(proxyBody, proxyNote.replacingOccurrences(of: #","prefix":"Bearer ""#, with: ""))),
            ("a note without its header", p(proxyBody, proxyNote.replacingOccurrences(of: #""header":"Authorization","#, with: ""))),
            ("an IP address", p(proxyBody, proxyNote.replacingOccurrences(of: "api.example.com", with: "10.0.0.1"))),
            ("a host in capitals", p(proxyBody, proxyNote.replacingOccurrences(of: "api.example.com", with: "API.example.com"))),
            ("a header that is not a token", p(proxyBody, proxyNote.replacingOccurrences(of: "Authorization", with: "Auth orization"))),
            ("a prefix with a control", p(proxyBody, proxyNote.replacingOccurrences(of: "Bearer ", with: "Bearer\\t"))),
            ("a prefix over 32", p(proxyBody, proxyNote.replacingOccurrences(of: "Bearer ", with: String(repeating: "x", count: 33)))),
            ("seconds under 60", p(proxyBody.replacingOccurrences(of: "3600", with: "59"))),
            ("seconds over 3,600", p(proxyBody.replacingOccurrences(of: "3600", with: "3601"))),
            ("seconds as a fraction", p(proxyBody.replacingOccurrences(of: "3600", with: "900.0"))),
            ("seconds with an exponent", p(proxyBody.replacingOccurrences(of: "3600", with: "9e2"))),
            ("seconds as a string", p(proxyBody.replacingOccurrences(of: "3600", with: "\"900\""))),
            ("any flag", p(proxyBody, proxyNote + #","flags":["shell"]"#)),
            ("an unknown member beside an empty flags list", p(proxyBody, proxyNote + #","flags":[],"later":1"#)),
            ("previous_* on a proxy", p(proxyBody, proxyNote + #","previous_sha256":"\#(sha2)","previous_path":"/x""#)),
            ("folders on a proxy", p(proxyBody, proxyNote + #","folders":{}"#)),
            ("an unknown body member", p(proxyBody.replacingOccurrences(of: "}", with: #","path":"/v1"}"#))),
            ("an empty replaces", p(proxyBody, proxyNote + #","replaces":"""#)),
            ("a proxy note that is not an object", p(proxyBody, #","proxy":"api.example.com""#)),
            ("a proxy member on an item.use", held(use("AAEC"), top: proxyNote)),
            ("a proxy member on a reveal", held(#"{"op":"item.get","item_id":"i1"}"#, top: proxyNote)),
        ]
        for (why, h) in cases { #expect(h == .unshown, Comment(rawValue: why)) }
        #expect(try p(proxyBody, proxyNote + #","flags":[]"#) != .unshown, "an empty flags list alone is fine")
    }

    @Test func withoutItsStrictReadingARunOrProxyIsDenyOnly() throws {
        for body in [runBody, proxyBody] {
            #expect(HeldApprovals.of(role: "agent", type: "agent.request", body: try StrictJson.parseObject(Array(body.utf8)), pending: nil) == .unshown)
        }
    }

    /// AA8: on an `item.use` or a `catalog`, a member that changes what approving means is deny only; another is ignored (§6.8).
    @Test func aUseOrACatalogWithAMemberThatChangesItsMeaningIsDenyOnly() throws {
        let u = use("AAEC")
        let cat = #"{"op":"catalog"}"#
        let meaningful = [
            #","replaces":"a0""#, proxyNote, #","flags":["history"]"#, #","flags":[]"#, #","previous_sha256":"\#(sha2)""#, #","previous_path":"/x""#, #","folders":{}"#,
        ]
        for top in meaningful {
            #expect(try held(u, top: top) == .unshown, Comment(rawValue: top))
            #expect(try held(cat, top: top) == .unshown, Comment(rawValue: top))
        }
        #expect(try held(cat, top: proxyNote + #","replaces":"a0","flags":["shell"]"#) == .unshown)
        #expect(try held(cat, top: #","later":1"#) == .catalog)
        #expect(HeldApprovals.of(role: "agent", type: "agent.request", body: try StrictJson.parseObject(Array(u.utf8)), pending: nil) == .unshown)
        #expect(HeldApprovals.of(role: "agent", type: "agent.request", body: try StrictJson.parseObject(Array(cat.utf8)), pending: nil) == .unshown)
    }

    @Test func replacesIsReadOnlyFromARunOrProxyOfAnAgent() throws {
        #expect(try device(runBody, top: #","replaces":"a0""#).replaces == "a0")
        #expect(try device(runBody, top: #","replaces":"a0","flags":["later"]"#).replaces == "a0", "a deny-only one still replaces")
        #expect(try device(#"{"op":"item.get","item_id":"i1"}"#, top: #","replaces":"a0""#).replaces == nil)
        #expect(try device(runBody, top: #","replaces":"""#).replaces == nil)
        #expect(try device(runBody, top: #","replaces":"a0""#, role: "desktop").replaces == nil)
    }
}
