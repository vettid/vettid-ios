import Foundation
import Testing
@testable import VettIDVault
import VettIDCrypto

/// A UTK is spent when the request that presents it is sent, whatever the answer (VAULT-MESSAGING 0.52.0 §3.5.4 "Using
/// a UTK"; IOS-PLAN 0.1.16 §4.5 (1)), and a pool the vault holds full of UTKs this phone no longer has is resynced once
/// (§3.5.4 "Resync"; §4.5 (2)).
@Suite struct UtkSpendTests {
    let ops = CredentialOpsTests()

    static let refusals = [
        "forbidden", "unsupported_type", "session_required", "owner_check_required", "signer_unconfirmed",
        "credential_required", "credential_frozen", "rotation_required", "credential_locked", "not_found", "bad_request",
        "bad_pin", "bad_password", "backoff", "stale_credential", "utk_invalid", "exists", "weak_password", "some_future_code",
    ]

    /// `credential.create` refused with [code], from a pool of two: the UTK stays spent.
    @Test(arguments: refusals) func everyRefusalLeavesTheUTKSpent(_ code: String) async throws {
        let (d, v) = try await ops.base.pairedDevice()
        let api = VaultApi(device: d) { true }
        let (utks, _) = try ops.pool(2)
        let create = Task { try await api.credentialCreate(password: "a long password", pin: "123456") }
        try await ops.answer(v, d, "credential.utk.get", utks)
        try await ops.answer(v, d, "credential.create", code: code, errorBody: "{}")
        await #expect(throws: VaultOpError.self) { try await create.value }
        #expect(d.utkCount == 1, "\(code): the UTK stays out of the pool")
    }

    /// A device holding the blob `AQID` at version 1.
    func holder() async throws -> (VaultDevice, FakeVault) {
        let (d, v) = try await ops.base.pairedDevice()
        let api = VaultApi(device: d) { true }
        let fetch = Task { try await api.credentialFetch() }
        try await ops.answer(v, d, "credential.get", #"{"credential":"AQID","version":1}"#)
        try await ops.answer(v, d, "credential.ack")
        try await fetch.value
        return (d, v)
    }

    /// The UTK a request presented.
    func utkID(_ req: Inner) throws -> String { try StrictJson.parseObject(req.body).string("utk_id") }

    /// Whether a `credential.utk.get` asks for a resync.
    func isResync(_ req: Inner) throws -> Bool {
        let o = try StrictJson.parseObject(req.body.isEmpty ? VaultJSON.empty : req.body)
        return o.has("resync") ? try o.bool("resync") : false
    }

    /// The owner check refused [code] (each attempt with a fresh UTK).
    func refusedCheck(
        _ api: VaultApi, _ v: FakeVault, _ d: VaultDevice, _ code: String, before: (() async throws -> Void)? = nil
    ) async throws -> String {
        let check = Task { try await api.ownerCheck(pin: "975310", password: "pw") }
        try await before?()
        let req = try await ops.answer(v, d, VaultApi.typeOwnerCheck, code: code, errorBody: "{}")
        await #expect(throws: VaultOpError.self) { _ = try await check.value }
        return try utkID(req)
    }

    /// `forbidden` and `signer_unconfirmed` one after another: each attempt presents another UTK and the pool shrinks;
    /// once it is empty and the top-up carries none, one resync, and its 20 UTKs are kept.
    @Test func refusalsSpendAndAnEmptyPoolResyncsOnce() async throws {
        let (d, v) = try await holder()
        let api = VaultApi(device: d) { true }
        let (utks, _) = try ops.pool(3)
        var seen: Set<String> = []
        for (i, code) in ["forbidden", "signer_unconfirmed", "forbidden"].enumerated() {
            let id = try await refusedCheck(api, v, d, code) {
                if i == 0 { try await ops.answer(v, d, "credential.utk.get", utks) }
            }
            #expect(seen.insert(id).inserted, "a fresh UTK for each attempt")
            #expect(d.utkCount == 2 - i)
        }
        let (full, _) = try ops.pool(20)
        _ = try await refusedCheck(api, v, d, "forbidden") {
            let get = try await ops.answer(v, d, "credential.utk.get", #"{"utks":[]}"#)
            #expect(try !isResync(get))
            let resync = try await ops.answer(v, d, "credential.utk.get", full)
            #expect(try isResync(resync))
        }
        #expect(d.utkCount == 19)
    }

    /// A resync refused `too_soon` is the failure, with no second resync; until its `allowed_after` none is sent.
    @Test func aResyncRefusedTooSoonIsNotRepeated() async throws {
        let (d, v) = try await holder()
        let api = VaultApi(device: d) { true }
        let after = Timestamps.formatMillis(Date().addingTimeInterval(600))
        let check = Task { try await api.ownerCheck(pin: "975310", password: "pw") }
        try await ops.answer(v, d, "credential.utk.get", #"{"utks":[]}"#)
        let resync = try await ops.answer(v, d, "credential.utk.get", code: "too_soon", errorBody: #"{"allowed_after":"\#(after)"}"#)
        #expect(try isResync(resync))
        do {
            _ = try await check.value
            Issue.record("no error")
        } catch let e as VaultOpError {
            #expect(e.code == "too_soon" && e.type == "credential.utk.get")
        }
        #expect(await ops.base.relay.noDeposit(within: 0.3), "no second resync, no check")
        // The next attempt: the top-up again, and no resync before `allowed_after`.
        let again = Task { try await api.ownerCheck(pin: "975310", password: "pw") }
        try await ops.answer(v, d, "credential.utk.get", #"{"utks":[]}"#)
        do {
            _ = try await again.value
            Issue.record("no error")
        } catch let e as VaultOpError {
            #expect(e.code == "too_soon")
        }
        #expect(await ops.base.relay.noDeposit(within: 0.3), "no resync sent")
        #expect(d.utkCount == 0)
    }

    /// A resync that carries no UTKs either: `utk_empty`, and nothing more sent.
    @Test func anEmptyResyncIsUtkEmpty() async throws {
        let (d, v) = try await holder()
        let api = VaultApi(device: d) { true }
        let check = Task { try await api.ownerCheck(pin: "975310", password: "pw") }
        try await ops.answer(v, d, "credential.utk.get", #"{"utks":[]}"#)
        let resync = try await ops.answer(v, d, "credential.utk.get", #"{"utks":[]}"#)
        #expect(try isResync(resync))
        do {
            _ = try await check.value
            Issue.record("no error")
        } catch let e as VaultOpError {
            #expect(e.code == "utk_empty")
        }
        #expect(await ops.base.relay.noDeposit(within: 0.3))
    }
}
