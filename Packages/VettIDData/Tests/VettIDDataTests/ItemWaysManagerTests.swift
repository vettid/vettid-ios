import Foundation
import Testing
import VettIDCrypto
@testable import VettIDData
import VettIDDataTesting
@testable import VettIDVault

// Fixtures stay on one line each.
// swiftlint:disable line_length

/// TEST ONLY. The vault calls of ``ItemWaysManager``: the sets sent, the failures to answer with, the answers, and gates for the
/// read and the save.
@MainActor
final class FakeItemWaysOps: ItemWaysOps {
    var sets: [[UInt8]] = []
    var refuse: [String] = []
    var detail = ""
    var answer = #"{"agent_id":"a1","item_id":"i1","version":2,"ways":["use","reveal"]}"#
    var listed = #"{"items":[{"agent_id":"a1","item_id":"i1","version":1,"ways":["use"]}]}"#
    var listGate: TestDeferred<Void>?
    var setGate: TestDeferred<Void>?
    let setEntered = TestDeferred<Void>()
    let listEntered = TestDeferred<Void>()

    func list(_ agentID: String, _ itemID: String?) async throws -> [UInt8] {
        listEntered.complete(())
        if let g = listGate { try await g.value() }
        return Array(listed.utf8)
    }

    func set(_ body: [UInt8]) async throws -> [UInt8] {
        sets.append(body)
        setEntered.complete(())
        if let g = setGate { try await g.value() }
        if !refuse.isEmpty { throw VaultOpError(type: "leash.item.set", code: refuse.removeFirst(), detail: detail, body: nil) }
        return Array(answer.utf8)
    }

    /// The `i`th body sent, as an object.
    func sent(_ i: Int = 0) throws -> JsonObject { try StrictJson.parseObject(sets[i]) }
}

/// The unlock window of a test: the calls made, and what the open and the lock do.
@MainActor
final class FakeWindow {
    var until: Date?
    var calls: [String] = []
    var unlockFails: (any Error)?
    var lockFails = false
}

/// ANDROID-PLAN 0.1.137 AA7 "Saving": the password for a widening, the answers, a read-only page's save. Mirrors vettid-android
/// `ItemWaysManagerTest`.
@MainActor
@Suite(.serialized) struct ItemWaysManagerTests {
    let now = OwnerCheckManager.instant("2026-11-22T12:00:00Z")!

    func manager(_ ops: FakeItemWaysOps, _ w: FakeWindow) -> ItemWaysManager {
        let at = now
        return ItemWaysManager(
            ops: { ops },
            windowUntil: { w.until },
            openWindow: { p in
                w.calls.append("unlock:\(p)")
                if let e = w.unlockFails { throw e }
            },
            closeWindow: {
                w.calls.append("lock")
                if w.lockFails { throw VaultFailure(.network) }
            },
            unlockTtl: { 300 },
            now: { at }
        )
    }

    func read(_ json: String) throws -> ItemWaysRead { try #require(ItemWaysRules.one(Array(json.utf8))) }

    var useOnly: ItemWaysRead { get throws { try read(#"{"agent_id":"a1","item_id":"i1","version":1,"ways":["use"]}"#) } }

    func withReveal() throws -> ItemWays {
        var w = try #require(try useOnly.ways)
        w.ways = [.use, .reveal]
        return w
    }

    func narrowed(_ cur: ItemWaysRead) throws -> ItemWays {
        var n = try #require(cur.ways)
        n.ways = [.use]
        return n
    }

    @Test func aWideningAsksForThePasswordAndLocksTheWindowItOpened() async throws {
        let ops = FakeItemWaysOps()
        let w = FakeWindow()
        let m = manager(ops, w)
        let cur = try useOnly
        let next = try withReveal()
        guard case .needsPassword = try await m.save(cur, next, password: nil) else { Issue.record("no prompt"); return }
        #expect(ops.sets.isEmpty && w.calls.isEmpty)
        let saved = try await m.save(cur, next, password: "pw")
        guard case .saved(let r) = saved else { Issue.record("not saved: \(saved)"); return }
        #expect(w.calls == ["unlock:pw", "lock"])
        #expect(ops.sets.single == next.setBody())
        #expect(r.ways?.version == 2)
    }

    @Test func aWindowAlreadyOpenIsLeftOpenButThePasswordIsStillAsked() async throws {
        let w = FakeWindow()
        w.until = now.addingTimeInterval(300)
        let m = manager(FakeItemWaysOps(), w)
        let cur = try useOnly
        let next = try withReveal()
        guard case .needsPassword = try await m.save(cur, next, password: nil) else { Issue.record("no prompt"); return }
        _ = try await m.save(cur, next, password: "pw")
        #expect(w.calls == ["unlock:pw"])
        // A window about to end counts as closed (the phone's clock may be off): locked after.
        let w2 = FakeWindow()
        w2.until = now.addingTimeInterval(10)
        _ = try await manager(FakeItemWaysOps(), w2).save(cur, next, password: "pw")
        #expect(w2.calls == ["unlock:pw", "lock"])
    }

    @Test func aNarrowingIsSentWithoutThePassword() async throws {
        let ops = FakeItemWaysOps()
        let w = FakeWindow()
        let cur = try read(#"{"agent_id":"a1","item_id":"i1","version":1,"ways":["use","reveal"]}"#)
        let saved = try await manager(ops, w).save(cur, try narrowed(cur), password: nil)
        guard case .saved = saved else { Issue.record("not saved: \(saved)"); return }
        #expect(w.calls.isEmpty)
        #expect(ops.sets.count == 1)
    }

    @Test func credentialLockedPromptsOnceThenSaysItLockedAgain() async throws {
        let cur = try read(#"{"agent_id":"a1","item_id":"i1","version":1,"ways":["use","reveal"]}"#)
        let next = try narrowed(cur)
        let ops = FakeItemWaysOps()
        ops.refuse = ["credential_locked", "credential_locked"]
        let m = manager(ops, FakeWindow())
        guard case .credentialLocked = try await m.save(cur, next, password: nil) else { Issue.record("not credentialLocked"); return }
        guard case .lockedAgain = try await m.save(cur, next, password: "pw", resent: true) else { Issue.record("not lockedAgain"); return }
        // The resend with the password opens the window and locks it after, as a widening does.
        let w = FakeWindow()
        let ops2 = FakeItemWaysOps()
        ops2.refuse = ["credential_locked"]
        let m2 = manager(ops2, w)
        guard case .credentialLocked = try await m2.save(cur, next, password: nil) else { Issue.record("not credentialLocked"); return }
        guard case .saved = try await m2.save(cur, next, password: "pw", resent: true) else { Issue.record("not saved"); return }
        #expect(w.calls == ["unlock:pw", "lock"])
        #expect(ops2.sets.count == 2)
    }

    @Test func aCancelledSaveStillLocksTheWindow() async throws {
        let ops = FakeItemWaysOps()
        ops.setGate = TestDeferred<Void>()
        let w = FakeWindow()
        let m = manager(ops, w)
        let cur = try useOnly
        let next = try withReveal()
        let job = Task { @MainActor in try await m.save(cur, next, password: "pw") }
        try await ops.setEntered.value() // the save waits for the vault
        #expect(w.calls == ["unlock:pw"])
        job.cancel()
        let result = await job.result
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(w.calls == ["unlock:pw", "lock"])
    }

    @Test func aLockThatFailsIsTold() async throws {
        let w = FakeWindow()
        w.lockFails = true
        let m = manager(FakeItemWaysOps(), w)
        #expect(m.windowNotClosed == nil)
        guard case .saved = try await m.save(try useOnly, try withReveal(), password: "pw") else { Issue.record("not saved"); return }
        #expect(m.windowNotClosed?.ttlSeconds == 300)
        w.lockFails = false
        try await m.closeWindowNow()
        #expect(m.windowNotClosed == nil)
    }

    @Test func settingsOfAnotherItemAskForThePassword() async throws {
        let cur = try read(#"{"agent_id":"a1","item_id":"i1","version":1,"ways":["use","reveal"]}"#)
        var other = try narrowed(cur)
        other.itemID = "i2"
        guard case .needsPassword = try await manager(FakeItemWaysOps(), FakeWindow()).save(cur, other, password: nil) else { Issue.record("no prompt"); return }
    }

    @Test func aReadAnsweredAfterAClearIsNotKept() async throws {
        let ops = FakeItemWaysOps()
        ops.listGate = TestDeferred<Void>()
        let m = manager(ops, FakeWindow())
        let job = Task { @MainActor in try await m.list("a1") }
        try await ops.listEntered.value()
        m.clear()
        ops.listGate?.complete(())
        let r = await job.result
        #expect((r.error as? VaultFailure)?.code == "voided_by_lock")
        #expect(m.items.isEmpty)
        // The same for one item's read.
        let ops2 = FakeItemWaysOps()
        ops2.listGate = TestDeferred<Void>()
        let m2 = manager(ops2, FakeWindow())
        let job2 = Task { @MainActor in try await m2.read("a1", "i1") }
        try await ops2.listEntered.value()
        m2.clear()
        ops2.listGate?.complete(())
        let r2 = await job2.result
        #expect((r2.error as? VaultFailure)?.code == "voided_by_lock")
    }

    @Test func oneItemsReadUpdatesTheHeldList() async throws {
        let ops = FakeItemWaysOps()
        let m = manager(ops, FakeWindow())
        _ = try await m.list("a1")
        ops.listed = #"{"items":[{"agent_id":"a1","item_id":"i1","version":7,"ways":["use","reveal"]}]}"#
        #expect(try await m.read("a1", "i1")?.ways?.version == 7)
        #expect(m.items["a1"]?.first?.ways?.version == 7)
        ops.listed = #"{"items":[]}"#
        #expect(try await m.read("a1", "i1") == nil)
        #expect(m.items["a1"]?.isEmpty == true)
        // An answer that is not a list is a failure, never "not included".
        ops.listed = "{}"
        await #expect(throws: VaultFailure.self) { _ = try await m.read("a1", "i1") }
        do {
            _ = try await m.read("a1", "i1")
        } catch {
            #expect((error as? VaultFailure)?.code == "unreadable_settings")
        }
    }

    /// A save the vault answers after a clear is saved, but the list held from before is not touched.
    @Test func aSaveAnsweredAfterAClearLeavesTheListAlone() async throws {
        let ops = FakeItemWaysOps()
        let m = manager(ops, FakeWindow())
        _ = try await m.list("a1")
        let cur = try read(#"{"agent_id":"a1","item_id":"i1","version":1,"ways":["use","reveal"]}"#)
        ops.setGate = TestDeferred<Void>()
        ops.answer = #"{"agent_id":"a1","item_id":"i1","version":2,"ways":["use"]}"#
        let job = Task { @MainActor in try await m.save(cur, try narrowed(cur), password: nil) }
        try await ops.setEntered.value()
        m.clear()
        // Listed again after the clear, before the late answer: the fresh entry stays.
        _ = try await m.list("a1")
        ops.setGate?.complete(())
        _ = try await job.value
        #expect(m.items["a1"]?.map { $0.ways?.version } == [1])
    }

    /// A read or a save of a1's i1 replaces that entry only: a2's list and a1's other item stay as they were.
    @Test func aReadOrASaveTouchesItsOwnEntryOnly() async throws {
        let ops = FakeItemWaysOps()
        let m = manager(ops, FakeWindow())
        ops.listed = #"{"items":[{"agent_id":"a1","item_id":"i1","version":1,"ways":["use"]},{"agent_id":"a1","item_id":"i2","version":1,"ways":["use"]}]}"#
        _ = try await m.list("a1")
        ops.listed = #"{"items":[{"agent_id":"a2","item_id":"i1","version":4,"ways":["use"]}]}"#
        _ = try await m.list("a2")
        ops.listed = #"{"items":[{"agent_id":"a1","item_id":"i1","version":7,"ways":["use"]}]}"#
        _ = try await m.read("a1", "i1")
        #expect(m.items["a1"]?.map { $0.ways?.version } == [7, 1])
        #expect(m.items["a2"]?.map { $0.ways?.version } == [4])
        let cur = try read(#"{"agent_id":"a1","item_id":"i1","version":7,"ways":["use","reveal"]}"#)
        ops.answer = #"{"agent_id":"a1","item_id":"i1","version":8,"ways":["use"]}"#
        _ = try await m.save(cur, try narrowed(cur), password: nil)
        #expect(m.items["a1"]?.map { $0.ways?.version } == [8, 1])
        #expect(m.items["a2"]?.map { $0.ways?.version } == [4])
    }

    /// Another agent's entry held in a1's list (a2/i1, foreign and read only) is never replaced by a1/i1's read or save,
    /// even when it is listed first.
    @Test func aForeignEntryWithTheSameItemIsKept() async throws {
        let ops = FakeItemWaysOps()
        let m = manager(ops, FakeWindow())
        let both = #"{"items":[{"agent_id":"a2","item_id":"i1","version":4,"ways":["use"]},{"agent_id":"a1","item_id":"i1","version":1,"ways":["use","reveal"]}]}"#
        ops.listed = both
        _ = try await m.list("a1")
        func foreignKept() -> Bool {
            guard let f = m.items["a1"]?.first else { return false }
            return f.foreign && f.readOnly && f.agentID == "a2"
        }
        #expect(foreignKept())
        let read = try #require(try await m.read("a1", "i1"))
        #expect(read.agentID == "a1" && !read.readOnly)
        #expect(foreignKept())
        #expect(m.items["a1"]?.last?.agentID == "a1")
        ops.answer = #"{"agent_id":"a1","item_id":"i1","version":2,"ways":["use"]}"#
        _ = try await m.save(read, try narrowed(read), password: nil)
        #expect(foreignKept())
        #expect(m.items["a1"]?.last?.ways?.version == 2)
    }

    @Test func aListThatIsNotAListIsAFailureNotNoItems() async throws {
        let ops = FakeItemWaysOps()
        ops.listed = "[]"
        let m = manager(ops, FakeWindow())
        do {
            _ = try await m.list("a1")
            Issue.record("no failure")
        } catch {
            #expect((error as? VaultFailure)?.code == "unreadable_settings")
        }
        #expect(m.items.isEmpty)
    }

    @Test func turningOffAWayOnAnEditablePageDropsItsSettings() async throws {
        let cur = try read(#"{"agent_id":"a1","item_id":"i1","version":1,"ways":["use","proxy"],"proxy":{"hosts":["a.example.com"],"header":"X"}}"#)
        let ops = FakeItemWaysOps()
        var next = try #require(cur.ways)
        next.ways = [.use]
        next.proxy = nil
        _ = try await manager(ops, FakeWindow()).save(cur, next, password: nil)
        #expect(try ops.sent()["proxy"] == nil)
    }

    @Test func eachAnswer() async throws {
        let cases: [(String, String)] = [
            ("conflict", "Conflict"), ("not_found", "NotIncluded"), ("owner_check_required", "OwnerCheck"), ("bad_request", "BadRequest"),
        ]
        for (code, want) in cases {
            let ops = FakeItemWaysOps()
            ops.refuse = [code]
            ops.detail = "program: refused name"
            let r = try await manager(ops, FakeWindow()).save(try useOnly, try withReveal(), password: "pw")
            #expect(r.description == want, Comment(rawValue: code))
            if case .badRequest(let text) = r { #expect(text == "program: refused name") }
        }
        // Any other code is a failure with its text.
        let other = FakeItemWaysOps()
        other.refuse = ["limit"]
        guard case .failed = try await manager(other, FakeWindow()).save(try useOnly, try withReveal(), password: "pw") else { Issue.record("not failed"); return }
        // An answer that does not read strictly is still the vault's: saved, and read only.
        let unreadable = FakeItemWaysOps()
        unreadable.answer = #"{"agent_id":"a1","item_id":"i1","ways":["use"],"x":1}"#
        let r = try await manager(unreadable, FakeWindow()).save(try useOnly, try withReveal(), password: "pw")
        guard case .saved(let read) = r else { Issue.record("not saved"); return }
        #expect(read.readOnly, "an answer that does not read strictly is still the vault's")
    }

    @Test func theUnlocksRefusals() async throws {
        let cases: [(FailureKind, String)] = [
            (.badPassword, "PasswordRefused"), (.backoff, "PasswordRefused"), (.credentialFrozen, "AlarmOpen"),
            (.rotationRequired, "AlarmOpen"), (.ownerCheckRequired, "OwnerCheck"),
        ]
        for (kind, want) in cases {
            let ops = FakeItemWaysOps()
            let w = FakeWindow()
            w.unlockFails = VaultFailure(kind)
            let r = try await manager(ops, w).save(try useOnly, try withReveal(), password: "pw")
            #expect(r.description == want, Comment(rawValue: "\(kind)"))
            #expect(ops.sets.isEmpty, Comment(rawValue: "\(kind) sent the settings"))
            #expect(w.calls == ["unlock:pw"], Comment(rawValue: "\(kind): a definite refusal opened nothing to lock"))
        }
        // A failure that may have come after the window opened: locked.
        let w = FakeWindow()
        w.unlockFails = VaultFailure(.network)
        let r = try await manager(FakeItemWaysOps(), w).save(try useOnly, try withReveal(), password: "pw")
        guard case .failed = r else { Issue.record("not failed"); return }
        #expect(w.calls == ["unlock:pw", "lock"])
    }

    @Test func aReadOnlyPageTurnsAWayOffWithoutThePrompt() async throws {
        let cur = try read(#"{"agent_id":"a1","item_id":"i1","version":4,"ways":["use","reveal","run"],"run":{"programs":[],"each":true,"x":1}}"#)
        #expect(cur.readOnly)
        let ops = FakeItemWaysOps()
        let w = FakeWindow()
        let m = manager(ops, w)
        let refused = try await m.save(cur, try withReveal(), password: "pw")
        guard case .failed(let f) = refused else { Issue.record("not failed"); return }
        #expect(f.code == "unreadable_settings")
        #expect(ops.sets.isEmpty && w.calls.isEmpty)
        let off = try await m.turnOff(cur, "run")
        guard case .saved = off else { Issue.record("not saved: \(off)"); return }
        #expect(try ops.sent()["run"] == nil)
        let locked = FakeItemWaysOps()
        locked.refuse = ["credential_locked"]
        guard case .readOnlyLocked = try await manager(locked, w).turnOff(cur, "reveal") else { Issue.record("not readOnlyLocked"); return }
        #expect(locked.sets.count == 1)
        #expect(w.calls.isEmpty)
    }

    /// An answer that is not the settings sent (another item, or `{}`) is not taken as saved.
    @Test func anAnswerForAnotherItemIsNotSaved() async throws {
        for a in [#"{"agent_id":"a1","item_id":"i2","version":2,"ways":["use"]}"#, "{}"] {
            let ops = FakeItemWaysOps()
            ops.answer = a
            let r = try await manager(ops, FakeWindow()).save(try useOnly, try withReveal(), password: "pw")
            guard case .failed(let f) = r else { Issue.record("saved: \(a)"); return }
            #expect(f.code == "unreadable_settings", Comment(rawValue: a))
        }
    }

    /// Settings of another version than the one read can't be judged: a widening.
    @Test func anotherVersionIsJudgedAWidening() async throws {
        let cur = try read(#"{"agent_id":"a1","item_id":"i1","version":1,"ways":["use","reveal"]}"#)
        var next = try narrowed(cur)
        next.version = 2
        guard case .needsPassword = try await manager(FakeItemWaysOps(), FakeWindow()).save(cur, next, password: nil) else { Issue.record("no prompt"); return }
    }

    @Test func theVaultsTextIsNeverPrinted() {
        #expect(ItemWaysSave.badRequest("secret detail").description == "BadRequest")
        #expect(!"\(ItemWaysSave.badRequest("secret detail"))".contains("secret"))
    }

    @Test func theListIsHeldUntilCleared() async throws {
        let m = manager(FakeItemWaysOps(), FakeWindow())
        #expect(try await m.list("a1").count == 1)
        #expect(m.items["a1"]?.count == 1)
        _ = try await m.save(try useOnly, try withReveal(), password: "pw")
        #expect(m.items["a1"]?.first?.ways?.version == 2)
        m.clear()
        #expect(m.items.isEmpty)
    }

    /// The wire: what the vault manager's ops send, end to end against the fake vault (list, then a save), and a lock forgets.
    @Test func theListIsReadOverTheSessionAndALockAndAHoldForgetIt() async throws {
        let service = try FakeVaultService()
        let phone = try TestVaultPhone(service: service)
        defer { phone.close() }
        let m = phone.manager
        let pin = "402817"
        let password = "correct horse battery"
        _ = try await m.redeemSetupCode(.secret(service.secret))
        try await m.enroll(pin: pin) { _ in }
        try await m.createCredential(password: password, backup: true, pin: pin) { _ in }
        try await m.finishSetup()
        let items = try await m.itemWays.list("a1")
        #expect(items.count == 1 && items.first?.ways?.itemID == "i1")
        #expect(m.itemWays.items["a1"]?.count == 1)
        let first = try #require(items.first)
        var next = try #require(first.ways)
        next.ways = [.use]
        guard case .saved(let r) = try await m.itemWays.save(first, next, password: nil) else { Issue.record("not saved"); return }
        #expect(r.ways?.version == 2)
        // A hold forgets the list, as a lock does (IOS-PLAN §6.9).
        m.ownerChecks.onHeldChange(true)
        #expect(m.itemWays.items.isEmpty)
        _ = try await m.itemWays.list("a1")
        #expect(!m.itemWays.items.isEmpty)
        try await m.lock()
        #expect(m.itemWays.items.isEmpty)
    }
}

private extension Array {
    /// The one element; the test fails when there is not exactly one.
    var single: Element? { count == 1 ? first : nil }
}

private extension Result {
    var error: Failure? { if case .failure(let e) = self { e } else { nil } }
}

// swiftlint:enable line_length
