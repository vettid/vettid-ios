import Foundation
import Testing
@testable import VettIDVault
import VettIDAltChan
import VettIDAltChanTesting
import VettIDCrypto
import VettIDRelay
import VettIDTesting
// swiftlint:disable line_length

/// The handshake's `hs.fin`: kept in the outbox, counted before it is sent, told to the waiting flow only when it was refused
/// for good at its first attempt, and removed by the `device.paired` of the epoch it was sealed under.
extension InitDepositTests {
    /// The relay refuses the `hs.fin` for good: the flow that waits for the code is told the pairing cannot finish, and no
    /// code is shown.
    @Test func aFinRefusedForGoodReachesTheWaitingFlow() async throws {
        let (d, v) = try await newPhone()
        let (qr, inviteID) = try codeFor(v, d)
        try await d.startTransfer(link: try qr.link(), attester: TestIOSAttester()) { _, _ in nil }
        let (_, initMsg) = try await base.relay.nextDeposit()
        base.relay.refuseStatus = 403
        base.relay.refuseDeposits = RelayError.tokenRevoked
        let waiting = Task { try await d.awaitPairingSas() }
        try await d.handle(try v.respondOpening(initMsg, d, ctx: inviteID).message)
        await #expect(throws: PairingNotCompleted.self) { _ = try await waiting.value }
        #expect(d.pairingSas == nil)
        #expect(d.mem.withLock { d.st.outbox.isEmpty })
    }

    /// A fin the relay could not take in time is dropped by age (the token's exp, at most a handshake's lifetime), not by the
    /// number of flushes, and the flow is not told.
    @Test func aFinPastItsTimeIsDroppedWithoutFailingTheFlow() async throws {
        let offset = Box<TimeInterval>(0)
        let (d, v) = try await newPhone(now: { Date().addingTimeInterval(offset.value) })
        let (qr, inviteID) = try codeFor(v, d)
        try await d.startTransfer(link: try qr.link(), attester: TestIOSAttester()) { _, _ in nil }
        let (_, initMsg) = try await base.relay.nextDeposit()
        base.relay.refuseStatus = 503
        base.relay.refuseDeposits = "unavailable"
        try await d.handle(try v.respondOpening(initMsg, d, ctx: inviteID).message)
        #expect(d.mem.withLock { d.st.outbox.map(\.type) } == ["hs.fin"], "kept: the refusal was a passing one")
        #expect(d.mem.withLock { d.st.outbox.first?.dropAfterMs } != nil)
        await d.flushOutbox()
        #expect(d.mem.withLock { d.st.outbox.count } == 1, "still owed while its time has not come")
        offset.value = 17 * 86_400 // past a handshake's lifetime
        await d.flushOutbox()
        #expect(d.mem.withLock { d.st.outbox.isEmpty }, "dropped by age")
        // No failure: the fin may have reached the vault, and its `device.paired` may wait for the deadline's collect.
        #expect(!d.mem.withLock { d.finFailed })
        #expect(try await d.awaitPairingSas() == d.pairingSas)
    }

    /// A fin is not left marked in flight once its deposit ended, passing refusal or not.
    @Test func aFinLeavesNoInFlightMarkBehind() async throws {
        let (d, v) = try await newPhone()
        let (qr, inviteID) = try codeFor(v, d)
        try await d.startTransfer(link: try qr.link(), attester: TestIOSAttester()) { _, _ in nil }
        let (_, initMsg) = try await base.relay.nextDeposit()
        base.relay.refuseStatus = 503
        base.relay.refuseDeposits = "unavailable"
        base.relay.refuseOnly = 3
        try await d.handle(try v.respondOpening(initMsg, d, ctx: inviteID).message)
        #expect(d.mem.withLock { d.outboxInFlight.isEmpty && d.st.outbox.count == 1 })
        await d.flushOutbox() // it can still go out
        #expect(d.mem.withLock { d.st.outbox.isEmpty })
    }

    /// The relay takes the fin's deposit but saving what follows fails: the fin was deposited, so the pairing is not failed.
    @Test func aFailedSaveAfterAGoodFinDepositIsNotAFailedFin() async throws {
        let store = FlakyStore()
        let secrets = DeviceSecrets(identity: Ed25519PrivateKey.generate(), kem: try KemPrivateKey.generate(), relay: Ed25519PrivateKey.generate(), apiKey: [UInt8](repeating: 0x30, count: 91))
        let d = try await VaultDevice.create(base.config(store), secrets: secrets)
        let v = try FakeVault(relayURL: base.relay.baseURL)
        let (qr, inviteID) = try codeFor(v, d)
        try await d.startTransfer(link: try qr.link(), attester: TestIOSAttester()) { _, _ in nil }
        let (_, initMsg) = try await base.relay.nextDeposit()
        base.relay.onDeposit = { store.fail() } // from the fin's deposit on, the store refuses writes
        try await d.handle(try v.respondOpening(initMsg, d, ctx: inviteID).message)
        let sas = try await d.awaitPairingSas()
        #expect(!sas.isEmpty)
        #expect(!d.mem.withLock { d.finFailed })
    }

    /// A fin never sent before (a kill between its save and its deposit) and refused for good by a flush tells the flow that
    /// waits.
    @Test func aFirstAttemptRefusedForGoodByAFlushReachesTheWaitingFlow() async throws {
        let (d, v) = try await newPhone()
        let (qr, inviteID) = try codeFor(v, d)
        try await d.startTransfer(link: try qr.link(), attester: TestIOSAttester()) { _, _ in nil }
        let (_, initMsg) = try await base.relay.nextDeposit()
        base.relay.failDeposits = .notConnectedToInternet
        try await d.handle(try v.respondOpening(initMsg, d, ctx: inviteID).message)
        #expect(d.pairingSas != nil, "the code is shown: the failure was a passing one")
        d.mem.withLock { for i in d.st.outbox.indices { d.st.outbox[i].attempts = 0 } } // as if the deposit had not run
        base.relay.failDeposits = nil
        base.relay.refuseStatus = 403
        base.relay.refuseDeposits = RelayError.tokenRevoked
        await d.flushOutbox()
        #expect(d.mem.withLock { d.st.outbox.isEmpty })
        await #expect(throws: PairingNotCompleted.self) { _ = try await d.awaitPairingSas() }
    }

    /// A fin sent before and refused for good when sent again is no evidence that the vault never took it (its answer may have
    /// been lost): the entry goes, the flow is not told, and the deadline's collect decides.
    @Test func aResentFinRefusedForGoodByAFlushIsSilent() async throws {
        let (d, v) = try await newPhone()
        let (qr, inviteID) = try codeFor(v, d)
        try await d.startTransfer(link: try qr.link(), attester: TestIOSAttester()) { _, _ in nil }
        let (_, initMsg) = try await base.relay.nextDeposit()
        base.relay.failDeposits = .notConnectedToInternet
        try await d.handle(try v.respondOpening(initMsg, d, ctx: inviteID).message)
        #expect(d.mem.withLock { d.st.outbox.first?.attempts } == 1)
        base.relay.failDeposits = nil
        base.relay.refuseStatus = 403
        base.relay.refuseDeposits = RelayError.tokenRevoked
        await d.flushOutbox()
        #expect(d.mem.withLock { d.st.outbox.isEmpty })
        #expect(!d.mem.withLock { d.finFailed })
        #expect(try await d.awaitPairingSas() == d.pairingSas, "the flow is not told it failed")
    }

    /// A first deposit that is cancelled while the relay holds it may have reached the vault: it counts as an attempt, and the
    /// refusal of the copy sent later is no evidence, so it is silent.
    @Test func aCancelledFirstDepositCountsSoThatTheRefusalOfTheNextIsSilent() async throws {
        let (d, v) = try await newPhone()
        let (qr, inviteID) = try codeFor(v, d)
        try await d.startTransfer(link: try qr.link(), attester: TestIOSAttester()) { _, _ in nil }
        let (_, initMsg) = try await base.relay.nextDeposit()
        let gate = FakeHTTPServer.Gate()
        base.relay.holdDeposits = gate
        let message = try v.respondOpening(initMsg, d, ctx: inviteID).message
        let handling = Task { try? await d.handle(message) }
        for _ in 0..<500 where gate.waiting == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(gate.waiting == 1, "the fin reached the relay")
        handling.cancel()
        await handling.value
        gate.open()
        base.relay.holdDeposits = nil
        #expect(d.mem.withLock { d.st.outbox.first?.attempts } == 1, "counted before it was sent")
        base.relay.refuseStatus = 403
        base.relay.refuseDeposits = RelayError.tokenRevoked
        await d.flushOutbox()
        #expect(d.mem.withLock { d.st.outbox.isEmpty })
        #expect(!d.mem.withLock { d.finFailed }, "the vault may have taken the first copy")
    }

    /// A transfer whose fin is owed (the relay refused it passingly), the vault past the fin, a rekey done after it; and a
    /// `device.paired` the vault sealed under the handshake's own epoch before the rekey, which arrives after it.
    func finOwedAfterARekey() async throws -> (d: VaultDevice, late: RelayMessage) {
        let (d, v) = try await newPhone()
        let (qr, inviteID) = try codeFor(v, d)
        try await d.startTransfer(link: try qr.link(), attester: TestIOSAttester()) { _, _ in nil }
        let (_, initMsg) = try await base.relay.nextDeposit()
        base.relay.refuseStatus = 503
        base.relay.refuseDeposits = "unavailable"
        base.relay.recordRefused = true
        try await d.handle(try v.respondOpening(initMsg, d, ctx: inviteID).message)
        try v.fin(try await base.relay.nextDeposit().payload, d)
        let paired = Inner(id: Ulid.new(), type: "device.paired", ts: Date(), re: nil, status: nil, body: Array(
            #"{"device_id":"dev-2","role":"app","vault_id":"\#(v.vaultID)","transfer":true,"user_guid":"guid-1234"}"#.utf8))
        let late = v.msg(try #require(v.keyring.current()).seal(paired)) // sealed now, arrives after the rekey
        base.relay.refuseDeposits = nil
        base.relay.dropDeposits() // the refused copies of the fin that the relay answered again
        let ini = try v.rekey(d)
        try await d.handle(v.msg(ini.envelope))
        let res = try ini.handleResp(try await base.relay.nextDeposit().payload, collectSender: d.relayAddr.pk, now: Date())
        v.keyring.activate(res.epoch, now: Date())
        try await d.handle(v.msg(res.fin))
        #expect(d.mem.withLock { d.st.outbox.count } == 1)
        return (d, late)
    }

    /// A `device.paired` sealed under a retired epoch of a different handshake does not clear a fin still owed.
    @Test func aPairedFromAnotherHandshakesRetiredEpochLeavesTheFin() async throws {
        let (d, late) = try await finOwedAfterARekey()
        d.mem.withLock { for i in d.st.outbox.indices { d.st.outbox[i].epochIDs = ["another-handshake"] } } // a newer handshake's fin
        try await d.handle(late)
        #expect(d.mem.withLock { d.st.outbox.count } == 1, "the other epoch's message left the fin")
    }

    /// A `device.paired` sealed under the fin's own epoch removes it, also after a rekey moved the handshake on.
    @Test func aPairedUnderTheOriginalEpochAfterARekeyRemovesTheFin() async throws {
        let (d, late) = try await finOwedAfterARekey()
        try await d.handle(late)
        #expect(d.mem.withLock { d.st.outbox.isEmpty })
    }

    /// A fin owed follows its handshake's epoch into a rekey's: the `device.paired` sealed under the new epoch removes it.
    @Test func aPairedAfterARekeyRemovesTheFin() async throws {
        let (d, v) = try await newPhone()
        let (qr, inviteID) = try codeFor(v, d)
        try await d.startTransfer(link: try qr.link(), attester: TestIOSAttester()) { _, _ in nil }
        let (_, initMsg) = try await base.relay.nextDeposit()
        base.relay.refuseStatus = 503
        base.relay.refuseDeposits = "unavailable"
        base.relay.recordRefused = true
        try await d.handle(try v.respondOpening(initMsg, d, ctx: inviteID).message)
        try v.fin(try await base.relay.nextDeposit().payload, d)
        base.relay.refuseDeposits = nil
        base.relay.dropDeposits()
        let ini = try v.rekey(d)
        try await d.handle(v.msg(ini.envelope))
        let res = try ini.handleResp(try await base.relay.nextDeposit().payload, collectSender: d.relayAddr.pk, now: Date())
        v.keyring.activate(res.epoch, now: Date())
        try await d.handle(v.msg(res.fin))
        #expect(d.mem.withLock { d.st.outbox.count } == 1)
        try await d.handle(try v.seal("device.paired", #"{"device_id":"dev-2","role":"app","vault_id":"\#(v.vaultID)","transfer":true,"user_guid":"guid-1234"}"#))
        // The fin is gone, and the pairing's device.features (§10.2) went out.
        #expect(d.mem.withLock { d.st.outbox.isEmpty })
    }

    /// The fin is dropped a minute past its token's exp (the 10-minute request token of a pairing), by the device's clock, and
    /// that is not reported as a failure.
    @Test func aFinIsDroppedPastItsTokensExp() async throws {
        let offset = Box<TimeInterval>(0)
        let (d, v) = try await newPhone(now: { Date().addingTimeInterval(offset.value) })
        v.requestTokenTTL = 600
        let (qr, inviteID) = try codeFor(v, d)
        try await d.startTransfer(link: try qr.link(), attester: TestIOSAttester()) { _, _ in nil }
        let (_, initMsg) = try await base.relay.nextDeposit()
        base.relay.refuseStatus = 503
        base.relay.refuseDeposits = "unavailable"
        try await d.handle(try v.respondOpening(initMsg, d, ctx: inviteID).message)
        let entry = try #require(d.mem.withLock { d.st.outbox.first })
        let exp = try DepositTokens.verify(entry.token, issuer: v.relayKey.publicKey).exp
        #expect(entry.dropAfterMs == VaultDevice.ms(exp.addingTimeInterval(60)), "a minute past the exp")
        let untilExp = exp.timeIntervalSinceNow
        offset.value = untilExp - 30 // inside the token's time
        await d.flushOutbox()
        #expect(d.mem.withLock { d.st.outbox.count } == 1)
        offset.value = untilExp + 30 // past the exp, within the minute: still owed
        await d.flushOutbox()
        #expect(d.mem.withLock { d.st.outbox.count } == 1, "the grace is kept")
        offset.value = untilExp + 90 // past the minute
        await d.flushOutbox()
        #expect(d.mem.withLock { d.st.outbox.isEmpty })
        #expect(!d.mem.withLock { d.finFailed }, "an age drop is no failure")
    }

    /// `device.paired` removes a fin still owed, so that its age cannot later fail a pairing that finished.
    @Test func aPairedDeviceOwesNoFin() async throws {
        let (d, v) = try await newPhone()
        let (qr, inviteID) = try codeFor(v, d)
        try await d.startTransfer(link: try qr.link(), attester: TestIOSAttester()) { _, _ in nil }
        let (_, initMsg) = try await base.relay.nextDeposit()
        base.relay.refuseStatus = 503
        base.relay.refuseDeposits = "unavailable"
        base.relay.recordRefused = true
        try await d.handle(try v.respondOpening(initMsg, d, ctx: inviteID).message)
        try v.fin(try await base.relay.nextDeposit().payload, d)
        #expect(d.mem.withLock { d.st.outbox.count } == 1)
        try await d.handle(try v.seal("device.paired", #"{"device_id":"dev-2","role":"app","vault_id":"\#(v.vaultID)","transfer":true,"user_guid":"guid-1234"}"#))
        // The fin is gone; what is left is the pairing's device.features (§10.2), refused like every deposit here.
        #expect(d.mem.withLock { d.st.outbox.map(\.type) } == ["device.features"])
    }

    /// The first handshake's `device.paired` of an enrollment clears a fin still owed too.
    @Test func anEnrolledDevicesPairedClearsTheFin() async throws {
        let (d, v) = try await enrolled()
        base.relay.refuseStatus = 503
        base.relay.refuseDeposits = "unavailable"
        base.relay.recordRefused = true
        base.relay.refuseOnly = 6 // the hs.init and the fin: three attempts each
        let outcome = enroll(d)
        let (_, initMsg) = try await base.relay.nextDeposit()
        try await d.handle(try v.respond(initMsg, d))
        try await settle(1.5)
        #expect(d.mem.withLock { d.st.outbox.map(\.type) } == ["hs.fin"], "owed")
        var fin: [UInt8]?
        while fin == nil {
            let (_, payload) = try await base.relay.nextDeposit()
            if (try? v.fin(payload, d)) != nil { fin = payload }
        }
        try await d.handle(try v.seal("device.paired", #"{"device_id":"dev-1","role":"app","vault_id":"\#(v.vaultID)","release":"\#(String(repeating: "a3", count: 48))","release_number":3}"#))
        #expect(d.mem.withLock { d.st.outbox.isEmpty })
        for _ in 0..<100 where !outcome.finished { try await settle(0.05) }
        #expect(outcome.finished && outcome.error == nil)
    }

    /// A fin whose first save failed is not lost, and not sent before its count is saved: it is marked in flight from the
    /// moment it is stored (a flush there leaves it alone), owed while saves fail, and deposited once, when they work.
    @Test func aFinWhoseSaveFailedWaitsForASaveAndIsDepositedOnce() async throws {
        let store = FlakyStore()
        let secrets = DeviceSecrets(identity: Ed25519PrivateKey.generate(), kem: try KemPrivateKey.generate(), relay: Ed25519PrivateKey.generate(), apiKey: [UInt8](repeating: 0x30, count: 91))
        let d = try await VaultDevice.create(base.config(store), secrets: secrets)
        let v = try FakeVault(relayURL: base.relay.baseURL)
        let (qr, inviteID) = try codeFor(v, d)
        try await d.startTransfer(link: try qr.link(), attester: TestIOSAttester()) { _, _ in nil }
        let (_, initMsg) = try await base.relay.nextDeposit()
        store.fail()
        let marked = Box<Bool?>(nil)
        d.finStoredHook = { [d] id in marked.value = d.mem.withLock { d.outboxInFlight.contains(id) } }
        try? await d.handle(try v.respondOpening(initMsg, d, ctx: inviteID).message) // its own saves fail too
        #expect(marked.value == true, "marked in flight when stored, with the lock still held: no flush can take it")
        #expect(await base.relay.noDeposit(within: 0.3), "not sent: its count could not be saved")
        #expect(d.mem.withLock { d.st.outbox.first?.attempts } == 0, "the count was taken back")
        #expect(d.mem.withLock { d.outboxInFlight.isEmpty })
        store.heal()
        await d.flushOutbox()
        let (_, payload) = try await base.relay.nextDeposit()
        try v.fin(payload, d) // the vault takes the fin
        #expect(await base.relay.noDeposit(within: 0.3), "the fin was deposited exactly once")
    }

    /// A flush that chose a fin before a new handshake removed it finds it gone once it has the lock: nothing is deposited and
    /// the new handshake is not told that its pairing failed.
    @Test func aFinReplacedBeforeItsCountIsNotDeposited() async throws {
        let (d, v) = try await newPhone()
        let (qr, inviteID) = try codeFor(v, d)
        try await d.startTransfer(link: try qr.link(), attester: TestIOSAttester()) { _, _ in nil }
        let (_, initMsg) = try await base.relay.nextDeposit()
        base.relay.failDeposits = .notConnectedToInternet
        try await d.handle(try v.respondOpening(initMsg, d, ctx: inviteID).message)
        d.mem.withLock { for i in d.st.outbox.indices { d.st.outbox[i].attempts = 0 } } // as if it had not been sent
        base.relay.failDeposits = nil
        base.relay.refuseStatus = 403
        base.relay.refuseDeposits = RelayError.tokenRevoked
        base.relay.recordRefused = true
        base.relay.dropDeposits()
        d.finCountHook = { [d] in d.mem.withLock { d.st.outbox.removeAll { $0.type == VaultDevice.typeHsFin }; d.finFailed = false } } // prepareInit of a new code
        await d.flushOutbox()
        #expect(await base.relay.noDeposit(within: 0.3), "the stale fin was not deposited")
        #expect(!d.mem.withLock { d.finFailed })
    }

    /// A fin refused for good while its deposit was in flight, a new handshake having removed the fins meanwhile (and reset the
    /// failure), does not fail the new handshake.
    @Test func aFinRefusedAfterANewHandshakeStartedDoesNotFailIt() async throws {
        let (d, v) = try await newPhone()
        let (qr, inviteID) = try codeFor(v, d)
        try await d.startTransfer(link: try qr.link(), attester: TestIOSAttester()) { _, _ in nil }
        let (_, initMsg) = try await base.relay.nextDeposit()
        base.relay.failDeposits = .notConnectedToInternet
        try await d.handle(try v.respondOpening(initMsg, d, ctx: inviteID).message)
        d.mem.withLock { for i in d.st.outbox.indices { d.st.outbox[i].attempts = 0 } } // as if it had not been sent
        base.relay.failDeposits = nil
        base.relay.refuseStatus = 403
        base.relay.refuseDeposits = RelayError.tokenRevoked
        d.finSendHook = { [d] in d.mem.withLock { d.st.outbox.removeAll { $0.type == VaultDevice.typeHsFin }; d.finFailed = false } } // prepareInit of a new code
        await d.flushOutbox()
        #expect(!d.mem.withLock { d.finFailed })
        #expect(d.mem.withLock { d.inboxWaiters.isEmpty })
    }

    /// The code of a handshake that a new one replaced while its fin was in flight is not shown to the new flow.
    @Test func theCodeOfAReplacedHandshakeIsNotShown() async throws {
        let (d, v) = try await newPhone()
        let (qr, inviteID) = try codeFor(v, d)
        try await d.startTransfer(link: try qr.link(), attester: TestIOSAttester()) { _, _ in nil }
        let (_, initMsg) = try await base.relay.nextDeposit()
        d.finSendHook = { [d] in
            d.mem.withLock { d.handshakeGeneration += 1; d.st.outbox.removeAll { $0.type == VaultDevice.typeHsFin }; d.finFailed = false }
        }
        try await d.handle(try v.respondOpening(initMsg, d, ctx: inviteID).message)
        #expect(d.pairingSas == nil, "the old handshake's code is not handed to the new flow")
    }

    /// The code of a handshake that was dropped (the owner rejected it, or the transfer was abandoned) while its fin was in
    /// flight is not shown once the deposit ends.
    @Test func theCodeOfADroppedHandshakeIsNotShown() async throws {
        let (d, v) = try await newPhone()
        let (qr, inviteID) = try codeFor(v, d)
        try await d.startTransfer(link: try qr.link(), attester: TestIOSAttester()) { _, _ in nil }
        let (_, initMsg) = try await base.relay.nextDeposit()
        let gate = FakeHTTPServer.Gate()
        base.relay.holdDeposits = gate // the fin's deposit is held at the relay
        let message = try v.respondOpening(initMsg, d, ctx: inviteID).message
        let handling = Task { try? await d.handle(message) }
        for _ in 0..<500 where gate.waiting == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(gate.waiting == 1, "the fin reached the relay")
        d.dropPairing() // device.pair.rejected
        gate.open()
        await handling.value
        #expect(d.pairingSas == nil, "the dropped handshake's code is not shown")
    }

    /// The match code that the closure of the previous handshake set meanwhile (between the new transfer's clearing of it and
    /// the new handshake) is not the new flow's.
    @Test func aCodeShownMeanwhileIsClearedByTheNewHandshake() async throws {
        let (d, v) = try await newPhone()
        let (qr, _) = try codeFor(v, d)
        d.beforePrepareInitHook = { [d] in d.mem.withLock { d.sas = "123456" } } // the old closure finishing
        try await d.startTransfer(link: try qr.link(), attester: TestIOSAttester()) { _, _ in nil }
        #expect(d.pairingSas == nil, "no code until this handshake's own hs.resp")
    }

    /// A fin past its time is dropped by a flush while the lock gate is shut too: dropping it sends nothing.
    @Test func aFinPastItsTimeIsDroppedWhileTheGateIsShut() async throws {
        let offset = Box<TimeInterval>(0)
        let (d, v) = try await newPhone(now: { Date().addingTimeInterval(offset.value) })
        d.setFlushGate { false }
        let (qr, inviteID) = try codeFor(v, d)
        try await d.startTransfer(link: try qr.link(), attester: TestIOSAttester()) { _, _ in nil }
        let (_, initMsg) = try await base.relay.nextDeposit()
        try await d.handle(try v.respondOpening(initMsg, d, ctx: inviteID).message)
        #expect(d.mem.withLock { d.st.outbox.map(\.type) } == ["hs.fin"])
        offset.value = 17 * 86_400 // past a handshake's lifetime
        await d.flushOutbox()
        #expect(d.mem.withLock { d.st.outbox.isEmpty })
        #expect(await base.relay.noDeposit(within: 0.2))
    }

    /// A fin held by the gate after it was counted (a lock went pending while the count waited) is not counted: it never went
    /// out (its attempts stay 0, which lets a later refusal for good of its first copy tell the flow).
    @Test func aFinHeldAfterItsCountIsNotCounted() async throws {
        let (d, v) = try await newPhone()
        let asks = Box(0)
        d.setFlushGate {
            asks.value += 1
            return asks.value <= 2 // the handling's ask and the deposit's first; the one after the count holds it
        }
        let (qr, inviteID) = try codeFor(v, d)
        try await d.startTransfer(link: try qr.link(), attester: TestIOSAttester()) { _, _ in nil }
        let (_, initMsg) = try await base.relay.nextDeposit()
        try await d.handle(try v.respondOpening(initMsg, d, ctx: inviteID).message)
        #expect(await base.relay.noDeposit(within: 0.2))
        #expect(asks.value == 3) // held at the third: after the count
        #expect(d.mem.withLock { d.st.outbox.first.map { $0.type == "hs.fin" && $0.attempts == 0 } } == true)
        #expect(d.mem.withLock { d.outboxInFlight.isEmpty })
    }

    /// A pairing's `hs.fin` asks the lock gate (nothing but the lock while one is pending): held, it waits in the outbox, not
    /// marked in flight, as after a passing failure, and the next flush the gate admits sends it.
    @Test func aFinWaitsForTheLockGate() async throws {
        let (d, v) = try await newPhone()
        let open = Box(false)
        d.setFlushGate { open.value }
        let (qr, inviteID) = try codeFor(v, d)
        try await d.startTransfer(link: try qr.link(), attester: TestIOSAttester()) { _, _ in nil }
        let (_, initMsg) = try await base.relay.nextDeposit()
        try await d.handle(try v.respondOpening(initMsg, d, ctx: inviteID).message)
        #expect(await base.relay.noDeposit(within: 0.2))
        #expect(d.mem.withLock { d.st.outbox.map(\.type) == ["hs.fin"] && d.outboxInFlight.isEmpty })
        #expect(!d.mem.withLock { d.finFailed })
        open.value = true
        await d.flushOutbox()
        try v.fin(try await base.relay.nextDeposit().payload, d)
        #expect(d.mem.withLock { d.st.outbox.isEmpty })
    }
}

// swiftlint:enable line_length
