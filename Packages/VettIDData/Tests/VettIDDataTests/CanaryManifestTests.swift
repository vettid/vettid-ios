import CryptoKit
import Foundation
import Testing
import VettIDAltChan
import VettIDAttestation
import VettIDCrypto
@testable import VettIDData
import VettIDDataTesting
import VettIDKeys

/// The canary manifest on the phone (VAULT-RELEASES §10.1 step 9, VAULT-MESSAGING §11.10.1 "A canary manifest") end to
/// end against ``FakeVaultService``, whose manifests are signed with the §16 TEST key: the installation checks, the
/// choice before each enroll and unlock, its removal, its retirement once published, and the wipe. Mirrors
/// vettid-android `CanaryManifestStoreTest` and `CanaryManifestTest`.
@MainActor
@Suite(.serialized) struct CanaryManifestTests {
    let service: FakeVaultService
    let phone: TestVaultPhone
    let pin = "402817"

    init() throws {
        service = try FakeVaultService()
        phone = try TestVaultPhone(service: service)
    }

    var m: VaultManager { phone.manager }
    var canary: CanaryManifestManager { m.canary }
    var file: URL { phone.directory.appendingPathComponent(VaultFiles.canary) }
    var fileExists: Bool { FileManager.default.fileExists(atPath: file.path) }

    func setUp() async throws {
        _ = try await m.redeemSetupCode(.secret(service.secret))
        try await m.enroll(pin: pin) { _ in }
        try await m.createCredential(password: "correct horse battery", backup: true, pin: pin) { _ in }
        try await m.finishSetup()
        #expect(m.phase == .unlocked)
    }

    /// A lock and an unlock: the vault's answer records the serial the unlock used.
    func lockAndUnlock() async throws {
        try await m.lock()
        #expect(try await m.unlock(pin: pin) == .success)
    }

    /// The serial this phone used for its vault (the vault's unlock answer says it, §11.4).
    var seen: UInt64 { m.session?.device.manifestSerialSeen() ?? 0 }

    func expectRefused(_ code: String, _ doc: [UInt8], sourceLocation: SourceLocation = #_sourceLocation) async {
        do {
            _ = try await canary.checkCanaryManifest(doc)
            Issue.record("expected \(code)", sourceLocation: sourceLocation)
        } catch let f as VaultFailure {
            #expect(f.kind == .manifest && f.code == code, "\(f)", sourceLocation: sourceLocation)
        } catch {
            Issue.record("unexpected \(error)", sourceLocation: sourceLocation)
        }
        // Installing refuses it the same way, and nothing is installed.
        await #expect(throws: VaultFailure.self, sourceLocation: sourceLocation) { try await canary.installCanaryManifest(doc) }
        #expect(canary.canaryManifest == nil && !fileExists, sourceLocation: sourceLocation)
    }

    // MARK: - Installation

    /// Before a channel's first release nothing is published (404): a canary document signed with the TEST key (the
    /// key this test build pins) is shown, installed only when confirmed, stored encrypted, and used for the enrollment.
    @Test func aCanaryInstallsAndIsUsedWhileNothingIsPublished() async throws {
        defer { phone.close() }
        service.publishedSerial = nil
        let doc = try service.canaryDocument(serial: 8)
        let v = try await canary.checkCanaryManifest(doc)
        #expect(v.serial == 8 && v.keyID == "1edbb48b6669decd" && v.sha256.count == 64)
        #expect(v.releases.map(\.number) == [3] && v.releases.map(\.status) == ["active"])
        // Checked only: nothing installed before the member confirms.
        #expect(canary.canaryManifest == nil && !fileExists)

        #expect(try await canary.installCanaryManifest(doc) == v)
        #expect(canary.canaryManifest == v && fileExists)
        // Encrypted: the file is not the document.
        let raw = try [UInt8](Data(contentsOf: file))
        #expect(raw != doc && indexOf(raw, Array("manifest".utf8)) == nil)

        try await setUp()
        try await lockAndUnlock()
        #expect(seen == 8)
        #expect(canary.canaryManifest == v)
    }

    /// With a published manifest of a lower serial, the canary's is the one used.
    @Test func theHigherCanaryIsChosenOverThePublishedOne() async throws {
        defer { phone.close() }
        _ = try await canary.installCanaryManifest(try service.canaryDocument(serial: 8))
        try await setUp()
        try await lockAndUnlock()
        #expect(seen == 8)
    }

    /// Without a canary, nothing published is an error, as before.
    @Test func withoutACanaryNothingPublishedFails() async throws {
        defer { phone.close() }
        service.publishedSerial = nil
        _ = try await m.redeemSetupCode(.secret(service.secret))
        await #expect(throws: VaultFailure.self) { try await m.enroll(pin: pin) { _ in } }
    }

    @Test func aDocumentSignedByAnotherKeyIsRefused() async throws {
        defer { phone.close() }
        let other = P256.Signing.PrivateKey()
        await expectRefused(CanaryManifestCodes.signature, try service.canaryDocument(serial: 8, signer: other))
        // Another key's signature under the pinned key_id.
        let pinned = try service.canaryDocument(serial: 8)
        let forged = try service.canaryDocument(serial: 8, signer: other)
        let doc = try JsonBuilder().string("manifest", try StrictJson.parseObject(forged).string("manifest"))
            .string("sig", try StrictJson.parseObject(forged).string("sig"))
            .string("key_id", try StrictJson.parseObject(pinned).string("key_id")).bytes()
        await expectRefused(CanaryManifestCodes.signature, doc)
    }

    @Test func aDocumentNotInTheStrictFormatIsRefused() async throws {
        defer { phone.close() }
        for doc in [Array("{}".utf8), Array("not json".utf8), Array(#"{"manifest":"","sig":"","key_id":""}"#.utf8)] {
            await expectRefused(CanaryManifestCodes.format, doc)
        }
        // A manifest that is not compact JSON, correctly signed with the TEST key.
        let pretty = Array(#"{ "v":1,"serial":8,"issued_at":"2026-10-02T12:00:00Z","releases":[] }"#.utf8)
        let sig = try FakeVaultService.testManifestSigner.signature(for: Array(ReleaseManifest.label.utf8) + [0] + pretty)
        let doc = JsonBuilder().base64("manifest", pretty).base64("sig", Array(sig.rawRepresentation))
            .string("key_id", "1edbb48b6669decd").bytes()
        await expectRefused(CanaryManifestCodes.format, doc)
        await expectRefused(CanaryManifestCodes.tooLarge, [UInt8](repeating: 0x20, count: ReleaseManifest.maxServed + 1))
    }

    /// Lower than the serial this phone used: refused.
    @Test func aLowerSerialIsRefused() async throws {
        defer { phone.close() }
        service.publishedSerial = 7
        try await setUp()
        try await lockAndUnlock()
        #expect(seen == 7)
        service.publishedSerial = 5
        await expectRefused(CanaryManifestCodes.older, try service.canaryDocument(serial: 6))
    }

    /// The published manifest already has that serial or a newer one: refused.
    @Test func anAlreadyPublishedSerialIsRefused() async throws {
        defer { phone.close() }
        service.publishedSerial = 8
        await expectRefused(CanaryManifestCodes.published, try service.canaryDocument(serial: 8))
        service.publishedSerial = 9
        await expectRefused(CanaryManifestCodes.published, try service.canaryDocument(serial: 8))
    }

    /// A published manifest that cannot be read (other than a 404) or does not verify refuses the installation: the
    /// check is what keeps a stale canary out (the owner's decision, vettid-ios #67).
    @Test func anUnreadablePublishedManifestRefuses() async throws {
        defer { phone.close() }
        service.manifestOffline = true
        await expectRefused(CanaryManifestCodes.unchecked, try service.canaryDocument(serial: 8))
        #expect(canary.canaryManifest == nil && !fileExists)
    }

    @Test func aPublishedManifestThatDoesNotVerifyRefuses() async throws {
        defer { phone.close() }
        service.manifestBroken = true
        await expectRefused(CanaryManifestCodes.unchecked, try service.canaryDocument(serial: 8))
        #expect(canary.canaryManifest == nil && !fileExists)
    }

    /// The serial this phone used cannot be read (its device state is not readable now): nothing is installed (chosen;
    /// not in the spec).
    @Test func anUnreadableSerialRefusesCleanly() async throws {
        defer { phone.close() }
        phone.prepareFailure = VaultFailure(.phoneLocked)
        try FileManager.default.createDirectory(at: phone.directory, withIntermediateDirectories: true)
        try Data([1]).write(to: phone.directory.appendingPathComponent(VaultFiles.device))
        await expectRefused(CanaryManifestCodes.unchecked, try service.canaryDocument(serial: 8))
    }

    /// One canary manifest at a time: a new one replaces the installed one.
    @Test func aSecondCanaryReplacesTheFirst() async throws {
        defer { phone.close() }
        _ = try await canary.installCanaryManifest(try service.canaryDocument(serial: 8))
        let doc9 = try service.canaryDocument(serial: 9)
        let v9 = try await canary.installCanaryManifest(doc9)
        #expect(canary.canaryManifest == v9 && v9.serial == 9)
        #expect(canary.store.served() == doc9)
    }

    /// A stored document that no longer verifies under this build's pins is dropped when it is read at the start.
    @Test func aStoredCanaryThatNoLongerVerifiesIsDropped() async throws {
        defer { phone.close() }
        let other = try service.canaryDocument(serial: 8, signer: P256.Signing.PrivateKey())
        let file = EncryptedFileStore(
            url: self.file, purpose: VaultFiles.canary, keys: phone.fileKeys, protectedData: phone.protectedData
        )
        try file.save(other)
        try await phone.restart()
        try await m.refresh()
        #expect(canary.canaryManifest == nil)
        #expect(!fileExists)
    }

    /// A wipe while an installation is being checked: nothing is written after it.
    @Test func aWipeDuringTheChecksSavesNothing() async throws {
        let store = CanaryManifestStore(file: EncryptedFileStore(
            url: file, purpose: VaultFiles.canary, keys: phone.fileKeys, protectedData: phone.protectedData
        ))
        let ref = ManagerBox()
        let mgr = CanaryManifestManager(
            store: store, trust: try service.trust,
            seen: {
                ref.manager?.forget()
                return 0
            },
            published: { throw MemberApiError(status: 404, code: MemberApiError.manifestUnavailable) }
        )
        ref.manager = mgr
        await #expect(throws: VaultFailure.self) { try await mgr.installCanaryManifest(try service.canaryDocument(serial: 8)) }
        #expect(mgr.canaryManifest == nil && store.served() == nil)
        // After it, an installation works again.
        ref.manager = nil
        _ = try await mgr.installCanaryManifest(try service.canaryDocument(serial: 8))
        #expect(mgr.canaryManifest?.serial == 8)
    }

    // MARK: - Removal, publication, restart and the wipe

    /// "Stop using the test manifest": the published manifest is used again.
    @Test func removalWorks() async throws {
        defer { phone.close() }
        service.publishedSerial = nil
        _ = try await canary.installCanaryManifest(try service.canaryDocument(serial: 8))
        canary.removeCanaryManifest()
        #expect(canary.canaryManifest == nil && !fileExists)
        _ = try await m.redeemSetupCode(.secret(service.secret))
        await #expect(throws: VaultFailure.self) { try await m.enroll(pin: pin) { _ in } }
    }

    /// Once the published serial reaches the canary's (the same document published), the published one is used and the
    /// canary is dropped by itself.
    @Test func theCanaryIsDroppedOncePublished() async throws {
        defer { phone.close() }
        _ = try await canary.installCanaryManifest(try service.canaryDocument(serial: 8))
        try await setUp()
        try await m.lock()
        service.publishedSerial = 8
        #expect(try await m.unlock(pin: pin) == .success)
        #expect(await eventually { canary.canaryManifest == nil })
        #expect(!fileExists && seen == 8)
    }

    /// The installed document survives a restart and is read again.
    @Test func aRestartReadsItAgain() async throws {
        defer { phone.close() }
        let v = try await canary.installCanaryManifest(try service.canaryDocument(serial: 8))
        try await phone.restart()
        #expect(canary.canaryManifest == nil)
        try await m.refresh()
        #expect(canary.canaryManifest == v)
    }

    /// The wipe of this phone erases it with everything else.
    @Test func theWipeErasesIt() async throws {
        defer { phone.close() }
        _ = try await canary.installCanaryManifest(try service.canaryDocument(serial: 8))
        try await setUp()
        try await m.eraseThisPhone()
        #expect(m.phase == .signedOut)
        #expect(canary.canaryManifest == nil && !fileExists)
    }

    /// The file is read at most the limit plus one byte.
    @Test func aSharedFileIsReadBounded() throws {
        let url = phone.directory.deletingLastPathComponent().appendingPathComponent("served-9.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x20, count: ReleaseManifest.maxServed + 5000).write(to: url)
        #expect(try CanaryManifestInbox.readBounded(url).count == ReleaseManifest.maxServed + 1)
        let doc = try service.canaryDocument(serial: 9)
        try Data(doc).write(to: url)
        #expect(try CanaryManifestInbox.readBounded(url) == doc)
    }
}

/// The manager under test, for its own `seen` closure.
@MainActor
final class ManagerBox {
    weak var manager: CanaryManifestManager?
}

/// The first index of [needle] in [hay].
private func indexOf(_ hay: [UInt8], _ needle: [UInt8]) -> Int? {
    guard hay.count >= needle.count else { return nil }
    return (0...(hay.count - needle.count)).first { Array(hay[$0..<($0 + needle.count)]) == needle }
}
