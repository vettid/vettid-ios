import Foundation
import Testing
import VettIDCrypto
@testable import VettIDData
@testable import VettIDVault

// Fixtures stay on one line each.
// swiftlint:disable line_length

/// The member's own profile and the name change (VAULT-MESSAGING §10.8) over their vault calls: the core read-only and
/// the fingerprint; the display name and the photo set against the version read; the names normalised and checked before
/// anything is sent, the request kept with the account, and every refusal as the screen shows it. Mirrors vettid-android
/// `ProfileManagerTest` and `AccountUpdateTest`.
@MainActor
@Suite struct ProfileManagerTests {
    nonisolated static let ik = [UInt8](repeating: 0x04, count: 32)

    final class Ops: ProfileOps, @unchecked Sendable {
        var nameSets: [[String]] = []
        var error: String?
        var errorBody: String?
        var profile = Profile(version: 4, name: "", photo: nil, firstName: "Ada", lastName: "Lovelace", ik: Base64s.encodeStd(ProfileManagerTests.ik))
        var sets: [(UInt64, String)] = []
        var photoSets: [(UInt64, String)] = []
        var gets = 0
        var profileError: String?

        func profileGet() async throws -> Profile {
            gets += 1
            if let profileError { throw VaultOpError(type: "profile.get", code: profileError, detail: "", body: nil) }
            return profile
        }

        func profileSet(version: UInt64, name: String) async throws -> UInt64 {
            sets.append((version, name))
            if let profileError { throw VaultOpError(type: "profile.set", code: profileError, detail: "", body: nil) }
            profile.version = version + 1
            profile.name = name
            return version + 1
        }

        func profileSetPhoto(version: UInt64, photo: String) async throws -> UInt64 {
            photoSets.append((version, photo))
            if let profileError { throw VaultOpError(type: "profile.set", code: profileError, detail: "", body: nil) }
            profile.version = version + 1
            profile.photo = photo.isEmpty ? nil : photo
            return version + 1
        }

        func accountNameSet(pin: String, password: String, firstName: String, lastName: String) async throws -> NameRequest {
            nameSets.append([pin, password, firstName, lastName])
            if let error { throw VaultOpError(type: "account.name.set", code: error, detail: "", body: errorBody.map { Array($0.utf8) }) }
            return NameRequest(seq: 7, firstName: firstName, lastName: lastName, requestedAt: "2026-10-07T12:00:00.000Z", state: "pending")
        }
    }

    final class Seen {
        var requests: [NameRequestView] = []
        var checksLeftCalls = 0
    }

    let ops = Ops()
    let seen = Seen()

    var m: ProfileManager {
        let ops = ops
        let seen = seen
        return ProfileManager(
            ops: { ops },
            onRequest: { r, _ in seen.requests.append(r) },
            checksLeft: {
                seen.checksLeftCalls += 1
                return 8
            }
        )
    }

    // MARK: - The shared profile

    @Test func readsTheCoreReadOnlyAndTheFingerprint() async throws {
        let m = m
        #expect(m.profile == nil)
        try await m.refreshProfile()
        let p = try #require(m.profile)
        #expect(p.fullName == "Ada Lovelace" && p.displayName == "" && p.photo == nil)
        #expect(p.fingerprint == (try IkFingerprint.format(Self.ik)))
    }

    @Test func aVaultWithoutTheCoreGivesNoNames() async throws {
        ops.profile = Profile(version: 1, name: "Ada")
        let m = m
        try await m.refreshProfile()
        #expect(m.profile?.fullName == nil && m.profile?.fingerprint == nil)
        // Names that break the receiver's rules are not shown (§10.8: no control characters).
        ops.profile = Profile(version: 2, firstName: "Ada\u{7}", lastName: "Lovelace", ik: "not base64")
        try await m.refreshProfile()
        #expect(m.profile?.firstName == nil && m.profile?.lastName == "Lovelace" && m.profile?.fingerprint == nil)
    }

    @Test func theDisplayNameIsSetWithTheVersionAndOnlyIt() async throws {
        let m = m
        try await m.refreshProfile()
        try await m.setDisplayName("  Countess ")
        #expect(ops.sets.map(\.0) == [4] && ops.sets.map(\.1) == ["Countess"])
        #expect(m.profile?.displayName == "Countess")
        try await m.setDisplayName("")
        #expect(ops.sets.last?.0 == 5 && ops.sets.last?.1 == "")
        #expect(ops.photoSets.isEmpty)
    }

    @Test func aPhotoIsSetWithTheVersionAndRemovedWithEmpty() async throws {
        let m = m
        try await m.refreshProfile()
        try await m.setPhoto("/9j/AAAA")
        #expect(ops.photoSets.count == 1 && ops.photoSets[0].0 == 4 && ops.photoSets[0].1 == "/9j/AAAA")
        #expect(m.profile?.photo == "/9j/AAAA")
        try await m.setPhoto("")
        #expect(ops.photoSets.last?.0 == 5 && ops.photoSets.last?.1 == "")
        #expect(m.profile?.photo == nil)
    }

    /// Without a profile read, a change is sent against the vault's version now.
    @Test func aChangeBeforeAnyReadUsesTheVaultsVersion() async throws {
        let m = m
        try await m.setPhoto("/9j/AAAA")
        #expect(ops.photoSets.first?.0 == 4)
        #expect(m.profile?.photo == "/9j/AAAA", "read again after the change")
    }

    @Test func aRefusedChangeIsAVaultFailureAndChangesNothing() async throws {
        let m = m
        try await m.refreshProfile()
        ops.profileError = "conflict"
        await #expect(throws: VaultFailure.self) { try await m.setPhoto("/9j/AAAA") }
        #expect(m.profile?.photo == nil && m.profile?.version == 4)
    }

    /// Cleared (the vault locked, or a wipe): nothing read before is kept, and an answer to a read sent before is dropped.
    @Test func clearForgetsTheProfile() async throws {
        let m = m
        try await m.refreshProfile()
        m.clear()
        #expect(m.profile == nil)
    }

    // MARK: - The name change

    @Test func aNameChangeSendsTheNormalisedNamesAndKeepsTheRequest() async throws {
        let r = await m.changeName(pin: "246810", password: "pw", firstName: " Ada ", lastName: "King")
        #expect(ops.nameSets == [["246810", "pw", "Ada", "King"]])
        guard case .requested(let request) = r else {
            Issue.record("not requested: \(r)")
            return
        }
        #expect(request.state == .pending && request.seq == 7)
        #expect(request.requestedAt == FakeDates.date("2026-10-07T12:00:00Z"))
        #expect(seen.requests == [request])
    }

    @Test func namesThatBreakTheRuleAreNotSent() async {
        #expect(await m.changeName(pin: "246810", password: "pw", firstName: "Ada1", lastName: "King") == .invalid)
        #expect(await m.changeName(pin: "246810", password: "pw", firstName: "Ada", lastName: "") == .invalid)
        #expect(ops.nameSets.isEmpty)
    }

    @Test func tooSoonCarriesTheDate() async {
        ops.error = "too_soon"
        ops.errorBody = #"{"allowed_after":"2026-11-01T00:00:00Z"}"#
        #expect(await m.changeName(pin: "246810", password: "pw", firstName: "Ada", lastName: "King") == .tooSoon(allowedAfter: FakeDates.date("2026-11-01T00:00:00Z")))
        ops.errorBody = nil
        #expect(await m.changeName(pin: "246810", password: "pw", firstName: "Ada", lastName: "King") == .tooSoon(allowedAfter: nil))
        #expect(seen.requests.isEmpty)
    }

    @Test func theOwnerChecksAnswers() async {
        let m = m
        ops.error = "bad_pin"
        #expect(await m.changeName(pin: "246810", password: "pw", firstName: "Ada", lastName: "King") == .badPin(checksLeft: 8))
        ops.error = "bad_password"
        #expect(await m.changeName(pin: "246810", password: "pw", firstName: "Ada", lastName: "King") == .badPassword(checksLeft: 8))
        #expect(seen.checksLeftCalls == 2)
        ops.error = "backoff"
        ops.errorBody = #"{"retry_after":30}"#
        #expect(await m.changeName(pin: "246810", password: "pw", firstName: "Ada", lastName: "King") == .backoff(retryAfterSeconds: 30))
        ops.error = "bad_request"
        #expect(await m.changeName(pin: "246810", password: "pw", firstName: "Ada", lastName: "King") == .invalid)
        ops.error = "owner_check_required"
        #expect(await m.changeName(pin: "246810", password: "pw", firstName: "Ada", lastName: "King") == .failed(.ownerCheckRequired, code: "owner_check_required"))
        ops.error = "credential_frozen"
        #expect(await m.changeName(pin: "246810", password: "pw", firstName: "Ada", lastName: "King") == .failed(.credentialFrozen, code: "credential_frozen"))
    }

    @Test func requestStates() {
        #expect(
            NameRequestView.of(NameRequest(seq: 3, firstName: "A", lastName: "B", requestedAt: nil, state: "refused", reason: "too_soon"))
                == NameRequestView(seq: 3, firstName: "A", lastName: "B", requestedAt: nil, state: .refused, reason: "too_soon")
        )
        // reason only with refused (0.19.0).
        #expect(NameRequestView.of(NameRequest(seq: 3, firstName: "A", lastName: "B", requestedAt: nil, state: "applied", reason: "too_soon"))?.reason == nil)
        #expect(NameRequestView.of(NameRequest(seq: 3, firstName: "A", lastName: "B", requestedAt: nil, state: "lost")) == nil)
        // As the account record keeps it, and back.
        let v = NameRequestView(seq: 4, firstName: "A", lastName: "B", requestedAt: FakeDates.date("2026-10-07T12:00:00Z"), state: .pending)
        #expect(NameRequestView.of(v.wire) == v)
    }
}

/// `account.get` after `sync.event{account.changed}` (VAULT-MESSAGING §10.1, §10.2, 0.19.0). Mirrors vettid-android
/// `AccountUpdateTest`.
@Suite struct AccountUpdateTests {
    static func snapshot(_ json: String) throws -> AccountSnapshot { try VaultJSON.decode(AccountSnapshot.self, Array(json.utf8)) }
    static func view(_ snap: String?, _ version: Int, _ request: NameRequest?) throws -> AccountView {
        let r = request.map { #","name_request":{"seq":\#($0.seq),"first_name":"\#($0.firstName)","last_name":"\#($0.lastName)","state":"\#($0.state)"}"# } ?? ""
        return try VaultJSON.decode(AccountView.self, Array(#"{"account":\#(snap ?? "null"),"version":\#(version)\#(r)}"#.utf8))
    }

    let snapJSON = #"{"as_of":"2026-10-07T10:00:00Z","first_name":"Ada","last_name":"Lovelace"}"#
    let pending = NameRequest(seq: 3, firstName: "Ada", lastName: "King", requestedAt: nil, state: "pending")
    var applied: NameRequest { NameRequest(seq: 3, firstName: "Ada", lastName: "King", requestedAt: nil, state: "applied") }

    @Test func aNameRequestChangeAloneIsKeptThoughTheVersionRepeats() throws {
        let snap = try Self.snapshot(snapJSON)
        // Same snapshot (same as_of, same version 4), only the request changed.
        let u = try #require(AccountSnapshots.update(stored: snap, storedRequest: pending, view: try Self.view(snapJSON, 4, applied)))
        #expect(u.snapshot == snap && u.nameRequest == applied)
    }

    @Test func nothingNewIsNothing() throws {
        let snap = try Self.snapshot(snapJSON)
        #expect(AccountSnapshots.update(stored: snap, storedRequest: pending, view: try Self.view(snapJSON, 4, pending)) == nil)
        // An older snapshot is not taken.
        let older = #"{"as_of":"2026-10-06T10:00:00Z","first_name":"Old","last_name":"Lovelace"}"#
        #expect(AccountSnapshots.update(stored: snap, storedRequest: pending, view: try Self.view(older, 3, pending)) == nil)
    }

    @Test func aNewerSnapshotBringsTheNewNames() throws {
        let snap = try Self.snapshot(snapJSON)
        let newer = #"{"as_of":"2026-10-08T10:00:00Z","first_name":"Ada","last_name":"King"}"#
        let u = try #require(AccountSnapshots.update(stored: snap, storedRequest: pending, view: try Self.view(newer, 5, applied)))
        #expect(u.snapshot?.lastName == "King" && u.nameRequest == applied)
    }

    /// The snapshot as the screens see it: names that break the core rule and an implausible address are left out; the
    /// next change's date is read.
    @Test func theSnapshotForDisplay() throws {
        let s = try Self.snapshot(#"{"as_of":"2026-10-07T10:00:00Z","email_hint":"a***@example.com","email":"ada@example.com","state":"member","account_status":"active","first_name":"Ada","last_name":"Love\u0007lace","voting_rights":true,"name_change":{"allowed_after":"2026-11-06T10:00:00Z"},"subscription":{"type_name":"Annual","status":"active","paid":true}}"#)
        let a = AccountSnapshots.info(s, fallbackHint: "x***@example.com")
        #expect(a.emailHint == "a***@example.com" && a.email == "ada@example.com" && a.state == "member" && a.votingRights)
        #expect(a.firstName == "Ada" && a.lastName == nil)
        #expect(a.nameAllowedAfter == FakeDates.date("2026-11-06T10:00:00Z"))
        #expect(a.subscription?.typeName == "Annual" && a.subscription?.paid == true)
        #expect(!AccountSnapshots.validEmail("a@") && !AccountSnapshots.validEmail("no-at-sign") && AccountSnapshots.validEmail("a@b"))
    }
}

/// Dates of the fixtures.
enum FakeDates {
    static func date(_ iso: String) -> Date? { OwnerCheckManager.instant(iso) }
}

// swiftlint:enable line_length
