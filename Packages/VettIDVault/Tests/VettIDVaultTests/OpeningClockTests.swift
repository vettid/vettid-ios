import Foundation
import Testing
@testable import VettIDVault
import VettIDCrypto

/// The opening's moment on the vault's clock (ANDROID-PLAN 0.1.134 Notification modes 7, IOS-PLAN §6.7): told once, by
/// the first answer to a request this device first sent after ``VaultDevice/beginOpening(onMark:)``. Never by an event's
/// `ts` (at a cold start the mailbox's backlog can be days old), an answer to no request, an answer to a request sent
/// before the opening, a redelivered answer, or a vault time learnt before.
extension LostAnswerTests {
    final class Marks: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [Date] = []
        var told: [Date] { lock.withLock { all } }
        func add(_ d: Date) { lock.withLock { all.append(d) } }
    }

    func event(_ ts: Date) -> Inner {
        Inner(id: Ulid.new(), type: "feed.event", ts: ts, body: Array("{}".utf8))
    }

    func answer(_ re: String, _ ts: Date, id: String = Ulid.new()) -> Inner {
        Inner(id: id, type: "vault.status", ts: ts, re: re, status: Inner.statusOK, body: Array("{}".utf8))
    }

    /// A request sent now; returns its task and its inner id as the vault reads it.
    func send(_ h: Holder) async throws -> (Task<VaultMessage, any Error>, String) {
        let t = Task { [d = h.d] in try await d.request("vault.status") }
        return (t, try await open(h.v).id)
    }

    @Test func theFirstAnswerToAFreshRequestOfTheOpeningTellsItsMomentOnce() async throws {
        let up = Uptime()
        let h = try await holder(uptime: up)
        let (d, v) = (h.d, h.v)
        // A request sent before the opening, answered after it: not the opening's.
        let (early, earlyID) = try await send(h)
        let marks = Marks()
        d.beginOpening { marks.add($0) }
        try await deliver(v, d, event(Date().addingTimeInterval(-3 * 86_400)))
        try await deliver(v, d, answer(Ulid.new(), Date().addingTimeInterval(-86_400)))
        try await deliver(v, d, answer(earlyID, Date().addingTimeInterval(-3_600)))
        _ = try await early.value
        #expect(marks.told.isEmpty, "an event, an answer to no request, and one to a request sent before the opening")
        // A fresh request, answered 5 s after the opening, with the vault's clock two minutes ahead.
        let (fresh, freshID) = try await send(h)
        up.advance(5)
        let ts = Date().addingTimeInterval(120)
        let first = answer(freshID, ts)
        try await deliver(v, d, first)
        _ = try await fresh.value
        #expect(marks.told.count == 1)
        #expect(abs((marks.told.first ?? .distantPast).timeIntervalSince(ts) + 5) < 0.001, "the opening, 5 s before that answer")
        // The same answer redelivered, and a second fresh request's answer: told once only.
        try await deliver(v, d, first)
        let (second, secondID) = try await send(h)
        try await deliver(v, d, answer(secondID, ts.addingTimeInterval(60)))
        _ = try await second.value
        #expect(marks.told.count == 1)
    }

    /// A redelivered answer (the same inner id, seen before) never counts, even to a fresh request of the opening.
    @Test func aRedeliveredAnswerDoesNotCount() async throws {
        let h = try await holder()
        let (d, v) = (h.d, h.v)
        let marks = Marks()
        d.beginOpening { marks.add($0) }
        let (t, id) = try await send(h)
        let a = answer(id, Date())
        try await deliver(v, d, a)
        _ = try await t.value
        #expect(marks.told.count == 1)
        // A new opening: the old answer seen again is not its first answer.
        d.beginOpening { marks.add($0) }
        try await deliver(v, d, a)
        #expect(marks.told.count == 1)
    }

    /// An answer collected after its request's wait ended (no longer pending) does not count: it could pull the mark earlier
    /// than the request's timeout allows. The next fresh request's answer does.
    @Test func anAnswerWhoseRequestNoLongerWaitsDoesNotCount() async throws {
        let h = try await holder()
        let (d, v) = (h.d, h.v)
        let marks = Marks()
        d.beginOpening { marks.add($0) }
        let gaveUp = Task { [d] in
            try await d.request("vault.status", body: VaultJSON.empty, timeout: 0.05, innerID: nil, exp: nil, retries: 0)
        }
        let late = try await open(v).id
        _ = try? await gaveUp.value
        try await deliver(v, d, answer(late, Date().addingTimeInterval(-600)))
        #expect(marks.told.isEmpty, "its wait had ended")
        let (t, id) = try await send(h)
        try await deliver(v, d, answer(id, Date()))
        _ = try await t.value
        #expect(marks.told.count == 1)
    }

    /// An opening begun again on a new device keeps its original moment on the monotonic clock: the mark is that moment on
    /// the vault's clock, not the new device's start.
    @Test func anOpeningBegunAgainKeepsItsOriginalMoment() async throws {
        let up = Uptime()
        let h = try await holder(uptime: up)
        let (d, v) = (h.d, h.v)
        let marks = Marks()
        let began = up.now
        up.advance(30) // the first device was let go; this one starts 30 s later
        d.beginOpening(began: began) { marks.add($0) }
        let (t, id) = try await send(h)
        let ts = Date()
        try await deliver(v, d, answer(id, ts))
        _ = try await t.value
        #expect(abs((marks.told.first ?? .distantPast).timeIntervalSince(ts) + 30) < 0.001, "30 s before that answer")
    }
}
