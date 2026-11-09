import Foundation
import Testing
@testable import VettIDData
import VettIDKeys
import VettIDKeysTesting

/// ``PhoneSecrets/dropPendings(keyVault:)``: what a new transfer scan drops before it makes its own epoch-1 record
/// (VAULT-MESSAGING §6.7.1, §11.14.10 rule 5).
@Suite struct PhoneSecretsDropPendingsTests {
    let t: TestPhone

    init() throws {
        t = try TestPhone()
    }

    /// Only the pending records of that `key_vault` and their keys go; the current record, a candidate, a replaced record and
    /// every other `key_vault`'s records and keys stay as they were.
    @Test func dropsOnlyThePendingRecordsOfThatKeyVault() throws {
        _ = try t.secrets.createConfirmed(keyVault: "")
        _ = try t.secrets.createConfirmed(keyVault: "") // the first one is a replaced record now
        _ = try t.secrets.beginChange(operation: "a")
        t.secrets.endChange(operation: "a") // a candidate: its answer did not arrive
        let first = try t.secrets.create(keyVault: "")
        let second = try t.secrets.create(keyVault: "")
        let other = try t.secrets.create(keyVault: "v2")
        let before = try t.records
        #expect(before.pendings.count == 3 && before.replaced.count == 1 && before.candidates.count == 1 && before.current != nil)
        let keys = t.keys.count

        try t.secrets.dropPendings(keyVault: "")

        let after = try t.records
        #expect(after.current == before.current && after.candidates == before.candidates)
        #expect(after.replaced.map(\.entry) == before.replaced.map(\.entry))
        #expect(after.pendings.map(\.keyID) == [other.id])
        #expect(!after.pendings.contains { $0.keyID == first.id || $0.keyID == second.id })
        // The two dropped keys are deleted, none other.
        #expect(t.keys.count == keys - 2)
        #expect(t.keys.lookup(keyVault: "", keyID: first.id).isMissing && t.keys.lookup(keyVault: "", keyID: second.id).isMissing)
        #expect(t.keys.lookup(keyVault: "v2", keyID: other.id).isFound)
        // Nothing pending for it any more: nothing to do, and no error.
        try t.secrets.dropPendings(keyVault: "")
        try t.secrets.dropPendings(keyVault: "no-such-vault")
        #expect(try t.records == after)
    }

    /// A records file that cannot be read now is refused, and nothing is changed or deleted (the scan then sends nothing).
    @Test func failsWithoutChangingAnythingWhenTheRecordsCannotBeWritten() throws {
        let made = try t.secrets.create(keyVault: "")
        let before = try t.records
        t.fileKeys.state.behaviour = .locked
        #expect(failureKind { try t.secrets.dropPendings(keyVault: "") } == .phoneLocked)
        t.fileKeys.state.behaviour = .normal
        #expect(try t.records == before)
        #expect(t.keys.lookup(keyVault: "", keyID: made.id).isFound)
    }

    /// A new scan never reuses: the pending record is dropped and another made, with a secret of its own.
    @Test func aNewRecordAfterTheDropHasAnotherSecret() throws {
        let first = try t.secrets.create(keyVault: "")
        try t.secrets.dropPendings(keyVault: "")
        let second = try t.secrets.create(keyVault: "")
        #expect(first.id != second.id && first.secret != second.secret)
        #expect(try t.records.pendings.map(\.keyID) == [second.id] && t.keys.count == 1)
    }
}

private extension ItemLookup where Value == any KeyAgreementKey {
    var isFound: Bool { if case .found = self { true } else { false } }
    var isMissing: Bool { if case .missing = self { true } else { false } }
}
