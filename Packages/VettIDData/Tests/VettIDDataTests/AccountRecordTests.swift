import Foundation
import Testing
@testable import VettIDData
import VettIDKeys
import VettIDKeysTesting
import VettIDVault

// Fixtures stay on one line each.
// swiftlint:disable line_length

/// The account record (vettid-android `AccountRecordTest`): read only when asked, members it does not know ignored, a
/// record that does not read never taken for "no account", and a write for a record that a reset replaced dropped.
@MainActor
@Suite struct AccountRecordTests {
    let keys = InMemoryFileKeyHolder()
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("vettid-record-tests/\(UUID().uuidString)/account")

    func store(_ available: Bool = true) -> EncryptedFileStore {
        EncryptedFileStore(
            url: url, purpose: VaultFiles.account, keys: keys, protectedData: ProtectedDataFlag(available: available)
        )
    }

    @Test func aMissingRecordIsNoAccountAndAWrittenOneIsReadBack() throws {
        let r = AccountRecord(store: store())
        try r.load()
        #expect(r.value == LocalAccount() && r.value.info() == nil)
        try r.reset(LocalAccount(userGuid: "u", vaultID: "v", emailHint: "m***@example.com"))
        try r.update(since: r.generation) { $0.capabilities = ["recovery_r"] }
        let again = AccountRecord(store: store())
        try again.load()
        #expect(again.value.userGuid == "u" && again.value.vaultID == "v" && again.value.capabilities == ["recovery_r"])
        #expect(again.value.info() == AccountInfo(emailHint: "m***@example.com"))
    }

    /// (Release R, §11.14.6) An open that got no answer and the attempts last reported are kept across a restart; an older
    /// record has neither.
    @Test func theRecoveryOpensStateIsKeptAcrossARestart() throws {
        let r = AccountRecord(store: store())
        try r.load()
        try r.reset(LocalAccount(userGuid: "u", vaultID: "v", emailHint: "m***@example.com"))
        #expect(!r.value.recoveryOpenUnanswered && r.value.recoveryAttemptsUsed == nil && !r.value.recoveryRegistered)
        try r.update(since: r.generation) {
            $0.recoveryOpenUnanswered = true
            $0.recoveryAttemptsUsed = 3
            $0.recoveryRegistered = true
        }
        let again = AccountRecord(store: store())
        try again.load()
        #expect(again.value.recoveryOpenUnanswered && again.value.recoveryAttemptsUsed == 3)
        // The vault holds the key the register attested: no start-over replaces a damaged key record, also when recovered.
        #expect(!again.value.noVaultHoldsAttestKey)
        try store().save(Array(#"{"user_guid":"u"}"#.utf8))
        let older = AccountRecord(store: store())
        try older.load()
        #expect(!older.value.recoveryOpenUnanswered && older.value.recoveryAttemptsUsed == nil)
    }

    /// Members of a later build are ignored; a missing member takes its default.
    @Test func unknownMembersAreIgnored() throws {
        try store().save(Array(#"{"user_guid":"u","snapshot":{"x":1},"setup_complete":true}"#.utf8))
        let r = AccountRecord(store: store())
        try r.load()
        #expect(r.value.userGuid == "u" && r.value.setupComplete && r.value.vaultID.isEmpty)
    }

    // MARK: - The own account is not the record's (IOS-PLAN §4.7, vettid-android `OwnAccountTest`)

    /// A record of an older build is read without the own account and written again without it.
    @Test func aRecordOfAnOlderBuildIsReadWithoutTheOwnAccountAndWrittenAgainWithout() throws {
        let legacy = #"{"user_guid":"u","vault_id":"v","email_hint":"a***@example.org","snapshot":{"v":1,"email":"ada@example.org","first_name":"Ada","last_name":"Lovelace"},"name_request":{"seq":3,"first_name":"Ada","last_name":"King","state":"pending"},"setup_complete":true}"#
        try store().save(Array(legacy.utf8))
        let r = AccountRecord(store: store())
        try r.load()
        #expect(r.value.userGuid == "u" && r.value.setupComplete)
        let written = try written()
        #expect(!written.contains("snapshot") && !written.contains("name_request"))
        #expect(!written.contains("Lovelace") && !written.contains("ada@example.org"))
        #expect(written.contains("a***@example.org"))
    }

    /// `account.get`'s answer writes only the masked email to the record.
    @Test func anAccountAnswerWritesOnlyTheMaskedEmail() throws {
        let r = AccountRecord(store: store())
        try r.load()
        try r.reset(LocalAccount(userGuid: "u", vaultID: "v", emailHint: "o***@example.org"))
        let snap = try AccountUpdateTests.snapshot(OwnAccountTests.snapJSON)
        let request = NameRequest(seq: 3, firstName: "Ada", lastName: "King", requestedAt: nil, state: "pending")
        #expect(try r.refreshed(since: r.generation, AccountUpdate(snapshot: snap, nameRequest: request)))
        #expect(r.value == LocalAccount(userGuid: "u", vaultID: "v", emailHint: "a***@example.org"))
        let written = try written()
        #expect(!written.contains("Lovelace") && !written.contains("King") && !written.contains("ada@example.org"))
    }

    /// The record's file as text.
    func written() throws -> String {
        let bytes = try #require(try store().load())
        return try #require(String(bytes: bytes, encoding: .utf8))
    }

    /// The record has no place for the own account: what it encodes never names it.
    @Test func theAccountRecordHasNoPlaceForTheOwnAccount() throws {
        let encoded = try #require(String(bytes: try JSONEncoder().encode(LocalAccount(userGuid: "u", vaultID: "v", emailHint: "a")), encoding: .utf8))
        #expect(!encoded.contains("snapshot") && !encoded.contains("name_request"))
    }

    /// A record that does not parse, or cannot be read while the iPhone is locked, is never "no account".
    @Test func anUnreadableRecordIsNotEmpty() throws {
        try store().save(Array("not json".utf8))
        #expect(throws: KeysError.corrupt("account record")) { try AccountRecord(store: self.store()).load() }
        #expect(throws: KeysError.self) { try AccountRecord(store: self.store(false)).load() }
    }

    /// A write for the record an operation started with is dropped once a reset replaced it.
    @Test func aWriteAfterAResetIsDropped() throws {
        let r = AccountRecord(store: store())
        try r.reset(LocalAccount(userGuid: "u", vaultID: "v", emailHint: "h"))
        let since = r.generation
        try r.reset(LocalAccount())
        #expect(try !r.update(since: since) { $0.vaultID = "other" })
        #expect(r.value == LocalAccount())
    }
}

// swiftlint:enable line_length
