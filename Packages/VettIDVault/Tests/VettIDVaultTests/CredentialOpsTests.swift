import Foundation
import Testing
@testable import VettIDVault
import VettIDCrypto

// Fixtures (JSON bodies of the fake vault) stay on one line each.
// swiftlint:disable line_length

/// The credential calls of enrollment (VAULT-MESSAGING §3.5.5, §10.6) and the settings (§10.8) against the fake vault:
/// the UTK pool, the sealed payload, the kept blob and its `credential.ack`, the errors and their bodies.
@Suite struct CredentialOpsTests {
    let base = VaultDeviceTests()

    /// A pool of [n] UTKs and their private keys (the vault's LTKs).
    func pool(_ n: Int) throws -> (body: String, keys: [String: KemPrivateKey]) {
        var keys: [String: KemPrivateKey] = [:]
        var items: [String] = []
        for i in 0..<n {
            let k = try KemPrivateKey.generate()
            let id = String(format: "%016x", i + 1)
            keys[id] = k
            items.append(JsonBuilder().string("utk_id", id).base64("ek", k.publicKey.bytes).string("expires_at", Timestamps.formatMillis(Date().addingTimeInterval(3600))).build())
        }
        return (#"{"utks":"# + JsonBuilder.array(items) + "}", keys)
    }

    /// Answers the next request, which must be of [type], with [body] (or an error [code] with [errorBody]).
    @discardableResult
    func answer(_ v: FakeVault, _ d: VaultDevice, _ type: String, _ body: String = "{}", code: String? = nil, errorBody: String? = nil) async throws -> Inner {
        let req = try v.open(try await base.relay.nextDeposit().payload)
        #expect(req.type == type)
        let inner: Inner
        if let code {
            inner = Inner(id: Ulid.new(), type: type, ts: Date(), re: req.id, status: Inner.statusError, error: InnerError(code), body: Array((errorBody ?? "").utf8))
        } else {
            inner = Inner(id: Ulid.new(), type: type, ts: Date(), re: req.id, status: Inner.statusOK, body: Array(body.utf8))
        }
        try await d.handle(v.msg(try #require(v.keyring.current()).seal(inner)))
        return req
    }

    /// The payload of a sealed request, opened with the UTK's private key as the vault does.
    func payload(_ req: Inner, _ vaultID: String, _ keys: [String: KemPrivateKey]) throws -> JsonObject {
        let o = try StrictJson.parseObject(req.body)
        let utk = try o.string("utk_id")
        let pt = try CredentialSeal.openPayload(ltk: try #require(keys[utk]), vaultID: vaultID, utkID: utk, type: req.type, innerID: req.id, sealed: try o.base64("sealed"))
        return try StrictJson.parseObject(pt)
    }

    /// credential.create with an empty pool: `credential.utk.get` first; the PIN and the password sealed to a UTK (the
    /// password NFC for a vault of release R, §11.14.7); the blob kept and acknowledged; the spare UTKs kept.
    @Test func createFetchesUTKsSealsAndKeepsTheBlob() async throws {
        let (d, v) = try await base.pairedDevice()
        let api = VaultApi(device: d) { true }
        let (utks, keys) = try pool(3)
        let create = Task { try await api.credentialCreate(password: "Cafe\u{301} long password", pin: "123456") }
        try await answer(v, d, "credential.utk.get", utks)
        let req = try await answer(v, d, "credential.create", #"{"credential":"AQID","version":1,"key":"x"}"#)
        let p = try payload(req, v.vaultID, keys)
        #expect(try p.string("pin") == "123456")
        #expect(try p.string("password") == "Caf\u{e9} long password")
        #expect(p.members.map(\.name) == ["pin", "password"])
        let ack = try await answer(v, d, "credential.ack")
        #expect(VaultJSON.int(VaultJSON.object(ack.body), "version") == 1)
        try await create.value
        #expect(d.credentialVersion == 1 && d.utkCount == 2)
    }

    /// Before release R the password goes as typed and without a PIN.
    @Test func beforeReleaseRThePasswordIsSentAsTyped() async throws {
        let (d, v) = try await base.pairedDevice()
        let api = VaultApi(device: d)
        let (utks, keys) = try pool(1)
        let create = Task { try await api.credentialCreate(password: "Cafe\u{301} long password") }
        try await answer(v, d, "credential.utk.get", utks)
        let req = try await answer(v, d, "credential.create", #"{"credential":"AQID","version":1}"#)
        let p = try payload(req, v.vaultID, keys)
        #expect(try p.string("password") == "Cafe\u{301} long password" && !p.has("pin"))
        try await answer(v, d, "credential.ack")
        try await create.value
    }

    /// A refusal carries its code and body (`weak_password{reason}`, §11.14.7); nothing is kept.
    @Test func aRefusalCarriesItsCodeAndBody() async throws {
        let (d, v) = try await base.pairedDevice()
        let api = VaultApi(device: d) { true }
        let (utks, _) = try pool(2)
        let create = Task { try await api.credentialCreate(password: "password", pin: "123456") }
        try await answer(v, d, "credential.utk.get", utks)
        try await answer(v, d, "credential.create", code: "weak_password", errorBody: #"{"reason":"common"}"#)
        do {
            try await create.value
            Issue.record("no error")
        } catch let e as VaultOpError {
            #expect(e.code == "weak_password")
            #expect(VaultJSON.string(VaultJSON.object(try #require(e.body)), "reason") == "common")
        }
        #expect(d.credentialVersion == nil)
    }

    /// `credential.get` keeps the vault's blob and acknowledges it (a create whose answer was lost: `exists`).
    @Test func fetchKeepsTheLatestBlob() async throws {
        let (d, v) = try await base.pairedDevice()
        let api = VaultApi(device: d)
        let fetch = Task { try await api.credentialFetch() }
        try await answer(v, d, "credential.get", #"{"credential":"AQID","version":4,"updated_at":"2026-10-04T00:00:00Z"}"#)
        try await answer(v, d, "credential.ack")
        try await fetch.value
        #expect(d.credentialVersion == 4)
    }

    /// settings.get reads every value as its JSON text; settings.set sends them as they are, against the version.
    @Test func settingsAreReadAndSet() async throws {
        let (d, v) = try await base.pairedDevice()
        let api = VaultApi(device: d)
        let get = Task { try await api.settingsGet() }
        try await answer(v, d, "settings.get", #"{"version":3,"settings":{"credential.backup":true,"credential.unlock_ttl_seconds":300}}"#)
        let s = try await get.value
        #expect(s.version == 3 && s.values["credential.backup"] == "true" && s.values["credential.unlock_ttl_seconds"] == "300")
        let set = Task { try await api.settingsSet(version: 3, set: [("credential.backup", "false")]) }
        let req = try await answer(v, d, "settings.set", #"{"version":4}"#)
        #expect(String(bytes: req.body, encoding: .utf8) == #"{"version":3,"set":{"credential.backup":false}}"#)
        #expect(try await set.value == 4)
    }
}

// swiftlint:enable line_length
