import Foundation
import Testing
@testable import VettIDVault
import VettIDCrypto

/// The UTK of a sealed operation goes back to the pool when the vault refused before spending it (§3.5.4,
/// ``CredentialOps/utkUnspentCodes``, from vettid-vault's order of checks), and stays spent otherwise: a phone that is
/// refused again and again (no longer the holder, `forbidden`) never runs out of UTKs while the vault holds a full pool
/// for it.
@Suite struct UtkReturnTests {
    let ops = CredentialOpsTests()

    /// Refused before the UTK is spent: the dispatch (`vault/inbound.go`), the credential feature's gate, `Operate` and
    /// `holderGate`, and `device.transfer.approve`'s signer.
    static let beforeSpend = ["forbidden", "unsupported_type", "session_required", "owner_check_required", "signer_unconfirmed"]
    /// Refused after the UTK is spent on at least one path of vettid-vault, and a code it does not answer.
    static let afterSpend = [
        "bad_pin", "bad_password", "backoff", "stale_credential", "utk_invalid", "exists", "weak_password", "bad_request",
        "not_found", "credential_required", "credential_frozen", "rotation_required", "some_future_code",
    ]

    /// `credential.create` (a sealed operation without the blob) refused with [code], from a pool of two.
    func createRefused(_ code: String) async throws -> VaultDevice {
        let (d, v) = try await ops.base.pairedDevice()
        let api = VaultApi(device: d) { true }
        let (utks, _) = try ops.pool(2)
        let create = Task { try await api.credentialCreate(password: "a long password", pin: "123456") }
        try await ops.answer(v, d, "credential.utk.get", utks)
        try await ops.answer(v, d, "credential.create", code: code, errorBody: "{}")
        await #expect(throws: VaultOpError.self) { try await create.value }
        return d
    }

    @Test(arguments: beforeSpend) func aRefusalBeforeTheSpendReturnsTheUTK(_ code: String) async throws {
        let d = try await createRefused(code)
        #expect(d.utkCount == 2, "\(code): the UTK back in the pool")
        #expect(CredentialOps.returnsUTK(onRefusal: code))
    }

    @Test(arguments: afterSpend) func aRefusalAfterTheSpendKeepsTheUTKSpent(_ code: String) async throws {
        let d = try await createRefused(code)
        #expect(d.utkCount == 1, "\(code): the UTK stays out of the pool")
        #expect(!CredentialOps.returnsUTK(onRefusal: code))
    }

    /// A refusal without a code keeps the UTK spent.
    @Test func noCodeKeepsTheUTKSpent() {
        #expect(!CredentialOps.returnsUTK(onRefusal: nil))
    }

    /// The owner check (an operation with the blob) refused `forbidden` again and again: the pool keeps its UTKs, each
    /// check is sealed to the UTK the refusal returned, and no `credential.utk.get` is needed.
    @Test func repeatedForbiddenRefusalsDoNotDrainThePool() async throws {
        let (d, v) = try await ops.base.pairedDevice()
        let api = VaultApi(device: d) { true }
        let fetch = Task { try await api.credentialFetch() }
        try await ops.answer(v, d, "credential.get", #"{"credential":"AQID","version":1}"#)
        try await ops.answer(v, d, "credential.ack")
        try await fetch.value
        let (utks, keys) = try ops.pool(2)
        var sealedTo: Set<String> = []
        for i in 0..<6 {
            let check = Task { try await api.ownerCheck(pin: "975310", password: "pw") }
            if i == 0 { try await ops.answer(v, d, "credential.utk.get", utks) }
            let req = try await ops.answer(v, d, VaultApi.typeOwnerCheck, code: "forbidden", errorBody: "{}")
            _ = try ops.payload(req, v.vaultID, keys)
            sealedTo.insert(try StrictJson.parseObject(req.body).string("utk_id"))
            do {
                _ = try await check.value
                Issue.record("no error")
            } catch let e as VaultOpError {
                #expect(e.code == "forbidden")
            }
            #expect(d.utkCount == 2)
        }
        #expect(sealedTo.count == 1, "the same UTK each time")
    }

    /// A wrong PIN is answered after the UTK is spent: each check takes one more from the pool.
    @Test func badPinRefusalsSpendTheirUTKs() async throws {
        let (d, v) = try await ops.base.pairedDevice()
        let api = VaultApi(device: d) { true }
        let fetch = Task { try await api.credentialFetch() }
        try await ops.answer(v, d, "credential.get", #"{"credential":"AQID","version":1}"#)
        try await ops.answer(v, d, "credential.ack")
        try await fetch.value
        let (utks, _) = try ops.pool(3)
        for i in 0..<2 {
            let check = Task { try await api.ownerCheck(pin: "111111", password: "pw") }
            if i == 0 { try await ops.answer(v, d, "credential.utk.get", utks) }
            try await ops.answer(v, d, VaultApi.typeOwnerCheck, code: "bad_pin", errorBody: "{}")
            await #expect(throws: VaultOpError.self) { _ = try await check.value }
            #expect(d.utkCount == 2 - i)
        }
    }
}
