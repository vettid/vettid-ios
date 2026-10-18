import Foundation
import Testing
@testable import VettIDVault
import VettIDCrypto
import VettIDRelay
import VettIDTesting

// Fixtures (JSON bodies of the fake vault) stay on one line each.
// swiftlint:disable line_length

/// The vault client against an in-process fake vault built from VettIDCrypto and a fake relay that records deposits.
/// Messages reach the device through ``VaultDevice/handle(_:)``, as the collector would deliver them. Mirrors the
/// transport and session cases of vettid-android `VaultDeviceTest`.
@Suite struct VaultDeviceTests {
    let relay = FakeRelay()

    func config(
        _ store: DeviceStateStore, timeout: TimeInterval = 5, attestation: EnrolledAttestation = .skipForTests,
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> DeviceConfig {
        DeviceConfig(
            name: "phone", relayURL: relay.baseURL, transport: HTTPTransport(session: relay.server.session, sleep: { _ in }),
            store: store, enrolledAttestation: attestation, now: now, requestTimeout: timeout
        )
    }

    /// Enrollment, the first handshake and device.paired: a device with a live session.
    func pairedDevice(
        store: DeviceStateStore = InMemoryDeviceStateStore(), secrets: DeviceSecrets? = nil, cfg: DeviceConfig? = nil
    ) async throws -> (VaultDevice, FakeVault) {
        let d = try await VaultDevice.create(cfg ?? config(store), secrets: try secrets ?? DeviceSecrets.generate())
        let v = try FakeVault(relayURL: relay.baseURL)
        try await d.handle(try v.enrolled(d))
        try await d.awaitEnrolled(timeout: 1)
        #expect(d.vaultID == v.vaultID)
        let paired = Task { try await d.completeEnrollment(timeout: 10) }
        let (mbx, initMsg) = try await relay.nextDeposit()
        #expect(mbx == v.mailbox)
        try await d.handle(try v.respond(initMsg, d))
        try v.fin(try await relay.nextDeposit().payload, d)
        try await d.handle(try v.seal("device.paired", #"{"device_id":"dev-1","role":"app","vault_id":"\#(v.vaultID)","release":"\#(String(repeating: "a3", count: 48))","release_number":3}"#))
        try await paired.value
        #expect(d.deviceID == "dev-1" && d.paired && d.altState.releaseNumber == 3)
        return (d, v)
    }

    func savedState(_ store: InMemoryDeviceStateStore) throws -> DeviceState {
        try JSONDecoder().decode(DeviceState.self, from: Data(try #require(store.load())))
    }

    @Test func enrollPairRequestAndEvents() async throws {
        let (d, v) = try await pairedDevice()
        let api = VaultApi(device: d)
        // A request and its response (§8.1).
        let status = Task { try await api.status() }
        let req = try v.open(try await relay.nextDeposit().payload)
        #expect(req.type == "vault.status")
        try await d.handle(try v.seal("vault.status", #"{"vault_id":"\#(v.vaultID)","state_seq":4,"header_seq":4,"provisional":false,"devices":1,"connections":0,"future_member":{"x":1}}"#, re: req.id, status: Inner.statusOK))
        #expect(try await status.value.stateSeq == 4)

        // An error response carries the spec's code (§10.1).
        let failing = Task { try await d.op("item.get", body: JsonBuilder().string("item_id", "nope").bytes()) }
        let r2 = try v.open(try await relay.nextDeposit().payload)
        try await d.handle(v.msg(try #require(v.keyring.current()).seal(Inner(id: Ulid.new(), type: r2.type, ts: Date(), re: r2.id, status: Inner.statusError, error: InnerError("not_found")))))
        do {
            _ = try await failing.value
            Issue.record("no error")
        } catch let e as VaultOpError {
            #expect(e.code == "not_found")
        }

        // Events reach the inbox; a duplicate msg_id or inner id is dropped (§8.2).
        let m = try v.seal("message.new", #"{"connection_id":"c1","message_id":"m1","direction":"in","text":"hi","sent_at":"2026-10-04T00:00:00.000Z"}"#)
        try await d.handle(m)
        try await d.handle(m)
        let id = Ulid.new()
        try await d.handle(try v.seal("message.new", #"{"connection_id":"c1","message_id":"m2","direction":"in","text":"again","sent_at":"x"}"#, id: id))
        try await d.handle(try v.seal("message.new", #"{"connection_id":"c1","message_id":"m2","direction":"in","text":"again","sent_at":"x"}"#, id: id))
        #expect(VaultJSON.string(try await api.awaitEvent("message.new") { VaultJSON.string($0.object, "text") == "hi" }.object, "text") == "hi")
        #expect(VaultJSON.string(try await api.awaitEvent("message.new").object, "text") == "again")
        await #expect(throws: VaultStateError.self) { _ = try await d.awaitEvent("message.new", timeout: 0.2) }

        // Only the vault's relay key may send to the device (§6.3).
        try await d.handle(v.msg(try #require(v.keyring.current()).seal(Inner(id: Ulid.new(), type: "message.new", ts: Date())), from: RelayAuth.encodeKey(Ed25519PrivateKey.generate().publicKey)))
        await #expect(throws: VaultStateError.self) { _ = try await d.awaitEvent("message.new", timeout: 0.2) }

        // relay.token.refresh from the vault is answered with a fresh standing token (§7.2).
        try await d.handle(try v.seal("relay.token.refresh", "{}"))
        let ans = try v.open(try await relay.nextDeposit().payload)
        #expect(ans.type == "relay.token.refresh" && ans.re != nil)
        let tok = try #require(VaultJSON.string(VaultJSON.object(ans.body), "token"))
        #expect(try DepositTokens.verify(tok, issuer: d.relayAddr.pk).sub == RelayAuth.encodeKey(v.relayKey.publicKey))
    }

    /// 0.10.5 (§6.7): the owner rejects after the new device's hs.fin; the device stops waiting, drops the epoch and
    /// the request token, and sends nothing back; a redelivery or a late device.paired is dropped.
    @Test func pairingRejectedEndsTheWaitAndDropsTheHandshake() async throws {
        let store = InMemoryDeviceStateStore()
        let d = try await VaultDevice.create(config(store), secrets: try DeviceSecrets.generate())
        let v = try FakeVault(relayURL: relay.baseURL)
        try await d.handle(try v.enrolled(d))
        try await d.awaitEnrolled(timeout: 1)
        let waiting = Task { try await d.completeEnrollment(timeout: 10) }
        try await d.handle(try v.respond(try await relay.nextDeposit().payload, d))
        try v.fin(try await relay.nextDeposit().payload, d)
        let rejected = try v.seal("device.pair.rejected", "{}")
        try await d.handle(rejected)
        await #expect(throws: PairingRejected.self) { try await waiting.value }
        #expect(!d.paired && d.deviceID == nil)
        // The request token and the epoch are gone, also from the persisted state.
        let saved = try savedState(store)
        #expect(saved.vault?.token == "" && saved.vault?.tokenExpMs == 0)
        #expect(await relay.noDeposit(within: 0.3))
        // A redelivery (new msg_id) or a device.paired after it finds no epoch: dropped.
        try await d.handle(v.msg(rejected.payload))
        await #expect(throws: VaultStateError.self) { _ = try await d.awaitEvent("device.paired", timeout: 0.2) }
        #expect(!d.paired)
        // Pairing again needs a new code: there is no token to start a handshake with.
        await #expect(throws: VaultStateError.self) { try await d.completeEnrollment(timeout: 0.2) }
    }

    /// A paired device drops a device.pair.rejected (only a device waiting for device.paired acts on it).
    @Test func aPairedDeviceIgnoresAPairingRejection() async throws {
        let (d, v) = try await pairedDevice()
        try await d.handle(try v.seal("device.pair.rejected", "{}"))
        #expect(d.paired && d.deviceID == "dev-1")
        let status = Task { try await d.op("vault.status") }
        let req = try v.open(try await relay.nextDeposit().payload)
        try await d.handle(try v.seal("vault.status", #"{"vault_id":"x"}"#, re: req.id, status: Inner.statusOK))
        #expect(VaultJSON.string(VaultJSON.object(try await status.value), "vault_id") == "x")
    }

    @Test func answersAVaultInitiatedRekey() async throws {
        let (d, v) = try await pairedDevice()
        let ini = try v.rekey(d)
        try await d.handle(v.msg(ini.envelope))
        let res = try ini.handleResp(try await relay.nextDeposit().payload, collectSender: d.relayAddr.pk, now: Date())
        v.keyring.activate(res.epoch, now: Date())
        try await d.handle(v.msg(res.fin))
        // The device now answers in the new epoch.
        let status = Task { try await d.op("vault.status") }
        let raw = try await relay.nextDeposit().payload
        #expect(try Envelope.parse(raw).recipientKid == res.epoch.recvKid)
        try await d.handle(try v.seal("vault.status", #"{"vault_id":"x"}"#, re: try v.open(raw).id, status: Inner.statusOK))
        #expect(VaultJSON.string(VaultJSON.object(try await status.value), "vault_id") == "x")
    }

    /// A replaced phone (its relay key on the vault's denylist, §7.4) has every deposit refused with `token_revoked`.
    /// The device counts them until the vault speaks to it again; other refusals do not count.
    @Test func refusedDepositsToTheVaultAreCountedUntilTheVaultSpeaks() async throws {
        let (d, v) = try await pairedDevice()
        let api = VaultApi(device: d)
        relay.refuseDeposits = RelayError.tokenRevoked
        for _ in 0..<3 { await #expect(throws: RelayError.self) { _ = try await api.status() } }
        #expect(d.vaultRefusals == 3)
        relay.refuseDeposits = RelayError.tokenExpired
        _ = try? await api.status()
        #expect(d.vaultRefusals == 3)
        relay.refuseDeposits = nil
        try await d.handle(try v.seal("message.new", #"{"connection_id":"c1","message_id":"m1","direction":"in","text":"hi","sent_at":"x"}"#))
        #expect(d.vaultRefusals == 0)
        relay.refuseDeposits = RelayError.tokenRevoked
        _ = try? await api.status()
        #expect(d.vaultRefusals == 1)
        d.clearVaultRefusals()
        #expect(d.vaultRefusals == 0)
    }

    /// A refused answer to the vault is counted, neither thrown nor repeated (its msg_id is saved with the refusal).
    @Test func aRefusedAnswerToTheVaultNeitherThrowsNorRepeats() async throws {
        let store = InMemoryDeviceStateStore()
        let secrets = try DeviceSecrets.generate()
        let (d, v) = try await pairedDevice(store: store, secrets: secrets)
        relay.refuseDeposits = RelayError.tokenRevoked
        let refresh = try v.seal("relay.token.refresh", "{}")
        try await d.handle(refresh)
        #expect(relay.refused == 1 && d.vaultRefusals == 1)
        let again = try #require(try VaultDevice.load(config(store), secrets: secrets))
        try await again.handle(refresh)
        #expect(relay.refused == 1)
        // A rekey whose answer is refused: counted the same way, nothing thrown.
        try await d.handle(v.msg(try v.rekey(d).envelope))
        #expect(relay.refused == 2 && d.vaultRefusals == 1)
        // Other relay errors on an answer neither throw nor count.
        for code in [RelayError.tokenExpired, RelayError.mailboxUnknown, RelayError.tokenInvalid] {
            relay.refuseDeposits = code
            d.clearVaultRefusals()
            try await d.handle(try v.seal("relay.token.refresh", "{}"))
            #expect(d.vaultRefusals == 0, "\(code)")
        }
    }

    /// The collector itself: a refused answer is acked and the device.unlinked behind it arrives; nothing escapes.
    @Test func theCollectorSurvivesARefusedAnswerAndReadsTheNextMessage() async throws {
        let (d, v) = try await pairedDevice()
        relay.refuseDeposits = RelayError.tokenRevoked
        relay.serveMailbox = true
        let refresh = try v.seal("relay.token.refresh", "{}")
        let unlinked = try v.seal("device.unlinked", #"{"reason":"replaced"}"#)
        relay.queue(refresh)
        relay.queue(unlinked)
        d.start()
        #expect(VaultJSON.string(try await d.awaitEvent("device.unlinked", timeout: 10).object, "reason") == "replaced")
        let ackedRefresh = await relay.waitAcked(refresh.msgID)
        let ackedUnlinked = await relay.waitAcked(unlinked.msgID)
        #expect(ackedRefresh && ackedUnlinked)
        #expect(d.collecting)
        d.stop()
    }

    /// A terminal relay error on collecting ends the collection quietly; ensureCollecting starts it again, never after
    /// stop().
    @Test func aTerminalCollectErrorEndsTheCollectionAndItStartsAgain() async throws {
        let (d, v) = try await pairedDevice()
        relay.refuseCollect = RelayError.signatureInvalid
        d.start()
        for _ in 0..<500 where d.collectionEnded == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(d.collectionEnded == RelayError.signatureInvalid && !d.collecting)
        relay.refuseCollect = nil
        relay.serveMailbox = true
        let m = try v.seal("message.new", #"{"connection_id":"c1","message_id":"m3","direction":"in","text":"after","sent_at":"x"}"#)
        relay.queue(m)
        #expect(d.ensureCollecting())
        #expect(d.collecting && d.collectionEnded == nil)
        #expect(!d.ensureCollecting()) // already running
        #expect(VaultJSON.string(try await d.awaitEvent("message.new", timeout: 10).object, "text") == "after")
        #expect(await relay.waitAcked(m.msgID))
        d.stop()
        #expect(!d.ensureCollecting())
    }

    /// A deposit refused with a stale or replayed signature stays in the outbox and goes out at the next flush, signed
    /// afresh; a terminal refusal drops it (§8.6).
    @Test func aDepositRefusedForAStaleSignatureStaysInTheOutbox() async throws {
        let store = InMemoryDeviceStateStore()
        let (d, v) = try await pairedDevice(store: store)
        relay.refuseStatus = 401
        relay.refuseDeposits = RelayError.timestampStale
        await #expect(throws: RelayError.self) { try await d.send("message.send", body: JsonBuilder().string("text", "hi").bytes()) }
        #expect(relay.refused == RelayClient.defaultAttempts) // each attempt signed afresh, then kept
        #expect(try savedState(store).outbox.count == 1)
        relay.refuseDeposits = nil
        await d.flushOutbox()
        #expect(try v.open(try await relay.nextDeposit().payload).type == "message.send")
        #expect(try savedState(store).outbox.isEmpty)
        relay.refuseStatus = 403
        relay.refuseDeposits = RelayError.tokenInvalid
        _ = try? await d.send("message.send", body: JsonBuilder().string("text", "again").bytes())
        #expect(try savedState(store).outbox.isEmpty)
    }

    /// The vault rekeys at every unlock and switches to the new epoch on hs.resp (§6.5). An app that ends between its
    /// hs.resp and the vault's hs.fin keeps the handshake (persisted). A message of the new epoch ahead of hs.fin is
    /// neither recorded as seen nor acked (LeaveUnacked), and its redelivery opens after hs.fin.
    @Test func aRekeySurvivesARestartAndAMessageAheadOfItsFinWaits() async throws {
        let store = InMemoryDeviceStateStore()
        let secrets = try DeviceSecrets.generate()
        let (d, v) = try await pairedDevice(store: store, secrets: secrets)
        let ini = try v.rekey(d)
        try await d.handle(v.msg(ini.envelope))
        let res = try ini.handleResp(try await relay.nextDeposit().payload, collectSender: d.relayAddr.pk, now: Date())
        v.keyring.activate(res.epoch, now: Date())
        d.stop() // the process ends before hs.fin arrives
        let again = try #require(try VaultDevice.load(config(store), secrets: secrets))
        let early = try v.seal("message.new", #"{"connection_id":"c1","message_id":"m9","direction":"in","text":"early","sent_at":"x"}"#)
        await #expect(throws: LeaveUnacked.self) { try await again.handle(early) }
        #expect(try savedState(store).seen[early.msgID] == nil)
        try await again.handle(v.msg(res.fin))
        #expect(try savedState(store).vault?.awaiting.isEmpty == true)
        try await again.handle(early) // the relay's redelivery: same msg_id
        #expect(VaultJSON.string(try await again.awaitEvent("message.new", timeout: 2).object, "text") == "early")
        let status = Task { try await again.op("vault.status") }
        let raw = try await relay.nextDeposit().payload
        #expect(try Envelope.parse(raw).recipientKid == res.epoch.recvKid)
        try await again.handle(try v.seal("vault.status", #"{"vault_id":"x"}"#, re: try v.open(raw).id, status: Inner.statusOK))
        #expect(VaultJSON.string(VaultJSON.object(try await status.value), "vault_id") == "x")
    }

    @Test func stateSurvivesARestart() async throws {
        let store = InMemoryDeviceStateStore()
        let secrets = try DeviceSecrets.generate()
        let (d, v) = try await pairedDevice(store: store, secrets: secrets)
        d.stop()
        let again = try #require(try VaultDevice.load(config(store), secrets: secrets))
        #expect(again.deviceID == "dev-1" && again.vaultID == v.vaultID && again.paired)
        let r = Task { try await again.op("vault.status") }
        let req = try v.open(try await relay.nextDeposit().payload)
        try await again.handle(try v.seal("vault.status", "{}", re: req.id, status: Inner.statusOK))
        _ = try await r.value
        #expect(try VaultDevice.load(config(InMemoryDeviceStateStore()), secrets: secrets) == nil)
    }

    /// device.list over the session is accepted only as the answer to its own request: an earlier answer delivered
    /// again is not taken for a new request, which then gets no answer.
    @Test func aReplayedAnswerIsNotTakenForANewRequest() async throws {
        let (d, v) = try await pairedDevice()
        let api = VaultApi(device: d)
        let first = Task { try await api.deviceList() }
        let r1 = try v.open(try await relay.nextDeposit().payload)
        #expect(r1.type == "device.list")
        let answer = try v.seal("device.list", #"{"devices":[{"id":"dev-1","kind":"app","state":"active","name":"phone"}]}"#, re: r1.id, status: Inner.statusOK)
        try await d.handle(answer)
        #expect(try await first.value.first?.id == "dev-1")
        let second = Task { try await d.op("device.list", timeout: 0.3) }
        let r2 = try v.open(try await relay.nextDeposit().payload)
        #expect(r2.id != r1.id)
        try? await d.handle(answer)
        await #expect(throws: VaultStateError.self) { _ = try await second.value }
    }

    /// A lock is deposited once with an expiry and never kept in the outbox; what an earlier version left there is
    /// dropped (VAULT-LOCK, §10.2).
    @Test func aLockIsSentOnceWithAnExpiryAndNeverFromTheOutbox() async throws {
        let store = InMemoryDeviceStateStore()
        let (d, v) = try await pairedDevice(store: store)
        let api = VaultApi(device: d)
        let locking = Task { try await api.lock(unlockID: String(repeating: "ab", count: 16), timeout: 5) }
        let req = try v.open(try await relay.nextDeposit().payload)
        #expect(req.type == "vault.lock")
        let exp = try #require(req.exp)
        #expect(exp > Date().addingTimeInterval(20) && exp < Date().addingTimeInterval(31))
        #expect(VaultJSON.string(VaultJSON.object(req.body), "unlock_id") == String(repeating: "ab", count: 16))
        #expect(try savedState(store).outbox.isEmpty)
        try await d.handle(try v.seal("vault.lock", "{}", re: req.id, status: Inner.statusOK))
        try await locking.value
        // The relay cannot be reached: the lock fails now and nothing is kept to be sent later.
        relay.refuseStatus = 503
        relay.refuseDeposits = "unavailable"
        await #expect(throws: (any Error).self) { try await api.lock(timeout: 0.5) }
        #expect(try savedState(store).outbox.isEmpty)
        _ = try? await d.send("vault.lock")
        _ = try? await d.send("message.send", body: JsonBuilder().string("text", "hi").bytes())
        #expect(try savedState(store).outbox.map(\.type) == ["vault.lock", "message.send"])
        #expect(try await d.dropFromOutbox("vault.lock") == 1)
        #expect(try savedState(store).outbox.map(\.type) == ["message.send"])
        relay.refuseDeposits = nil
        await d.flushOutbox()
        #expect(try v.open(try await relay.nextDeposit().payload).type == "message.send")
        #expect(await relay.noDeposit(within: 0.3))
    }

    @Test func theTypedStatusAndTransferCalls() async throws {
        let (d, v) = try await pairedDevice()
        let api = VaultApi(device: d)
        let account = Task { try await api.accountGet() }
        let r1 = try v.open(try await relay.nextDeposit().payload)
        try await d.handle(try v.seal("account.get", #"{"account":{"v":1,"email":"sam@example.org","account_status":"active","first_name":"Sam"},"version":3,"name_request":{"seq":1,"first_name":"Sam","last_name":"Lee","state":"pending"}}"#, re: r1.id, status: Inner.statusOK))
        let a = try await account.value
        #expect(a.version == 3 && a.account?.email == "sam@example.org" && a.nameRequest?.lastName == "Lee")
        let offer = Task { try await api.transferCreate() }
        let r2 = try v.open(try await relay.nextDeposit().payload)
        try await d.handle(try v.seal("device.transfer.create", #"{"transfer_id":"t1","link":"https://vettid.org/p#x","exp":"2026-10-18T00:10:00Z"}"#, re: r2.id, status: Inner.statusOK))
        #expect(try await offer.value == TransferOffer(transferID: "t1", link: "https://vettid.org/p#x", exp: "2026-10-18T00:10:00Z"))
        try await d.handle(try v.seal("device.transfer.pending", #"{"transfer_id":"t1","name":"new phone","sas":"123456","signer_changed":"true"}"#))
        let p = try await api.awaitTransferPending("t1", timeout: 2)
        #expect(p.name == "new phone" && p.sas == "123456" && !p.signerChanged) // only a JSON true counts
    }

    /// §8.6: a request without an answer is re-sent with the same inner id at most twice, then fails; an answer to a
    /// re-sent copy completes it.
    @Test func aRequestIsResentTwiceWithItsInnerIDThenFails() async throws {
        let (d, v) = try await pairedDevice(cfg: config(InMemoryDeviceStateStore(), timeout: 0.3))
        let unanswered = Task { try await d.op("vault.status") }
        var ids: [String] = []
        for _ in 0..<3 { ids.append(try v.open(try await relay.nextDeposit().payload).id) }
        await #expect(throws: VaultStateError.self) { _ = try await unanswered.value }
        #expect(Set(ids).count == 1)
        #expect(await relay.noDeposit(within: 0.3))
        let answered = Task { try await d.op("vault.status") }
        let first = try v.open(try await relay.nextDeposit().payload)
        let resent = try v.open(try await relay.nextDeposit().payload)
        #expect(resent.id == first.id)
        try await d.handle(try v.seal("vault.status", #"{"vault_id":"x"}"#, re: resent.id, status: Inner.statusOK))
        #expect(VaultJSON.string(VaultJSON.object(try await answered.value), "vault_id") == "x")
    }

    /// vault.enrolled whose attestation does not pass, or without a pending enrollment's nonce, pins nothing; a paired
    /// device ignores a later vault.enrolled (it would re-pin the vault and drop the session).
    @Test func vaultEnrolledIsCheckedAndNeverRepins() async throws {
        struct Refused: Error {}
        for attestation: EnrolledAttestation in [.verify { _, _, _, _, _ in throw Refused() }, .verify { _, _, _, _, _ in }] {
            let d = try await VaultDevice.create(config(InMemoryDeviceStateStore(), attestation: attestation), secrets: try DeviceSecrets.generate())
            let v = try FakeVault(relayURL: relay.baseURL)
            try await d.handle(try v.enrolled(d))
            #expect(!d.hasVault && d.vaultID == nil) // the first throws; the second has no enrollment nonce to check
        }
        let (d, v) = try await pairedDevice()
        let other = try FakeVault(relayURL: relay.baseURL)
        try await d.handle(try other.enrolled(d))
        #expect(d.paired && d.vaultID == v.vaultID)
        let status = Task { try await d.op("vault.status") }
        let req = try v.open(try await relay.nextDeposit().payload) // still sealed to the first vault's session
        try await d.handle(try v.seal("vault.status", "{}", re: req.id, status: Inner.statusOK))
        _ = try await status.value
    }

    /// §7.2: ten days before the token this device gave the vault expires it issues a new one; three days before the
    /// vault's token expires it asks for a fresh one.
    @Test func tokensAreRefreshedInBothDirections() async throws {
        let shift = Box(0.0)
        let (d, v) = try await pairedDevice(cfg: config(InMemoryDeviceStateStore(), now: { Date().addingTimeInterval(shift.value) }))
        shift.value = 28 * 86_400
        try await d.handle(try v.seal("message.new", #"{"connection_id":"c1","message_id":"m1","direction":"in","text":"hi","sent_at":"x"}"#, ts: Date().addingTimeInterval(shift.value)))
        var types: Set<String> = []
        for _ in 0..<2 { types.insert(try v.open(try await relay.nextDeposit().payload).type) }
        #expect(types == ["relay.token.issued", "relay.token.refresh"])
    }

    /// §8.6: a deposit refused because the vault's mailbox is full waits in the outbox.
    @Test func aFullMailboxKeepsTheDepositInTheOutbox() async throws {
        let store = InMemoryDeviceStateStore()
        let (d, v) = try await pairedDevice(store: store)
        relay.refuseStatus = 429
        relay.refuseDeposits = RelayError.quotaExceeded
        await #expect(throws: RelayError.self) { try await d.send("message.send", body: JsonBuilder().string("text", "hi").bytes()) }
        #expect(relay.refused == 1) // not retried at once
        #expect(try savedState(store).outbox.count == 1)
        relay.refuseDeposits = nil
        await d.flushOutbox()
        #expect(try v.open(try await relay.nextDeposit().payload).type == "message.send")
    }

    /// After forget() the device keeps nothing and writes nothing.
    @Test func forgetLeavesNothing() async throws {
        let store = InMemoryDeviceStateStore()
        let (d, _) = try await pairedDevice(store: store)
        try await d.forget()
        #expect(store.load() == nil && !d.hasVault)
        await #expect(throws: VaultStateError.self) { try await d.send("message.send") }
        #expect(store.load() == nil)
    }

    @Test func deviceStateJSONRoundTrips() throws {
        let s = DeviceState(role: "app", name: "phone", relayURL: "https://relay.example.org")
        s.vaultID = "v"
        s.outbox = [OutboxEntry(id: "i", type: "t", relayURL: "u", mailbox: "m", token: "tok", envelope: "ZW52")]
        let back = try JSONDecoder().decode(DeviceState.self, from: try JSONEncoder().encode(s))
        #expect(back.vaultID == "v" && back.outbox == s.outbox && back.role == "app")
    }

    @Test func aTransferUserGuidIsCheckedBeforeItIsKept() throws {
        func o(_ s: String) throws -> JsonObject { try StrictJson.parseObject(Array(s.utf8)) }
        #expect(VaultDevice.transferUserGuid(try o(#"{"transfer":true,"user_guid":"guid-1"}"#)) == "guid-1")
        #expect(VaultDevice.transferUserGuid(try o(#"{"user_guid":"guid-1"}"#)) == nil)
        #expect(VaultDevice.transferUserGuid(try o(#"{"transfer":true,"user_guid":"a b"}"#)) == nil)
        #expect(VaultDevice.transferUserGuid(try o(#"{"transfer":true,"user_guid":"\#(String(repeating: "x", count: 129))"}"#)) == nil)
    }
}

// swiftlint:enable line_length
