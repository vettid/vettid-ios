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

    /// While its first deposit is on its way, a repeat `hs.init` is left for the relay's redelivery (not acked unanswered, not
    /// marked seen), and a re-send makes no second request. The redelivery, the same msg_id, is then handled: accepted
    /// meanwhile, it is dropped.
    @Test(.timeLimit(.minutes(1)))
    func aRepeatWhileTheDepositIsInFlightIsLeftUnackedAndNoSecondRequestGoes() async throws {
        let store = InMemoryDeviceStateStore()
        let (d, v) = try await pairedDevice(store: store)
        let ini = try v.rekey(d)
        let gate = FakeHTTPServer.Gate()
        relay.holdDeposits = gate
        let first = Task { try await d.handle(v.msg(ini.envelope)) }
        await waitHeld(gate)
        let repeated = v.msg(ini.envelope)
        await #expect(throws: LeaveUnacked.self) { try await d.handle(repeated) }
        #expect(try savedState(store).seen[repeated.msgID] == nil, "not taken as handled")
        let resend = Task { await d.resendResps() }
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(gate.waiting == 1, "one request: the re-send claims nothing while the deposit is on its way")
        gate.open()
        await resend.value
        try await first.value
        relay.holdDeposits = nil
        _ = try ini.handleResp(try await relay.nextDeposit().payload, collectSender: d.relayAddr.pk, now: Date())
        #expect(await relay.noDeposit(within: 0.2), "one request")
        try await d.handle(repeated) // the relay's redelivery: handled now, and dropped (accepted)
        #expect(await relay.noDeposit(within: 0.2))
        #expect(try savedState(store).seen[repeated.msgID] != nil)
    }

    /// The in-flight deposit fails in a way that may have reached the relay: the repeat left unacked, redelivered, sends the
    /// same bytes.
    @Test(.timeLimit(.minutes(1)))
    func aRepeatLeftUnackedThenSendsTheSameBytesAfterAnUnknownOutcome() async throws {
        let (d, v) = try await pairedDevice()
        let ini = try v.rekey(d)
        let gate = FakeHTTPServer.Gate()
        relay.holdDeposits = gate
        relay.holdRefusals = true
        relay.refuseStatus = 503
        relay.refuseDeposits = RelayError.internalError
        relay.refuseOnly = 1
        relay.recordRefused = true
        let first = Task { try await d.handle(v.msg(ini.envelope)) }
        await waitHeld(gate)
        let repeated = v.msg(ini.envelope)
        await #expect(throws: LeaveUnacked.self) { try await d.handle(repeated) }
        gate.open()
        try await first.value
        let sent = try await relay.nextDeposit().payload
        relay.holdDeposits = nil
        relay.recordRefused = false
        try await d.handle(repeated)
        #expect(try await relay.nextDeposit().payload == sent)
    }

    /// The in-flight first attempt is refused for good: the repeat left unacked, redelivered, is answered afresh.
    @Test(.timeLimit(.minutes(1)))
    func aRepeatLeftUnackedIsAnsweredAfreshAfterAFirstRefusal() async throws {
        let (d, v) = try await pairedDevice()
        let ini = try v.rekey(d)
        let gate = FakeHTTPServer.Gate()
        relay.holdDeposits = gate
        relay.holdRefusals = true
        relay.refuseDeposits = RelayError.tokenInvalid
        relay.refuseOnly = 1
        let first = Task { try await d.handle(v.msg(ini.envelope)) }
        await waitHeld(gate)
        let repeated = v.msg(ini.envelope)
        await #expect(throws: LeaveUnacked.self) { try await d.handle(repeated) }
        gate.open()
        try await first.value
        relay.holdDeposits = nil
        for _ in 0..<200 where !awaitingState(d).isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        try await d.handle(repeated)
        _ = try ini.handleResp(try await relay.nextDeposit().payload, collectSender: d.relayAddr.pk, now: Date())
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

    /// Through ``VaultDevice/start()``: the start's re-send comes first, and a stop since that start claims nothing.
    @Test func aStopRightAfterTheStartClaimsNoResend() async throws {
        let (d, v) = try await pairedDevice()
        let ini = try v.rekey(d)
        relay.refuseStatus = 503
        relay.refuseDeposits = RelayError.internalError
        relay.refuseOnly = 1
        try await d.handle(v.msg(ini.envelope))
        d.mem.withLock { d.awaiting[0].attempted = false }
        relay.serveMailbox = true
        let reached = Box(false)
        d.beforeStartResend = { [d] in
            reached.value = true
            d.stop()
        }
        d.start()
        for _ in 0..<200 where !reached.value { try await Task.sleep(nanoseconds: 10_000_000) }
        d.beforeStartResend = nil
        #expect(reached.value)
        #expect(await relay.noDeposit(within: 0.3))
        #expect(awaitingState(d).first?.attempted == false)
        // Started again with no stop: the re-send goes.
        d.start()
        _ = try ini.handleResp(try await relay.nextDeposit().payload, collectSender: d.relayAddr.pk, now: Date())
        d.stop()
    }

    /// A cancelled task claims no re-send.
    @Test func aCancelledTaskClaimsNoResend() async throws {
        let (d, v) = try await pairedDevice()
        let ini = try v.rekey(d)
        relay.refuseStatus = 503
        relay.refuseDeposits = RelayError.internalError
        relay.refuseOnly = 1
        try await d.handle(v.msg(ini.envelope))
        d.mem.withLock { d.awaiting[0].attempted = false }
        let t = Task {
            while !Task.isCancelled { await Task.yield() }
            await d.resendResps()
        }
        t.cancel()
        await t.value
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
