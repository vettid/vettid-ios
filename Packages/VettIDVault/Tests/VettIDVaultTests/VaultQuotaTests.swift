import Foundation
import Testing
@testable import VettIDVault
import VettIDCrypto
import VettIDRelay
import VettIDTesting

/// `quota_exceeded` for a device (VAULT-MESSAGING 0.88.8 §8.6, "A device"; RELAY-PROTOCOL §7.1 "MUST NOT retry the request
/// unchanged"): the mailbox's quota (or none named) backs off from a minute, doubling to an hour, until a deposit is taken;
/// the token's holds every entry under it, the refresh too, until the device holds another standing token, and marks the
/// token spent (persisted); while the mailbox waits, entries go in order, the refresh excepted. Mirrors the quota cases of
/// vettid-android `VaultDeviceTest` (#345).
extension VaultDeviceTests {
    func quotaDevice(
        _ store: InMemoryDeviceStateStore = InMemoryDeviceStateStore()
    ) async throws -> (VaultDevice, FakeVault, Box<TimeInterval>) { // swiftlint:disable:this large_tuple
        let up = Box(1_000.0)
        let (d, v) = try await pairedDevice(cfg: config(store, uptime: { up.value }))
        relay.refuseStatus = 429
        return (d, v, up)
    }

    func outboxTypes(_ d: VaultDevice) -> [String] { d.mem.withLock { d.st.outbox.map(\.type) } }

    @Test func theMailboxsQuotaBacksOffFromAMinuteDoubling() async throws {
        let (d, v, up) = try await quotaDevice()
        relay.refuseDeposits = RelayError.quotaExceeded // no `quota`: the mailbox's, for a device
        await #expect(throws: RelayError.self) { try await d.send("device.features") }
        #expect(relay.refused == 1)
        // Within the minute: nothing is deposited, not even refused.
        up.value += 59
        await d.flushOutbox()
        #expect(relay.refused == 1)
        // After it: tried once more, refused again; the next wait is two minutes.
        up.value += 2
        await d.flushOutbox()
        #expect(relay.refused == 2)
        up.value += 119
        await d.flushOutbox()
        #expect(relay.refused == 2)
        up.value += 2
        relay.refuseDeposits = nil
        await d.flushOutbox()
        #expect(try v.open(try await relay.nextDeposit().payload).type == "device.features")
        #expect(outboxTypes(d).isEmpty)
        #expect(d.mem.withLock { d.st.outbox.isEmpty && d.quotaBackoff.isEmpty })
    }

    @Test func theBackoffStopsAtAnHour() async throws {
        let (d, _, up) = try await quotaDevice()
        relay.refuseDeposits = RelayError.quotaExceeded
        relay.refuseQuota = RelayError.quotaMailbox
        await #expect(throws: RelayError.self) { try await d.send("device.features") }
        for _ in 0..<8 {
            up.value += 3_601
            await d.flushOutbox()
        }
        #expect(d.mem.withLock { d.quotaBackoff.values.first?.last } == VaultDevice.quotaBackoffMax)
    }

    /// Any deposit the relay takes to that mailbox ends the backoff.
    @Test func anAcceptedDepositEndsTheBackoff() async throws {
        let (d, v, _) = try await quotaDevice()
        relay.refuseDeposits = RelayError.quotaExceeded
        relay.refuseOnly = 1
        await #expect(throws: RelayError.self) { try await d.send("device.features") }
        _ = try await d.sendOnce("vault.lock")
        #expect(try v.open(try await relay.nextDeposit().payload).type == "vault.lock")
        await d.flushOutbox()
        #expect(try v.open(try await relay.nextDeposit().payload).type == "device.features")
    }

    /// While the mailbox waits, a new entry goes only after every earlier one has gone: it never overtakes them.
    @Test func entriesGoInOrderWhileTheMailboxWaits() async throws {
        let (d, v, up) = try await quotaDevice()
        relay.refuseDeposits = RelayError.quotaExceeded
        relay.refuseOnly = 1
        await #expect(throws: RelayError.self) { try await d.send("device.features") }
        // The backoff runs: the new entry waits behind the earlier one, nothing is deposited.
        await #expect(throws: QuotaWait.self) { try await d.send("call.end") }
        #expect(await relay.noDeposit(within: 0.2))
        up.value += 61
        await d.flushOutbox()
        #expect(try v.open(try await relay.nextDeposit().payload).type == "device.features")
        #expect(try v.open(try await relay.nextDeposit().payload).type == "call.end")
    }

    /// Past the backoff but before a deposit ended it: an earlier entry that fails again in passing still holds a new one.
    @Test func aNewEntryWaitsBehindAnEarlierOneThatFailsAgain() async throws {
        let (d, v, up) = try await quotaDevice()
        relay.refuseDeposits = RelayError.quotaExceeded
        relay.refuseOnly = 1
        await #expect(throws: RelayError.self) { try await d.send("device.features") }
        up.value += 61
        relay.refuseDeposits = "unavailable"
        relay.refuseStatus = 503
        relay.refuseOnly = RelayClient.defaultAttempts
        await #expect(throws: QuotaWait.self) { try await d.send("call.end") }
        #expect(await relay.noDeposit(within: 0.2))
        await d.flushOutbox()
        #expect(try v.open(try await relay.nextDeposit().payload).type == "device.features")
        #expect(try v.open(try await relay.nextDeposit().payload).type == "call.end")
    }

    /// The refresh is not held behind earlier entries (it asks for the token they may need); the backoff holds it as any other.
    @Test func theRefreshPassesTheEarlierEntries() async throws {
        let (d, v, up) = try await quotaDevice()
        relay.refuseDeposits = RelayError.quotaExceeded
        relay.refuseOnly = 1
        await #expect(throws: RelayError.self) { try await d.send("device.features") }
        await #expect(throws: QuotaWait.self) { try await d.send("relay.token.refresh") }
        up.value += 61
        // The earlier entry fails in passing (retryable, kept): the mailbox still waits, the refresh goes all the same.
        relay.refuseDeposits = "unavailable"
        relay.refuseStatus = 503
        relay.refuseOnly = RelayClient.defaultAttempts // every attempt of the relay client's own retries
        await d.flushOutbox()
        #expect(try v.open(try await relay.nextDeposit().payload).type == "relay.token.refresh")
        #expect(outboxTypes(d) == ["device.features"])
    }

    /// The token's quota: that entry and every other one under the token, the refresh too, wait for another standing
    /// token, are never sent under the spent one, and go once under the new one. The spent token is kept (persisted).
    @Test func theTokensQuotaHoldsEveryEntryUnderItUntilAnotherToken() async throws {
        let store = InMemoryDeviceStateStore()
        let (d, v, up) = try await quotaDevice(store)
        let spent = try #require(d.mem.withLock { d.st.vault?.token })
        relay.refuseDeposits = RelayError.quotaExceeded
        relay.refuseQuota = RelayError.quotaToken
        relay.refuseOnly = 1
        await #expect(throws: RelayError.self) { try await d.send("device.features") }
        #expect(try savedState(store).outbox.first?.quotaToken == spent)
        await #expect(throws: QuotaWait.self) { try await d.send("relay.token.refresh") }
        up.value += 7_200
        await d.flushOutbox()
        #expect(relay.refused == 1)
        #expect(await relay.noDeposit(within: 0.2))
        // Another standing token for the vault (an unlock result, `relay.token.issued`): both go once, under it.
        d.mem.withLock { d.st.vault?.token = "fresh-token" }
        await d.flushOutbox()
        var types: Set<String> = []
        for _ in 0..<2 { types.insert(try v.open(try await relay.nextDeposit().payload).type) }
        #expect(types == ["device.features", "relay.token.refresh"])
        #expect(Array(relay.depositTokens.suffix(2)) == ["fresh-token", "fresh-token"])
        #expect(!relay.depositTokens.dropFirst(relay.depositTokens.count - 2).contains(spent))
        #expect(outboxTypes(d).isEmpty)
    }

    /// The spent token outlives the entry it refused: a later entry under it waits too, and so does one held across a restart.
    @Test func theSpentTokenIsKeptOnItsOwnAndAcrossARestart() async throws {
        let store = InMemoryDeviceStateStore()
        let secrets = try DeviceSecrets.generate()
        let up = Box(1_000.0)
        let (d, v) = try await pairedDevice(secrets: secrets, cfg: config(store, uptime: { up.value }))
        relay.refuseStatus = 429
        let spent = try #require(d.mem.withLock { d.st.vault?.token })
        relay.refuseDeposits = RelayError.quotaExceeded
        relay.refuseQuota = RelayError.quotaToken
        relay.refuseOnly = 1
        await #expect(throws: RelayError.self) { try await d.send("device.features") }
        #expect(try await d.dropFromOutbox("device.features") == 1)
        #expect(try savedState(store).quotaSpentTokens == [spent])
        // A new entry under the same token: held, though the entry that was refused is gone.
        await #expect(throws: QuotaWait.self) { try await d.send("call.end") }
        #expect(await relay.noDeposit(within: 0.2))
        // After a restart: still held, and so is an entry queued after it under the spent token (the kept list alone).
        let again = try #require(try VaultDevice.load(config(store, uptime: { up.value }), secrets: secrets))
        await again.flushOutbox()
        #expect(await relay.noDeposit(within: 0.2))
        _ = try await again.dropFromOutbox("call.end")
        await #expect(throws: QuotaWait.self) { try await again.send("call.end") }
        #expect(await relay.noDeposit(within: 0.2))
        again.mem.withLock { again.st.vault?.token = "fresh-token" }
        await again.flushOutbox()
        #expect(try v.open(try await relay.nextDeposit().payload).type == "call.end")
        #expect(relay.depositTokens.last == "fresh-token")
    }

    /// An entry is re-addressed only to a held token not known to be spent.
    @Test func noEntryIsReAddressedToASpentToken() async throws {
        let (d, _, _) = try await quotaDevice()
        let spent = try #require(d.mem.withLock { d.st.vault?.token })
        relay.refuseDeposits = RelayError.quotaExceeded
        relay.refuseQuota = RelayError.quotaToken
        relay.refuseOnly = 1
        await #expect(throws: RelayError.self) { try await d.send("device.features") }
        // The vault's token is still the spent one: nothing to re-address to.
        await d.flushOutbox()
        #expect(await relay.noDeposit(within: 0.2))
        #expect(d.mem.withLock { d.st.outbox.first?.token } == spent)
    }

    /// The iPhone keeps a handshake's `hs.fin` in the outbox (vettid-android sends it outside): it follows the same rules,
    /// the backoff, the order behind an earlier entry, and the token's hold.
    @Test func anOutboxFinFollowsTheQuotaRules() async throws {
        let (d, v, up) = try await quotaDevice()
        // The backoff, and the order: the fin waits behind the earlier entry.
        relay.refuseDeposits = RelayError.quotaExceeded
        relay.refuseOnly = 1
        await #expect(throws: RelayError.self) { try await d.send("device.features") }
        await #expect(throws: QuotaWait.self) { try await d.send(VaultDevice.typeHsFin) }
        up.value += 30
        await d.flushOutbox()
        #expect(await relay.noDeposit(within: 0.2))
        up.value += 31
        await d.flushOutbox()
        #expect(try v.open(try await relay.nextDeposit().payload).type == "device.features")
        #expect(try v.open(try await relay.nextDeposit().payload).type == VaultDevice.typeHsFin)
        // The token's hold.
        relay.refuseDeposits = RelayError.quotaExceeded
        relay.refuseQuota = RelayError.quotaToken
        relay.refuseOnly = 1
        await #expect(throws: RelayError.self) { try await d.send(VaultDevice.typeHsFin) }
        up.value += 7_200
        await d.flushOutbox()
        #expect(await relay.noDeposit(within: 0.2))
        d.mem.withLock { d.st.vault?.token = "fresh-token" }
        await d.flushOutbox()
        #expect(try v.open(try await relay.nextDeposit().payload).type == VaultDevice.typeHsFin)
    }

    /// An earlier fin past its time, behind which a new entry waits, is dropped, not sent (as a flush drops it).
    @Test func aStaleFinBehindAWaitingMailboxIsDropped() async throws {
        let (d, v, up) = try await quotaDevice()
        relay.refuseDeposits = RelayError.quotaExceeded
        relay.refuseOnly = 1
        await #expect(throws: RelayError.self) { try await d.send(VaultDevice.typeHsFin) }
        d.mem.withLock { d.st.outbox[0].dropAfterMs = VaultDevice.ms(Date()) - 1 }
        up.value += 61
        let before = relay.depositTokens.count
        try await d.send("device.features")
        #expect(try v.open(try await relay.nextDeposit().payload).type == "device.features")
        #expect(outboxTypes(d).isEmpty)
        #expect(relay.depositTokens.count == before + 1, "the fin was not sent")
    }
}
