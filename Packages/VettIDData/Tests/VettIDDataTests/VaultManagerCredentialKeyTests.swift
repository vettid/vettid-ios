import Foundation
import Testing
import VettIDCrypto
@testable import VettIDData
import VettIDDataTesting
import VettIDVault

/// Vault status's Credential key row, the repository side (VAULT-MESSAGING 0.83.8 §10.8; ANDROID-PLAN 0.1.119 §4 "Owner
/// check and status"): `credential.version` asked for the fingerprint, and the key of a rotation or a new credential
/// published at once. Against ``FakeVaultService``. Mirrors vettid-android's `VaultManager.credentialKey` and
/// `credentialKeyUpdates`.
@MainActor
@Suite(.serialized) struct VaultManagerCredentialKeyTests {
    let service: FakeVaultService
    let phone: TestVaultPhone
    let pin = "402817"
    let password = "correct horse battery"
    /// VAULT-MESSAGING §16's credential key, 32 x 0x09, and its fingerprint as shown.
    let key = Data(repeating: 0x09, count: 32).base64EncodedString()
    let shown = "e939 754d 09aa a93a"

    init() throws {
        service = try FakeVaultService()
        service.stampsOnVaultClock = true
        phone = try TestVaultPhone(service: service, requestTimeout: TestVaultPhone.shortRequestTimeout)
    }

    var m: VaultManager { phone.manager }

    func setUp() async throws {
        _ = try await m.redeemSetupCode(.secret(service.secret))
        try await m.enroll(pin: pin) { _ in }
        try await m.createCredential(password: password, backup: true, pin: pin) { _ in }
        try await m.finishSetup()
        #expect(m.phase == .unlocked)
    }

    @Test func theKeyIsAskedAndShownAsItsFingerprint() async throws {
        defer { phone.close() }
        try await setUp()
        service.credentialKey = key
        #expect(try await m.credentialKey() == CredentialKeyAnswer(exists: true, fingerprint: shown))
    }

    /// An answer without a `key`, or with one that is not the base64 of 32 bytes: the fingerprint is not known.
    @Test func noKeyOrAnUnreadableOneHasNoFingerprint() async throws {
        defer { phone.close() }
        try await setUp()
        service.credentialKey = "not a key"
        #expect(try await m.credentialKey() == CredentialKeyAnswer(exists: true, fingerprint: nil))
        service.credentialKey = key
        service.versionWithoutKey = true
        #expect(try await m.credentialKey() == CredentialKeyAnswer(exists: true, fingerprint: nil))
    }

    /// A rotation's answer names the new key: published at once, a change of its own.
    @Test func aRotationPublishesTheNewKeysFingerprint() async throws {
        defer { phone.close() }
        try await setUp()
        let before = m.credentialKeyChange?.seq ?? 0
        service.nextCredentialKey = key
        try await m.openUnlockWindow(password: password)
        try await m.rotate(password: password)
        #expect(await eventually { (m.credentialKeyChange?.seq ?? 0) > before })
        #expect(m.credentialKeyChange?.fingerprint == shown)
    }

    /// A new credential (`credential.reset`) names its new key: published at once too.
    @Test func aNewCredentialPublishesItsKeysFingerprint() async throws {
        defer { phone.close() }
        try await setUp()
        try await m.openUnlockWindow(password: password)
        try await m.rotate(password: password)
        #expect(await eventually { m.credentialKeyChange != nil })
        let before = m.credentialKeyChange?.seq ?? 0
        service.nextCredentialKey = key
        try await m.newCredential(pin: pin, password: password, newPassword: "a new long password")
        #expect(await eventually { (m.credentialKeyChange?.seq ?? 0) > before })
        #expect(m.credentialKeyChange?.fingerprint == shown)
    }

    /// A key that is not 32 bytes: the change says the key is not known (the screen asks again).
    @Test func anUnreadableKeyIsAChangeWithoutFingerprint() async throws {
        defer { phone.close() }
        try await setUp()
        let before = m.credentialKeyChange?.seq ?? 0
        try await m.openUnlockWindow(password: password)
        try await m.rotate(password: password) // the fake's made-up key
        #expect(await eventually { (m.credentialKeyChange?.seq ?? 0) > before })
        #expect(m.credentialKeyChange?.fingerprint == nil)
    }

    @Test func neitherPrintsTheFingerprint() {
        #expect("\(CredentialKeyAnswer(exists: true, fingerprint: shown))" == "CredentialKeyAnswer")
        #expect(!"\(CredentialKeyChange(seq: 1, fingerprint: shown))".contains("e939"))
    }
}
