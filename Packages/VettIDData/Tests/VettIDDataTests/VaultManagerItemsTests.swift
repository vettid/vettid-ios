import Foundation
import Testing
import VettIDCrypto
@testable import VettIDData
import VettIDDataTesting

// Fixtures stay on one line each.
// swiftlint:disable line_length

/// The items end to end against ``FakeVaultService``, which answers as vettid-vault does (VAULT-MESSAGING §10.7): the
/// three sensitivities written and read, a critical item's every read and change a credential operation with the password
/// (IOS-PLAN §8 I3.1's acceptance: "Critical items need the password"), its values only sealed to the request's reply key,
/// the kept values of 0.21.0, another device's changes followed, and nothing kept once the vault is locked.
@MainActor
@Suite(.serialized) struct VaultManagerItemsTests {
    let service: FakeVaultService
    let phone: TestVaultPhone
    let pin = "402817"
    let password = "correct horse battery"

    init() throws {
        service = try FakeVaultService()
        phone = try TestVaultPhone(service: service)
    }

    var m: VaultManager { phone.manager }
    var items: ItemsManager { phone.manager.items }

    func setUp() async throws {
        _ = try await m.redeemSetupCode(.secret(service.secret))
        try await m.enroll(pin: pin) { _ in }
        try await m.createCredential(password: password, backup: true, pin: pin) { _ in }
        try await m.finishSetup()
        #expect(m.phase == .unlocked)
        #expect(await eventually { items.load == .loaded })
    }

    func failure(_ body: () async throws -> some Any) async -> VaultFailure? {
        do {
            _ = try await body()
            return nil
        } catch {
            return error as? VaultFailure
        }
    }

    static let phrase = ItemDraft(
        name: "Recovery phrase", category: "crypto_wallet", sensitivity: .critical,
        fields: [DraftField(label: "Words", kind: "multiline", text: "abandon ability able"), DraftField(label: "Passphrase", kind: "password", text: "tr0ub4dor")],
        notes: "cold storage"
    )

    /// I3.1's acceptance: a critical item is created, read, changed and deleted only with the credential password; a wrong
    /// one is `bad_password` and changes nothing; the values come back sealed to the request's reply key and nowhere else.
    @Test func criticalItemsNeedThePassword() async throws {
        defer { phone.close() }
        try await setUp()
        #expect(await failure { try await items.createCritical(Self.phrase, password: "wrong horse") }?.kind == .badPassword)
        #expect(service.itemCount == 0)
        #expect(await failure { try await items.create(Self.phrase) }?.kind == .badPassword, "never without the password")
        let id = try await items.createCritical(Self.phrase, password: password)
        #expect(service.itemValues(id)?.sensitivity == "critical" && service.itemValues(id)?.values["Words"] == #""abandon ability able""#)
        #expect(items.items.map(\.itemID) == [id] && items.items.first?.sensitivity == .critical)
        // item.get gives the metadata only.
        let hidden = try await items.get(id)
        #expect(!hidden.revealed && hidden.fields.allSatisfy { $0.value == nil } && hidden.hasNotes && hidden.notes == nil)
        #expect(await failure { try await items.revealCritical(id, password: "wrong horse") }?.kind == .badPassword)
        let shown = try await items.revealCritical(id, password: password)
        #expect(shown.revealed && shown.fields.map(\.value) == [.text("abandon ability able"), .text("tr0ub4dor")] && shown.notes == "cold storage")
        #expect(service.itemRequests.filter { $0.hasSuffix(":critical") } == ["item.put:critical", "item.put:critical", "item.reveal:critical", "item.reveal:critical"])
        #expect(service.itemPasswords == ["wrong horse", password, "wrong horse", password])
        #expect(await failure { try await items.delete(id, sensitivity: .critical, password: nil) }?.kind == .badPassword)
        #expect(service.itemCount == 1)
        try await items.delete(id, sensitivity: .critical, password: password)
        #expect(service.itemCount == 0 && items.items.isEmpty)
    }

    /// Every credential operation rotates the CEK: the phone keeps each new blob, so the next one is accepted.
    @Test func everyCriticalOperationKeepsTheNewBlob() async throws {
        defer { phone.close() }
        try await setUp()
        let before = service.vaultCredentialVersion
        let id = try await items.createCritical(Self.phrase, password: password)
        _ = try await items.revealCritical(id, password: password)
        let v = try await items.setSensitivity(id, version: 1, from: .critical, to: .secret, password: password)
        #expect(v == 2 && service.itemValues(id)?.sensitivity == "secret")
        #expect(service.vaultCredentialVersion == before + 3)
        // The secret item reveals without the password now.
        let shown = try await items.reveal(id)
        #expect(shown.fields.first?.value == .text("abandon ability able"))
    }

    @Test func dataAndSecretItemsAreWrittenAndRead() async throws {
        defer { phone.close() }
        try await setUp()
        let passport = ItemDraft(name: "Passport", category: "identity_document", template: "passport", tags: ["Travel"], fields: [DraftField(label: "Number", kind: "text", text: "X123"), DraftField(label: "Expires", kind: "date", text: "2031-04", monthYear: true), DraftField(label: "Home", kind: "address", address: AddressValue(city: "Oslo", country: "NO"))])
        let a = try await items.create(passport)
        let d = try await items.get(a)
        #expect(d.revealed && d.tags == ["travel"] && d.template == "passport")
        #expect(d.fields.map(\.value) == [.text("X123"), .text("2031-04"), .address(AddressValue(city: "Oslo", country: "NO"))])
        #expect(ItemDraft.of(d).fields[1].monthYear, "a stored month is edited as a month")
        let login = ItemDraft(name: "Bank", category: "login", sensitivity: .secret, fields: [DraftField(label: "User", kind: "text", text: "sam"), DraftField(label: "Password", kind: "password", text: "hunter2")], notes: "branch 4")
        let b = try await items.create(login)
        let hidden = try await items.get(b)
        #expect(!hidden.revealed && hidden.fields.allSatisfy { $0.value == nil } && hidden.size == ItemChecks.check(login).size)
        let shown = try await items.reveal(b)
        #expect(shown.fields.map(\.value) == [.text("sam"), .text("hunter2")] && shown.notes == "branch 4")
        #expect(Set(items.items.map(\.name)) == ["Passport", "Bank"] && items.names?[b] == "Bank")
    }

    /// 0.21.0 Kept values: a secret item is edited without being revealed, the values the member did not type kept by the
    /// vault; a critical item in one credential operation.
    @Test func editsKeepTheValuesTheMemberDidNotType() async throws {
        defer { phone.close() }
        try await setUp()
        let b = try await items.create(ItemDraft(name: "Bank", category: "login", sensitivity: .secret, fields: [DraftField(label: "User", kind: "text", text: "sam"), DraftField(label: "Password", kind: "password", text: "hunter2")], notes: "branch 4"))
        var draft = ItemDraft.of(try await items.get(b))
        #expect(draft.fields.allSatisfy(\.kept) && draft.keepNotes && ItemChecks.check(draft).exact)
        draft.fields[0].label = "Login"
        draft.fields[1].text = "new-pass"
        draft.fields[1].kept = false
        _ = try await items.update(b, version: 1, draft: draft)
        #expect(!service.itemRequests.contains("item.reveal"))
        #expect(service.itemValues(b)?.values == ["Login": #""sam""#, "Password": #""new-pass""#] && service.itemValues(b)?.notes == "branch 4")
        let c = try await items.createCritical(Self.phrase, password: password)
        var critical = ItemDraft.of(try await items.get(c))
        critical.name = "Cold phrase"
        _ = try await items.updateCritical(c, version: 1, draft: critical, password: password)
        #expect(service.itemValues(c)?.values["Passphrase"] == #""tr0ub4dor""# && service.itemValues(c)?.notes == "cold storage")
        #expect(!service.itemRequests.contains("item.reveal:critical"))
        // A stale version is a conflict.
        #expect(await failure { try await items.update(b, version: 1, draft: draft) }?.kind == .conflict)
    }

    /// A vault before 0.21.0 keeps no values: the app reads them (never shown) and sends them all; a critical item's with
    /// the same password.
    @Test func anOlderVaultGetsEveryValue() async throws {
        defer { phone.close() }
        try await setUp()
        service.itemsKeepNoValues = true
        let b = try await items.create(ItemDraft(name: "Bank", category: "login", sensitivity: .secret, fields: [DraftField(label: "User", kind: "text", text: "sam"), DraftField(label: "Password", kind: "password", text: "old")], notes: "branch 4"))
        var draft = ItemDraft.of(try await items.get(b))
        #expect(!ItemChecks.check(draft).sizeKnown)
        draft.fields[1].text = "new"
        draft.fields[1].kept = false
        _ = try await items.update(b, version: 1, draft: draft)
        #expect(service.itemRequests.contains("item.reveal"))
        #expect(service.itemValues(b)?.values == ["User": #""sam""#, "Password": #""new""#] && service.itemValues(b)?.notes == "branch 4")
        let c = try await items.createCritical(Self.phrase, password: password)
        _ = try await items.updateCritical(c, version: 1, draft: ItemDraft.of(try await items.get(c)), password: password)
        #expect(service.itemValues(c)?.values["Words"] == #""abandon ability able""# && service.itemValues(c)?.notes == "cold storage")
    }

    @Test func tagsAndTheProfileTag() async throws {
        defer { phone.close() }
        try await setUp()
        let a = try await items.create(ItemDraft(name: "Email", category: "contact", fields: [DraftField(label: "Email", kind: "email", text: "ada@example.org")]))
        #expect(try await items.setTags(a, version: 1, tags: ["@profile", "Work "]) == 2)
        #expect(service.itemValues(a)?.tags == ["@profile", "work"])
        // `@profile` stays on data items: the vault refuses a secret one (bad_request).
        let s = try await items.create(ItemDraft(name: "PIN", sensitivity: .secret, fields: [DraftField(label: "PIN", kind: "password", text: "1234")]))
        #expect(await failure { try await items.setTags(s, version: 1, tags: ["@profile"]) }?.kind == .vaultCode("bad_request"))
        service.itemEffect(#""shares":[{"rule_id":"01R1","subject":{"connection_id":"c1"},"mode":"ask"}],"withdrawals":[]"#)
        let e = try await items.shareEffect(a, version: 2, sensitivity: .data, tags: ["work"])
        #expect(e.version == 2 && e.shares.map(\.ruleID) == ["01R1"])
    }

    /// Another device's changes are followed (`sync.event`), and nothing is kept once the vault is locked: the list is
    /// dropped and the screens are told (``ItemsRepository/cleared``).
    @Test func theListFollowsOtherDevicesAndIsDroppedAtTheLock() async throws {
        defer { phone.close() }
        try await setUp()
        let id = service.addItem(name: "Visa", fields: [.init("Number", "V1")])
        service.itemChangedElsewhere(id, name: "Visa 2031")
        #expect(await eventually { items.items.map(\.name) == ["Visa 2031"] })
        service.itemChangedElsewhere(id, delete: true)
        #expect(await eventually { items.items.isEmpty })
        _ = service.addItem(name: "Passport")
        try await items.refresh()
        #expect(items.items.count == 1)
        let cleared = items.cleared
        try await m.lock()
        #expect(await eventually { items.items.isEmpty && items.load == .notLoaded && items.cleared > cleared })
    }

    /// Due (§3.6.3): the list is dropped and another device's change does not refill it; this phone's passed check reads
    /// it again once, with the other lists.
    @Test func whileDueNothingRefillsTheListAndAPassedCheckReadsItOnce() async throws {
        defer { phone.close() }
        try await setUp()
        let id = try await items.create(ItemDraft(name: "Note", fields: [DraftField(label: "Text", kind: "text", text: "x")]))
        #expect(items.items.map(\.itemID) == [id])
        service.advanceVaultClock(86_401)
        try await m.ownerChecks.refreshOwnerCheck()
        #expect(m.ownerChecks.ownerCheck?.state != .ok && items.items.isEmpty && items.load == .notLoaded)
        let listsBefore = service.requestsSeen.filter { $0 == "item.list" }.count
        #expect(try await m.ownerChecks.check(pin: pin, password: password) == .passed)
        #expect(await eventually { items.load == .loaded && items.items.map(\.itemID) == [id] }, "read again after the check")
        #expect(service.requestsSeen.filter { $0 == "item.list" }.count == listsBefore + 1, "once")
    }
}

// swiftlint:enable line_length
