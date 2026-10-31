import Foundation
import Testing
import VettIDCrypto
@testable import VettIDData
import VettIDDataTesting
@testable import VettIDVault

// Fixtures stay on one line each.
// swiftlint:disable line_length

/// TEST ONLY. The fixtures of the votes tests (VAULT-MESSAGING 0.81.3 §10.19.8).
enum VoteFixture {
    static let conn = "conn-1"
    static let pid = "01JBQZ0000000000000000000A"
    static let key = VoteKey(connectionID: conn, proposalID: pid)
}

func voteObj(_ s: String) -> JsonObject { (try? StrictJson.parseObject(s)) ?? VaultJSON.object([]) }

private let conn = VoteFixture.conn
private let pid = VoteFixture.pid
private let key = VoteFixture.key

private func obj(_ s: String) -> JsonObject { voteObj(s) }

/// TEST ONLY. The vault calls of ``VotesManager``, as vettid-vault's `features/vote` answers them.
@MainActor
final class FakeVoteOps: VoteOps, @unchecked Sendable {
    var list = obj("{}")
    var detail = obj("{}")
    var evidence = obj(#"{"evidence":{"proposal":"AAAA","member":{"ballot":{"choice_id":"yes"}}}}"#)
    var calls: [String] = []
    var acks: [[String]] = []
    var refuse: [String: String] = [:]
    var castGate: TestDeferred<Void>?
    var listGate: TestDeferred<Void>?

    private func go(_ type: String) throws {
        calls.append(type)
        if let code = refuse[type] { throw VaultOpError(type: type, code: code, detail: "", body: nil) }
    }

    private static func name(_ k: VoteKey) -> String { "\(k.connectionID)/\(k.proposalID)" }

    nonisolated func voteList(after: String?, ack: [String]) async throws -> JsonObject {
        try await MainActor.run { try go("list"); acks.append(ack) }
        let gate = await MainActor.run { listGate }
        if let gate { try await gate.value() }
        return await MainActor.run { list }
    }

    nonisolated func voteGet(_ key: VoteKey) async throws -> JsonObject {
        try await MainActor.run { try go("get:\(Self.name(key))"); return detail }
    }

    nonisolated func voteCast(_ key: VoteKey, choiceID: String) async throws -> JsonObject {
        let gate = await MainActor.run { castGate }
        if let gate { try await gate.value() }
        try await MainActor.run { try go("cast:\(Self.name(key)):\(choiceID)") }
        return obj(#"{"proposal_id":"\#(key.proposalID)","ballot":{"state":"sending"}}"#)
    }

    nonisolated func voteCheck(_ key: VoteKey) async throws { try await MainActor.run { try go("check:\(Self.name(key))") } }

    nonisolated func voteConfirm(_ key: VoteKey, mine: Bool) async throws -> JsonObject {
        try await MainActor.run { try go("confirm:\(Self.name(key)):\(mine)") }
        return obj(#"{"ballot":{"state":"\#(mine ? "recorded" : "disputed")"}}"#)
    }

    nonisolated func voteEvidence(_ key: VoteKey) async throws -> JsonObject {
        try await MainActor.run { try go("evidence:\(Self.name(key))"); return evidence }
    }

    nonisolated func voteRelease(_ key: VoteKey, pin: String) async throws { try await MainActor.run { try go("release:\(Self.name(key))") } }
}

/// A vault whose answer to `vote.cast` never comes (the device's waits ran out).
struct NoAnswerCast: VoteOps {
    let inner: FakeVoteOps

    func voteList(after: String?, ack: [String]) async throws -> JsonObject { try await inner.voteList(after: after, ack: ack) }
    func voteGet(_ key: VoteKey) async throws -> JsonObject { try await inner.voteGet(key) }
    func voteCast(_ key: VoteKey, choiceID: String) async throws -> JsonObject {
        _ = try? await inner.voteCast(key, choiceID: choiceID)
        throw VaultStateError(message: "vote.cast: no response")
    }
    func voteCheck(_ key: VoteKey) async throws { try await inner.voteCheck(key) }
    func voteConfirm(_ key: VoteKey, mine: Bool) async throws -> JsonObject { try await inner.voteConfirm(key, mine: mine) }
    func voteEvidence(_ key: VoteKey) async throws -> JsonObject { try await inner.voteEvidence(key) }
    func voteRelease(_ key: VoteKey, pin: String) async throws { try await inner.voteRelease(key, pin: pin) }
}

/// The credential's unlock window as the tests drive it.
@MainActor
final class TestWindow {
    var until: Date?
    var opened: [String] = []
    var closed = 0
    var openFail: VaultFailure?
    var closeFail: VaultFailure?
}

/// The helpers of the votes manager's tests: the fixtures, the manager over the fakes, and a failure's kind.
@MainActor
protocol VotesTestCase {
    var clock: TestClock { get }
}

extension VotesTestCase {
    func summary(id: String = pid, conn c: String = conn, state: String = "open", extra: String = "") -> String {
        #"{"proposal_id":"\#(id)","connection_id":"\#(c)","title":"Adopt the budget","state":"\#(state)","opens_at":"2026-11-01T09:00:00.000Z","closes_at":"2026-11-06T17:00:00.000Z","can_cast":true\#(extra)}"#
    }

    func listing(_ votes: String..., tail: String = "") -> JsonObject {
        obj(#"{"votes":[\#(votes.joined(separator: ","))],"dropped":[],"problems":[],"reconnect":[]\#(tail)}"#)
    }

    func event(_ type: String, _ body: String) -> VaultMessage {
        VaultMessage(inner: Inner(id: Ulid.new(), type: type, ts: clock.date, body: Array(body.utf8)))
    }

    func manager(_ ops: FakeVoteOps, window: TestWindow = TestWindow(), gated: @escaping @MainActor () -> Bool = { false }) -> VotesManager {
        let c = clock
        return VotesManager(
            ops: { ops },
            gated: gated,
            windowUntil: { window.until },
            openWindow: { password in
                window.opened.append(password)
                window.until = c.date.addingTimeInterval(300)
                if let f = window.openFail { throw f }
            },
            closeWindow: {
                window.closed += 1
                // A failed lock leaves the window open, as the vault manager keeps it.
                if let f = window.closeFail { throw f }
                window.until = nil
            },
            unlockTtl: { 300 },
            now: { c.date }
        )
    }

    func failure(_ body: () async throws -> some Any) async -> VaultFailure? {
        do {
            _ = try await body()
            return nil
        } catch {
            return error as? VaultFailure
        }
    }

    /// A window manager whose lock waits on [gate] and fails or succeeds as [fails] says.
    func gatedWindow(_ window: TestWindow, _ ops: FakeVoteOps, gate: TestDeferred<Void>, fails: Bool) -> VotesManager {
        let c = clock
        return VotesManager(
            ops: { ops }, windowUntil: { window.until },
            openWindow: { password in
                window.opened.append(password)
                window.until = c.date.addingTimeInterval(300)
            },
            closeWindow: {
                try await gate.value()
                window.closed += 1
                if fails { throw VaultFailure(.noResponse) }
                window.until = nil
            },
            unlockTtl: { 300 },
            now: { c.date }
        )
    }
}

// swiftlint:enable line_length
