import Foundation
import Testing
import VettIDCrypto
import VettIDRelay
@testable import VettIDVault

// Requests never go through the persisted outbox (VAULT-MESSAGING §8.6): what failed in transport is not delivered later.
extension VaultDeviceTests {
    /// A request whose deposit fails is reported as failed and never delivered later: not by the next flush, nor by the
    /// first flush after a restart (as vettid-android #185). A late copy of a credential operation the member has since
    /// retried would carry the superseded credential, which the vault treats as a clone (VAULT-MESSAGING §3.5.3 step 3).
    @Test func aRequestThatFailedInTransportIsNeverDeliveredLater() async throws {
        let store = InMemoryDeviceStateStore()
        let secrets = try DeviceSecrets.generate()
        let (d, _) = try await pairedDevice(store: store, secrets: secrets)
        relay.refuseStatus = 503
        relay.refuseDeposits = "unavailable"
        await #expect(throws: RelayError.self) { _ = try await d.op("vault.status") }
        await #expect(throws: RelayError.self) { _ = try await d.request("item.reveal", innerID: d.newRequestID()) }
        #expect(try savedState(store).outbox.isEmpty)
        relay.refuseDeposits = nil
        await d.flushOutbox()
        #expect(await relay.noDeposit(within: 0.3))
        let again = try #require(try VaultDevice.load(config(store), secrets: secrets))
        await again.flushOutbox()
        #expect(await relay.noDeposit(within: 0.3))
    }

    /// While a request is deposited and while it waits for its answer, the stored state holds no copy of it: a kill then
    /// sends nothing at the next start.
    @Test func aRequestInProgressIsNotStoredForAfterAKill() async throws {
        let store = InMemoryDeviceStateStore()
        let (d, v) = try await pairedDevice(store: store)
        let storedDuringDeposit = StoredCounts()
        relay.onDeposit = {
            let state = store.load().flatMap { try? JSONDecoder().decode(DeviceState.self, from: Data($0)) }
            storedDuringDeposit.add(state?.outbox.count ?? -1)
        }
        let status = Task { try await d.op("vault.status") }
        let req = try v.open(try await relay.nextDeposit().payload)
        #expect(req.type == "vault.status")
        #expect(try savedState(store).outbox.isEmpty)
        try await d.handle(try v.seal("vault.status", #"{"state":"unlocked"}"#, re: req.id, status: Inner.statusOK))
        _ = try await status.value
        #expect(storedDuringDeposit.all == [0])
        #expect(try savedState(store).outbox.isEmpty)
    }

    /// What an earlier version kept in the outbox is dropped at load, except the standing tokens; a credential request
    /// among the dropped stays unsettled until its `exp` (§11.14.9 step 1).
    @Test func requestsQueuedByAnEarlierVersionAreDroppedAtLoad() async throws {
        let store = InMemoryDeviceStateStore()
        let secrets = try DeviceSecrets.generate()
        _ = try await pairedDevice(store: store, secrets: secrets)
        let old = try savedState(store)
        func entry(_ id: String, _ type: String) -> OutboxEntry {
            OutboxEntry(id: id, type: type, relayURL: "u", mailbox: "m", token: "tok", envelope: "ZW52")
        }
        old.outbox = [entry("a", "vault.owner-check"), entry("b", "relay.token.issued"), entry("c", "message.send"),
                      entry("d", "relay.token.refresh")]
        old.unsettled = ["a": Int64(Date().addingTimeInterval(600).timeIntervalSince1970 * 1000)]
        store.save(Array(try JSONEncoder().encode(old)))
        let again = try #require(try VaultDevice.load(config(store), secrets: secrets))
        #expect(try savedState(store).outbox.map(\.id) == ["b", "d"])
        #expect(try savedState(store).unsettled?.keys.sorted() == ["a"])
        #expect(!(await again.credentialSettled()))
    }
}

/// The outbox sizes the stored state had at each deposit.
private final class StoredCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [Int] = []

    func add(_ n: Int) { lock.withLock { counts.append(n) } }
    var all: [Int] { lock.withLock { counts } }
}
