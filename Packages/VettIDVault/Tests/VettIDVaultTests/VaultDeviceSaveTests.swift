import Foundation
import Testing
import VettIDCrypto
import VettIDRelay
@testable import VettIDVault

// How often the device state is written (VAULT-MESSAGING §8.3: persist, then ack; a counter is stored before the
// message that uses it is deposited).
extension VaultDeviceTests {
    /// A store that counts its writes, and the writes made while a deposit was being handed to the relay.
    final class CountingStore: DeviceStateStore, @unchecked Sendable {
        private let lock = NSLock()
        private var b: [UInt8]?
        private var n = 0

        var writes: Int { lock.withLock { n } }
        func load() -> [UInt8]? { lock.withLock { b } }
        func clear() { lock.withLock { b = nil } }
        func save(_ state: [UInt8]) throws { lock.withLock { b = state; n += 1 } }
        var state: DeviceState? { lock.withLock { b }.flatMap { try? JSONDecoder().decode(DeviceState.self, from: Data($0)) } }
    }

    /// A request and its answer write the state twice: the send counter before the deposit, and the answer's id before it
    /// is acked.
    @Test func aRequestAndItsAnswerWriteTheStateTwice() async throws {
        let store = CountingStore()
        let (d, v) = try await pairedDevice(store: store)
        let before = store.writes
        let status = Task { try await d.op("vault.status") }
        let req = try v.open(try await relay.nextDeposit().payload)
        #expect(store.writes == before + 1, "the counter was stored before the deposit")
        try await d.handle(try v.seal("vault.status", #"{"state":"unlocked"}"#, re: req.id, status: Inner.statusOK))
        _ = try await status.value
        #expect(store.writes == before + 2)
    }

    /// A credential request's record is stored by the write that stores its counter, before the deposit: no write of its
    /// own, and a kill after the deposit finds it.
    @Test func aCredentialRecordIsStoredWithTheSendCounter() async throws {
        let store = CountingStore()
        let (d, v) = try await pairedDevice(store: store)
        let before = store.writes
        let id = d.newRequestID()
        await d.trackCredential(id, exp: Date().addingTimeInterval(600))
        #expect(store.writes == before, "no write of its own")
        let sent = Task { try await d.request("vault.status", innerID: id) }
        let req = try v.open(try await relay.nextDeposit().payload)
        #expect(store.writes == before + 1)
        #expect(store.state?.unsettled?[id] != nil, "stored before the deposit went out")
        try await d.handle(try v.seal("vault.status", "{}", re: req.id, status: Inner.statusOK))
        _ = try await sent.value
        #expect(store.state?.unsettled?[id] == nil, "settled by the answer")
    }

    /// The answer to a token refresh is stored by the write that ends the handling of the message, before it is deposited:
    /// one write for the message, not one more for the answer's record.
    @Test func aReplyMadeWhileHandlingIsStoredByTheHandlingsWrite() async throws {
        let store = CountingStore()
        let (d, v) = try await pairedDevice(store: store)
        let before = store.writes
        let outboxAtDeposit = Recorder<Int>()
        let stateAtDeposit = store
        relay.onDeposit = { outboxAtDeposit.add(stateAtDeposit.state?.outbox.count ?? -1) }
        try await d.handle(try v.seal("relay.token.refresh", "{}"))
        _ = try await relay.nextDeposit()
        #expect(outboxAtDeposit.all == [1], "the entry was stored when it went out")
        // The message's write, and the removal of the entry once the relay took it.
        #expect(store.writes == before + 2)
        #expect(store.state?.outbox.isEmpty == true)
    }
}

extension VaultDeviceTests {
    /// A store whose writes fail once armed.
    final class FlakyStore: DeviceStateStore, @unchecked Sendable {
        private let lock = NSLock()
        private var b: [UInt8]?
        private var armed = false

        private var allowed: Int?

        func arm() { lock.withLock { armed = true } }
        func disarm() { lock.withLock { armed = false; allowed = nil } }
        /// The next [n] writes succeed, then every write fails.
        func failAfter(_ n: Int) { lock.withLock { allowed = n } }
        func load() -> [UInt8]? { lock.withLock { b } }
        func clear() { lock.withLock { b = nil } }
        var state: DeviceState? { lock.withLock { b }.flatMap { try? JSONDecoder().decode(DeviceState.self, from: Data($0)) } }
        func save(_ state: [UInt8]) throws {
            try lock.withLock {
                if let n = allowed {
                    if n == 0 { throw CocoaError(.fileWriteOutOfSpace) }
                    allowed = n - 1
                }
                if armed { throw CocoaError(.fileWriteOutOfSpace) }
                b = state
            }
        }
    }

    /// The replies made while a message is handled go out only when the save that ends the handling succeeded: a failing
    /// write deposits nothing (a token answer, and a rekey's `hs.resp` before its responder is on disk), and leaves nothing
    /// in the outbox.
    @Test func noReplyIsDepositedWhenTheSaveFailed() async throws {
        let store = FlakyStore()
        let (d, v) = try await pairedDevice(store: store)
        store.arm()
        await #expect(throws: (any Error).self) { try await d.handle(try v.seal("relay.token.refresh", "{}")) }
        #expect(await relay.noDeposit(within: 0.3), "no token answer")
        #expect(d.outboxIDs.isEmpty)
        await #expect(throws: (any Error).self) { try await d.handle(v.msg(try v.rekey(d).envelope)) }
        #expect(await relay.noDeposit(within: 0.3), "no hs.resp before the responder is stored")
    }

    /// A message whose handling failed to save is handled again when the relay delivers it again, and answered: it was not
    /// taken as seen.
    @Test func aMessageWhoseSaveFailedIsAnsweredWhenDeliveredAgain() async throws {
        let store = FlakyStore()
        let (d, v) = try await pairedDevice(store: store)
        let refresh = try v.seal("relay.token.refresh", "{}")
        store.arm()
        await #expect(throws: (any Error).self) { try await d.handle(refresh) }
        store.disarm()
        try await d.handle(refresh)
        let answer = try v.open(try await relay.nextDeposit().payload)
        #expect(answer.type == "relay.token.refresh" && answer.re != nil, "the redelivery was answered, not acked unanswered")
    }

    /// A reply queued by a handling that failed is taken out whatever wrote it, and the redelivery's is the only answer: one
    /// standing token for one refresh, not two.
    @Test func aRefreshAnsweredAfterAFailedSaveGetsOneAnswer() async throws {
        let store = FlakyStore()
        let (d, v) = try await pairedDevice(store: store)
        let refresh = try v.seal("relay.token.refresh", "{}")
        store.arm()
        await #expect(throws: (any Error).self) { try await d.handle(refresh) }
        #expect(d.outboxIDs.isEmpty, "the queued answer is gone, so the redelivery's is the only one")
        store.disarm()
        try await d.handle(refresh)
        _ = try await relay.nextDeposit()
        #expect(await relay.noDeposit(within: 0.3), "one answer, not two")
    }

    /// An event is published once, though its message is handled again after a failed save.
    @Test func anEventIsPublishedOnceAfterAFailedSave() async throws {
        let store = FlakyStore()
        let (d, v) = try await pairedDevice(store: store)
        let event = try v.seal("message.new", #"{"n":1}"#)
        store.arm()
        await #expect(throws: (any Error).self) { try await d.handle(event) }
        #expect(d.inboxCount == 1)
        store.disarm()
        try await d.handle(event)
        #expect(d.inboxCount == 1, "the redelivery did not publish it again")
    }

    /// An `hs.fin` that the handling itself wrote to disk is not taken out of memory when the final write fails: the next
    /// good write does not lose it.
    @Test func anHsFinOnDiskIsNotLostByAFailedFinalSave() async throws {
        let (d, store) = try await respondingWithAFailingFinalSave(relayTakesTheFin: false)
        #expect(d.outboxIDs.count == 1, "the fin that is on disk stays in memory")
        #expect(store.state?.outbox.count == 1)
        try d.save()
        #expect(store.state?.outbox.count == 1, "the next good write keeps it")
    }

    /// The fin that the handling stored goes out all the same, with the code (the work after the lock that belongs to it is
    /// kept): a pairing code is spent by its handshake.
    @Test func theFinStoredByTheHandlingIsDepositedAfterAFailedFinalSave() async throws {
        let (d, _) = try await respondingWithAFailingFinalSave(relayTakesTheFin: true)
        _ = try await relay.nextDeposit()
        #expect(d.outboxIDs.isEmpty, "the relay took it")
    }

    private func respondingWithAFailingFinalSave(relayTakesTheFin: Bool) async throws -> (VaultDevice, FlakyStore) {
        let store = FlakyStore()
        let d = try await VaultDevice.create(config(store), secrets: try DeviceSecrets.generate())
        let v = try FakeVault(relayURL: relay.baseURL)
        try await d.handle(try v.enrolled(d))
        try await d.awaitEnrolled(timeout: 1)
        let paired = Task { try await d.completeEnrollment(timeout: 2) }
        let (_, initMsg) = try await relay.nextDeposit()
        if !relayTakesTheFin {
            relay.refuseStatus = 503
            relay.refuseDeposits = "unavailable"
        }
        store.failAfter(1) // the fin's own write, then the final write fails
        await #expect(throws: (any Error).self) { try await d.handle(try v.respond(initMsg, d)) }
        store.disarm()
        paired.cancel()
        return (d, store)
    }
}

private final class Recorder<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []

    func add(_ v: T) { lock.withLock { items.append(v) } }
    var all: [T] { lock.withLock { items } }
}
