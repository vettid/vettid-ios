import Foundation
import Testing
import VettIDCrypto
@testable import VettIDData
import VettIDDataTesting

/// The member's own shared profile end to end against ``FakeVaultService``, which answers as vettid-vault does
/// (VAULT-MESSAGING §10.8): read when the vault opens, with the core from the account snapshot and the vault's key; the
/// display name and the photo set against the version read; `profile.changed` read again; the core never sent; nothing
/// kept once the vault is locked. Mirrors the profile part of vettid-android's `VaultManager` tests.
@MainActor
@Suite(.serialized) struct VaultManagerProfileTests {
    let service: FakeVaultService
    let phone: TestVaultPhone
    let pin = "402817"
    let password = "correct horse battery"

    init() throws {
        service = try FakeVaultService()
        phone = try TestVaultPhone(service: service)
    }

    var m: VaultManager { phone.manager }

    func setUp() async throws {
        service.accountSnapshot(VaultManagerSettingsTests.snapshot)
        _ = try await m.redeemSetupCode(.secret(service.secret))
        try await m.enroll(pin: pin) { _ in }
        try await m.createCredential(password: password, backup: true, pin: pin) { _ in }
        try await m.finishSetup()
        #expect(m.phase == .unlocked)
    }

    /// A JPEG's first bytes and some more: what the vault takes as an image (it does not decode it).
    static func jpeg(_ n: Int) -> [UInt8] { [0xFF, 0xD8, 0xFF, 0xE0] + [UInt8](repeating: 0x11, count: max(0, n - 4)) }

    @Test func theProfileIsReadWhenTheVaultOpensWithTheCore() async throws {
        defer { phone.close() }
        try await setUp()
        #expect(await eventually { m.profiles.profile?.fullName == "Ada Lovelace" })
        let fp = try #require(m.profiles.profile?.fingerprint)
        #expect(fp.count == 39, "8 groups of 4 hex digits")
        #expect(m.profiles.profile?.displayName == "" && m.profiles.profile?.photo == nil)
    }

    /// The photo and the display name go with `profile.set` against the version read, never naming the core; the vault's
    /// `profile.changed` is read again.
    @Test func thePhotoAndTheDisplayNameAreSet() async throws {
        defer { phone.close() }
        try await setUp()
        #expect(await eventually { m.profiles.profile != nil })
        let photo = Base64s.encodeStd(Self.jpeg(1_000))
        try await m.profiles.setPhoto(photo)
        #expect(service.profilePhoto == Self.jpeg(1_000))
        #expect(service.profileSets.last?.version == 0 && service.profileSets.last?.name == nil)
        #expect(m.profiles.profile?.photo == photo && m.profiles.profile?.version == 1)
        try await m.profiles.setDisplayName(" Countess ")
        #expect(service.profileName == "Countess" && service.profileSets.last?.version == 1 && service.profileSets.last?.photo == nil)
        #expect(m.profiles.profile?.displayName == "Countess")
        try await m.profiles.setPhoto("")
        #expect(service.profilePhoto.isEmpty && m.profiles.profile?.photo == nil)
    }

    /// The vault's limits: a photo over 65,536 bytes, or not a JPEG or PNG, is refused and nothing changes.
    @Test func aPhotoOverTheLimitIsRefused() async throws {
        defer { phone.close() }
        try await setUp()
        #expect(await eventually { m.profiles.profile != nil })
        await #expect(throws: VaultFailure.self) { try await m.profiles.setPhoto(Base64s.encodeStd(Self.jpeg(65_537))) }
        await #expect(throws: VaultFailure.self) { try await m.profiles.setPhoto(Base64s.encodeStd([UInt8](repeating: 1, count: 100))) }
        #expect(service.profilePhoto.isEmpty && m.profiles.profile?.photo == nil)
        try await m.profiles.setPhoto(Base64s.encodeStd(Self.jpeg(65_536)))
        #expect(service.profilePhoto.count == 65_536)
    }

    /// The display name is text without control characters (vettid-vault `itemspec.ValidText`): refused, nothing changes.
    @Test func aDisplayNameWithAControlCharacterIsRefused() async throws {
        defer { phone.close() }
        try await setUp()
        #expect(await eventually { m.profiles.profile != nil })
        let f = await failure { try await m.profiles.setDisplayName("Ada\u{7}") }
        #expect(f?.code == "bad_request", "\(String(describing: f))")
        #expect(service.profileName.isEmpty && m.profiles.profile?.displayName == "")
    }

    /// `checkProfile` (§10.8): a change that would bring the `profile.update` body, with maximum-length names, over 196,608
    /// bytes is refused with `limit` `profile_size`, its bound and size named; nothing changes.
    @Test func aPhotoThatMakesTheSharedProfileTooLargeIsRefused() async throws {
        defer { phone.close() }
        try await setUp()
        #expect(await eventually { m.profiles.profile != nil })
        service.profileItems(bytes: 120_000)
        let f = await failure { try await m.profiles.setPhoto(Base64s.encodeStd(Self.jpeg(60_000))) }
        #expect(f?.kind == .limit && f?.limit?.name == "profile_size" && f?.limit?.max == 196_608, "\(String(describing: f))")
        #expect((f?.limit?.size ?? 0) > 196_608)
        #expect(service.profilePhoto.isEmpty && m.profiles.profile?.photo == nil)
        // A smaller photo fits.
        try await m.profiles.setPhoto(Base64s.encodeStd(Self.jpeg(10_000)))
        #expect(service.profilePhoto.count == 10_000)
    }

    func failure(_ body: () async throws -> Void) async -> VaultFailure? {
        do {
            try await body()
            return nil
        } catch {
            return error as? VaultFailure
        }
    }

    /// A change made on another of the member's devices arrives with `profile.changed`.
    @Test func aChangeElsewhereIsReadAgain() async throws {
        defer { phone.close() }
        try await setUp()
        #expect(await eventually { m.profiles.profile != nil })
        service.profileChangedElsewhere(name: "Ada", photo: Self.jpeg(500))
        #expect(await eventually { m.profiles.profile?.displayName == "Ada" })
        #expect(m.profiles.profile?.photo == Base64s.encodeStd(Self.jpeg(500)))
    }

    /// Nothing read from the vault is kept once it is locked; the next opening reads it again.
    @Test func theProfileIsForgottenAtTheLock() async throws {
        defer { phone.close() }
        try await setUp()
        try await m.profiles.setPhoto(Base64s.encodeStd(Self.jpeg(800)))
        #expect(m.profiles.profile?.photo != nil)
        try await m.lock()
        #expect(m.profiles.profile == nil)
        _ = try await m.unlock(pin: pin)
        #expect(await eventually { m.profiles.profile?.photo == Base64s.encodeStd(Self.jpeg(800)) })
    }

    // MARK: - The own account and profile while the vault is not open (IOS-PLAN §4.7)

    /// The names, the full address and the photo leave memory at the lock, and only the masked hint stays on the phone;
    /// the unlock reads them again. Mirrors vettid-android `VaultManager`'s own-profile wiring (`OwnProfileStep.onPhase`).
    @Test func theOwnAccountIsForgottenAtTheLockAndReadAgainAfterTheUnlock() async throws {
        defer { phone.close() }
        try await setUp()
        try await m.profiles.setPhoto(Base64s.encodeStd(Self.jpeg(800)))
        #expect(await eventually { m.account?.fullName == "Ada Lovelace" && m.account.shownInShell != nil })
        try await m.lock()
        #expect(m.account?.fullName == nil && m.account?.email == nil && m.account.shownInShell == nil)
        #expect(m.account?.emailHint == "m***@example.com", "the unlock screen's hint stays")
        #expect(m.profiles.profile == nil && m.ownAccount.snapshot == nil)
        _ = try await m.unlock(pin: pin)
        #expect(await eventually { m.account?.fullName == "Ada Lovelace" && m.profiles.profile?.photo != nil })
        #expect(m.account?.email == "member@example.com")
    }

    /// Held or due (VAULT-MESSAGING §3.6.3): the names, the full address and the photo leave memory; the passed check
    /// reads them again. Mirrors vettid-android `OwnProfileStep.onCheck`.
    @Test func theHoldForgetsTheOwnAccountAndThePassedCheckReadsItAgain() async throws {
        defer { phone.close() }
        try await setUp()
        #expect(await eventually { m.account.shownInShell != nil && m.profiles.profile != nil })
        service.advanceVaultClock(86_401)
        try await m.ownerChecks.refreshOwnerCheck()
        #expect(m.ownerChecks.ownerCheck?.state != .ok)
        #expect(m.account.shownInShell == nil && m.profiles.profile == nil)
        #expect(m.account?.emailHint == "m***@example.com")
        // While held nothing read comes back.
        await m.refreshAccount()
        #expect(m.account.shownInShell == nil)
        #expect(try await m.ownerChecks.check(pin: pin, password: password) == .passed)
        #expect(await eventually { m.account?.fullName == "Ada Lovelace" && m.profiles.profile != nil }, "read again after the check")
    }
}
