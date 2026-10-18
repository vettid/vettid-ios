import CryptoKit
import Foundation
import Testing
import VettIDCrypto
@testable import VettIDData
import VettIDKeys
import VettIDKeysTesting

/// `PhoneSecrets` on the iPhone (VAULT-MESSAGING §11.14.1 "On an iPhone", IOS-PLAN §6.3) with the software phone key:
/// vettid-android `PhoneSecretsTest`'s cases that concern the phone secret, and the iPhone's rules for lost keys against
/// a locked iPhone.
@Suite struct PhoneSecretsTests {
    let t: TestPhone

    init() throws {
        t = try TestPhone()
    }

    /// Epoch 1 at creation, then each change at the next epoch, bound to the key's `key_vault`.
    @Test func epochOneAndTheNextEpoch() throws {
        let s1 = try t.secrets.createConfirmed(keyVault: "test-vault-0001")
        #expect(s1.count == 32)
        let cur = try #require(try t.records.current)
        #expect(cur.keyVault == "test-vault-0001" && cur.epoch == 1)
        #expect(try t.secrets.currentSecret() == s1)
        let s2 = try t.secrets.beginChange(operation: "op-1")
        #expect(s2 != s1)
        #expect(try t.records.candidates.map(\.entry.record.epoch) == [2])
        try t.secrets.confirmChange(operation: "op-1")
        #expect(try t.records.current?.epoch == 2)
        #expect(try t.secrets.currentSecret() == s2)
        #expect(t.secrets.inUse)
    }

    /// A missing key or record is the phone no longer holding the keys.
    @Test func aMissingKeyIsThePhoneNoLongerHoldingTheKeys() throws {
        #expect(!t.secrets.inUse)
        #expect(failureKind { try t.secrets.currentSecret() } == .deviceSecret)
        _ = try t.secrets.createConfirmed(keyVault: "v1")
        t.keys.deleteKeys(of: "v1")
        #expect(failureKind { try t.secrets.currentSecret() } == .deviceSecret)
        #expect(t.secrets.keysUsable() == .lost)
        // The record file missing (the app's files removed while the keychain kept the key).
        _ = try t.secrets.createConfirmed(keyVault: "v2")
        try FileManager.default.removeItem(at: t.url)
        #expect(failureKind { try t.secrets.currentSecret() } == .deviceSecret)
    }

    /// A key iOS reports invalid, a tag that does not match, a damaged file: lost.
    @Test func anInvalidKeyATagMismatchAndADamagedFileAreLost() throws {
        _ = try t.secrets.createConfirmed(keyVault: "v1")
        #expect(t.secrets.keysUsable() == .usable)
        t.keys.key("v1")?.state.behaviour = .invalid
        #expect(failureKind { try t.secrets.currentSecret() } == .deviceSecret)
        t.keys.key("v1")?.state.behaviour = .normal
        // A record whose tag does not match what its key computes.
        var recs = try t.records
        let cur = try #require(recs.current)
        var check = cur.check
        check[0] ^= 1
        recs.current = PhoneRecords.Entry(keyID: cur.keyID, record: PhoneSecretRecord(
            keyVault: cur.keyVault, epoch: cur.epoch, ephemeral: cur.ephemeral, check: check))
        try t.overwriteRecords(recs)
        #expect(failureKind { try t.secrets.currentSecret() } == .deviceSecret)
        #expect(t.secrets.keysUsable() == .lost)
        // A file that does not decrypt while its key works.
        _ = try t.secrets.createConfirmed(keyVault: "v1")
        var raw = try Array(Data(contentsOf: t.url))
        raw[raw.count - 1] ^= 1
        try Data(raw).write(to: t.url)
        #expect(failureKind { try t.secrets.currentSecret() } == .deviceSecret)
    }

    /// A locked iPhone (the key's class `WhenUnlockedThisDeviceOnly`, a file-protection refusal, protected data gone) is
    /// temporary: "Unlock your iPhone", every key and record kept, nothing sent; it works once unlocked.
    @Test func aLockedIPhoneIsTemporaryAndKeepsEverything() async throws {
        let vault = OpenDEKVault()
        vault.enroll(try t.secrets.createConfirmed(keyVault: "v1"))
        let before = try t.records
        t.keys.key("v1")?.state.behaviour = .locked
        #expect(failureKind { try t.secrets.currentSecret() } == .phoneLocked)
        #expect(t.secrets.keysUsable() == .unavailable)
        #expect(await failureKind { try await t.secrets.unlock(vault) } == .phoneLocked)
        #expect(failureKind { try t.secrets.beginChange(operation: "op") } == .phoneLocked)
        #expect(vault.unlocks == 0)
        t.keys.key("v1")?.state.behaviour = .normal
        t.keys.source.behaviour = .locked
        #expect(failureKind { try t.secrets.currentSecret() } == .phoneLocked)
        #expect(failureKind { try t.secrets.reuseOrCreate(keyVault: "v1").secret } == .phoneLocked)
        t.keys.source.behaviour = .normal
        // An absent records file while protected data is unavailable is not "missing", and nothing is made over it.
        let other = try TestPhone()
        other.protectedData.set(false)
        #expect(failureKind { try other.secrets.currentSecret() } == .phoneLocked)
        #expect(failureKind { try other.secrets.createConfirmed(keyVault: "v1") } == .phoneLocked)
        #expect(other.keys.created == 0)
        // The records file's key refused for now.
        t.fileKeys.state.behaviour = .locked
        #expect(failureKind { try t.secrets.currentSecret() } == .phoneLocked)
        t.fileKeys.state.behaviour = .normal
        #expect(try t.records == before)
        #expect(t.keys.created == 1)
        #expect(try await t.secrets.unlock(vault) == .opened)
    }

    /// A device without a Secure Enclave makes nothing (`hardwareKeys`).
    @Test func noSecureHardwareIsRefused() throws {
        let none = try TestPhone(keys: SoftwarePhoneSecretSource { throw KeysError.noSecureHardware })
        #expect(failureKind { try none.secrets.createConfirmed(keyVault: "v1") } == .hardwareKeys)
        #expect(try none.records == PhoneRecords())
    }

    /// A retry of an enrollment or a transfer reuses `P` and the epoch-1 record the vault may already hold; another
    /// `key_vault`, a later epoch, or keys that no longer work make new ones.
    @Test func aRetryReusesTheKeyOfEpochOne() throws {
        // An enrollment sent, its answer not arrived: the retry reuses the pending key and record.
        let made = try t.secrets.create(keyVault: "v1")
        let first = made.secret
        #expect(try t.records.pendings.last?.keyVault == "v1")
        let retried = try t.secrets.reuseOrCreate(keyVault: "v1")
        #expect(retried.secret == first && retried.id == made.id)
        #expect(t.keys.created == 1)
        // After the success, a retry still reuses the current epoch-1 record.
        #expect(try !t.secrets.confirmCreate(id: "no-such-id"))
        try t.secrets.confirmCreate(id: made.id)
        #expect(try t.secrets.reuseOrCreate(keyVault: "v1").secret == first)
        #expect(t.keys.created == 1)
        // Another vault: a new pending key and record; the old vault's key and record stay until that succeeds.
        let otherMade = try t.secrets.reuseOrCreate(keyVault: "v2")
        let other = otherMade.secret
        #expect(other != first)
        #expect(t.keys.keyVaults == ["v1", "v2"])
        #expect(try t.secrets.currentSecret() == first)
        try t.secrets.confirmCreate(id: otherMade.id)
        #expect(try t.secrets.currentSecret() == other)
        // A later epoch: a new epoch 1.
        _ = try t.secrets.beginChange(operation: "op")
        try t.secrets.confirmChange(operation: "op")
        _ = try t.secrets.reuseOrCreate(keyVault: "v2").secret
        #expect(try t.records.pendings.last?.epoch == 1)
        #expect(t.keys.created == 3)
        // A key that is gone: a new one.
        t.keys.deleteKeys(of: "v2")
        _ = try t.secrets.reuseOrCreate(keyVault: "v2").secret
        #expect(t.keys.created == 4)
        // Nothing yet: a new key.
        let fresh = try TestPhone()
        _ = try fresh.secrets.reuseOrCreate(keyVault: "v3").secret
        #expect(try fresh.records.pendings.last?.keyVault == "v3")
    }

    /// A transfer's new phone keeps `key_vault` "" for the key's life.
    @Test func theKeyVaultOfATransferStaysEmpty() throws {
        _ = try t.secrets.createConfirmed(keyVault: "")
        _ = try t.secrets.beginChange(operation: "op")
        try t.secrets.confirmChange(operation: "op")
        #expect(try t.records.all.allSatisfy { $0.keyVault == "" })
        #expect(t.keys.keyVaults == [""])
    }

    /// Only answers the vault gives after the secret matched move a record.
    @Test func onlyAnswersAfterTheSecretCheckConfirm() {
        #expect(UnlockEpoch.confirmsNext(ok: true, code: nil))
        #expect(UnlockEpoch.confirmsNext(ok: false, code: "bad_pin"))
        #expect(UnlockEpoch.confirmsNext(ok: false, code: "transfer_incomplete"))
        for c in ["device_secret", "backoff", "manifest", "retry", "attestation", "recovery_pending", nil] {
            #expect(!UnlockEpoch.confirmsNext(ok: false, code: c))
        }
        #expect(UnlockEpoch.restoresEarlier(ok: true, code: nil))
        #expect(UnlockEpoch.restoresEarlier(ok: false, code: "transfer_incomplete"))
        #expect(!UnlockEpoch.restoresEarlier(ok: false, code: "bad_pin"))
    }

    /// The records file round-trips, refuses a fifth candidate, and a format this app does not know is never used nor
    /// written over (VAULT-MESSAGING §11.14.1 rule 9).
    @Test func theRecordsFile() throws {
        _ = try t.secrets.createConfirmed(keyVault: "v1")
        _ = try t.secrets.beginChange(operation: "a")
        try t.secrets.confirmChange(operation: "a")
        _ = try t.secrets.beginChange(operation: "b")
        t.secrets.endChange(operation: "b")
        let recs = try t.records
        #expect(try PhoneRecords.parse(recs.marshal()) == recs)
        #expect(recs.current != nil && recs.candidates.count == 1 && recs.replaced.count == 1)
        var five = recs
        five.candidates = Array(repeating: recs.candidates[0], count: 5)
        #expect(throws: CryptoError.self) { try PhoneRecords.parse(five.marshal()) }

        let store = EncryptedFileStore(url: t.url, purpose: PhoneSecrets.purpose, keys: t.fileKeys, protectedData: t.protectedData)
        try store.save(Array(#"{"v":2,"current":null}"#.utf8))
        #expect(failureKind { try t.secrets.currentSecret() } == .localState)
        #expect(failureKind { try t.secrets.createConfirmed(keyVault: "v1") } == .localState)
        #expect(failureKind { try t.secrets.beginChange(operation: "c") } == .localState)
        #expect(try store.load() == Array(#"{"v":2,"current":null}"#.utf8))
    }

    /// A wipe deletes every phone key and record.
    @Test func aWipeDeletesEveryKeyAndRecord() throws {
        _ = try t.secrets.createConfirmed(keyVault: "v1")
        _ = try t.secrets.beginChange(operation: "op")
        try t.secrets.delete()
        #expect(t.keys.keyVaults.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: t.url.path))
        #expect(try t.records == PhoneRecords())
    }

    /// The new failures have the texts of IOS-PLAN §14.
    @Test func theIPhoneTexts() {
        #expect(FailureKind.phoneLocked.message == "Unlock your iPhone, then try again.")
        #expect(FailureKind.unconfirmedChanges.message == """
            Unlock your vault first, then try again. VettID needs to confirm your last change before it can make another.
            """)
    }
}
