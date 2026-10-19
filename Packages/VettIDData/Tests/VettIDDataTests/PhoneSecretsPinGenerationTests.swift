import Foundation
import Testing
@testable import VettIDData

/// ``PhoneSecrets/pinGeneration`` (VAULT-MESSAGING §11.14.9 step 2): each write that may change which PIN the vault
/// expects moves it, and an unlock that settles nothing leaves it.
@Suite struct PhoneSecretsPinGenerationTests {
    let t: TestPhone
    let vault = OpenDEKVault()

    init() throws {
        t = try TestPhone()
        vault.enroll(try t.secrets.createConfirmed(keyVault: vault.vaultID))
    }

    var generation: Int { t.secrets.pinGeneration }

    func marker(_ type: ChangeType, operation: String? = nil) -> UnresolvedChange {
        UnresolvedChange(type: type, id: "req-\(UUID().uuidString)", version: 1, exp: Date(), operation: operation)
    }

    /// A PIN change sent with its marker, its answer lost after the vault stored it.
    func pinChangeLost() async throws -> UnresolvedChange {
        let m = marker(.pin, operation: "pin.change-1")
        let lost = try? await t.secrets.change(
            operation: "pin.change-1", unresolved: m, send: { try vault.change($0, .lostAfterStoring) }, confirmed: { $0.ok }
        )
        #expect(lost == nil)
        return m
    }

    @Test func aPasswordChangesMarkerMovesIt() throws {
        let before = generation
        try t.secrets.setUnresolved(marker(.password))
        #expect(generation != before)
    }

    @Test func aChangeAppliedMovesIt() async throws {
        let m = try await pinChangeLost()
        let before = generation
        #expect(try t.secrets.confirmChange(operation: "pin.change-1", clearing: m.id))
        #expect(generation != before)
    }

    @Test func aChangeNotAppliedMovesIt() async throws {
        let m = try await pinChangeLost()
        let before = generation
        try t.secrets.clearUnresolved(id: m.id)
        #expect(generation != before)
    }

    @Test func aCheckThatEndsMovesIt() async throws {
        let m = try await pinChangeLost()
        let before = generation
        try t.secrets.endUnresolved(m)
        #expect(try t.secrets.uncertainPin() == "pin.change-1" && generation != before)
    }

    @Test func aRenewDecidedMovesIt() async throws {
        let sent = PhoneRecords.SentRequest(id: "req-renew", version: 1)
        var next = try t.secrets.beginChange(operation: "renew-1", exp: Date(), sent: sent)
        next = []
        t.secrets.endChange(operation: "renew-1")
        let before = generation
        try t.secrets.clearSent(operation: "renew-1", id: "req-renew")
        #expect(generation != before && next.isEmpty)
    }

    /// The uncertain PIN settled by an unlock (the candidate the vault holds made current) moves it.
    @Test func theUncertainPinSettledByAnUnlockMovesIt() async throws {
        let m = try await pinChangeLost()
        try t.secrets.endUnresolved(m)
        let before = generation
        #expect(try await t.secrets.unlock(vault) == .opened)
        #expect(try t.secrets.uncertainPin() == nil && generation != before)
    }

    /// An unlock that settles a candidate with no uncertain PIN (a renew the vault never stored) leaves it.
    @Test func anUnlockThatSettlesNothingOfThePinLeavesIt() async throws {
        try await t.secrets.renew(vault, operation: "renew-1", .lostMidway)
        let before = generation
        #expect(try await t.secrets.unlock(vault) == .opened)
        #expect(try t.records.replaced.count == 1 && generation == before)
    }

    @Test func deletingTheRecordsMovesIt() throws {
        let before = generation
        try t.secrets.delete()
        #expect(generation != before)
    }
}
