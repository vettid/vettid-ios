import Foundation
import Testing
import VettIDCrypto
@testable import VettIDData
import VettIDDataTesting
@testable import VettIDVault

// Event bodies and fixtures stay on one line each.
// swiftlint:disable line_length

/// ANDROID-PLAN 0.1.138 AA8: approving an agent's request: what is looked up, what is checked again at the send (the session is
/// opened first, the item's settings are read), and that only the request the member was shown is approved.
extension AgentApprovalsFlowTests {
    // MARK: - Approving: what is looked up, and what is checked again

    static let proxyBody = #"{"op":"item.proxy","item_id":"i1","field_id":"f1","host":"api.example.com","seconds":3600}"#
    static let proxyNote = #","proxy":{"host":"api.example.com","header":"Authorization","prefix":"Bearer "}"#
    var withCwd: String { runBody().replacingOccurrences(of: #""how":"env""#, with: #""cwd":"/home/me","how":"env""#) }

    @Test func aRunAndAProxyAreApprovedWithApprovalDecide() async throws {
        let m = manager()
        m.onEvent(event(held("h1", runBody())))
        m.onEvent(event(held("h2", Self.proxyBody, top: Self.proxyNote)))
        #expect(try request(m, "h1").held?.approvable == true && request(m, "h2").held?.approvable == true)
        _ = try await approve(m, "h1")
        _ = try await approve(m, "h2")
        #expect(ops.calls == ["approvalDecide:h1:true", "approvalDecide:h2:true"] && keys(m).isEmpty)
    }

    /// AA8 "Fail closed": a run with a `cwd` and no `member_folder` only when the item's settings, read for the request's own
    /// agent and item, carry `run` without `folders`.
    @Test func aRunWithACwdNeedsTheSettingsOfItsOwnAgentAndItemToAllowIt() async throws {
        var asked: [String] = []
        let allow = Allow()
        let m = manager(read: { agent, item in
            asked.append("\(agent):\(item)")
            return try Self.settings(folders: !allow.allowed, agent: agent, item: item)
        })
        m.onEvent(event(held("h1", withCwd)))
        m.onEvent(event(held("h2", runBody())))
        for _ in 0..<2 {
            do { _ = try await approve(m, "h1"); Issue.record("approved") } catch let f as VaultFailure { #expect(f.kind == .notSupported) }
        }
        #expect(ops.calls.isEmpty && asked == ["A:i1", "A:i1"], "folders: not allowed, nothing sent")
        allow.allowed = true
        _ = try await approve(m, "h1")
        _ = try await approve(m, "h2")
        #expect(ops.calls == ["approvalDecide:h1:true", "approvalDecide:h2:true"] && asked == ["A:i1", "A:i1", "A:i1"], "no cwd: not asked")
    }

    @Test func aCwdIsNotAllowedByAnotherAgentsOrAnotherItemsSettingsOrAFailedRead() async throws {
        let reads: [(String, @MainActor (String, String) async throws -> ItemWaysRead?)] = [
            ("foreign", { a, i in try Self.settings(folders: false, agent: a, item: i, foreign: true) }),
            ("another agent", { _, i in try Self.settings(folders: false, agent: "B", item: i) }),
            ("another item", { a, _ in try Self.settings(folders: false, agent: a, item: "i2") }),
            ("no settings", { _, _ in nil }),
            ("failed", { _, _ in throw VaultFailure(.network) }),
        ]
        for (name, read) in reads {
            let m = manager(read: read)
            m.onEvent(event(held("h1", withCwd)))
            do { _ = try await approve(m, "h1"); Issue.record("\(name): approved") } catch let f as VaultFailure {
                #expect(f.kind == .notSupported, Comment(rawValue: name))
            }
        }
        #expect(ops.calls.isEmpty)
        let ok = manager()
        #expect(await ok.runCwdRule(agentID: "A", itemID: "i1") == false)
        #expect(await manager(read: { a, i in try Self.settings(folders: false, agent: a, item: i) }).runCwdRule(agentID: "A", itemID: "i1") == true)
        #expect(await manager(read: { _, _ in throw VaultFailure(.network) }).runCwdRule(agentID: "A", itemID: "i1") == nil, "failed: nil, to retry")
    }

    /// The cwd rule is judged after the session is open, with the item's settings of that moment.
    @Test func theSettingsAreReadAfterTheSessionIsOpenedAndJudgedAtTheSend() async throws {
        let gate = TestDeferred<Void>()
        let allow = Allow()
        allow.allowed = true
        let m = manager(read: { a, i in try Self.settings(folders: !allow.allowed, agent: a, item: i) }, gate: gate)
        m.onEvent(event(held("h1", withCwd)))
        let shown = try request(m, "h1")
        let task = Task { try await m.approveDeviceRequest(shown, generation: m.forgetCount, stillShown: { true }) }
        await Task.yield()
        allow.allowed = false
        gate.complete(())
        await #expect(throws: VaultFailure.self) { try await task.value }
        #expect(ops.calls.isEmpty)
    }

    @Test func theProgramRecordedAfterAnApprovalIsFoundByItsPathAndFingerprint() async throws {
        let zero = String(repeating: "0", count: 64)
        func ways(_ programs: [RunProgram], foreign: Bool = false) -> ItemWaysRead {
            let w = ItemWays(agentID: "A", itemID: "i1", version: 1, ways: [.use, .run], run: RunSettings(programs: programs, each: true))
            return ItemWaysRead(agentID: "A", itemID: "i1", ways: w, rawWays: ["use", "run"], foreign: foreign)
        }
        let rec = [RunProgram(program: "git", sha256: sha, path: "/usr/bin/git")]
        let other = [RunProgram(program: "git", sha256: sha, path: "/opt/git"), RunProgram(program: "git", sha256: zero, path: "/usr/bin/git")]
        func recorded(_ read: @escaping @MainActor (String, String) async throws -> ItemWaysRead?) async -> Bool {
            await manager(read: read).programRecorded(agentID: "A", itemID: "i1", program: "/usr/bin/git", sha256: sha)
        }
        #expect(await recorded { _, _ in ways(rec) })
        #expect(await !recorded { _, _ in ways(other) }, "another path, or another fingerprint")
        #expect(await !recorded { _, _ in ways(rec, foreign: true) })
        #expect(await !recorded { _, _ in throw VaultFailure(.network) })
    }

    @Test func anItemUseOrRevealIsApprovedWithApprovalDecide() async throws {
        let m = manager()
        m.onEvent(event(held("h1", use)))
        m.onEvent(event(held("h2", #"{"op":"item.get","item_id":"i1","fields":["f1"]}"#)))
        _ = try await approve(m, "h1")
        _ = try await approve(m, "h2")
        #expect(ops.calls == ["approvalDecide:h1:true", "approvalDecide:h2:true"] && keys(m).isEmpty, "decided: they leave")
    }

    @Test func anItemOrAFieldTheListCannotNameIsNotApproved() async throws {
        let m = manager()
        for (id, body) in [
            ("h1", use.replacingOccurrences(of: #""item_id":"i1""#, with: #""item_id":"i9""#)),
            ("h2", #"{"op":"item.get","item_id":"i9"}"#),
            ("h3", use.replacingOccurrences(of: #""field_id":"f1""#, with: #""field_id":"f9""#)),
            ("h4", #"{"op":"item.get","item_id":"i1","fields":["f1","f9"]}"#),
        ] {
            m.onEvent(event(held(id, body)))
            await #expect(throws: VaultFailure.self) { try await approve(m, "\(id)") }
        }
        let empty = manager(cache: [])
        empty.onEvent(event(held("h1", use)))
        await #expect(throws: VaultFailure.self) { try await approve(empty, "h1") }
        // An item whose name is nothing once cleaned is not named either.
        let blank = manager(cache: [ItemSummary(itemID: "i1", version: 1, name: "\u{200B}", category: "x", sensitivity: .secret, fieldLabels: Self.cache[0].fieldLabels)])
        blank.onEvent(event(held("h1", use)))
        await #expect(throws: VaultFailure.self) { try await approve(blank, "h1") }
        #expect(ops.calls.isEmpty)
    }

    @Test func anApprovalThatIsDenyOnlyOrDifferingOrReplacedOrGoneIsNeverApproved() async throws {
        let m = manager()
        m.onEvent(event(held("h1", runBody())))
        m.onEvent(event(held("h1", runBody(#"["git","push"]"#))))
        m.onEvent(event(held("h2", runBody(), top: #","flags":["a_later_flag"]"#)))
        m.onEvent(event(held("h3", runBody())))
        m.onEvent(event(held("h4", runBody(), top: #","replaces":"h3""#)))
        let gone = held("h6", runBody()).replacingOccurrences(of: exp, with: Timestamps.formatMillis(now.addingTimeInterval(-1)))
        m.onEvent(event(gone))
        for (id, kind) in [("h1", FailureKind.notSupported), ("h2", .notSupported), ("h3", .notFound), ("h6", .notFound), ("h9", .notFound)] {
            do {
                _ = try await approve(m, "\(id)")
                Issue.record("\(id) was approved")
            } catch let f as VaultFailure {
                #expect(f.kind == kind, Comment(rawValue: id))
            }
        }
        #expect(ops.calls.isEmpty, "nothing sent")
    }

    @Test func aDesktopsStepUpAndAnOtherOpAreNotApproved() async throws {
        let m = manager()
        m.onEvent(event(held("h1", #"{"op":"item.put"}"#)))
        m.onEvent(event(held("h2", #"{"op":"catalog"}"#).replacingOccurrences(of: #""role":"agent""#, with: #""role":"desktop""#)))
        for id in ["h1", "h2"] {
            await #expect(throws: VaultFailure.self) { try await approve(m, "\(id)") }
        }
        #expect(ops.calls.isEmpty)
    }

    @Test func aSessionRequestIsNotApprovedHere() async throws {
        let m = manager()
        m.onEvent(VaultMessage(inner: Inner(id: Ulid.new(), type: "device.session.pending", ts: now, body: Array(#"{"request_id":"s1","device_id":"A","role":"agent","name":"Bot","seconds":900,"exp":"\#(exp)"}"#.utf8))))
        await #expect(throws: VaultFailure.self) { try await m.approveDeviceRequest(DeviceRequest(type: "device.session.pending", id: "s1", receivedAt: now), generation: m.forgetCount, stillShown: { true }) }
        #expect(ops.calls.isEmpty)
    }

    // MARK: - What is sent is what was shown, and what is listed when it is sent

    /// `decide` awaits the vault's session before it sends: an event that arrives meanwhile is judged at the send.
    @Test func anApprovalThatChangesWhileTheSessionIsOpenedIsNotSent() async throws {
        for change in ["differs", "replaced"] {
            let gate = TestDeferred<Void>(), mark = GateMark()
            let m = manager(gate: gate, atGate: mark)
            m.onEvent(event(held("h1", use)))
            let shown = try request(m, "h1")
            let task = Task { try await m.approveDeviceRequest(shown, generation: m.forgetCount, stillShown: { true }) }
            // The approval waits at the gate, past every check made before the session opens.
            for _ in 0..<100 where !mark.reached { await Task.yield() }
            #expect(mark.reached, Comment(rawValue: change))
            if change == "differs" {
                m.onEvent(event(held("h1", #"{"op":"item.use","item_id":"i1","field_id":"f1","action":"hmac-sha256","data":"AAED"}"#)))
            } else {
                m.onEvent(event(held("h2", runBody(), top: #","replaces":"h1""#)))
            }
            gate.complete(())
            do {
                _ = try await task.value
                Issue.record("\(change): sent")
            } catch let f as VaultFailure {
                // Another request in its place is one that changed; one replaced is no longer waiting.
                #expect(f.kind == (change == "differs" ? .requestChanged : .notFound), Comment(rawValue: change))
            }
            #expect(ops.calls.isEmpty, Comment(rawValue: change))
        }
        // Unchanged: sent once the session is open.
        let gate = TestDeferred<Void>()
        let m = manager(gate: gate)
        m.onEvent(event(held("h1", use)))
        let shown = try request(m, "h1")
        let task = Task { try await m.approveDeviceRequest(shown, generation: m.forgetCount, stillShown: { true }) }
        await Task.yield()
        gate.complete(())
        _ = try await task.value
        #expect(ops.calls == ["approvalDecide:h1:true"])
    }

    /// Only the request the member was shown: another `exp`, name or item is not approved; another time of arrival (the same
    /// `approval.pending` delivered again) is the same request.
    @Test func onlyTheRequestThatWasShownIsApproved() async throws {
        let m = manager()
        m.onEvent(event(held("h1", use)))
        let shown = try request(m, "h1")
        var later = shown
        later.exp = shown.exp.map { $0.addingTimeInterval(60) }
        var renamed = shown
        renamed.deviceName = "Bot2"
        var other = shown
        other.held = .itemUse(itemID: "i1", fieldID: "f2", data: [0, 1, 2])
        var came = shown
        came.receivedAt = shown.receivedAt.addingTimeInterval(5)
        for stale in [later, renamed, other] {
            do {
                _ = try await m.approveDeviceRequest(stale, generation: m.forgetCount, stillShown: { true })
                Issue.record("approved a request that was not shown")
            } catch let f as VaultFailure {
                #expect(f.kind == .requestChanged)
            }
        }
        // Nor one shown before a lock, nor one whose screen no longer shows it as it did.
        for (generation, still) in [(m.forgetCount + 1, true), (m.forgetCount, false)] {
            await #expect(throws: VaultFailure.self) { try await m.approveDeviceRequest(shown, generation: generation, stillShown: { still }) }
        }
        #expect(ops.calls.isEmpty)
        _ = try await m.approveDeviceRequest(came, generation: m.forgetCount, stillShown: { true })
        #expect(ops.calls == ["approvalDecide:h1:true"])
    }

    /// The same for a run and a proxy: what changes while the session is opened (another argument, another proxy host, a
    /// replacement) is not sent, and the cwd rule is judged then too.
    @Test func aRunOrAProxyThatChangesWhileTheSessionIsOpenedIsNotSent() async throws {
        struct Variant { var name, body, top, changed: String }
        let cases = [
            Variant(name: "run", body: runBody(), top: "", changed: runBody(#"["git","push","--force"]"#)),
            Variant(name: "proxy", body: Self.proxyBody, top: Self.proxyNote, changed: Self.proxyBody.replacingOccurrences(of: "api.example.com", with: "evil.example.com")),
        ]
        for c in cases {
            let (name, body, top, changed) = (c.name, c.body, c.top, c.changed)
            for change in ["differs", "replaced"] {
                let gate = TestDeferred<Void>(), mark = GateMark()
                let m = manager(gate: gate, atGate: mark)
                m.onEvent(event(held("h1", body, top: top)))
                let shown = try request(m, "h1")
                let task = Task { try await m.approveDeviceRequest(shown, generation: m.forgetCount, stillShown: { true }) }
                for _ in 0..<100 where !mark.reached { await Task.yield() }
                #expect(mark.reached, Comment(rawValue: "\(name) \(change)"))
                if change == "differs" {
                    let note = top.replacingOccurrences(of: "api.example.com", with: "evil.example.com")
                    m.onEvent(event(held("h1", changed, top: note)))
                } else {
                    m.onEvent(event(held("h2", runBody(), top: #","replaces":"h1""#)))
                }
                gate.complete(())
                do {
                    _ = try await task.value
                    Issue.record("\(name) \(change): sent")
                } catch let f as VaultFailure {
                    #expect(f.kind == (change == "differs" ? .requestChanged : .notFound), Comment(rawValue: "\(name) \(change)"))
                }
                #expect(ops.calls.isEmpty, Comment(rawValue: "\(name) \(change)"))
            }
        }
    }

    @Test func onlyTheRunOrProxyThatWasShownIsApproved() async throws {
        let m = manager()
        m.onEvent(event(held("h1", runBody())))
        m.onEvent(event(held("h2", Self.proxyBody, top: Self.proxyNote)))
        var run = try request(m, "h1")
        if case .itemRun(var r)? = run.held {
            r.argv = ["git", "push"]
            run.held = .itemRun(r)
        }
        var proxy = try request(m, "h2")
        if case .itemProxy(var p)? = proxy.held {
            p.prefix = "Token "
            proxy.held = .itemProxy(p)
        }
        for stale in [run, proxy] {
            await #expect(throws: VaultFailure.self) { try await m.approveDeviceRequest(stale, generation: m.forgetCount, stillShown: { true }) }
        }
        #expect(ops.calls.isEmpty)
    }

    /// The vault's answers to `approval.decide` are handed on as they came, and a `not_found` from the vault drops the approval.
    @Test func approvalDecideAnswersAreHanded() async throws {
        ops.decideResult = "referred"
        let m = manager()
        m.onEvent(event(held("h1", use)))
        let d = try await approve(m, "h1")
        #expect(d.result == "referred")
        // `not_found` from the vault: the approval leaves, the failure is thrown.
        m.onEvent(event(held("h2", use)))
        ops.errors["approvalDecide"] = FakeApprovalOps.error("not_found")
        await #expect(throws: VaultFailure.self) { try await approve(m, "h2") }
        #expect(keys(m).isEmpty)
    }
}

// swiftlint:enable line_length
