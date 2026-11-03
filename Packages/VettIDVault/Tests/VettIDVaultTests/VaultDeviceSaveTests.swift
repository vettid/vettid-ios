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

private final class Recorder<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []

    func add(_ v: T) { lock.withLock { items.append(v) } }
    var all: [T] { lock.withLock { items } }
}
