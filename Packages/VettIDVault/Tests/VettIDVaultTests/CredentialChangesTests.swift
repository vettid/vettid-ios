import Foundation
import Testing
@testable import VettIDVault
import VettIDCrypto

// Fixtures (JSON bodies of the fake vault) stay on one line each.
// swiftlint:disable line_length

/// The holder's credential operations of Settings against the fake vault: the name change (VAULT-MESSAGING §10.8), the
/// PIN change of release R (§11.14.9), the password change, the unlock window (§3.5.3), `credential.version` and the
/// count of critical items (§10.7). Each sealed operation carries the blob and seals its members, in the spec's order,
/// to a UTK; the rotated blob is kept and acknowledged.
@Suite struct CredentialChangesTests {
    let ops = CredentialOpsTests()

    /// A paired device holding blob 1, its API (release R), and a pool of UTKs with their private keys.
    struct Holder {
        let d: VaultDevice
        let v: FakeVault
        let api: VaultApi
        let utks: String
        let keys: [String: KemPrivateKey]
    }

    func holder() async throws -> Holder {
        let (d, v) = try await ops.base.pairedDevice()
        let api = VaultApi(device: d) { true }
        let fetch = Task { try await api.credentialFetch() }
        try await ops.answer(v, d, "credential.get", #"{"credential":"AQID","version":1}"#)
        try await ops.answer(v, d, "credential.ack")
        try await fetch.value
        let (utks, keys) = try ops.pool(3)
        return Holder(d: d, v: v, api: api, utks: utks, keys: keys)
    }

    /// `account.name.set`: the PIN, the password and the two names sealed with the blob; the stored request returned and
    /// the rotated blob kept.
    @Test func aNameChangeSealsThePinPasswordAndNames() async throws {
        let h = try await holder()
        let (d, v, api, utks, keys) = (h.d, h.v, h.api, h.utks, h.keys)
        let set = Task { try await api.accountNameSet(pin: "975310", password: "Cafe\u{301} pw", firstName: "Ada", lastName: "Byron") }
        try await ops.answer(v, d, "credential.utk.get", utks)
        let req = try await ops.answer(v, d, VaultApi.typeAccountNameSet, #"{"credential":"BAUG","version":2,"request":{"seq":4,"first_name":"Ada","last_name":"Byron","requested_at":"2026-10-18T12:00:00Z","state":"pending"}}"#)
        #expect(try StrictJson.parseObject(req.body).string("credential") == "AQID")
        let p = try ops.payload(req, v.vaultID, keys)
        #expect(p.members.map(\.name) == ["pin", "password", "first_name", "last_name"])
        #expect(try p.string("pin") == "975310" && p.string("password") == "Caf\u{e9} pw")
        #expect(try p.string("first_name") == "Ada" && p.string("last_name") == "Byron")
        try await ops.answer(v, d, "credential.ack")
        let r = try await set.value
        #expect(r == NameRequest(seq: 4, firstName: "Ada", lastName: "Byron", requestedAt: "2026-10-18T12:00:00Z", state: "pending"))
        #expect(d.credentialVersion == 2)
    }

    /// `too_soon` carries `allowed_after` in its body; an answer without `request` is not a request.
    @Test func aNameChangeRefusalCarriesItsBody() async throws {
        let h = try await holder()
        let (d, v, api, utks) = (h.d, h.v, h.api, h.utks)
        let set = Task { try await api.accountNameSet(pin: "975310", password: "pw", firstName: "Ada", lastName: "Byron") }
        try await ops.answer(v, d, "credential.utk.get", utks)
        try await ops.answer(v, d, VaultApi.typeAccountNameSet, code: "too_soon", errorBody: #"{"allowed_after":"2026-11-01T00:00:00Z"}"#)
        do {
            _ = try await set.value
            Issue.record("no error")
        } catch let e as VaultOpError {
            #expect(e.code == "too_soon")
            #expect(VaultJSON.string(VaultJSON.object(try #require(e.body)), "allowed_after") == "2026-11-01T00:00:00Z")
        }
        let again = Task { try await api.accountNameSet(pin: "975310", password: "pw", firstName: "Ada", lastName: "Byron") }
        try await ops.answer(v, d, VaultApi.typeAccountNameSet, #"{"credential":"BAUG","version":2}"#)
        try await ops.answer(v, d, "credential.ack")
        await #expect(throws: VaultStateError.self) { _ = try await again.value }
    }

    /// Release R `pin.change`: the current PIN, the new one, the password and the next epoch's secret (base64, 32 bytes);
    /// `epoch_advanced: true` is what moves the phone on.
    @Test func aPinChangeCarriesTheNextSecret() async throws {
        let h = try await holder()
        let (d, v, api, utks, keys) = (h.d, h.v, h.api, h.utks, h.keys)
        let secret = [UInt8](repeating: 0x5A, count: 32)
        let change = Task { try await api.pinChange(pin: "975310", newPin: "864201", password: "pw", newUnlockSecret: secret, marked: Marked()) }
        try await ops.answer(v, d, "credential.version", #"{"exists":true,"version":1}"#)
        try await ops.answer(v, d, "credential.utk.get", utks)
        let req = try await ops.answer(v, d, "pin.change", #"{"credential":"BAUG","version":2,"epoch_advanced":true}"#)
        #expect(try StrictJson.parseObject(req.body).string("credential") == "AQID")
        let p = try ops.payload(req, v.vaultID, keys)
        #expect(p.members.map(\.name) == ["pin", "new_pin", "password", "new_unlock_secret"])
        #expect(try p.string("pin") == "975310" && p.string("new_pin") == "864201" && p.string("password") == "pw")
        #expect(try p.base64("new_unlock_secret") == secret)
        try await ops.answer(v, d, "credential.ack")
        #expect(try await change.value)
        let second = Task { try await api.pinChange(pin: "864201", newPin: "975310", password: "pw", newUnlockSecret: secret, marked: Marked()) }
        try await ops.answer(v, d, "credential.version", #"{"exists":true,"version":2}"#)
        try await ops.answer(v, d, "pin.change", #"{"credential":"BwgJ","version":3}"#)
        try await ops.answer(v, d, "credential.ack")
        #expect(try await second.value == false, "no epoch_advanced: not moved on")
    }

    /// The password change carries the PIN on a vault of release R, the passwords in NFC; without a PIN, none.
    @Test func aPasswordChangeCarriesThePin() async throws {
        let h = try await holder()
        let (d, v, api, utks, keys) = (h.d, h.v, h.api, h.utks, h.keys)
        let change = Task { try await api.credentialChangePassword(password: "Cafe\u{301} one", newPassword: "Cafe\u{301} two", pin: "975310", marked: Marked()) }
        try await ops.answer(v, d, "credential.version", #"{"exists":true,"version":1}"#)
        try await ops.answer(v, d, "credential.utk.get", utks)
        let req = try await ops.answer(v, d, "credential.password.change", #"{"credential":"BAUG","version":2}"#)
        let p = try ops.payload(req, v.vaultID, keys)
        #expect(p.members.map(\.name) == ["pin", "password", "new_password"])
        #expect(try p.string("password") == "Caf\u{e9} one" && p.string("new_password") == "Caf\u{e9} two" && p.string("pin") == "975310")
        try await ops.answer(v, d, "credential.ack")
        try await change.value
        let without = Task { try await api.credentialChangePassword(password: "a", newPassword: "b", marked: Marked()) }
        try await ops.answer(v, d, "credential.version", #"{"exists":true,"version":2}"#)
        let req2 = try await ops.answer(v, d, "credential.password.change", #"{"credential":"BwgJ","version":3}"#)
        #expect(try ops.payload(req2, v.vaultID, keys).members.map(\.name) == ["password", "new_password"])
        try await ops.answer(v, d, "credential.ack")
        try await without.value
    }

    /// The unlock window: `credential.unlock` with the password and the blob answers its expiry; `credential.lock` closes it.
    @Test func theUnlockWindowOpensAndCloses() async throws {
        let h = try await holder()
        let (d, v, api, utks, keys) = (h.d, h.v, h.api, h.utks, h.keys)
        let open = Task { try await api.credentialUnlock(password: "pw") }
        try await ops.answer(v, d, "credential.utk.get", utks)
        let req = try await ops.answer(v, d, "credential.unlock", #"{"expires_at":"2026-10-18T12:05:00Z"}"#)
        #expect(try ops.payload(req, v.vaultID, keys).members.map(\.name) == ["password"])
        #expect(try await open.value == "2026-10-18T12:05:00Z")
        let close = Task { try await api.credentialLock() }
        try await ops.answer(v, d, "credential.lock")
        try await close.value
    }

    /// Release R `vault.secret.renew` (§11.14.9): the PIN, the password and the next epoch's secret sealed with the blob;
    /// the rotated blob is kept and acknowledged.
    @Test func aRenewCarriesTheNextSecret() async throws {
        let h = try await holder()
        let (d, v, api, utks, keys) = (h.d, h.v, h.api, h.utks, h.keys)
        let secret = [UInt8](repeating: 0x3C, count: 32)
        let marked = Marked()
        let renew = Task { try await api.secretRenew(pin: "975310", password: "pw", newUnlockSecret: secret, marked: marked) }
        // The same checks as a change (VAULT-MESSAGING 0.47.0 §11.14.9 step 1).
        try await ops.answer(v, d, "credential.version", #"{"exists":true,"version":1}"#)
        try await ops.answer(v, d, "credential.utk.get", utks)
        let req = try await ops.answer(v, d, VaultApi.typeSecretRenew, #"{"credential":"BAUG","version":2}"#)
        #expect(req.exp != nil && req.id == marked.change?.id, "a renew carries its stored id and exp")
        #expect(try StrictJson.parseObject(req.body).string("credential") == "AQID")
        let p = try ops.payload(req, v.vaultID, keys)
        #expect(p.members.map(\.name) == ["pin", "password", "new_unlock_secret"])
        #expect(try p.string("pin") == "975310" && p.string("password") == "pw" && p.base64("new_unlock_secret") == secret)
        try await ops.answer(v, d, "credential.ack")
        try await renew.value
        #expect(d.credentialVersion == 2)
    }

    /// `vault.delete` (§12.5): the phrase beside the blob, the PIN and the password sealed to one UTK; the vault's `{}`
    /// ends it; a refusal is the vault's own.
    @Test func aDeleteCarriesThePhraseBesideTheBlob() async throws {
        let h = try await holder()
        let (d, v, api, utks, keys) = (h.d, h.v, h.api, h.utks, h.keys)
        let refused = Task { try await api.deleteVault(pin: "111111", password: "pw", exp: Date().addingTimeInterval(600)) }
        try await ops.answer(v, d, "credential.utk.get", utks)
        try await ops.answer(v, d, VaultApi.typeVaultDelete, code: "bad_pin", errorBody: "{}")
        await #expect(throws: VaultOpError.self) { try await refused.value }
        let delete = Task { try await api.deleteVault(pin: "975310", password: "pw", exp: Date().addingTimeInterval(600)) }
        let req = try await ops.answer(v, d, VaultApi.typeVaultDelete, "{}")
        #expect(req.exp != nil, "a deletion carries its exp")
        let outer = try StrictJson.parseObject(req.body)
        #expect(try outer.string("confirm") == "delete my vault" && outer.string("credential") == "AQID")
        let p = try ops.payload(req, v.vaultID, keys)
        #expect(p.members.map(\.name) == ["pin", "password"])
        #expect(try p.string("pin") == "975310" && p.string("password") == "pw")
        try await delete.value
    }

    /// `credential.version` with its alarm; the critical items counted one page at a time, `next` absent or `null` at the end.
    @Test func theVersionAndTheCriticalCount() async throws {
        let (d, v) = try await ops.base.pairedDevice()
        let api = VaultApi(device: d) { true }
        let version = Task { try await api.credentialVersion() }
        try await ops.answer(v, d, "credential.version", #"{"exists":true,"version":7,"key":"k1","updated_at":"2026-10-04T12:00:00Z","alarm":{"alarm_id":"al-1","state":"frozen","at":"2026-10-04T11:00:00Z"}}"#)
        let info = try await version.value
        #expect(info.exists && info.version == 7 && info.key == "k1" && info.updatedAt == "2026-10-04T12:00:00Z")
        #expect(info.alarm?.alarmID == "al-1" && info.alarm?.state == "frozen")
        let first = Task { try await api.itemCount(sensitivity: "critical", limit: 500) }
        let req = try await ops.answer(v, d, "item.list", #"{"items":[{"item_id":"a"},{"item_id":"b"}],"next":"c1"}"#)
        #expect(String(bytes: req.body, encoding: .utf8) == #"{"sensitivity":"critical","limit":500}"#)
        #expect(try await first.value == ItemCountPage(count: 2, next: "c1"))
        let last = Task { try await api.itemCount(sensitivity: "critical", after: "c1", limit: 500) }
        let req2 = try await ops.answer(v, d, "item.list", #"{"items":[{"item_id":"c"}],"next":null}"#)
        #expect(String(bytes: req2.body, encoding: .utf8) == #"{"sensitivity":"critical","after":"c1","limit":500}"#)
        #expect(try await last.value == ItemCountPage(count: 1, next: nil))
    }
}

// swiftlint:enable line_length
