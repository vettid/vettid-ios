import Foundation
import Testing
@testable import VettIDVault
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
        await d.gatedFlush()
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
        let first = Task { await d.flushOutbox() }
        #expect(await asked.wait(timeout: 10) == true)
        let second = Task { await d.flushOutbox() }
        try await Task.sleep(nanoseconds: 100_000_000) // the second waits for the first to end
        d.stop()
        answer.complete(true)
        await first.value
        await second.value
        #expect(await relay.noDeposit(within: 0.2))
        #expect(outboxTypes(d) == ["device.features"])
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
