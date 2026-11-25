import Foundation
import Testing
import VettIDCrypto
@testable import VettIDData
import VettIDDataTesting
@testable import VettIDVault

// Fixtures stay on one line each.
// swiftlint:disable line_length

/// AA8: what is approved is the request the member was shown, judged again just before it is sent (VAULT-MESSAGING §6.8), and
/// what that judgement compares.
extension AgentApprovalsFlowTests {
    /// The hand-written `==` of a run, a proxy and a device request: every member that matters changes the result.
    @Test func everyMemberCountsInTheComparisons() {
        let run = ItemRun(itemID: "i1", fieldID: "f1", program: "/usr/bin/git", sha256: sha, argv: ["git", "status"], cwd: "/w", how: .env, name: "T", env: [ItemRun.EnvEntry(name: "A", value: "b")], flags: [.shell], previousSha256: nil, previousPath: nil, replaces: nil)
        let runs: [(String, (inout ItemRun) -> Void)] = [
            ("itemID", { $0.itemID = "i2" }), ("fieldID", { $0.fieldID = "f2" }), ("program", { $0.program = "/bin/git" }),
            ("sha256", { $0.sha256 = String(repeating: "0", count: 64) }), ("argv", { $0.argv = ["git"] }), ("argv order", { $0.argv = ["status", "git"] }),
            ("argv element", { $0.argv = ["git", "Status"] }), ("cwd", { $0.cwd = nil }), ("how", { $0.how = .stdin }), ("name", { $0.name = nil }),
            ("env name", { $0.env = [ItemRun.EnvEntry(name: "B", value: "b")] }), ("env value", { $0.env = [ItemRun.EnvEntry(name: "A", value: "c")] }),
            ("env count", { $0.env = [] }), ("flags", { $0.flags = [] }), ("previousSha256", { $0.previousSha256 = "x" }),
            ("previousPath", { $0.previousPath = "/x" }), ("replaces", { $0.replaces = "h0" }),
        ]
        for (what, change) in runs {
            var other = run
            change(&other)
            #expect(run != other && HeldApproval.itemRun(run) != .itemRun(other), Comment(rawValue: what))
        }
        #expect(run == run)
        let proxy = ItemProxy(itemID: "i1", fieldID: "f1", host: "api.example.com", header: "Authorization", prefix: "Bearer ", seconds: 900, replaces: nil)
        let proxies: [(String, (inout ItemProxy) -> Void)] = [
            ("itemID", { $0.itemID = "i2" }), ("fieldID", { $0.fieldID = "f2" }), ("host", { $0.host = "api.example.org" }),
            ("header", { $0.header = "X-Key" }), ("prefix", { $0.prefix = "" }), ("seconds", { $0.seconds = 901 }), ("replaces", { $0.replaces = "h0" }),
        ]
        for (what, change) in proxies {
            var other = proxy
            change(&other)
            #expect(proxy != other, Comment(rawValue: what))
        }
        #expect(proxy == proxy)
        let d = DeviceRequest(type: "approval.pending", id: "h1", deviceName: "Bot", role: "agent", requestType: "agent.request", receivedAt: now, exp: now.addingTimeInterval(60), deviceID: "A", held: .catalog, replaces: nil)
        let requests: [(String, (inout DeviceRequest) -> Void)] = [
            ("type", { $0.type = "device.session.pending" }), ("id", { $0.id = "h2" }), ("deviceName", { $0.deviceName = "Bot2" }),
            ("role", { $0.role = "desktop" }), ("requestType", { $0.requestType = "other" }), ("exp", { $0.exp = nil }),
            ("deviceID", { $0.deviceID = "B" }), ("held", { $0.held = .unshown }), ("replaces", { $0.replaces = "h0" }),
        ]
        for (what, change) in requests {
            var other = d
            change(&other)
            #expect(d != other && !d.sameContent(as: other) && !other.sameContent(as: d), Comment(rawValue: what))
        }
        // The time of arrival counts for `==` (what the screens observe), never for what the member reads.
        var came = d
        came.receivedAt = now.addingTimeInterval(1)
        #expect(d != came && d.sameContent(as: came) && came.sameContent(as: d) && d == d)
    }

    /// The vault delivers the same `approval.pending` again (a replay, a list read): only this phone's stamp of its arrival moves,
    /// and the member's tap still approves it, also while the session is opened.
    @Test func theSameApprovalDeliveredAgainIsStillApproved() async throws {
        let gate = TestDeferred<Void>(), mark = GateMark()
        let clock = TestClock(Int64(now.timeIntervalSince1970 * 1000))
        let m = manager(gate: gate, atGate: mark, clock: clock)
        m.onEvent(event(held("h1", use)))
        let shown = try request(m, "h1")
        clock.advance(2_000)
        m.onEvent(event(held("h1", use)))
        #expect(try request(m, "h1").receivedAt != shown.receivedAt && m.mismatched.isEmpty, "restamped, same content")
        let task = Task { try await m.approveDeviceRequest(shown, generation: m.forgetCount, stillShown: { true }) }
        for _ in 0..<100 where !mark.reached { await Task.yield() }
        clock.advance(2_000)
        m.onEvent(event(held("h1", use)))
        gate.complete(())
        _ = try await task.value
        #expect(ops.calls == ["approvalDecide:h1:true"])
    }

    // MARK: - What changes while the session is opened (the gate)

    /// Runs one approval of `h1` (a use) that waits at the gate while [change] happens, and returns how it ended.
    /// [body] and [top] the approval (a use by default).
    func atTheGate(
        _ body: String? = nil, top: String = "", clock: TestClock? = nil, stillShown: @escaping @MainActor () -> Bool = { true },
        _ change: (ApprovalsManager, GateMark) throws -> Void
    ) async throws -> FailureKind? {
        let gate = TestDeferred<Void>(), mark = GateMark()
        let m = manager(cwd: { _, _ in true }, gate: gate, atGate: mark, clock: clock)
        m.onEvent(event(held("h1", body ?? use, top: top)))
        let shown = try request(m, "h1")
        let generation = m.forgetCount
        let task = Task { try await m.approveDeviceRequest(shown, generation: generation, stillShown: stillShown) }
        for _ in 0..<100 where !mark.reached { await Task.yield() }
        #expect(mark.reached)
        try change(m, mark)
        gate.complete(())
        do {
            _ = try await task.value
            return nil
        } catch let f as VaultFailure {
            return f.kind
        }
    }

    @Test func aLockAtTheGateSendsNothing() async throws {
        // The lock drops the approval: no longer waiting here, and nothing of it is forgotten as a decision.
        #expect(try await atTheGate { m, _ in m.forgetOpenVault() } == .notFound)
        // Locked and opened again, the same approval read back: still not the one the screen showed before the lock.
        let kind = try await atTheGate { m, _ in
            m.forgetOpenVault()
            m.onEvent(event(held("h1", use)))
        }
        #expect(kind == .requestChanged)
        #expect(ops.calls.isEmpty)
    }

    @Test func anItemThatLeavesTheListAtTheGateIsNotApproved() async throws {
        #expect(try await atTheGate { _, mark in mark.cache = [] } == .requestChanged)
        let other = [ItemSummary(itemID: "i1", version: 2, name: "GitHub", category: "login", sensitivity: .secret, fieldLabels: [Self.cache[0].fieldLabels[1]])]
        #expect(try await atTheGate { _, mark in mark.cache = other } == .requestChanged, "its field went")
        #expect(ops.calls.isEmpty)
        // The list as it was: sent.
        #expect(try await atTheGate { _, mark in mark.cache = Self.cache } == nil)
    }

    @Test func anApprovalThatExpiresAtTheGateIsNotSent() async throws {
        let clock = TestClock(Int64(now.timeIntervalSince1970 * 1000))
        #expect(try await atTheGate(clock: clock) { _, _ in clock.advance(601_000) } == .notFound)
        #expect(ops.calls.isEmpty)
    }

    @Test func anApprovalMarkedDifferentOrReplacedAtTheGateIsNotSent() async throws {
        #expect(try await atTheGate { m, _ in m.mismatched.insert("device:approval.pending:h1") } == .requestChanged)
        #expect(try await atTheGate { m, _ in m.replaced.insert("device:approval.pending:h1") } == .notFound)
        #expect(ops.calls.isEmpty)
    }

    /// The same approval delivered again with another `exp` asks the same (it is not marked different), but it is not the
    /// request the screen showed: its waiting time changed.
    @Test func anApprovalDeliveredAgainWithAnotherExpAtTheGateIsNotSent() async throws {
        let kind = try await atTheGate { m, _ in
            m.onEvent(event(held("h1", use).replacingOccurrences(of: exp, with: Timestamps.formatMillis(now.addingTimeInterval(900)))))
            #expect(m.mismatched.isEmpty)
        }
        #expect(kind == .requestChanged && ops.calls.isEmpty)
    }

    @Test func aScreenThatNoLongerShowsTheRequestAsItDidSendsNothing() async throws {
        var still = true
        #expect(try await atTheGate(stillShown: { still }) { _, _ in still = false } == .requestChanged)
        #expect(ops.calls.isEmpty)
    }

    /// The gate judges a run and a proxy (and a run's `cwd` rule, read after the session opens) as it judges a use: a lock, the
    /// item leaving the list, a screen that no longer shows it as it did, all send nothing; unchanged, it is sent.
    @Test func aRunOrAProxyIsJudgedAtTheGateAsAUseIs() async throws {
        let cwd = runBody().replacingOccurrences(of: #""how":"env""#, with: #""cwd":"/home/me","how":"env""#)
        struct Way { var name, body, top: String }
        let ways = [Way(name: "run", body: runBody(), top: ""), Way(name: "run with a cwd", body: cwd, top: ""), Way(name: "proxy", body: Self.proxyBody, top: Self.proxyNote)]
        for way in ways {
            let (name, body, top) = (way.name, way.body, way.top)
            let c = Comment(rawValue: name)
            #expect(try await atTheGate(body, top: top) { m, _ in m.forgetOpenVault() } == .notFound, c)
            #expect(try await atTheGate(body, top: top) { m, _ in
                m.forgetOpenVault()
                m.onEvent(event(held("h1", body, top: top)))
            } == .requestChanged, c)
            #expect(try await atTheGate(body, top: top) { _, mark in mark.cache = [] } == .requestChanged, c)
            var still = true
            #expect(try await atTheGate(body, top: top, stillShown: { still }) { _, _ in still = false } == .requestChanged, c)
            #expect(ops.calls.isEmpty, c)
            #expect(try await atTheGate(body, top: top) { _, _ in } == nil, c)
            ops.calls = []
        }
    }
}

// swiftlint:enable line_length
