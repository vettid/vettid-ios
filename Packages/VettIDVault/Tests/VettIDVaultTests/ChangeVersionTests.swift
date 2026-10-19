import Foundation
import Testing
@testable import VettIDVault
import VettIDCrypto

// Fixtures (JSON bodies of the fake vault) stay on one line each.
// swiftlint:disable line_length

/// Step 1 of VAULT-MESSAGING §11.14.9 "A lost answer" at the client: a change of PIN or password is sent only when no
/// other credential operation is in flight (it waits for them at most 30 s, then is refused with nothing sent), and only
/// when the vault's `credential.version` is the version the change goes with, so that "version + 1" of step 3 means this
/// change. An earlier operation applied without its answer (an owner check, a name change, the unlock window, a renew)
/// moved the version: the latest blob is fetched and the change refused with nothing sent.
@Suite struct ChangeVersionTests {
    let lost = LostAnswerTests()
    var ops: CredentialOpsTests { lost.ops }

    /// Pauses the test ends: each records its length and waits for ``release()`` (or its task's cancellation).
    final class Pauses: @unchecked Sendable {
        private let lock = NSLock()
        private var asked: [TimeInterval] = []
        private var waiting: [UUID: CheckedContinuation<Void, Never>] = [:]

        var lengths: [TimeInterval] { lock.withLock { asked } }

        func sleep(_ s: TimeInterval) async throws {
            let id = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    let cancelled: Bool = lock.withLock {
                        asked.append(s)
                        if Task.isCancelled { return true }
                        waiting[id] = c
                        return false
                    }
                    if cancelled { c.resume() }
                }
            } onCancel: {
                lock.withLock { waiting.removeValue(forKey: id) }?.resume()
            }
            try Task.checkCancellation()
        }

        func release() {
            let ws: [CheckedContinuation<Void, Never>] = lock.withLock {
                defer { waiting.removeAll() }
                return Array(waiting.values)
            }
            for w in ws { w.resume() }
        }

        /// Waits until a pause was asked for.
        func asked(within s: TimeInterval = 5) async -> Bool {
            let end = Date().addingTimeInterval(s)
            while Date() < end {
                if !lengths.isEmpty { return true }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            return false
        }
    }

    func change(_ api: VaultApi, _ marked: Marked = Marked()) -> Task<Bool, any Error> {
        Task { try await api.pinChange(pin: "975310", newPin: "864201", password: "pw", newUnlockSecret: [UInt8](repeating: 1, count: 32), marked: marked) }
    }

    /// The vault holds a newer blob than the phone (an owner check applied, its answer lost): the latest blob is fetched
    /// and kept, and the change goes with it and its version, the marker handed over only then (VAULT-MESSAGING 0.47.0
    /// §11.14.9 step 1, "Sent with the vault's current blob").
    @Test func aMovedVersionSendsTheChangeWithTheFetchedBlob() async throws {
        let h = try await lost.holder()
        let (d, v, api) = (h.d, h.v, h.api)
        let marked = Marked()
        let task = change(api, marked)
        try await ops.answer(v, d, "credential.version", #"{"exists":true,"version":2}"#)
        try await ops.answer(v, d, "credential.get", #"{"credential":"BAUG","version":2}"#)
        #expect(marked.change == nil, "no marker before the blob is the vault's")
        try await ops.answer(v, d, "credential.ack")
        let req = try await ops.answer(v, d, VaultApi.typePinChange, #"{"credential":"BwgJ","version":3,"epoch_advanced":true}"#)
        let sentBlob = try StrictJson.parseObject(req.body).string("credential")
        #expect(req.id == marked.change?.id && marked.change?.version == 2 && sentBlob == "BAUG")
        try await ops.answer(v, d, "credential.ack")
        #expect(try await task.value)
        #expect(d.credentialVersion == 3)
    }

    /// A fetch that gives another version than the vault said: the "earlier request" refusal, nothing sent or stored, the
    /// fetched blob kept.
    @Test func aFetchOfAnotherVersionRefusesTheChange() async throws {
        let h = try await lost.holder()
        let (d, v, api) = (h.d, h.v, h.api)
        let marked = Marked()
        let task = change(api, marked)
        try await ops.answer(v, d, "credential.version", #"{"exists":true,"version":2}"#)
        try await ops.answer(v, d, "credential.get", #"{"credential":"BwgJ","version":3}"#)
        try await ops.answer(v, d, "credential.ack")
        do {
            _ = try await task.value
            Issue.record("sent")
        } catch let e as CredentialUnsettled {
            #expect(e.reason == .inFlight && e.type == VaultApi.typePinChange)
        }
        #expect(marked.change == nil && d.credentialVersion == 3)
        #expect(await ops.base.relay.noDeposit(within: 0.3), "no pin.change")
    }

    /// `credential.version` answered with an error, without a version, or with no credential: counted as different (as
    /// vettid-android does), so the latest blob is fetched and kept, and since the vault's version is not known the change
    /// is refused with the "earlier request" refusal, never the answer's own code; nothing sent, no marker.
    @Test func anAnswerWithoutTheVaultsVersionRefusesTheChange() async throws {
        for (body, code) in [("{}", "busy" as String?), (#"{"exists":true}"#, nil), (#"{"exists":false}"#, nil)] {
            let h = try await lost.holder()
            let (d, v, api) = (h.d, h.v, h.api)
            let marked = Marked()
            let task = change(api, marked)
            try await ops.answer(v, d, "credential.version", body, code: code, errorBody: code.map { _ in "{}" })
            try await ops.answer(v, d, "credential.get", #"{"credential":"BAUG","version":2}"#)
            try await ops.answer(v, d, "credential.ack")
            do {
                _ = try await task.value
                Issue.record("sent: \(body) \(String(describing: code))")
            } catch let e as CredentialUnsettled {
                #expect(e.reason == .inFlight && e.type == VaultApi.typePinChange)
            }
            #expect(marked.change == nil && d.credentialVersion == 2, "the fetched blob kept")
            #expect(await ops.base.relay.noDeposit(within: 0.3), "no pin.change")
        }
    }

    /// A fetch of the latest blob that fails after the version moved: the "earlier request" refusal, nothing sent.
    @Test func aFailedFetchIsTheEarlierRequestRefusal() async throws {
        let h = try await lost.holder(timeout: 0.2)
        let (d, v, api) = (h.d, h.v, h.api)
        let task = change(api)
        try await ops.answer(v, d, "credential.version", #"{"exists":true,"version":2}"#)
        for _ in 0...VaultDevice.appRetries { #expect(try await lost.open(v).type == "credential.get") }
        do {
            _ = try await task.value
            Issue.record("sent")
        } catch let e as CredentialUnsettled {
            #expect(e.reason == .inFlight)
        }
    }

    /// The question goes unanswered (a locked vault does not handle its mailbox; a slow one): after the automatic resends
    /// of the same question, the change is refused with its failure and nothing else sent.
    @Test func noAnswerToTheVersionRefusesTheChange() async throws {
        let h = try await lost.holder(timeout: 0.2)
        let (v, api) = (h.v, h.api)
        let task = change(api)
        var asked: Set<String> = []
        for _ in 0...VaultDevice.appRetries {
            let q = try await lost.open(v)
            #expect(q.type == "credential.version")
            asked.insert(q.id)
        }
        #expect(asked.count == 1, "the same question")
        await #expect(throws: VaultStateError.self) { _ = try await task.value }
        #expect(await ops.base.relay.noDeposit(within: 0.4), "one question, no change")
    }

    /// An owner check still waiting for its answer holds the credential lock: the change waits for it (30 s at most, on
    /// the given sleep) and, once that check is answered, is sent with the version the check left.
    @Test func aChangeWaitsForAnOperationInFlight() async throws {
        let h = try await lost.holder()
        let pauses = Pauses()
        let (d, v) = (h.d, h.v)
        let api = VaultApi(device: d, normalizePasswords: { true }, changeWaitSleep: { try await pauses.sleep($0) })
        let check = Task { try await api.ownerCheck(pin: "975310", password: "pw") }
        let checkReq = try await lost.open(v)
        #expect(checkReq.type == VaultApi.typeOwnerCheck)
        let marked = Marked()
        let task = change(api, marked)
        #expect(await pauses.asked())
        #expect(pauses.lengths == [30])
        #expect(marked.change == nil, "no marker while waiting")
        #expect(await ops.base.relay.noDeposit(within: 0.2), "waiting")
        try await lost.deliver(v, d, Inner(id: Ulid.new(), type: checkReq.type, ts: Date(), re: checkReq.id, status: Inner.statusOK, body: Array(#"{"credential":"BAUG","version":2,"deadline":"2026-10-19T00:00:00Z","interval_seconds":86400,"hold":true}"#.utf8)))
        try await ops.answer(v, d, "credential.ack")
        _ = try await check.value
        // Settled: the change goes on, fixed on the version the check left.
        try await ops.answer(v, d, "credential.version", #"{"exists":true,"version":2}"#)
        try await ops.answer(v, d, VaultApi.typePinChange, #"{"credential":"BwgJ","version":3,"epoch_advanced":true}"#)
        try await ops.answer(v, d, "credential.ack")
        #expect(try await task.value && marked.change?.version == 2)
    }

    /// The operation in flight is still unanswered when the wait ends: the change is refused with nothing sent, and the
    /// lock is never handed to it afterwards.
    @Test func aChangeIsRefusedAfterTheWait() async throws {
        let h = try await lost.holder(timeout: 2)
        let pauses = Pauses()
        let (d, v) = (h.d, h.v)
        let api = VaultApi(device: d, normalizePasswords: { true }, changeWaitSleep: { try await pauses.sleep($0) })
        let check = Task { try await api.ownerCheck(pin: "975310", password: "pw") }
        let checkReq = try await lost.open(v)
        let task = change(api)
        #expect(await pauses.asked())
        pauses.release()
        do {
            _ = try await task.value
            Issue.record("sent")
        } catch let e as CredentialUnsettled {
            #expect(e.reason == .inFlight)
        }
        // The check's answer arrives: it completes, and the lock is free for the next operation.
        try await lost.deliver(v, d, Inner(id: Ulid.new(), type: checkReq.type, ts: Date(), re: checkReq.id, status: Inner.statusOK, body: Array(#"{"credential":"BAUG","version":2,"deadline":"2026-10-19T00:00:00Z","interval_seconds":86400,"hold":true}"#.utf8)))
        try await ops.answer(v, d, "credential.ack")
        _ = try await check.value
        let fetch = Task { try await api.credentialFetch() }
        try await ops.answer(v, d, "credential.get", #"{"credential":"BAUG","version":2}"#)
        try await ops.answer(v, d, "credential.ack")
        try await fetch.value
    }

    /// A renew goes through the same checks as a change (VAULT-MESSAGING 0.47.0 §11.14.9 step 1): a version that moved
    /// fetches the latest blob, and the renew goes with it, its record handed over only then.
    @Test func aRenewIsCheckedLikeAChange() async throws {
        let h = try await lost.holder()
        let (d, v, api) = (h.d, h.v, h.api)
        let marked = Marked()
        let task = Task { try await api.secretRenew(pin: "975310", password: "pw", newUnlockSecret: [UInt8](repeating: 7, count: 32), marked: marked) }
        try await ops.answer(v, d, "credential.version", #"{"exists":true,"version":2}"#)
        try await ops.answer(v, d, "credential.get", #"{"credential":"BAUG","version":2}"#)
        try await ops.answer(v, d, "credential.ack")
        let req = try await ops.answer(v, d, VaultApi.typeSecretRenew, #"{"credential":"BwgJ","version":3}"#)
        #expect(try StrictJson.parseObject(req.body).string("credential") == "BAUG")
        #expect(req.id == marked.change?.id && marked.change?.version == 2)
        try await ops.answer(v, d, "credential.ack")
        try await task.value
        #expect(d.credentialVersion == 3)
    }

    /// `stale_credential` to a renew means it did not apply: not retried, the latest blob fetched, the refusal thrown.
    @Test func aStaleRenewIsNotRetried() async throws {
        let h = try await lost.holder()
        let (d, v, api) = (h.d, h.v, h.api)
        let marked = Marked()
        let task = Task { try await api.secretRenew(pin: "975310", password: "pw", newUnlockSecret: [UInt8](repeating: 7, count: 32), marked: marked) }
        try await ops.answer(v, d, "credential.version", #"{"exists":true,"version":1}"#)
        let req = try await ops.answer(v, d, VaultApi.typeSecretRenew, code: "stale_credential", errorBody: "{}")
        #expect(req.id == marked.change?.id)
        try await ops.answer(v, d, "credential.get", #"{"credential":"BAUG","version":2}"#)
        try await ops.answer(v, d, "credential.ack")
        await #expect(throws: VaultOpError.self) { try await task.value }
        #expect(await ops.base.relay.noDeposit(within: 0.3), "no second renew")
        #expect(await d.credentialSettled(), "its answer settled it")
    }

    /// A credential request without its answer stays unsettled; an answer to another request settles it only when its
    /// `ts` is more than a minute after the request's `exp` (VAULT-MESSAGING 0.46.0 §11.14.9 step 1).
    @Test func anUnansweredRequestIsSettledByALaterAnswer() async throws {
        let clock = LostAnswerTests.PhoneClock()
        let h = try await lost.holder(timeout: 0.2, clock: clock)
        let (d, v, api) = (h.d, h.v, h.api)
        let check = Task { try await api.ownerCheck(pin: "975310", password: "pw") }
        for _ in 0...VaultDevice.appRetries { #expect(try await lost.open(v).type == VaultApi.typeOwnerCheck) }
        _ = await check.result
        #expect(!(await d.credentialSettled()))
        // The phone's clock moves with the vault's, so that their answers are not dropped as from the future.
        clock.advance(ChangeRequest.validFor + 2 * VaultDevice.settleMargin)
        for (ahead, settles) in [(ChangeRequest.validFor, false), (ChangeRequest.validFor + 2 * VaultDevice.settleMargin, true)] {
            let q = Task { try await api.credentialVersionStamped() }
            let req = try await lost.open(v)
            try await lost.deliver(v, d, Inner(id: Ulid.new(), type: req.type, ts: Date().addingTimeInterval(ahead), re: req.id, status: Inner.statusOK, body: Array(#"{"exists":true,"version":2}"#.utf8)))
            _ = try await q.value
            #expect(await d.credentialSettled() == settles, "\(ahead)")
        }
    }

    /// In a quiet session, once the phone's estimate says every pending request has expired, the wait asks
    /// `credential.version` once for a stamped time, which settles them.
    @Test func aQuietSessionAsksForTheVaultsTime() async throws {
        let up = LostAnswerTests.Uptime()
        let clock = LostAnswerTests.PhoneClock()
        let h = try await lost.holder(timeout: 0.2, uptime: up, clock: clock)
        let (d, v, api) = (h.d, h.v, h.api)
        let check = Task { try await api.ownerCheck(pin: "975310", password: "pw") }
        for _ in 0...VaultDevice.appRetries { _ = try await lost.open(v) }
        _ = await check.result
        up.advance(ChangeRequest.validFor + 2 * VaultDevice.settleMargin)
        clock.advance(ChangeRequest.validFor + 2 * VaultDevice.settleMargin)
        let wait = Task { await d.awaitCredentialSettled(within: 5, sleep: VaultApi.sleep) }
        let probe = try await lost.open(v)
        #expect(probe.type == "credential.version")
        try await lost.deliver(v, d, Inner(id: Ulid.new(), type: probe.type, ts: d.vaultNow(), re: probe.id, status: Inner.statusOK, body: Array(#"{"exists":true,"version":2}"#.utf8)))
        #expect(await wait.value)
    }

    /// A renew waits for the earlier requests to settle too (VAULT-MESSAGING 0.47.0 §11.14.9 step 1), and nothing is
    /// stored for it when they do not.
    @Test func aRenewWaitsForTheEarlierRequests() async throws {
        let h = try await lost.holder(timeout: 2)
        let pauses = Pauses()
        let (d, v) = (h.d, h.v)
        let api = VaultApi(device: d, normalizePasswords: { true }, changeWaitSleep: { try await pauses.sleep($0) })
        let check = Task { try await api.ownerCheck(pin: "975310", password: "pw") }
        _ = try await lost.open(v)
        let marked = Marked()
        let renew = Task { try await api.secretRenew(pin: "975310", password: "pw", newUnlockSecret: [UInt8](repeating: 7, count: 32), marked: marked) }
        #expect(await pauses.asked())
        pauses.release()
        await #expect(throws: CredentialUnsettled.self) { try await renew.value }
        #expect(marked.change == nil)
        check.cancel()
        _ = await check.result
    }

    /// A renew runs the credential gate under the lock, as every credential operation does: refused there, nothing is
    /// asked of the vault.
    @Test func aRenewRunsTheCredentialGate() async throws {
        struct Refused: Error {}
        let h = try await lost.holder()
        let api = VaultApi(device: h.d, normalizePasswords: { true }, credentialGate: { carriesPin in
            if carriesPin { throw Refused() }
        })
        await #expect(throws: Refused.self) {
            try await api.secretRenew(pin: "975310", password: "pw", newUnlockSecret: [UInt8](repeating: 7, count: 32), marked: Marked())
        }
        #expect(await ops.base.relay.noDeposit(within: 0.3), "nothing asked")
    }

    /// VAULT-MESSAGING 0.47.0 §11.14.9 step 2: an operation that began before a change or a renew went out, and waited
    /// for the credential lock meanwhile, is refused with nothing sent, also when no gate sees that change any more (it
    /// was answered and decided before the operation got the lock). Here the test holds the lock as the change would.
    @Test func anOperationThatWaitedWhileASecretWentOutIsRefused() async throws {
        // A short wait for answers: an operation sent by mistake fails fast, after the deposit checked below.
        let h = try await lost.holder(timeout: 0.3)
        let (d, api) = (h.d, h.api)
        // Two plain cases (an array of async closures crashed the Xcode 26.6 test runner).
        await d.credentialLock.acquire()
        let check = Task { _ = try await api.ownerCheck(pin: "975310", password: "pw") }
        try await expectRefusedAfterASecret(d, check)
        await d.credentialLock.acquire()
        let renew = Task {
            _ = try await api.secretRenew(pin: "975310", password: "pw", newUnlockSecret: [UInt8](repeating: 7, count: 32), marked: Marked())
        }
        try await expectRefusedAfterASecret(d, renew)
    }

    /// [op] waits on the credential lock held here, a secret goes out meanwhile, and [op] is then refused, nothing sent.
    private func expectRefusedAfterASecret(_ d: VaultDevice, _ op: Task<Void, Error>) async throws {
        for _ in 0..<500 where d.credentialLock.waiting == 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(d.credentialLock.waiting == 1, "queued")
        d.secretSent()
        d.credentialLock.release()
        #expect(await ops.base.relay.noDeposit(within: 0.3), "nothing sent")
        do {
            try await op.value
            Issue.record("sent")
        } catch let e as CredentialUnsettled {
            #expect(e.reason == .inFlight)
        }
    }

    /// The wait ends at its limit even while its probe of the vault's time is still waiting for an answer.
    @Test func theSettleWaitEndsAtItsLimitDuringTheProbe() async throws {
        let up = LostAnswerTests.Uptime()
        let h = try await lost.holder(timeout: 5, uptime: up)
        let (d, v, api) = (h.d, h.v, h.api)
        let check = Task { try await api.ownerCheck(pin: "975310", password: "pw") }
        _ = try await lost.open(v)
        check.cancel()
        _ = await check.result
        up.advance(ChangeRequest.validFor + 2 * VaultDevice.settleMargin)
        let started = Date()
        let wait = Task { await d.awaitCredentialSettled(within: 0.5, sleep: VaultApi.sleep) }
        // The settle wait flushes the outbox first, so the cancelled owner check's copy may come before the probe.
        var type = try await lost.open(v).type
        for _ in 0..<2 where type != "credential.version" { type = try await lost.open(v).type }
        #expect(type == "credential.version", "the probe")
        #expect(await wait.value == false)
        #expect(Date().timeIntervalSince(started) < 3, "not the probe's 5 s")
    }
}

// swiftlint:enable line_length
