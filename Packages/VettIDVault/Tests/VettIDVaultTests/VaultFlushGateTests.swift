import Foundation
import Testing
@testable import VettIDVault
import VettIDCrypto
import VettIDRelay
import VettIDTesting

/// The lock gate of the outbox (ANDROID-PLAN "Locking", "While pending": nothing is sent to the vault but the lock and a
/// pending `call.end`): every flush asks it before each entry, whoever starts it (the collection's start, a quota backoff's
/// end, the manager); a stop that comes while it is asked wins.
extension VaultDeviceTests {
    /// A paired device with [types] kept in its outbox (their deposits failed in transport).
    func heldOutbox(_ types: [String]) async throws -> (VaultDevice, FakeVault) {
        let (d, v) = try await pairedDevice()
        relay.failDeposits = .notConnectedToInternet
        for t in types { _ = try? await d.send(t) }
        relay.failDeposits = nil
        #expect(outboxTypes(d) == types)
        return (d, v)
    }

    @Test func aShutGateHoldsTheOutbox() async throws {
        let (d, v) = try await heldOutbox(["device.features"])
        let open = Box(false)
        d.setFlushGate { open.value }
        await d.flushOutbox()
        #expect(await relay.noDeposit(within: 0.2))
        #expect(outboxTypes(d) == ["device.features"])
        open.value = true
        await d.flushOutbox()
        #expect(try v.open(try await relay.nextDeposit().payload).type == "device.features")
        #expect(outboxTypes(d).isEmpty)
    }

    /// The collection's start flushes through the gate (a return to the foreground starts it).
    @Test func startFlushesThroughTheGate() async throws {
        let (d, _) = try await heldOutbox(["device.features"])
        d.setFlushGate { false }
        d.start()
        defer { d.stop() }
        await d.gatedFlush() // a flush the device starts on its own (a quota backoff's end, a new token)
        #expect(await relay.noDeposit(within: 0.5))
        #expect(outboxTypes(d) == ["device.features"])
    }

    /// Asked before each entry: a lock that goes pending while a flush runs holds what is left.
    @Test func theGateIsAskedBeforeEachEntry() async throws {
        let (d, v) = try await heldOutbox(["device.features", "relay.token.refresh"])
        let asks = Box(0)
        d.setFlushGate {
            asks.value += 1
            return asks.value == 1
        }
        await d.flushOutbox()
        #expect(try v.open(try await relay.nextDeposit().payload).type == "device.features")
        #expect(await relay.noDeposit(within: 0.2))
        #expect(outboxTypes(d) == ["relay.token.refresh"])
    }

    /// A stop that comes while the gate is asked wins: the flush deposits nothing, even when the gate then admits.
    @Test func aStopWhileTheGateIsAskedWins() async throws {
        let (d, _) = try await heldOutbox(["device.features"])
        let asked = OneShot<Bool>()
        let answer = OneShot<Bool>()
        d.setFlushGate {
            asked.complete(true)
            return await answer.wait(timeout: 10) ?? false
        }
        let flush = Task { await d.flushOutbox() }
        #expect(await asked.wait(timeout: 10) == true)
        d.stop()
        answer.complete(true)
        await flush.value
        #expect(await relay.noDeposit(within: 0.2))
        #expect(outboxTypes(d) == ["device.features"])
    }

    /// A flush asked for while another runs waits for it, and a stop meanwhile wins for it too: it deposits nothing once it
    /// holds the flush slot.
    @Test func aFlushQueuedBehindAnotherHonoursAStop() async throws {
        let (d, _) = try await heldOutbox(["device.features"])
        let asked = OneShot<Bool>()
        let answer = OneShot<Bool>()
        d.setFlushGate {
            asked.complete(true)
            return await answer.wait(timeout: 10) ?? false
        }
        let waiting = OneShot<Bool>()
        d.flushWaits = { waiting.complete(true) }
        let first = Task { await d.flushOutbox() }
        #expect(await asked.wait(timeout: 10) == true)
        let second = Task { await d.flushOutbox() }
        #expect(await waiting.wait(timeout: 10) == true) // the second waits for the first to end
        d.stop()
        answer.complete(true)
        await first.value
        await second.value
        #expect(await relay.noDeposit(within: 0.2))
        #expect(outboxTypes(d) == ["device.features"])
    }

    /// The vault's `relay.token.refresh` while a lock is pending: its answer waits in the outbox (not in flight), and goes
    /// at the next flush the gate admits.
    @Test func theAnswerToARefreshWaitsForTheGate() async throws {
        let (d, v) = try await pairedDevice()
        relay.dropDeposits()
        let open = Box(false)
        d.setFlushGate { open.value }
        try await d.handle(try v.seal("relay.token.refresh", "{}"))
        #expect(await relay.noDeposit(within: 0.2))
        #expect(outboxTypes(d) == ["relay.token.refresh"] && d.mem.withLock { d.outboxInFlight.isEmpty })
        open.value = true
        await d.flushOutbox()
        let answer = try v.open(try await relay.nextDeposit().payload)
        #expect(answer.type == "relay.token.refresh" && answer.re != nil)
    }

    /// A reply held while the lock ends: a flush that ran meanwhile left it alone (still marked in flight), so it asks the
    /// gate once more after its mark is cleared, and goes without waiting for another flush.
    @Test func aHeldReplyAsksAgainWhenTheLockEndsMeanwhile() async throws {
        let (d, v) = try await pairedDevice()
        relay.dropDeposits()
        let asks = Box(0)
        d.setFlushGate {
            asks.value += 1
            guard asks.value == 1 else { return true }
            await d.flushOutbox() // the lock ended: a flush runs, and leaves the reply alone
            return false
        }
        try await d.handle(try v.seal("relay.token.refresh", "{}"))
        let answer = try v.open(try await relay.nextDeposit().payload)
        #expect(answer.type == "relay.token.refresh" && answer.re != nil)
        #expect(outboxTypes(d).isEmpty)
    }

    /// While the mailbox waits for its quota, a new entry's earlier ones are tried first: a fin past its time among them is
    /// dropped before the gate is asked, as a flush drops it.
    @Test func aSendDropsAnExpiredFinBeforeAskingTheGate() async throws {
        let (d, _, up) = try await quotaDevice()
        let fin = try await d.lock.withLock {
            try d.enqueueLocked(id: nil, type: VaultDevice.typeHsFin, body: VaultJSON.empty, re: nil, status: nil, exp: nil)
        }
        d.mem.withLock {
            d.outboxInFlight.remove(fin.id)
            if let i = d.st.outbox.firstIndex(where: { $0.id == fin.id }) { d.st.outbox[i].dropAfterMs = 1 }
        }
        relay.refuseDeposits = RelayError.quotaExceeded
        relay.refuseOnly = 1
        await #expect(throws: RelayError.self) { try await d.send("device.features") }
        up.value += 61
        d.setFlushGate { false }
        await #expect(throws: QuotaWait.self) { try await d.send("call.end") }
        #expect(outboxTypes(d) == ["device.features", "call.end"])
    }

    /// The renewals a handling queues (a standing token near its end, §7.2) wait for the gate too.
    @Test func aRenewalQueuedByAHandlingWaitsForTheGate() async throws {
        let (d, v) = try await pairedDevice()
        relay.dropDeposits()
        let open = Box(false)
        d.setFlushGate { open.value }
        d.mem.withLock { d.st.issuedExpMs = VaultDevice.ms(Date()) + 1_000 }
        try await d.handle(try v.seal("vault.notice", "{}"))
        #expect(await relay.noDeposit(within: 0.2))
        #expect(outboxTypes(d) == ["relay.token.issued"] && d.mem.withLock { d.outboxInFlight.isEmpty })
        open.value = true
        await d.flushOutbox()
        #expect(try v.open(try await relay.nextDeposit().payload).type == "relay.token.issued")
    }

    /// The vault's rekey while a lock is pending is answered all the same: the vault answers a rekey's `hs.init` once, and one
    /// left unanswered would hold every later rekey for its lifetime. The vault's `hs.fin` is processed (the epoch is active);
    /// its confirmation waits for the gate.
    @Test func aRekeyIsAnsweredWhileTheGateIsShut() async throws {
        let (d, v) = try await pairedDevice()
        relay.dropDeposits()
        d.setFlushGate { false }
        let ini = try v.rekey(d)
        try await d.handle(v.msg(ini.envelope))
        let res = try ini.handleResp(try await relay.nextDeposit().payload, collectSender: d.relayAddr.pk, now: Date())
        try await d.handle(v.msg(res.fin))
        // The vault's hs.fin is processed: the new epoch is the device's, and nothing else is deposited.
        #expect(d.mem.withLock { d.keyring.current()?.ctx } == res.epoch.ctx)
        #expect(await relay.noDeposit(within: 0.2))
        #expect(outboxTypes(d) == ["hs.confirm", "device.features"])
    }

    /// A rekey answered before the lock: its `hs.confirm` and `device.features`, queued when the vault's `hs.fin` arrives
    /// with a lock pending, wait in the outbox for the gate.
    @Test func aRekeysConfirmAndFeaturesWaitForTheGate() async throws {
        let (d, v) = try await pairedDevice()
        relay.dropDeposits()
        let open = Box(true)
        d.setFlushGate { open.value }
        let ini = try v.rekey(d)
        try await d.handle(v.msg(ini.envelope))
        let res = try ini.handleResp(try await relay.nextDeposit().payload, collectSender: d.relayAddr.pk, now: Date())
        open.value = false
        try await d.handle(v.msg(res.fin))
        #expect(await relay.noDeposit(within: 0.2))
        #expect(outboxTypes(d) == ["hs.confirm", "device.features"] && d.mem.withLock { d.outboxInFlight.isEmpty })
        open.value = true
        await d.flushOutbox()
        let first = try res.epoch.open(try Envelope.parse(try await relay.nextDeposit().payload))
        let second = try res.epoch.open(try Envelope.parse(try await relay.nextDeposit().payload))
        #expect([first.type, second.type] == ["hs.confirm", "device.features"])
    }

    /// A pending `call.end` still goes while the gate is shut; what is held stays.
    @Test func aCallEndPassesAShutGate() async throws {
        let (d, v) = try await heldOutbox(["device.features", "call.end"])
        d.setFlushGate { false }
        await d.flushOutbox()
        #expect(try v.open(try await relay.nextDeposit().payload).type == "call.end")
        #expect(await relay.noDeposit(within: 0.2))
        #expect(outboxTypes(d) == ["device.features"])
    }

    /// While the mailbox waits for its quota, a new entry first tries the earlier ones: they ask the gate too, and one held
    /// back holds the new entry behind it.
    @Test func theEarlierEntriesOfASendAskTheGate() async throws {
        let (d, _, up) = try await quotaDevice()
        relay.refuseDeposits = RelayError.quotaExceeded
        relay.refuseOnly = 1
        await #expect(throws: RelayError.self) { try await d.send("device.features") }
        up.value += 61
        d.setFlushGate { false }
        await #expect(throws: QuotaWait.self) { try await d.send("call.end") }
        #expect(await relay.noDeposit(within: 0.2))
        #expect(outboxTypes(d) == ["device.features", "call.end"])
    }
}
