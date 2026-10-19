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

    /// S8 (STAGING-TIME-SCALE 0.1.1; IOS-PLAN 0.1.7 §6.6): the recovery counter unavailable for 24 hours at scale 1, for
    /// 1 hour at 24, divided when the clock starts and kept with it.
    @Test func theRecoveryCounterDayIsScaled() {
        typealias Clock = RecoveryUnknownClock
        let hour: Int64 = 3_600_000
        let t: Int64 = 1_800_000_000_000
        #expect(Clock.periodMs(timeScale: 1) == 24 * hour && Clock.periodMs(timeScale: 24) == hour)

        // Scale 1: urgent after 24 hours, the period stored as none.
        var real = Clock.advance(Clock.State(), unavailable: true, nowMs: t, timeScale: 1)
        #expect(real == Clock.State(since: t, periodMs: nil))
        real = Clock.advance(real, unavailable: true, nowMs: t + 24 * hour - 1, timeScale: 1)
        #expect(!real.urgent(nowMs: t + 24 * hour - 1) && real.urgent(nowMs: t + 24 * hour))
        // Read at 24 since: a clock started in real time keeps its 24 hours.
        real = Clock.advance(real, unavailable: true, nowMs: t + 23 * hour, timeScale: 24)
        #expect(real.period == 24 * hour && !real.urgent(nowMs: t + 23 * hour))

        // Scale 24: urgent after 1 hour, kept when the scale changes.
        var scaled = Clock.advance(Clock.State(), unavailable: true, nowMs: t, timeScale: 24)
        #expect(scaled == Clock.State(since: t, periodMs: hour))
        #expect(!scaled.urgent(nowMs: t + hour - 1) && scaled.urgent(nowMs: t + hour))
        scaled = Clock.advance(scaled, unavailable: true, nowMs: t + hour, timeScale: 1)
        #expect(scaled.period == hour && scaled.urgent(nowMs: t + hour))

        // An available read stops it and forgets the period; a clock set back starts it again with the scale now.
        #expect(Clock.advance(scaled, unavailable: false, nowMs: t + 2 * hour, timeScale: 24) == Clock.State())
        #expect(Clock.advance(Clock.State(since: t, periodMs: nil), unavailable: true, nowMs: t - hour, timeScale: 24)
            == Clock.State(since: t - hour, periodMs: hour))
        #expect(Clock.unavailable(state: "armed", counter: "unavailable") && Clock.unavailable(state: "unknown", counter: nil))
        #expect(!Clock.unavailable(state: "armed", counter: "ok") && !Clock.unavailable(state: nil, counter: nil))
        // A stored period is never longer than 24 hours nor shorter than the largest scale gives; a production build
        // reads any stored period as 24 hours.
        #expect(Clock.State(since: t, periodMs: 1).period == 1_000 && Clock.State(since: t, periodMs: 48 * hour).period == 24 * hour)
        #expect(Clock.State(since: t, periodMs: hour).validated(maxScale: 1) == Clock.State(since: t, periodMs: nil))
        #expect(Clock.State(since: t, periodMs: 1_000).validated(maxScale: 24) == Clock.State(since: t, periodMs: hour))
        #expect(Clock.State(since: t, periodMs: hour).validated(maxScale: 24) == Clock.State(since: t, periodMs: hour))
        #expect(TimeScales.text(TimeScales.recoveryUnknownDay, by: 1) == "24 hours")
        #expect(TimeScales.text(TimeScales.recoveryUnknownDay, by: 24) == "1 hour")
    }

    /// S8's text: at scale 1 the approved text verbatim; on a scaled vault both durations computed (the owner's decision
    /// of 2026-10-19; vettid-android `settings_recovery_unknown_day` with this package's prefix, and the scaled key).
    @Test func theRecoveryCounterDayText() {
        let real = RecoveryStatusView(state: "unknown", used: nil, counterUnavailable: true, unknownForADay: true)
        #expect(real.unknownDayText == """
            For a day your vault has not been able to check its recovery attempts or record that you were here. If this \
            goes on for three days, your vault is no longer protected against a recovery started by someone else, and until \
            it ends you cannot change your PIN or password. This is a fault of the VettID service or an attack on it. \
            Contact VettID.
            """)
        #expect(real.stagingNote == nil)
        let scaled = RecoveryStatusView(
            state: "unknown", used: nil, counterUnavailable: true, unknownForADay: true, unknownForSeconds: 3_600, timeScale: 24
        )
        #expect(scaled.unknownDayText.hasPrefix("For 1 hour your vault"))
        #expect(scaled.unknownDayText.contains("If this goes on for 3 hours, your vault"))
        #expect(scaled.stagingNote == "Staging: 1 day = 1 hour")
        // A clock started at 24 and read in real time keeps its hour: the computed text.
        let started = RecoveryStatusView(
            state: "unknown", used: nil, counterUnavailable: true, unknownForADay: true, unknownForSeconds: 3_600
        )
        #expect(started.unknownDayText.hasPrefix("For 1 hour your vault") && started.unknownDayText.contains("goes on for 3 days,"))
        let format = Bundle.module.localizedString(forKey: "data_recovery_unknown_day_scaled", value: nil, table: nil)
        #expect(format.hasPrefix("For %1$@ your vault") && format.contains("goes on for %2$@, your vault"))
    }

    /// S10: the old phone's 7 days (I3 starts the timer) at 24.
    @Test func theOldPhonesKeepIsScaled() {
        #expect(TimeScales.scaled(TimeScales.oldPhoneKeep, by: 24) == 7 * 3_600)
        #expect(TimeScales.scaled(TimeScales.oldPhoneKeep, by: 1) == 7 * 86_400)
    }

    /// The duration format vettid-android uses word for word (vettid-android #145): seconds under 10 minutes, whole
    /// minutes rounded up from 10 minutes, whole hours (a day is "24 hours"), days from 2 whole days.
    @Test(arguments: [
        (59.0, "59 seconds"), (150, "150 seconds"), (599, "599 seconds"), (600, "10 minutes"), (601, "11 minutes"),
        (3_600, "1 hour"), (5_400, "90 minutes"), (86_400, "24 hours"), (172_800, "2 days"), (259_200, "3 days"),
    ])
    func theDurationTable(_ seconds: TimeInterval, _ text: String) {
        #expect(DurationText.of(seconds) == text)
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

    /// The "this phone no longer holds the keys" text: in real time the approved words verbatim (ANDROID-PLAN §4
    /// "Recovery and unlock from release R"); on a scaled vault a recovery's time at the scale (the owner's decision of
    /// 2026-10-19).
    @Test func theDeviceSecretTextSaysTheScaledRecovery() {
        let real = """
            This phone no longer holds the keys of your vault. That happens when the app's data was cleared or the phone \
            was set up again from a backup. Nothing was disclosed. Whether you can get back into the vault depends on one \
            of its settings. If its credential backup was on (the usual case), you can recover it: start a recovery on the \
            account site. It takes one to three days, and you need your PIN and your password. If you had turned \
            credential backup off, this vault cannot be brought back; you can delete it on the account site and start a \
            new one. If you still have a phone on which VettID works, use 'Move to a new phone' there instead. The account \
            site tells you which of these applies.
            """
        #expect(FailureKind.deviceSecret.message == real)
        #expect(FailureKind.deviceSecret.message(timeScale: 1) == real)
        let staging = real.replacingOccurrences(of: "one to three days", with: "1 hour to 3 hours")
        #expect(staging != real && FailureKind.deviceSecret.message(timeScale: 24) == staging)
        #expect(FailureKind.deviceSecret.message(timeScale: 3_600).contains("It takes 24 seconds to 72 seconds, and you need"))
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
        #expect(before.recoveryUnknownSinceMs == nil && before.recoveryUnknownForMs == nil)
        // S8: the clock's start and its period go with the record.
        a.recoveryUnknownSinceMs = 1_800_000_000_000
        a.recoveryUnknownForMs = 3_600_000
        let clock = try JSONDecoder().decode(LocalAccount.self, from: JSONEncoder().encode(a))
        #expect(clock.recoveryUnknownSinceMs == 1_800_000_000_000 && clock.recoveryUnknownForMs == 3_600_000)
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

    /// S8 end to end: the status screen's reads move the clock; at 24 the counter unavailable for an hour is urgent and
    /// the text says so; a running clock keeps its period when the scale changes.
    @Test func theRecoveryCounterClockAtTwentyFour() async throws {
        let service = try FakeVaultService()
        service.timeScales = .staging
        service.timeScale = 24
        let phone = try TestVaultPhone(service: service)
        defer { phone.close() }
        let m = phone.manager
        try await setUp(phone, service)
        service.recoveryCounter = "unavailable"
        let first = try #require(try await m.overview().recovery)
        #expect(!first.unknownForADay && first.unknownForSeconds == 3_600 && first.timeScale == 24)
        #expect(m.record.value.recoveryUnknownSinceMs != nil && m.record.value.recoveryUnknownForMs == 3_600_000)
        phone.clockAhead = 1_800
        #expect(try await m.overview().recovery?.unknownForADay == false)
        // The vault back at real time: the clock started at 24 keeps its hour.
        service.timeScale = 1
        phone.clockAhead = 3_601
        let urgent = try #require(try await m.overview().recovery)
        #expect(urgent.unknownForADay && urgent.unknownForSeconds == 3_600 && urgent.timeScale == 1)
        #expect(urgent.unknownDayText.hasPrefix("For 1 hour") && urgent.unknownDayText.contains("goes on for 3 days,"))
        // An available counter stops the clock.
        service.recoveryCounter = "ok"
        #expect(try await m.overview().recovery?.unknownForADay == false)
        #expect(m.record.value.recoveryUnknownSinceMs == nil && m.record.value.recoveryUnknownForMs == nil)
    }

    /// S8 at scale 1: 24 hours, and the period is not stored. The owner check's status read moves the clock too.
    @Test func theRecoveryCounterClockInRealTime() async throws {
        let service = try FakeVaultService()
        let phone = try TestVaultPhone(service: service)
        defer { phone.close() }
        let m = phone.manager
        try await setUp(phone, service)
        service.recoveryCounter = "unavailable"
        try await m.ownerChecks.refreshOwnerCheck()
        #expect(m.record.value.recoveryUnknownSinceMs != nil && m.record.value.recoveryUnknownForMs == nil)
        phone.clockAhead = 23 * 3_600
        #expect(try await m.overview().recovery?.unknownForADay == false)
        phone.clockAhead = 24 * 3_600 + 1
        let urgent = try #require(try await m.overview().recovery)
        #expect(urgent.unknownForADay && urgent.unknownForSeconds == 86_400)
        #expect(urgent.unknownDayText.hasPrefix("For a day your vault") && urgent.unknownDayText.contains("goes on for three days,"))
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
