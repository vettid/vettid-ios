import Foundation
import Testing
import VettIDCrypto
@testable import VettIDData
import VettIDDataTesting

// Fixtures stay on one line each.
// swiftlint:disable line_length

/// The tags end to end against ``FakeVaultService``, which answers as vettid-vault does (VAULT-MESSAGING §10.8,
/// §10.12): the registry listed with each tag's items and rules, a description and a colour stored, a rename previewed
/// with what it shares and then made (the items read again), a tag a rule names not deleted, and nothing kept once the
/// vault is locked.
@MainActor
@Suite(.serialized) struct VaultManagerTagsTests {
    let service: FakeVaultService
    let phone: TestVaultPhone
    let pin = "402817"
    let password = "correct horse battery"

    init() throws {
        service = try FakeVaultService()
        phone = try TestVaultPhone(service: service)
    }

    var m: VaultManager { phone.manager }
    var sharing: SharingManager { phone.manager.sharing }

    func setUp() async throws {
        _ = try await m.redeemSetupCode(.secret(service.secret))
        try await m.enroll(pin: pin) { _ in }
        try await m.createCredential(password: password, backup: true, pin: pin) { _ in }
        try await m.finishSetup()
        #expect(m.phase == .unlocked)
        #expect(await eventually { m.items.load == .loaded })
    }

    func failure(_ body: () async throws -> some Any) async -> VaultFailure? {
        do {
            _ = try await body()
            return nil
        } catch {
            return error as? VaultFailure
        }
    }

    @Test func theRegistryListsEveryTagWithItsItemsAndRules() async throws {
        defer { phone.close() }
        try await setUp()
        let id = service.addItem(name: "Allergies", tags: ["health", "@profile"])
        _ = service.addItem(name: "Visa", tags: ["travel"])
        let rule = service.addShareRule("c1", tags: ["health"])
        let r = try await sharing.refreshTags()
        #expect(r.tags.map(\.tag) == ["@profile", "health", "travel"])
        #expect(r.tags[1].items == 1 && r.tags[1].rules == [rule] && r.tags[0].reserved)
        try await sharing.setTag("Travel", description: "Trips", color: nil)
        #expect(service.tagEntry("travel")?.description == "Trips" && sharing.tags?.tags.first { $0.tag == "travel" }?.description == "Trips")
        try await sharing.setTagColor("travel", color: "#59bbfb")
        #expect(service.tagEntry("travel")?.color == "#59bbfb" && service.tagEntry("travel")?.description == "Trips" && sharing.colors["travel"] == "#59bbfb")
        let rules = try await sharing.rules(connectionID: "c1")
        #expect(rules.map(\.ruleID) == [rule] && rules.first?.tags == ["health"])
        #expect(try await sharing.rules(connectionID: "c2").isEmpty)
        _ = id
    }

    /// A rename is previewed (what it changes and newly shares) and then made; the items carry the new tag.
    @Test func aRenameIsPreviewedThenMade() async throws {
        defer { phone.close() }
        try await setUp()
        let a = service.addItem(name: "Allergies", tags: ["health"])
        service.addShareRule("c1", tags: ["medical"], mode: "auto")
        try await sharing.refreshTags()
        let dry = try await sharing.renameTag("health", into: "Medical", dryRun: true)
        #expect(dry.items == 1 && dry.sharesTotal == 1 && dry.shares.first?.itemID == a && dry.shares.first?.mode == .auto)
        #expect(service.itemValues(a)?.tags == ["health"], "a dry run changes nothing")
        _ = try await sharing.renameTag("health", into: "medical", dryRun: false)
        #expect(service.itemValues(a)?.tags == ["medical"])
        #expect(sharing.tags?.tags.map(\.tag) == ["medical"])
        #expect(await eventually { m.items.items.first?.tags == ["medical"] }, "the items read again")
        #expect(service.tagRequests == ["tag.list", "tag.merge:dry", "tag.merge", "tag.list"])
    }

    @Test func aTagARuleNamesIsNotDeletedAndAnotherIs() async throws {
        defer { phone.close() }
        try await setUp()
        let a = service.addItem(name: "Allergies", tags: ["health", "old"])
        service.addShareRule("c1", tags: ["health"])
        #expect(await failure { try await sharing.deleteTag("health", dryRun: true) }?.kind == .inUse)
        #expect(try await sharing.deleteTag("old", dryRun: true).items == 1)
        _ = try await sharing.deleteTag("old", dryRun: false)
        #expect(service.itemValues(a)?.tags == ["health"])
        #expect(await failure { try await sharing.deleteTag("@profile", dryRun: true) }?.code == "bad_request")
    }

    /// A stale version is a conflict; another device's change drops the registry until read again; a lock drops it all.
    @Test func otherDevicesAndTheLock() async throws {
        defer { phone.close() }
        try await setUp()
        service.storeTag("travel", color: "#000001")
        try await sharing.refreshTags()
        service.storeTag("garden")
        #expect(await failure { try await sharing.renameTag("travel", into: "trips", dryRun: true) }?.kind == .conflict)
        service.tagsChangedElsewhere()
        #expect(await eventually { sharing.tags == nil })
        #expect(sharing.colors == ["travel": "#000001"], "the colours stay until read again")
        try await sharing.refreshTags()
        try await m.lock()
        #expect(await eventually { sharing.tags == nil && sharing.colors.isEmpty })
    }
}

// swiftlint:enable line_length
