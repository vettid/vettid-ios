import Foundation
import Testing
@testable import VettIDVault
import VettIDCrypto
import VettIDRelay
import VettIDTesting

// (VAULT-MESSAGING §3.6.4, 0.73.0 §3.6.5) What the device reports for the owner check's estimate of tries left.
extension VaultDeviceTests {
    /// (VAULT-MESSAGING 0.73.0 §3.6.5) A collection that ended and starts again is a relay reconnect.
    @Test func aCollectionThatStartsAgainIsAReconnect() async throws {
        let (d, _) = try await pairedDevice()
        var reconnects = d.relayReconnects().makeAsyncIterator()
        relay.refuseCollect = RelayError.signatureInvalid
        d.start()
        for _ in 0..<500 where d.collectionEnded == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        relay.refuseCollect = nil
        relay.serveMailbox = true
        #expect(d.ensureCollecting())
        #expect(await reconnects.next() == 1)
        d.stop()
    }

    /// (VAULT-MESSAGING §3.6.4, 0.73.0 §3.6.5) A request with no answer is reported with its type (it may have counted at
    /// the vault); an answer `bad_pin` is too, and any other answer is not.
    @Test func requestsThatMayHaveCountedAreReportedWithTheirType() async throws {
        let (d, v) = try await pairedDevice(cfg: config(InMemoryDeviceStateStore(), timeout: 0.2))
        var counted = d.countedEnds().makeAsyncIterator()
        await #expect(throws: VaultStateError.self) { _ = try await d.requestOnce("pin.change") }
        #expect(await counted.next() == "pin.change")
        _ = try await relay.nextDeposit() // the unanswered one
        let refused = Task { try await d.requestOnce("item.reveal", timeout: 10) }
        let req = try v.open(try await relay.nextDeposit().payload)
        let answer = Inner(
            id: Ulid.new(), type: req.type, ts: Date(), re: req.id, status: Inner.statusError, error: InnerError("bad_pin")
        )
        try await d.handle(v.msg(try #require(v.keyring.current()).seal(answer)))
        _ = try await refused.value
        #expect(await counted.next() == "item.reveal")
        let ok = Task { try await d.requestOnce("feed.list", timeout: 10) }
        let req2 = try v.open(try await relay.nextDeposit().payload)
        let answer2 = Inner(
            id: Ulid.new(), type: req2.type, ts: Date(), re: req2.id, status: Inner.statusError, error: InnerError("not_found")
        )
        try await d.handle(v.msg(try #require(v.keyring.current()).seal(answer2)))
        _ = try await ok.value
        await #expect(throws: VaultStateError.self) { _ = try await d.requestOnce("vault.status") }
        #expect(await counted.next() == "vault.status", "a not_found is not reported")
    }
}
