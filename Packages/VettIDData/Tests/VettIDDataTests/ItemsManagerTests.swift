import Foundation
import Testing
import VettIDCrypto
@testable import VettIDData
import VettIDDataTesting
@testable import VettIDVault

// Fixtures stay on one line each; the recorded calls are tuples.
// swiftlint:disable line_length large_tuple

/// TEST ONLY. A value behind a lock: the fake's calls run off the main actor while the test reads them on it.
@propertyWrapper
final class TestLocked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(wrappedValue: Value) { value = wrappedValue }

    var wrappedValue: Value {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
        _modify {
            lock.lock()
            defer { lock.unlock() }
            yield &value
        }
    }
}

/// TEST ONLY. The vault calls of ``ItemsManager``: every call recorded, answers set by the test; every member behind a
/// lock. Mirrors the `Ops` of vettid-android's `ItemsManagerTest`.
final class FakeItemOps: ItemOps, @unchecked Sendable {
    @TestLocked var calls: [String] = []
    @TestLocked var pages: [ItemPage] = []
    @TestLocked var items: [String: Item] = [:]
    @TestLocked var revealed: [String: Item] = [:]
    @TestLocked var plaintext: [UInt8] = []
    /// The opened values the last critical reveal handed out, to check that the manager wiped them.
    @TestLocked var handedOut: SecretBytes?
    /// `item.put` and its dry run fail with this.
    @TestLocked var error: VaultOpError?
    /// A critical reveal fails with this (after the gate and the metadata).
    @TestLocked var revealError: VaultOpError?
    /// The next critical `item.put` fails with this code (an older vault refusing kept values: `bad_request`).
    @TestLocked var criticalError: String?
    @TestLocked var effect = "{}"
    @TestLocked var dryRuns: [(String?, Int64?, String?, [String]?)] = []
    @TestLocked var puts: [(content: ItemContent, sensitivity: String?, tags: [String]?, itemID: String?, version: Int64?)] = []
    @TestLocked var deletes: [(String, String?)] = []
    @TestLocked var sensitivities: [(String, Int64, String, String?)] = []
    /// Set: `item.reveal` (both forms) waits for it.
    @TestLocked var revealGate: TestDeferred<Void>?
    /// Set: `item.put` waits for it.
    @TestLocked var putGate: TestDeferred<Void>?

    private func err() throws { if let error { throw error } }

    func list(after: String?, limit: Int) async throws -> ItemPage {
        calls.append("list:\(after ?? "nil"):\(limit)")
        return pages.isEmpty ? ItemPage() : pages.removeFirst()
    }

    func get(_ itemID: String) async throws -> Item {
        calls.append("get")
        guard let i = items[itemID] else { throw VaultOpError(type: "item.get", code: "not_found", detail: "", body: nil) }
        return i
    }

    func reveal(_ itemID: String) async throws -> Item {
        calls.append("reveal")
        if let revealGate { try await revealGate.value() }
        guard let i = revealed[itemID] else { throw VaultOpError(type: "item.reveal", code: "not_found", detail: "", body: nil) }
        return i
    }

    func revealCritical(password: String, itemID: String) async throws -> SecretBytes {
        calls.append("revealCritical:\(password)")
        if let revealGate { try await revealGate.value() }
        if let revealError { throw revealError }
        let box = SecretBytes(plaintext)
        handedOut = box
        return box
    }

    func put(_ content: ItemContent, sensitivity: String?, tags: [String]?, itemID: String?, version: Int64?) async throws -> ItemRef {
        calls.append("put")
        if let putGate { try await putGate.value() }
        try err()
        puts.append((content, sensitivity, tags, itemID, version))
        return ItemRef(itemID: itemID ?? "01NEW", version: (version ?? 0) + 1)
    }

    func putCritical(password: String, content: ItemContent, tags: [String]?, itemID: String?, version: Int64?) async throws -> ItemRef {
        calls.append("putCritical:\(password)")
        if let code = criticalError {
            criticalError = nil
            throw VaultOpError(type: "item.put", code: code, detail: "", body: nil)
        }
        puts.append((content, "critical", tags, itemID, version))
        return ItemRef(itemID: itemID ?? "01CRIT", version: (version ?? 0) + 1, credentialVersion: 9)
    }

    func tag(_ itemID: String, version: Int64, tags: [String]) async throws -> Int64 {
        calls.append("tag:\(tags)")
        return version + 1
    }

    func putDryRun(itemID: String?, version: Int64?, sensitivity: String?, tags: [String]?) async throws -> JsonObject {
        calls.append("dryRun")
        try err()
        dryRuns.append((itemID, version, sensitivity, tags))
        return try StrictJson.parseObject(effect)
    }

    func sensitivity(_ itemID: String, version: Int64, sensitivity: String, password: String?) async throws -> Int64 {
        sensitivities.append((itemID, version, sensitivity, password))
        return version + 1
    }

    func delete(_ itemID: String, password: String?) async throws { deletes.append((itemID, password)) }

    static func item(_ id: String, _ name: String, _ s: String = "data", fields: [ItemField] = [], hasNotes: Bool = false, notes: String? = nil, size: Int64? = nil) -> Item {
        Item(itemID: id, version: 2, name: name, category: "identity_document", sensitivity: s, tags: ["travel"], fields: fields, notes: notes, hasNotes: hasNotes, size: size)
    }

    static func field(_ id: String?, _ label: String, _ kind: String, _ json: String? = nil) -> ItemField {
        ItemField(fieldID: id, label: label, kind: kind, valueJSON: json)
    }
}

/// The items repository over the vault calls (VAULT-MESSAGING §10.7): parsing, the critical path, checks, sync and the
/// clears. Mirrors vettid-android `ItemsManagerTest`.
@MainActor
@Suite struct ItemsManagerTests {
    let ops = FakeItemOps()
    let m: ItemsManager

    init() {
        let ops = ops
        m = ItemsManager(ops: { ops }, debounce: .milliseconds(10))
    }

    func failure(_ body: () async throws -> some Any) async -> VaultFailure? {
        do {
            _ = try await body()
            return nil
        } catch {
            return error as? VaultFailure
        }
    }

    @Test func theListIsReadPageByPage() async throws {
        ops.pages = [ItemPage(items: [FakeItemOps.item("01A", "Passport")], next: "01A"), ItemPage(items: [FakeItemOps.item("01B", "Login", "secret")])]
        try await m.refresh()
        #expect(ops.calls == ["list:nil:500", "list:01A:500"])
        #expect(m.items.map(\.name) == ["Passport", "Login"] && m.items[1].sensitivity == .secret && m.load == .loaded)
        #expect(m.names == ["01A": "Passport", "01B": "Login"])
    }

    @Test func aDataItemComesWithItsValuesAndAddresses() async throws {
        ops.items["01A"] = FakeItemOps.item("01A", "Licence", fields: [FakeItemOps.field("f1", "Number", "text", #""X1""#), FakeItemOps.field("f2", "Address", "address", #"{"city":"Berlin","country":"DE"}"#)])
        let d = try await m.get("01A")
        #expect(d.revealed && d.fields[0].value == .text("X1"))
        #expect(d.fields[1].value == .address(AddressValue(city: "Berlin", country: "DE")))
    }

    @Test func aSecretItemComesWithoutValuesUntilRevealed() async throws {
        ops.items["01S"] = FakeItemOps.item("01S", "Login", "secret", fields: [FakeItemOps.field("f1", "Password", "password")], hasNotes: true)
        ops.revealed["01S"] = FakeItemOps.item("01S", "Login", "secret", fields: [FakeItemOps.field("f1", "Password", "password", #""hunter2""#)], notes: "n")
        let hidden = try await m.get("01S")
        #expect(!hidden.revealed && hidden.fields[0].value == nil && hidden.hasNotes)
        let shown = try await m.reveal("01S")
        #expect(shown.revealed && shown.fields[0].value == .text("hunter2") && shown.notes == "n")
        #expect(!shown.hidden().revealed && shown.hidden().fields[0].value == nil && shown.hidden().notes == nil)
    }

    @Test func aCriticalItemOpensWithThePasswordAndThePlaintextIsWiped() async throws {
        ops.items["01C"] = FakeItemOps.item("01C", "Phrase", "critical", fields: [FakeItemOps.field("f1", "Words", "multiline"), FakeItemOps.field("f2", "Passphrase", "password")])
        ops.plaintext = Array(#"{"fields":[{"field_id":"f1","value":"abandon ability"},{"field_id":"f2","value":""}],"notes":"cold"}"#.utf8)
        let d = try await m.revealCritical("01C", password: "pw")
        #expect(ops.calls.contains("revealCritical:pw"))
        let handed = try #require(ops.handedOut)
        #expect(handed.isWiped && handed.withBytes { $0.count } == ops.plaintext.count, "the opened values are zeroed once read")
        #expect(d.fields[0].value == .text("abandon ability") && d.fields[1].value == .text("") && d.notes == "cold" && d.revealed)
    }

    @Test func aBackoffCarriesItsWait() async {
        ops.items["01C"] = FakeItemOps.item("01C", "Phrase", "critical")
        ops.revealError = VaultOpError(type: "item.reveal", code: "backoff", detail: "", body: Array(#"{"retry_after":30}"#.utf8))
        let f = await failure { try await m.revealCritical("01C", password: "x") }
        #expect(f?.kind == .backoff && f?.retryAfterSeconds == 30)
        ops.revealError = VaultOpError(type: "item.reveal", code: "bad_password", detail: "", body: nil)
        #expect(await failure { try await m.revealCritical("01C", password: "x") }?.kind == .badPassword)
        #expect(ops.calls.filter { $0 == "get" }.count == 2 && ops.calls.filter { $0 == "revealCritical:x" }.count == 2, "the reveal itself refused")
    }

    @Test func createSendsTheCheckedContent() async throws {
        let draft = ItemDraft(name: " Passport ", category: "identity_document", template: "passport", sensitivity: .secret, tags: ["Travel", "travel", "ID"], fields: [DraftField(label: " Number ", kind: "text", text: "X1")])
        #expect(try await m.create(draft) == "01NEW")
        let p = try #require(ops.puts.first)
        #expect(p.content.name == "Passport" && p.content.template == "passport" && p.content.notes == nil)
        #expect(p.content.fields == [FakeItemOps.field(nil, "Number", "text", #""X1""#)])
        #expect(p.sensitivity == "secret" && p.tags == ["id", "travel"] && p.itemID == nil && p.version == nil)
    }

    @Test func anInvalidDraftIsNeverSent() async {
        let f = await failure { try await m.create(ItemDraft(name: "", fields: [DraftField(label: "D", kind: "date", text: "tomorrow")])) }
        #expect(f?.kind == .other && f?.code == "bad_request" && ops.puts.isEmpty)
        #expect(await failure { try await m.create(ItemDraft(name: "Phrase", sensitivity: .critical)) }?.kind == .badPassword)
    }

    @Test func anUpdateNamesTheVersionAndKeepsTheSensitivity() async throws {
        #expect(try await m.update("01A", version: 3, draft: ItemDraft(name: "P", fields: [DraftField(fieldID: "f1", label: "N", kind: "text", text: "1")])) == 4)
        let p = try #require(ops.puts.first)
        #expect(p.sensitivity == nil && p.itemID == "01A" && p.version == 3 && p.content.fields?.first?.fieldID == "f1")
    }

    @Test func criticalItemsAreWrittenWithThePassword() async throws {
        let d = ItemDraft(name: "Phrase", category: "crypto_wallet", sensitivity: .critical, fields: [DraftField(label: "W", kind: "multiline", text: "a b")])
        #expect(try await m.createCritical(d, password: "pw") == "01CRIT")
        _ = try await m.updateCritical("01CRIT", version: 1, draft: d, password: "pw")
        #expect(ops.calls == ["putCritical:pw", "list:nil:500", "putCritical:pw", "list:nil:500"])
    }

    @Test func aCriticalDeleteNeedsThePassword() async throws {
        #expect(await failure { try await m.delete("01C", sensitivity: .critical, password: nil) }?.kind == .badPassword)
        try await m.delete("01C", sensitivity: .critical, password: "pw")
        try await m.delete("01A", sensitivity: .data, password: "ignored")
        #expect(ops.deletes.map(\.0) == ["01C", "01A"] && ops.deletes.map(\.1) == ["pw", nil])
    }

    @Test func onlyMovesToOrFromCriticalCarryThePassword() async throws {
        _ = try await m.setSensitivity("01A", version: 2, from: .data, to: .secret, password: "ignored")
        _ = try await m.setSensitivity("01A", version: 3, from: .secret, to: .critical, password: "pw")
        _ = try await m.setSensitivity("01A", version: 4, from: .critical, to: .data, password: "pw")
        #expect(ops.sensitivities.map(\.3) == [nil, "pw", "pw"] && ops.sensitivities.map(\.2) == ["secret", "critical", "data"])
        #expect(await failure { try await m.setSensitivity("01A", version: 5, from: .data, to: .critical, password: nil) }?.kind == .badPassword)
    }

    @Test func tagsAreNormalisedBeforeTheyAreSent() async throws {
        _ = try await m.setTags("01A", version: 2, tags: ["Medical ", "@profile"])
        #expect(ops.calls.contains(#"tag:["@profile", "medical"]"#))
        #expect(await failure { try await m.setTags("01A", version: 3, tags: ["!no"]) }?.code == "bad_request")
    }

    @Test func theVaultsLimitNamesItsLimit() async {
        ops.error = VaultOpError(type: "item.put", code: "limit", detail: "", body: Array(#"{"limit":"item_size","max":65536,"size":70001}"#.utf8))
        let f = await failure { try await m.create(ItemDraft(name: "Big")) }
        #expect(f?.kind == .limit && f?.limit == VaultLimit("item_size", max: 65_536, size: 70_001))
        ops.error = VaultOpError(type: "item.put", code: "limit", detail: "", body: nil)
        #expect(await failure { try await m.create(ItemDraft(name: "Older vault")) }?.limit == nil)
    }

    @Test func anotherDevicesChangeReReadsTheList() async throws {
        ops.pages = [ItemPage(items: [FakeItemOps.item("01A", "Passport"), FakeItemOps.item("01B", "Visa")])]
        try await m.refresh()
        ops.pages = [ItemPage(items: [FakeItemOps.item("01A", "Passport")])]
        func sync(_ body: String) -> VaultMessage {
            VaultMessage(inner: Inner(id: Ulid.new(), type: "sync.event", ts: Date(), body: Array(body.utf8)))
        }
        m.onEvent(sync(#"{"kind":"item.deleted","item_id":"01B"}"#))
        #expect(m.items.map(\.itemID) == ["01A"])
        m.onEvent(sync(#"{"kind":"item.changed","item_id":"01A","version":3}"#))
        m.onEvent(sync(#"{"kind":"tag.changed","version":3}"#))
        m.onEvent(sync(#"{"kind":"message.read"}"#))
        #expect(await eventually { ops.calls.count { $0.hasPrefix("list:nil") } == 2 })
        #expect(ops.calls.count { $0.hasPrefix("list:nil") } == 2, "one read per burst")
    }

    // MARK: - VAULT-MESSAGING 0.21.0: kept values, the size, the dry run

    func secretLogin(size: Int64?) -> Item {
        FakeItemOps.item("01S", "Login", "secret", fields: [FakeItemOps.field("f1", "User", "text"), FakeItemOps.field("f2", "Password", "password")], hasNotes: true, size: size)
    }

    @Test func aSecretItemIsEditedWithItsValuesKeptAndNothingRevealed() async throws {
        ops.items["01S"] = secretLogin(size: 180)
        let d = try await m.get("01S")
        #expect(d.size == 180)
        var draft = ItemDraft.of(d)
        #expect(draft.fields.allSatisfy(\.kept) && draft.keepNotes)
        // The member renames one field and types a new password; the user name stays kept.
        draft.fields[0].label = "Login name"
        draft.fields[1].text = "new-pass"
        draft.fields[1].kept = false
        _ = try await m.update("01S", version: 2, draft: draft)
        #expect(!ops.calls.contains("reveal"))
        let c = try #require(ops.puts.first).content
        #expect(c.fields == [FakeItemOps.field("f1", "Login name", "text"), FakeItemOps.field("f2", "Password", "password", #""new-pass""#)])
        #expect(c.keepNotes && c.notes == nil)
    }

    @Test func aCriticalItemIsEditedInOneCredentialOperation() async throws {
        ops.items["01C"] = FakeItemOps.item("01C", "Phrase", "critical", fields: [FakeItemOps.field("f1", "Words", "multiline")], hasNotes: true, size: 150)
        var draft = ItemDraft.of(try await m.get("01C"))
        draft.name = "Cold phrase"
        _ = try await m.updateCritical("01C", version: 2, draft: draft, password: "pw")
        #expect(ops.calls.count { $0.hasPrefix("putCritical") } == 1 && !ops.calls.contains { $0.hasPrefix("revealCritical") })
        let c = try #require(ops.puts.first).content
        #expect(c.fields == [FakeItemOps.field("f1", "Words", "multiline")] && c.keepNotes)
    }

    @Test func aVaultWithoutSizeGetsASecretItemsValuesInFull() async throws {
        // Before 0.21.0 a vault keeps no values: the app reads them (never shown) and sends them all.
        ops.items["01S"] = secretLogin(size: nil)
        ops.revealed["01S"] = FakeItemOps.item("01S", "Login", "secret", fields: [FakeItemOps.field("f1", "User", "text", #""sam""#), FakeItemOps.field("f2", "Password", "password", #""old""#)], notes: "branch")
        var draft = ItemDraft.of(try await m.get("01S"))
        #expect(!ItemChecks.check(draft).sizeKnown)
        draft.fields[1].text = "new"
        draft.fields[1].kept = false
        _ = try await m.update("01S", version: 2, draft: draft)
        #expect(ops.calls.contains("reveal"))
        let c = try #require(ops.puts.first).content
        #expect(c.fields?.map(\.valueJSON) == [#""sam""#, #""new""#] && c.notes == "branch" && !c.keepNotes)
    }

    @Test func anOlderVaultRefusingKeptValuesGetsThemWithTheSamePassword() async throws {
        ops.items["01C"] = FakeItemOps.item("01C", "Phrase", "critical", fields: [FakeItemOps.field("f1", "Words", "multiline")])
        ops.plaintext = Array(#"{"fields":[{"field_id":"f1","value":"abandon ability"}]}"#.utf8)
        ops.criticalError = "bad_request"
        _ = try await m.updateCritical("01C", version: 2, draft: ItemDraft.of(try await m.get("01C")), password: "pw")
        #expect(ops.calls.filter { $0.contains(":pw") } == ["putCritical:pw", "revealCritical:pw", "putCritical:pw"])
        #expect(try #require(ops.puts.first).content.fields?.first?.valueJSON == #""abandon ability""#)
    }

    @Test func keptNotesAloneOnAnItemWithoutSizeAreOpenedFirst() async throws {
        // An older vault ignores keep_notes: with every field typed, the notes would be lost. The values come first.
        ops.items["01C"] = FakeItemOps.item("01C", "Phrase", "critical", fields: [FakeItemOps.field("f1", "Words", "multiline")], hasNotes: true)
        ops.plaintext = Array(#"{"fields":[{"field_id":"f1","value":"old"}],"notes":"cold"}"#.utf8)
        var draft = ItemDraft.of(try await m.get("01C"))
        draft.fields[0].text = "new"
        draft.fields[0].kept = false
        _ = try await m.updateCritical("01C", version: 2, draft: draft, password: "pw")
        #expect(ops.calls.filter { $0.contains(":pw") } == ["revealCritical:pw", "putCritical:pw"])
        let c = try #require(ops.puts.first).content
        #expect(c.notes == "cold" && c.fields?.first?.valueJSON == #""new""#)
    }

    @Test func anotherRefusalOfACriticalEditIsNotRetried() async throws {
        ops.items["01C"] = FakeItemOps.item("01C", "Phrase", "critical", fields: [FakeItemOps.field("f1", "Words", "multiline")], size: 120)
        ops.criticalError = "bad_request"
        let draft = ItemDraft.of(try await m.get("01C"))
        #expect(await failure { try await m.updateCritical("01C", version: 2, draft: draft, password: "pw") }?.code == "bad_request")
        #expect(!ops.calls.contains { $0.hasPrefix("revealCritical") })
    }

    @Test func theDryRunNeverCarriesContentAndIsParsed() async throws {
        ops.effect = #"{"version":3,"shares":[{"rule_id":"01R1","subject":{"connection_id":"c1"},"mode":"auto"},{"rule_id":"01R2","subject":{"connection_id":"c2"},"mode":"ask","usable":true,"ask_rule_id":"01R9"},{"subject":{}}],"withdrawals":[{"rule_id":"01R3","subject":{"agent_id":"a1"},"state":"pending"}]}"#
        let e = try await m.shareEffect("01A", version: 3, sensitivity: .data, tags: ["Medical"])
        let first = try #require(ops.dryRuns.first)
        #expect(first.0 == "01A" && first.1 == 3 && first.2 == nil && first.3 == ["medical"])
        #expect(e.version == 3)
        #expect(e.shares == [EffectShare(ruleID: "01R1", subject: ShareSubject(connectionID: "c1"), mode: .auto), EffectShare(ruleID: "01R2", subject: ShareSubject(connectionID: "c2"), mode: .ask, usable: true, askRuleID: "01R9")])
        #expect(e.withdrawals == [EffectWithdrawal(ruleID: "01R3", subject: ShareSubject(agentID: "a1"), state: "pending")])
        _ = try await m.shareEffect(nil, version: 9, sensitivity: .critical, tags: [])
        #expect(ops.dryRuns[1].0 == nil && ops.dryRuns[1].1 == nil && ops.dryRuns[1].2 == "critical" && ops.dryRuns[1].3 == [])
    }

    // MARK: - Clears (the vault locked, held or due; a wipe)

    @Test func clearForgetsTheList() async throws {
        ops.pages = [ItemPage(items: [FakeItemOps.item("01A", "Passport")])]
        try await m.refresh()
        let before = m.cleared
        m.clear()
        #expect(m.items.isEmpty && m.load == .notLoaded && m.cleared == before + 1 && m.names == nil)
    }

    @Test func aRevealAnsweredAfterAClearIsNotHandedOut() async throws {
        ops.items["01C"] = FakeItemOps.item("01C", "Phrase", "critical", fields: [FakeItemOps.field("f1", "Words", "multiline")])
        ops.plaintext = Array(#"{"fields":[{"field_id":"f1","value":"abandon ability"}]}"#.utf8)
        let gate = TestDeferred<Void>()
        ops.revealGate = gate
        let task = Task { try await m.revealCritical("01C", password: "pw") }
        #expect(await eventually { ops.calls.contains("revealCritical:pw") })
        m.clear()
        gate.complete()
        let f = await failure { try await task.value }
        #expect(f?.code == ItemsManager.codeUnavailable)
        // A secret item's reveal too.
        ops.revealed["01S"] = FakeItemOps.item("01S", "Login", "secret", fields: [FakeItemOps.field("f1", "Password", "password", #""hunter2""#)])
        let gate2 = TestDeferred<Void>()
        ops.revealGate = gate2
        let task2 = Task { try await m.reveal("01S") }
        #expect(await eventually { ops.calls.contains("reveal") })
        m.clear()
        gate2.complete()
        #expect(await failure { try await task2.value }?.code == ItemsManager.codeUnavailable)
    }

    @Test func aListAnsweredAfterAClearIsNotKept() async throws {
        ops.pages = [ItemPage(items: [FakeItemOps.item("01A", "Passport")])]
        let gate = TestDeferred<Void>()
        let slow = SlowListOps(inner: ops, gate: gate)
        let m2 = ItemsManager(ops: { slow })
        let task = Task { try await m2.refresh() }
        #expect(await eventually { m2.load == .loading })
        m2.clear()
        gate.complete()
        try await task.value
        #expect(m2.items.isEmpty && m2.load == .notLoaded)
    }

    // MARK: - The gate, the hold, and writes across a clear

    /// The credential operations' gate runs before anything is opened or sent; a refusal sends nothing.
    @Test func theGateComesFirst() async throws {
        let opened = Counter()
        let ops = ops
        let m2 = ItemsManager(ops: { opened.n += 1; return ops }, gate: { throw VaultFailure(.changeChecking, code: "change_unresolved") })
        ops.items["01C"] = FakeItemOps.item("01C", "Phrase", "critical")
        let critical = ItemDraft(name: "Phrase", sensitivity: .critical, fields: [DraftField(label: "W", kind: "multiline", text: "a")])
        #expect(await failure { try await m2.revealCritical("01C", password: "pw") }?.kind == .changeChecking)
        #expect(await failure { try await m2.createCritical(critical, password: "pw") }?.kind == .changeChecking)
        #expect(await failure { try await m2.updateCritical("01C", version: 2, draft: critical, password: "pw") }?.kind == .changeChecking)
        #expect(await failure { try await m2.delete("01C", sensitivity: .critical, password: "pw") }?.kind == .changeChecking)
        #expect(await failure { try await m2.setSensitivity("01C", version: 2, from: .critical, to: .data, password: "pw") }?.kind == .changeChecking)
        #expect(opened.n == 0 && ops.calls.isEmpty, "nothing opened or sent")
        // Operations without the password do not pass it.
        _ = try await m2.create(ItemDraft(name: "Note"))
        #expect(ops.calls.first == "put")
    }

    /// Held or due (§3.6.3): another device's change does not refill the list, and no read nobody asked for goes out.
    @Test func nothingRefillsTheListWhileDue() async throws {
        let due = Counter()
        due.n = 1
        let ops = ops
        let m2 = ItemsManager(ops: { ops }, gated: { due.n == 1 }, debounce: .milliseconds(10))
        let sync = VaultMessage(inner: Inner(id: Ulid.new(), type: "sync.event", ts: Date(), body: Array(#"{"kind":"item.changed","item_id":"01A","version":3}"#.utf8)))
        m2.onEvent(sync)
        #expect(m2.pending == nil, "no reread scheduled")
        try await m2.refresh(quietly: true)
        #expect(ops.calls.isEmpty && m2.items.isEmpty && m2.load == .notLoaded)
        // Once the check passed, another device's change reads the list again.
        due.n = 0
        m2.onEvent(sync)
        #expect(await eventually { ops.calls.contains("list:nil:500") })
    }

    /// A write answered after a clear (a lock, the hold) refills nothing and opens no session; the quiet read after a
    /// write never opens one either.
    @Test func aWriteAnsweredAfterAClearRefillsNothing() async throws {
        let opened = Counter(), quiet = Counter()
        let ops = ops
        let m2 = ItemsManager(ops: { opened.n += 1; return ops }, quietOps: { quiet.n += 1; return ops })
        ops.pages = [ItemPage(items: [FakeItemOps.item("01NEW", "Note")])]
        let gate = TestDeferred<Void>()
        ops.putGate = gate
        let write = Task { try await m2.create(ItemDraft(name: "Note")) }
        #expect(await eventually { ops.calls.contains("put") })
        m2.clear()
        gate.complete()
        #expect(try await write.value == "01NEW")
        #expect(opened.n == 1 && quiet.n == 0 && !ops.calls.contains { $0.hasPrefix("list") })
        #expect(m2.items.isEmpty && m2.load == .notLoaded)
        // Without a clear, the list is read again over the session already open.
        ops.putGate = nil
        _ = try await m2.create(ItemDraft(name: "Note"))
        #expect(opened.n == 2 && quiet.n == 1 && m2.items.map(\.itemID) == ["01NEW"])
    }
}

/// A count the closures of a test change on the main actor.
@MainActor
final class Counter {
    var n = 0
}

/// ``FakeItemOps`` whose `item.list` waits for [gate].
private struct SlowListOps: ItemOps, @unchecked Sendable {
    let inner: FakeItemOps
    let gate: TestDeferred<Void>

    func list(after: String?, limit: Int) async throws -> ItemPage {
        try await gate.value()
        return try await inner.list(after: after, limit: limit)
    }

    func get(_ itemID: String) async throws -> Item { try await inner.get(itemID) }
    func reveal(_ itemID: String) async throws -> Item { try await inner.reveal(itemID) }
    func revealCritical(password: String, itemID: String) async throws -> SecretBytes { try await inner.revealCritical(password: password, itemID: itemID) }
    func put(_ content: ItemContent, sensitivity: String?, tags: [String]?, itemID: String?, version: Int64?) async throws -> ItemRef {
        try await inner.put(content, sensitivity: sensitivity, tags: tags, itemID: itemID, version: version)
    }
    func putCritical(password: String, content: ItemContent, tags: [String]?, itemID: String?, version: Int64?) async throws -> ItemRef {
        try await inner.putCritical(password: password, content: content, tags: tags, itemID: itemID, version: version)
    }
    func tag(_ itemID: String, version: Int64, tags: [String]) async throws -> Int64 { try await inner.tag(itemID, version: version, tags: tags) }
    func putDryRun(itemID: String?, version: Int64?, sensitivity: String?, tags: [String]?) async throws -> JsonObject {
        try await inner.putDryRun(itemID: itemID, version: version, sensitivity: sensitivity, tags: tags)
    }
    func sensitivity(_ itemID: String, version: Int64, sensitivity: String, password: String?) async throws -> Int64 {
        try await inner.sensitivity(itemID, version: version, sensitivity: sensitivity, password: password)
    }
    func delete(_ itemID: String, password: String?) async throws { try await inner.delete(itemID, password: password) }
}

// swiftlint:enable line_length large_tuple
