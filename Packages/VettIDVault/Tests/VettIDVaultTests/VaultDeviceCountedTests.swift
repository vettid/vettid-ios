import Foundation
import Testing
@testable import VettIDVault
import VettIDCrypto
import VettIDRelay
import VettIDTesting

// (VAULT-MESSAGING §3.6.4, 0.73.0 §3.6.5) What the device reports for the owner check's estimate of tries left.
extension VaultDeviceTests {
    /// A counted request whose deposit the relay refuses may still have counted: it is reported once; a request re-sent
    /// with no answer is reported once, not per send.
    @Test func aRefusedSendIsReportedOnceAndRetriesAreNotCountedTwice() async throws {
        let (d, _) = try await pairedDevice(cfg: config(InMemoryDeviceStateStore(), timeout: 0.1))
        var counted = d.countedEnds().makeAsyncIterator()
        relay.refuseStatus = 503
        relay.refuseDeposits = RelayError.internalError
        await #expect(throws: RelayError.self) { _ = try await d.requestOnce("pin.change") }
        #expect(await counted.next() == "pin.change")
        relay.refuseDeposits = nil
        await #expect(throws: VaultStateError.self) { _ = try await d.request("vault.delete") }
        await #expect(throws: VaultStateError.self) { _ = try await d.requestOnce("item.reveal") }
        #expect(await counted.next() == "vault.delete")
        #expect(await counted.next() == "item.reveal", "the re-sends were not reported")
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
