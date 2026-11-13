import Foundation
import Testing
@testable import VettIDVault
import VettIDCrypto
import VettIDRelay
import VettIDTesting

/// More of ``RekeyRespOnceTests``: deposits in flight, stops, the quota's backoff, the lock gate, and the refusals the relay
/// client retries first.
extension VaultDeviceTests {
    private func awaitingState(_ d: VaultDevice) -> [VaultDevice.Awaiting] { d.mem.withLock { d.awaiting } }

    private func waitHeld(_ gate: FakeHTTPServer.Gate) async {
        for _ in 0..<500 where gate.waiting == 0 { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    /// While its first deposit is on its way, a repeat `hs.init` is left for the relay's redelivery (not acked unanswered),
    /// and a re-send makes no second request.
    @Test func aRepeatWhileTheDepositIsInFlightIsLeftUnackedAndNoSecondRequestGoes() async throws {
        let (d, v) = try await pairedDevice()
        let ini = try v.rekey(d)
        let gate = FakeHTTPServer.Gate()
        relay.holdDeposits = gate
        let first = Task { try await d.handle(v.msg(ini.envelope)) }
        await waitHeld(gate)
        #expect(gate.waiting == 1)
        await #expect(throws: LeaveUnacked.self) { try await d.handle(v.msg(ini.envelope)) }
        let resend = Task { await d.resendResps() }
        await resend.value
        gate.open()
        try await first.value
        relay.holdDeposits = nil
        _ = try ini.handleResp(try await relay.nextDeposit().payload, collectSender: d.relayAddr.pk, now: Date())
        #expect(await relay.noDeposit(within: 0.2), "one request")
        // Accepted: its redelivery now is acked and dropped.
        try await d.handle(v.msg(ini.envelope))
        #expect(await relay.noDeposit(within: 0.2))
    }

    /// A stop since the start's re-send was asked for claims nothing: nothing is sent, and nothing is left attempted.
    @Test func aStopSinceTheStartClaimsNoResend() async throws {
        let (d, v) = try await pairedDevice()
        let ini = try v.rekey(d)
        relay.refuseStatus = 503
        relay.refuseDeposits = RelayError.internalError
        relay.refuseOnly = 1
        try await d.handle(v.msg(ini.envelope))
        d.mem.withLock { d.awaiting[0].attempted = false } // as if the first deposit had never been made
        let mark = d.stopMark
        d.stop()
        await d.resendResps(since: mark)
        #expect(await relay.noDeposit(within: 0.2))
        #expect(awaitingState(d).first?.attempted == false)
    }

    /// The re-send after `quota_exceeded` waits a minute, doubling to an hour.
    @Test func theRespsQuotaWaitDoublesToAnHour() async throws {
        let up = Box<TimeInterval>(1000)
        let store = InMemoryDeviceStateStore()
        let (d, v) = try await pairedDevice(store: store, cfg: config(store, uptime: { up.value }))
        let ini = try v.rekey(d)
        relay.refuseStatus = 429
        relay.refuseDeposits = RelayError.quotaExceeded
        try await d.handle(v.msg(ini.envelope))
        var waits: [TimeInterval] = []
        for _ in 0..<8 {
            let a = try #require(awaitingState(d).first)
            waits.append(a.quotaBackoff)
            up.value = a.quotaUntil
            await d.resendResps()
        }
        #expect(waits == [60, 120, 240, 480, 960, 1920, 3600, 3600])
        #expect(awaitingState(d).first?.respBytes != nil, "kept: no refusal of the hs.resp")
    }

    /// A first attempt whose retries (`rate_limited`, `timestamp_stale`: nothing applied) end in a refusal for good is still
    /// the first: the responder and its mark end, and the `hs.init` is answered afresh.
    @Test func aRefusalAfterRetriesThatAppliedNothingIsStillTheFirst() async throws {
        let (d, v) = try await pairedDevice()
        let ini = try v.rekey(d)
        relay.refuseStatus = 429
        relay.refuseDeposits = RelayError.rateLimited
        relay.refuseOnly = 1
        relay.thenRefuse = (403, RelayError.tokenInvalid)
        try await d.handle(v.msg(ini.envelope))
        for _ in 0..<200 where !awaitingState(d).isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(awaitingState(d).isEmpty)
        relay.refuseDeposits = nil
        try await d.handle(v.msg(ini.envelope))
        _ = try ini.handleResp(try await relay.nextDeposit().payload, collectSender: d.relayAddr.pk, now: Date())
    }

    /// The `hs.resp` is not held by the lock gate: a repeat, and the device's re-send, go while a lock is pending.
    @Test func aRepeatAndAResendGoWhileALockIsPending() async throws {
        let (d, v) = try await pairedDevice()
        d.setFlushGate { false }
        let ini = try v.rekey(d)
        relay.refuseStatus = 503
        relay.refuseDeposits = RelayError.internalError
        relay.refuseOnly = 1
        relay.recordRefused = true
        try await d.handle(v.msg(ini.envelope))
        let first = try await relay.nextDeposit().payload
        relay.recordRefused = false
        relay.refuseDeposits = RelayError.internalError
        relay.refuseOnly = 1
        try await d.handle(v.msg(ini.envelope))
        #expect(relay.refused == 2, "the repeat went, refused again")
        await d.resendResps()
        #expect(try await relay.nextDeposit().payload == first)
    }

    /// `quota_exceeded` on a re-send keeps the bytes and waits, as on a first attempt.
    @Test func aQuotaRefusalOfAResendKeepsTheBytes() async throws {
        let up = Box<TimeInterval>(1000)
        let store = InMemoryDeviceStateStore()
        let (d, v) = try await pairedDevice(store: store, cfg: config(store, uptime: { up.value }))
        let ini = try v.rekey(d)
        relay.refuseStatus = 503
        relay.refuseDeposits = RelayError.internalError
        relay.refuseOnly = 1
        relay.thenRefuse = (429, RelayError.quotaExceeded)
        try await d.handle(v.msg(ini.envelope))
        await d.resendResps()
        #expect(relay.refused == 2)
        #expect(awaitingState(d).first?.respBytes != nil && awaitingState(d).first?.quotaBackoff == 60)
        relay.refuseDeposits = nil
        up.value += 61
        await d.resendResps()
        _ = try ini.handleResp(try await relay.nextDeposit().payload, collectSender: d.relayAddr.pk, now: Date())
    }

    /// `replay_detected` and a lost connection may follow a copy the relay took: one request each, the bytes kept, then the
    /// device's re-send.
    @Test func aReplayOrALostConnectionKeepsTheBytesForTheResend() async throws {
        let (d, v) = try await pairedDevice()
        let ini = try v.rekey(d)
        relay.refuseStatus = 401
        relay.refuseDeposits = RelayError.replayDetected
        relay.refuseOnly = 1
        try await d.handle(v.msg(ini.envelope))
        #expect(relay.refused == 1, "one request")
        relay.failDeposits = .networkConnectionLost
        await d.resendResps()
        #expect(awaitingState(d).first?.respBytes != nil)
        relay.failDeposits = nil
        await d.resendResps()
        _ = try ini.handleResp(try await relay.nextDeposit().payload, collectSender: d.relayAddr.pk, now: Date())
    }

    /// A pairing dropped while the `hs.resp` is on its way leaves nothing to re-send.
    @Test func aDroppedPairingDuringTheDepositLeavesNothing() async throws {
        let (d, v) = try await pairedDevice()
        let ini = try v.rekey(d)
        let gate = FakeHTTPServer.Gate()
        relay.holdDeposits = gate
        let first = Task { try await d.handle(v.msg(ini.envelope)) }
        await waitHeld(gate)
        d.dropPairing()
        gate.open()
        try await first.value
        relay.holdDeposits = nil
        relay.dropDeposits()
        #expect(awaitingState(d).isEmpty)
        await d.resendResps()
        #expect(await relay.noDeposit(within: 0.2))
    }
}
