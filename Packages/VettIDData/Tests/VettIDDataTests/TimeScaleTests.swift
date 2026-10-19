import CryptoKit
import Foundation
import Testing
import VettIDAltChan
import VettIDCrypto
@testable import VettIDData
import VettIDDataTesting
import VettIDKeys
import VettIDKeysTesting

/// The staging time scale (STAGING-TIME-SCALE §3, §5.2; VAULT-MESSAGING 0.43.0 §11.10.9; IOS-PLAN §6.6): each app-side
/// wait divided by the vault's scale when it starts, the texts and the staging note.
struct TimeScaleWaitTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// S2: the early warning from 1 h before the deadline in real time, 2.5 minutes at 24.
    @Test func theEarlyWarningIsScaled() {
        let real = OwnerCheckView(state: .ok, deadline: now.addingTimeInterval(200))
        #expect(real.warning(now))
        var scaled = real
        scaled.timeScale = 24
        #expect(!scaled.warning(now))
        #expect(scaled.warning(now.addingTimeInterval(50)))
        #expect(!scaled.warning(now.addingTimeInterval(200)))
        #expect(scaled.scaledIntervalSeconds == 3_600 && real.scaledIntervalSeconds == 86_400)
    }

    /// S9: a replaced record made at 24 is kept 7 hours, and keeps them when the scale changes; one written before the
    /// scale (no `keep_ms`) keeps its 7 days.
    @Test func replacedRecordsAreKeptForTheScaledWeek() throws {
        let pub = Array(P256.KeyAgreement.PrivateKey().publicKey.x963Representation)
        let record = PhoneSecretRecord(keyVault: "v1", epoch: 2, ephemeral: pub, check: [UInt8](repeating: 7, count: 16))
        let entry = PhoneRecords.Entry(keyID: "k1", record: record)
        let start: Int64 = 1_800_000_000_000
        let fresh = PhoneRecords(replaced: [PhoneRecords.Replaced(entry: entry, operation: nil, since: start)])
        let keep7h = TimeScale.scaledMs(PhoneSecrets.keepMs, by: 24)
        #expect(keep7h == 7 * 3_600_000)
        let stored = PhoneSecrets.pruned(fresh, nowMs: start, keepMs: keep7h)
        #expect(stored.replaced.first?.keepMs == keep7h)
        // Stored and read back: the period goes with the record.
        let read = try PhoneRecords.parse(stored.marshal())
        #expect(read.replaced.first?.keepMs == keep7h)
        #expect(PhoneSecrets.pruned(read, nowMs: start + keep7h - 1).replaced.count == 1)
        #expect(PhoneSecrets.pruned(read, nowMs: start + keep7h).replaced.isEmpty)
        // A record from before the scale: 7 days, also when the vault is scaled now.
        let old = try PhoneRecords.parse(PhoneSecrets.pruned(fresh, nowMs: start).marshal())
        #expect(String(bytes: PhoneSecrets.pruned(fresh, nowMs: start).marshal(), encoding: .utf8)?.contains("keep_ms") == false)
        #expect(old.replaced.first?.keepMs == PhoneSecrets.keepMs)
        #expect(PhoneSecrets.pruned(old, nowMs: start + keep7h, keepMs: keep7h).replaced.count == 1)
        #expect(PhoneSecrets.pruned(old, nowMs: start + PhoneSecrets.keepMs, keepMs: keep7h).replaced.isEmpty)
    }

    /// S12: erase-or-recover after 7 days without contact, 7 hours at 24.
    @Test func theLongUnreachableWaitIsScaled() {
        let last: Int64 = 1_800_000_000_000
        let sevenHours = last + 7 * 3_600_000
        #expect(!StuckScreens.longUnreachable(.network, lastContactMs: last, nowMs: sevenHours))
        #expect(StuckScreens.longUnreachable(.network, lastContactMs: last, nowMs: sevenHours, timeScale: 24))
        #expect(!StuckScreens.longUnreachable(.network, lastContactMs: last, nowMs: sevenHours - 1, timeScale: 24))
        #expect(StuckScreens.longUnreachable(.network, lastContactMs: last, nowMs: last + StuckScreens.longUnreachableMs))
        #expect(!StuckScreens.longUnreachable(.clock, lastContactMs: last, nowMs: sevenHours, timeScale: 24))
    }

    /// S10: the old phone's 7 days (I3 starts the timer) at 24.
    @Test func theOldPhonesKeepIsScaled() {
        #expect(TimeScales.scaled(TimeScales.oldPhoneKeep, by: 24) == 7 * 3_600)
        #expect(TimeScales.scaled(TimeScales.oldPhoneKeep, by: 1) == 7 * 86_400)
    }

    @Test func durationsAreSaidInWholeUnits() {
        #expect(DurationText.of(86_400) == "24 hours")
        #expect(DurationText.of(7 * 86_400) == "7 days")
        #expect(DurationText.of(72 * 3_600) == "3 days")
        #expect(DurationText.of(3_600) == "1 hour")
        #expect(DurationText.of(7 * 3_600) == "7 hours")
        // Under 10 minutes in seconds, never rounded: 1 h at 24 is "150 seconds".
        #expect(DurationText.of(150) == "150 seconds")
        #expect(DurationText.of(599) == "599 seconds")
        #expect(DurationText.of(600) == "10 minutes")
        #expect(DurationText.of(5_400) == "90 minutes")
        #expect(DurationText.of(24) == "24 seconds")
        #expect(DurationText.of(1) == "1 second")
    }

    /// The texts show the scaled times; settings keep their real units with the scaled one beside; the note only on a
    /// staging vault.
    @Test func theTextsAndTheStagingNote() {
        #expect(TimeScales.text(TimeScales.recoveryDelay, by: 1) == "24 hours")
        #expect(TimeScales.text(TimeScales.recoveryDelay, by: 24) == "1 hour")
        #expect(TimeScales.text(TimeScales.recoveryQuiet, by: 24) == "3 hours")
        #expect(TimeScales.setting(86_400, by: 1) == "24 hours")
        #expect(TimeScales.setting(86_400, by: 24) == "24 hours (staging: 1 hour)")
        #expect(TimeScales.withStaging("Every 24 hours", 86_400, by: 24) == "Every 24 hours (staging: 1 hour)")
        #expect(TimeScales.stagingNote(24) == "Staging: 1 day = 1 hour")
        #expect(TimeScales.stagingNote(1) == nil && TimeScales.stagingNote(3_600) == nil)
    }

    /// STAGING-TIME-SCALE §5.2: the "this phone no longer holds the keys" text says a recovery's time at the scale.
    @Test func theDeviceSecretTextSaysTheScaledRecovery() {
        #expect(FailureKind.deviceSecret.message.contains("It takes 24 hours to 3 days, and you need"))
        #expect(FailureKind.deviceSecret.message(timeScale: 1) == FailureKind.deviceSecret.message)
        #expect(FailureKind.deviceSecret.message(timeScale: 24).contains("It takes 1 hour to 3 hours, and you need"))
        #expect(FailureKind.network.message(timeScale: 24) == FailureKind.network.message)
    }

    /// S9 end to end: a phone secret replaced on a staging vault is written with its 7 hours (`keep_ms`) and deleted
    /// after them.
    @Test func phoneSecretsWriteTheScaledKeep() throws {
        let clock = TestClock()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vettid-data-tests/\(UUID().uuidString)/VettID/phone-secrets")
        let store = EncryptedFileStore(
            url: url, purpose: PhoneSecrets.purpose, keys: InMemoryFileKeyHolder(), protectedData: ProtectedDataFlag(available: true)
        )
        let secrets = PhoneSecrets(keys: SoftwarePhoneSecretSource(), store: store, now: { clock.date }, timeScale: { 24 })
        _ = try secrets.createConfirmed(keyVault: "v1")
        _ = try secrets.createConfirmed(keyVault: "v1")
        let replaced = try #require(try secrets.records().replaced.first)
        #expect(replaced.keepMs == Int64(7 * 3_600_000))
        clock.advance(7 * 3_600_000 - 1)
        try secrets.prune()
        #expect(try secrets.records().replaced.count == 1)
        clock.advance(1)
        try secrets.prune()
        #expect(try secrets.records().replaced.isEmpty)
    }

    /// §11.10.9: the refusal's text, and the failure it maps from.
    @Test func theRefusalSaysTheSoftwareIsNotForThisApp() throws {
        #expect(FailureKind.timeScale.message == "This vault's software is not for this app. Contact VettID.")
        #expect(FailureKind.timeScale.messageKey == "data_failure_time_scale")
        let f = try #require(VaultFailures.map(TimeScaleRefused(scale: 24)) as? VaultFailure)
        #expect(f.kind == .timeScale && f.code == "time_scale")
    }

    /// The scale is stored per vault in the account record; a record without it (written before) is real time.
    @Test func theAccountRecordKeepsTheScale() throws {
        var a = LocalAccount(userGuid: "g", vaultID: "v", emailHint: "")
        #expect(a.timeScale == 1)
        a.timeScale = 24
        let read = try JSONDecoder().decode(LocalAccount.self, from: JSONEncoder().encode(a))
        #expect(read.timeScale == 24)
        let before = try JSONDecoder().decode(LocalAccount.self, from: Data(#"{"user_guid":"g","vault_id":"v"}"#.utf8))
        #expect(before.timeScale == 1)
    }
}

/// The scale end to end: learnt from the verified descriptor and `vault.status`, stored, refused by a production build.
@MainActor
@Suite(.serialized) struct VaultManagerTimeScaleTests {
    let pin = "402817"

    private func setUp(_ phone: TestVaultPhone, _ service: FakeVaultService) async throws {
        let m = phone.manager
        _ = try await m.redeemSetupCode(.secret(service.secret))
        try await m.enroll(pin: pin) { _ in }
        try await m.createCredential(password: "correct horse battery", backup: true, pin: pin) { _ in }
        try await m.finishSetup()
    }

    @Test func aStagingBuildStoresTheVaultsScale() async throws {
        let service = try FakeVaultService()
        service.timeScales = .staging
        service.timeScale = 24
        let phone = try TestVaultPhone(service: service)
        defer { phone.close() }
        let m = phone.manager
        try await setUp(phone, service)
        #expect(m.phase == .unlocked)
        #expect(m.timeScale == 24 && m.record.value.timeScale == 24 && m.ownerChecks.timeScale == 24)
        // The deadline learnt at 24 warns 2.5 minutes ahead.
        try await m.ownerChecks.refreshOwnerCheck()
        #expect(m.ownerChecks.ownerCheck?.timeScale == 24)
        try await m.lock()
        _ = try await m.preflight()
        #expect(m.timeScale == 24)
    }

    @Test func aProductionBuildSendsNothingToAScaledVault() async throws {
        let service = try FakeVaultService()
        service.timeScale = 24
        let phone = try TestVaultPhone(service: service)
        defer { phone.close() }
        let m = phone.manager
        _ = try await m.redeemSetupCode(.secret(service.secret))
        await #expect {
            try await m.enroll(pin: pin) { _ in }
        } throws: { e in
            (e as? VaultFailure)?.kind == .timeScale
        }
        #expect(m.timeScale == 1 && m.record.value.timeScale == 1)
    }

    /// A Release build reads any stored scale other than 1 as real time, whoever wrote it (I3's bundle included).
    @Test func aReleaseBuildReadsAStoredScaleAsReal() async throws {
        let service = try FakeVaultService()
        let phone = try TestVaultPhone(service: service)
        defer { phone.close() }
        let m = phone.manager
        try await setUp(phone, service)
        m.learnTimeScale(24, since: m.record.generation)
        #expect(m.record.value.timeScale == 24)
        #expect(m.timeScale == 1 && m.timeScaleCell.value == 1 && m.ownerChecks.timeScale == 1)
    }

    /// A Release build does not store `vault.status`'s `time_scale` 24.
    @Test func aReleaseBuildIgnoresAScaledStatus() async throws {
        let service = try FakeVaultService()
        let phone = try TestVaultPhone(service: service)
        defer { phone.close() }
        let m = phone.manager
        try await setUp(phone, service)
        service.timeScale = 24
        try await m.ownerChecks.refreshOwnerCheck()
        _ = try await m.overview()
        #expect(m.record.value.timeScale == 1 && m.timeScale == 1)
    }

    /// `vault.status` says the scale; a deadline learnt before keeps its real-time warning (STAGING-TIME-SCALE §5.5).
    @Test func theStatusTellsTheScaleAndAnEarlierDeadlineKeepsItsTime() async throws {
        let service = try FakeVaultService()
        service.timeScales = .staging
        let phone = try TestVaultPhone(service: service)
        defer { phone.close() }
        let m = phone.manager
        try await setUp(phone, service)
        try await m.ownerChecks.refreshOwnerCheck()
        #expect(m.timeScale == 1 && m.ownerChecks.ownerCheck?.timeScale == 1)
        service.timeScale = 24
        try await m.ownerChecks.refreshOwnerCheck()
        #expect(m.timeScale == 24 && m.record.value.timeScale == 24)
        #expect(m.ownerChecks.ownerCheck?.timeScale == 1)
    }
}
