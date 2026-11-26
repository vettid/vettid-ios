import Foundation
import Testing
import VettIDCrypto
@testable import VettIDData
import VettIDDataTesting
@testable import VettIDVault

// Event bodies and fixtures stay on one line each.
// swiftlint:disable line_length

/// ANDROID-PLAN 0.1.145 "The desktop block and removal rows fail closed": a desktop's held `block.add` and `connection.remove`
/// read strictly from `approval.pending`; anything else is the deny-only desktop row.
@Suite struct DesktopHeldConnectionTests {
    private func held(_ type: String, _ body: String, top: String = "", role: String = "desktop", name: String = "Work desktop") throws -> HeldApproval {
        let o = try StrictJson.parseObject(Array(#"{"approval_id":"h1","device_id":"D","role":"\#(role)","name":"\#(name)","type":"\#(type)","body":\#(body),"exp":"2026-11-02T12:05:00.000Z"\#(top)}"#.utf8))
        guard case .device(let d)? = ApprovalParser.parse("approval.pending", o, at: Date()), let h = d.held else { throw CocoaError(.featureUnsupported) }
        return h
    }

    @Test func aBlockAndARemovalReadStrictly() throws {
        #expect(try held("block.add", #"{"connection_id":"c1"}"#) == .desktopConnection(DesktopConnection(remove: false, connectionID: "c1")))
        #expect(try held("block.add", #"{"connection_id":"c1","note":"spam\nagain"}"#) == .desktopConnection(DesktopConnection(remove: false, connectionID: "c1", note: "spam\nagain")))
        #expect(try held("connection.remove", #"{"connection_id":"c1"}"#) == .desktopConnection(DesktopConnection(remove: true, connectionID: "c1")))
        #expect(try held("block.add", #"{"connection_id":"c1"}"#).approvable)
        let note256 = String(repeating: "é", count: 128)
        #expect(try held("block.add", #"{"connection_id":"c1","note":"\#(note256)"}"#) == .desktopConnection(DesktopConnection(remove: false, connectionID: "c1", note: note256)), "256 bytes")
    }

    @Test func anythingElseIsTheDenyOnlyDesktopRow() throws {
        // (what, type, body, top-level members)
        let cases: [[String]] = [
            ["extra member", "block.add", #"{"connection_id":"c1","x":1}"#, ""],
            ["a removal with a note", "connection.remove", #"{"connection_id":"c1","note":"n"}"#, ""],
            ["note not a string", "block.add", #"{"connection_id":"c1","note":1}"#, ""],
            ["note over 256 bytes", "block.add", #"{"connection_id":"c1","note":"\#(String(repeating: "é", count: 128))x"}"#, ""],
            ["no connection_id", "block.add", #"{"note":"n"}"#, ""],
            ["empty connection_id", "block.add", #"{"connection_id":""}"#, ""],
            ["connection_id not a string", "connection.remove", #"{"connection_id":7}"#, ""],
            ["another step-up type", "item.delete", #"{"connection_id":"c1"}"#, ""],
            ["an agent's member", "block.add", #"{"connection_id":"c1"}"#, #","flags":["shell"]"#],
            ["replaces", "block.add", #"{"connection_id":"c1"}"#, #","replaces":"h0""#],
        ]
        for c in cases {
            #expect(try held(c[1], c[2], top: c[3]) == .desktopStepUp, Comment(rawValue: c[0]))
        }
        #expect(try held("block.add", #"{"connection_id":"c1"}"#, name: " \u{200B} ") == .desktopStepUp, "a blank name")
        #expect(try held("block.add", #"{"connection_id":"c1"}"#, role: "Desktop") == .unshown, "the role as the vault wrote it")
        #expect(try held("block.add", #"{"connection_id":"c1"}"#, role: "agent") == .unshown, "not a desktop")
    }

    @Test func aDuplicatedMemberOrALenientReadingIsDenyOnly() throws {
        // A duplicate member never reads strictly: the parser's lenient copy is deny only.
        let raw = #"{"approval_id":"h1","device_id":"D","role":"desktop","name":"Work desktop","type":"block.add","body":{"connection_id":"c1","connection_id":"c2"},"exp":"2026-11-02T12:05:00.000Z"}"#
        let lenient = try #require(try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        let deny = try #require(ApprovalParser.denyOnly(lenient))
        #expect(HeldApprovals.of(role: "desktop", type: "block.add", body: VaultJSON.obj(deny, "body"), pending: deny) == .desktopStepUp)
        #expect(HeldApprovals.of(role: "desktop", type: "block.add", body: nil, pending: nil) == .desktopStepUp)
    }

    @Test func theEnvelopeNamesTheDeviceAndItsTime() throws {
        func of(_ envelope: String) throws -> HeldApproval {
            let o = try StrictJson.parseObject(Array(#"{"approval_id":"h1","role":"desktop","name":"W","type":"block.add","body":{"connection_id":"c1"}\#(envelope)}"#.utf8))
            return HeldApprovals.of(role: "desktop", type: "block.add", body: nil, pending: o)
        }
        let exp = #","exp":"2026-11-02T12:05:00.000Z""#
        #expect(try of(#","device_id":"D""# + exp) == .desktopConnection(DesktopConnection(remove: false, connectionID: "c1")))
        for (name, env) in [("no device_id", exp), ("empty device_id", #","device_id":"""# + exp), ("blank device_id", #","device_id":" \u3000""# + exp),
                            ("no exp", #","device_id":"D""#), ("unreadable exp", #","device_id":"D","exp":"soon""#)] {
            #expect(try of(env) == .desktopStepUp, Comment(rawValue: name))
        }
    }

    @Test func theTypeMustBeTheStrictReadingsOwn() throws {
        let o = try StrictJson.parseObject(Array(#"{"approval_id":"h1","device_id":"D","role":"desktop","name":"W","type":"block.add","body":{"connection_id":"c1"},"exp":"2026-11-02T12:05:00.000Z"}"#.utf8))
        #expect(HeldApprovals.of(role: "desktop", type: "connection.remove", body: nil, pending: o) == .desktopStepUp)
        #expect(HeldApprovals.of(role: "desktop", type: "block.add", body: nil, pending: o) == .desktopConnection(DesktopConnection(remove: false, connectionID: "c1")))
    }

    @Test func itNamesNoItemAndPrintsNothingOfTheDesktops() throws {
        let h = try held("block.add", #"{"connection_id":"c1","note":"secret words"}"#)
        #expect(HeldApprovals.nameable(h, []))
        #expect(!"\(h)".contains("secret") && !String(reflecting: h).contains("c1"))
    }

    @Test func theSameRequestIsComparedAsBytes() {
        let nfc = DesktopConnection(remove: false, connectionID: "c1", note: "caf\u{E9}")
        let nfd = DesktopConnection(remove: false, connectionID: "c1", note: "cafe\u{301}")
        #expect(nfc != nfd && nfc == nfc)
        #expect(DesktopConnection(remove: true, connectionID: "c1") != DesktopConnection(remove: false, connectionID: "c1"))
    }
}

/// ANDROID-PLAN 0.1.145 and 0.1.146: the connection a desktop's block or removal names, and how it is told from a namesake.
@Suite struct DesktopTargetsTests {
    let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    let day = Date(timeIntervalSince1970: 1_790_000_000)

    func person(_ id: String, _ first: String?, _ last: String?, state: ConnectionState = .active, at: Date? = nil) -> ConnectionInfo {
        var c = ConnectionInfo(id: id, name: "", state: state)
        c.firstName = first
        c.lastName = last
        c.createdAt = at
        return c
    }

    /// A service is named as every connection on this phone is, by the names its profile's core carries (``ConnectionInfo/displayName``).
    func service(_ id: String, _ first: String, _ last: String, at: Date? = nil) -> ConnectionInfo {
        var c = person(id, first, last, at: at)
        c.isService = true
        return c
    }

    func shown(_ cs: [ConnectionInfo], id: String = "c1") -> DesktopTargets.Shown? {
        DesktopTargets.shown(DesktopConnection(remove: false, connectionID: id), cs, calendar: utc)
    }

    @Test func anActiveOrStaleConnectionWithItsNameIsNamed() {
        #expect(shown([person("c1", "Ana", "Lee")]) == DesktopTargets.Shown(name: "Ana Lee", service: false))
        #expect(shown([person("c1", "Ana", "Lee", state: .stale)]) == DesktopTargets.Shown(name: "Ana Lee", service: false))
        #expect(shown([service("c1", "Acme", "Bank")]) == DesktopTargets.Shown(name: "Acme Bank", service: true))
    }

    /// ANDROID-PLAN 0.1.145: a service without a First Last is named by its own name, and counted among namesakes.
    @Test func aServiceWithoutFirstLastIsNamedByItsOwnName() {
        var s = ConnectionInfo(id: "c1", name: " Acme\u{200B} Bank ", state: .active)
        s.isService = true
        #expect(shown([s]) == DesktopTargets.Shown(name: "Acme Bank", service: true))
        var p = ConnectionInfo(id: "c1", name: "Acme Bank", state: .active)
        p.isService = false
        #expect(shown([p]) == nil, "a person's display name never names them")
        s.createdAt = day
        #expect(shown([s, service("c2", "Acme", "Bank", at: day.addingTimeInterval(-86_400 * 5))])?.connectedOn == day, "a namesake")
    }

    @Test func anythingElseIsNotNamed() {
        #expect(shown([]) == nil, "not listed")
        #expect(shown([person("c2", "Ana", "Lee")]) == nil, "another id")
        for state in [ConnectionState.pending, .blocked, .other] {
            #expect(shown([person("c1", "Ana", "Lee", state: state)]) == nil, "\(state)")
        }
        #expect(shown([person("c1", nil, nil)]) == nil, "no name yet")
        #expect(shown([person("c1", "\u{200B}", " ")]) == nil, "a name empty once cleaned")
    }

    @Test func aNamesakeAddsTheDayEachWasConnected() {
        let other = day.addingTimeInterval(-3 * 86_400)
        let cs = [person("c1", "Ana", "Lee", at: day), person("c2", "Ana", "Lee", at: other)]
        #expect(shown(cs) == DesktopTargets.Shown(name: "Ana Lee", service: false, connectedOn: day))
        #expect(shown(cs, id: "c2") == DesktopTargets.Shown(name: "Ana Lee", service: false, connectedOn: other))
        #expect(shown([person("c1", "Ana", "Lee", at: day), person("c2", "Bo", "Lee", at: day)])?.connectedOn == nil, "unique: no date")
    }

    @Test func namesakesAreComparedAsShown() {
        let other = day.addingTimeInterval(-86_400 * 10)
        let ana = person("c1", "Ana", "Lee", at: day)
        // (what, target, namesake)
        let alike: [(String, [ConnectionInfo])] = [
            ("stale", [ana, person("c2", "Ana", "Lee", state: .stale, at: other)]),
            ("a service", [ana, service("c2", "Ana", "Lee", at: other)]),
            ("case", [ana, person("c2", "ANA", "LEE", at: other)]),
            ("composed and decomposed", [person("c1", "Ana", "L\u{E9}e", at: day), person("c2", "Ana", "Le\u{301}e", at: other)]),
            ("split differently", [person("c1", "Mary Ann", "Lee", at: day), person("c2", "Mary", "Ann Lee", at: other)]),
            ("white space", [ana, person("c2", "Ana\u{3000}\u{3000}", "Lee", at: other)]),
            ("invisible", [ana, person("c2", "A\u{200B}na", "Lee", at: other)]),
            ("sharp s", [person("c1", "Ana", "Le\u{DF}", at: day), person("c2", "Ana", "LE\u{1E9E}", at: other)]),
        ]
        for (name, pair) in alike {
            #expect(shown(pair)?.connectedOn == day, Comment(rawValue: name))
        }
        let apart: [(String, ConnectionInfo)] = [
            ("pending", person("c2", "Ana", "Lee", state: .pending, at: other)),
            ("blocked", person("c2", "Ana", "Lee", state: .blocked, at: other)),
            ("dotless i", person("c2", "Ana", "L\u{131}ee", at: other)),
        ]
        for (name, c) in apart {
            #expect(shown([person("c1", "Ana", name == "dotless i" ? "Liee" : "Lee", at: day), c])?.connectedOn == nil, Comment(rawValue: name))
        }
    }

    @Test func theKeyFoldsAsVettidAndroidsDoes() {
        #expect(DesktopTargets.key("Straße Lee") == DesktopTargets.key("STRASSE  lee"))
        #expect(DesktopTargets.key("Weiß") == DesktopTargets.key("WEISS") && DesktopTargets.key("Weiß") == "weiss")
        #expect(DesktopTargets.key("Ana\u{A0}\u{A0}Lee") == "ana lee" && DesktopTargets.key("Ana\u{3000}Lee") == "ana lee")
        #expect(DesktopTargets.key("Le\u{301}e") == DesktopTargets.key("L\u{C9}E"))
        #expect(DesktopTargets.key("L\u{131}ee") != DesktopTargets.key("Liee"), "a dotless i stays apart")
    }

    @Test func namesakesTheDayCannotTellApartAreDenyOnly() {
        #expect(shown([person("c1", "Ana", "Lee", at: day), person("c2", "Ana", "Lee", at: day.addingTimeInterval(60))]) == nil, "the same day")
        #expect(shown([person("c1", "Ana", "Lee"), person("c2", "Ana", "Lee", at: day)]) == nil, "no created_at")
        #expect(shown([person("c1", "Ana", "Lee", at: day), person("c2", "Ana", "Lee")]) == nil, "the namesake's created_at missing")
        // The same instant is another day in another time zone: the phone's own decides.
        let start = utc.startOfDay(for: day)
        let cs = [person("c1", "Ana", "Lee", at: start.addingTimeInterval(-60)), person("c2", "Ana", "Lee", at: start.addingTimeInterval(60))]
        #expect(shown(cs) != nil)
        var east = utc
        east.timeZone = TimeZone(secondsFromGMT: 3_600)!
        #expect(DesktopTargets.shown(DesktopConnection(remove: false, connectionID: "c1"), cs, calendar: east) == nil)
    }

    @Test func resolvedOnlyJudgesADesktopsBlockOrRemoval() {
        var d = DeviceRequest(type: "approval.pending", id: "h1", receivedAt: day)
        d.held = .catalog
        #expect(DesktopTargets.resolved(d, nil, []))
        d.held = .desktopConnection(DesktopConnection(remove: true, connectionID: "c1"))
        let ana = DesktopTargets.Shown(name: "Ana Lee", service: false)
        #expect(!DesktopTargets.resolved(d, ana, []) && DesktopTargets.resolved(d, ana, [person("c1", "Ana", "Lee")], calendar: utc))
        #expect(!DesktopTargets.resolved(d, nil, [person("c1", "Ana", "Lee")]), "not shown: not approved")
        #expect(!DesktopTargets.resolved(d, ana, [person("c1", "Ana", "Lee-Park")]), "renamed")
        let other = day.addingTimeInterval(-86_400 * 30)
        let sakes = [person("c1", "Ana", "Lee", at: day), person("c2", "Ana", "Lee", at: other)]
        #expect(!DesktopTargets.resolved(d, ana, sakes, calendar: utc), "a namesake since")
        let dated = DesktopTargets.Shown(name: "Ana Lee", service: false, connectedOn: day)
        #expect(DesktopTargets.resolved(d, dated, sakes, calendar: utc) && !DesktopTargets.resolved(d, dated, [sakes[0]], calendar: utc), "a namesake gone since")
    }
}

/// ANDROID-PLAN 0.1.145: approving a desktop's block or removal sends `approval.decide` only while the connection list names its
/// connection; the approvals' own checks are those of AA8.
extension AgentApprovalsFlowTests {
    func desktopHeld(_ id: String, _ type: String, _ body: String) -> String {
        #"{"approval_id":"\#(id)","device_id":"D","role":"desktop","name":"Work desktop","type":"\#(type)","body":\#(body),"exp":"\#(exp)"}"#
    }

    func named(_ m: ApprovalsManager, _ ids: String...) {
        m.connections.connections = ids.map { id in
            var c = ConnectionInfo(id: id, name: "", state: .active)
            (c.firstName, c.lastName) = ("Ana", "Lee \(id)")
            return c
        }
    }

    static let anaC1 = DesktopTargets.Shown(name: "Ana Lee c1", service: false)

    func approve(_ m: ApprovalsManager, _ id: String, target: DesktopTargets.Shown?) async throws -> DeviceDecision {
        try await m.approveDeviceRequest(try request(m, id), generation: m.forgetCount, target: target, stillShown: { true })
    }

    @Test func aDesktopsBlockOrRemovalIsApprovedWhileItsConnectionIsNamed() async throws {
        let m = manager()
        named(m, "c1")
        m.onEvent(event(desktopHeld("h1", "block.add", #"{"connection_id":"c1","note":"spam"}"#)))
        m.onEvent(event(desktopHeld("h2", "connection.remove", #"{"connection_id":"c1"}"#)))
        _ = try await approve(m, "h1", target: Self.anaC1)
        _ = try await approve(m, "h2", target: Self.anaC1)
        #expect(ops.calls == ["approvalDecide:h1:true", "approvalDecide:h2:true"])
    }

    /// The data layer compares the connection as it was shown, whatever the caller's own check says.
    @Test func aDesktopsBlockShownOtherwiseOrWithoutItsNameIsRefused() async throws {
        let m = manager()
        named(m, "c1")
        m.onEvent(event(desktopHeld("h1", "block.add", #"{"connection_id":"c1"}"#)))
        for target in [nil, DesktopTargets.Shown(name: "Ana Lee c2", service: false), DesktopTargets.Shown(name: "Ana Lee c1", service: true)] {
            do { _ = try await approve(m, "h1", target: target); Issue.record("approved") } catch let f as VaultFailure { #expect(f.kind == .requestChanged) }
        }
        #expect(ops.calls.isEmpty)
    }

    @Test func aDesktopsBlockOfAConnectionNotNamedIsRefusedWithNothingSent() async throws {
        let m = manager()
        named(m, "c2")
        m.onEvent(event(desktopHeld("h1", "block.add", #"{"connection_id":"c1"}"#)))
        do { _ = try await approve(m, "h1", target: Self.anaC1); Issue.record("approved") } catch let f as VaultFailure { #expect(f.kind == .requestChanged) }
        #expect(ops.calls.isEmpty)
    }

    @Test func aConnectionRenamedWhileTheSessionOpensIsRefusedAtTheSend() async throws {
        let gate = TestDeferred<Void>()
        let mark = GateMark()
        let m = manager(gate: gate, atGate: mark)
        named(m, "c1")
        m.onEvent(event(desktopHeld("h1", "connection.remove", #"{"connection_id":"c1"}"#)))
        let t = Task { try await approve(m, "h1", target: Self.anaC1) }
        while !mark.reached { await Task.yield() }
        // Renamed meanwhile: still listed, no longer named as shown.
        m.connections.connections[0].lastName = "Park"
        gate.complete()
        await #expect(throws: VaultFailure.self) { _ = try await t.value }
        #expect(ops.calls.isEmpty)
    }

    @Test func aListEntryThatDiffersKeepsTheDenyOnlyDesktopRow() throws {
        let m = manager()
        var d = DeviceRequest(type: "approval.pending", id: "h1", role: "desktop", receivedAt: now)
        d.held = .desktopConnection(DesktopConnection(remove: false, connectionID: "c1"))
        m.mismatched.insert(PendingApproval.device(d).key)
        guard case .device(let shown) = m.denyIfDiffering(.device(d)) else { Issue.record("not a device"); return }
        #expect(shown.held == .desktopStepUp)
    }
}
// swiftlint:enable line_length
