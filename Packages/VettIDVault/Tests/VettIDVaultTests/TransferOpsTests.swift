import Foundation
import Testing
@testable import VettIDVault
import VettIDCrypto

// Fixtures (JSON bodies of the fake vault) stay on one line each.
// swiftlint:disable line_length

/// The old phone's approval of a direct transfer and the new phone's take-over of the credential (VAULT-MESSAGING §6.7.1
/// steps 3 and 5, §11.14.10, §11.7.1) against the fake vault. Mirrors vettid-android `VaultDeviceTest`'s transfer
/// approvals. The approval's answer for a signer the vault wants confirmed (VA4, signer continuity across an iOS app)
/// cannot be tested against the real vault until it is implemented; the fake vault answers as the spec says.
@Suite struct TransferOpsTests {
    let ops = CredentialOpsTests()

    /// A paired device holding the credential blob (version 1), and a pool of UTKs on offer.
    struct Holder {
        let d: VaultDevice
        let v: FakeVault
        let api: VaultApi
        let utks: String
        let keys: [String: KemPrivateKey]
    }

    /// A paired device holding the credential blob (version 1) and a pool of [n] UTKs on offer.
    func holder(_ n: Int) async throws -> Holder {
        let (d, v) = try await ops.base.pairedDevice()
        let api = VaultApi(device: d) { true }
        let (utks, keys) = try ops.pool(n)
        let fetch = Task { try await api.credentialFetch() }
        try await ops.answer(v, d, "credential.get", #"{"credential":"AQID","version":1}"#)
        try await ops.answer(v, d, "credential.ack")
        try await fetch.value
        return Holder(d: d, v: v, api: api, utks: utks, keys: keys)
    }

    /// Release R: the blob and the transfer id beside the sealed password and PIN, the answer `{"unlink":
    /// "after_new_unlock"}` keeps this phone's keys; the confirmed signer class goes beside the transfer id.
    @Test func theApprovalCarriesTheBlobTheTransferAndTheSignerAndSaysKeep() async throws {
        let h = try await holder(2)
        let approve = Task { try await h.api.transferApprove(transferID: "t-1", pin: "246802", password: "Cafe\u{301} pw", signer: "google_play") }
        try await ops.answer(h.v, h.d, "credential.utk.get", h.utks)
        let req = try await ops.answer(h.v, h.d, VaultApi.typeTransferApprove, #"{"unlink":"after_new_unlock"}"#)
        let outer = try StrictJson.parseObject(req.body)
        #expect(outer.members.map(\.name) == ["utk_id", "sealed", "credential", "transfer_id", "signer"])
        #expect(try outer.string("credential") == "AQID" && outer.string("transfer_id") == "t-1" && outer.string("signer") == "google_play")
        let p = try ops.payload(req, h.v.vaultID, h.keys)
        #expect(p.members.map(\.name) == ["password", "pin"])
        #expect(try p.string("pin") == "246802" && p.string("password") == "Caf\u{e9} pw")
        #expect(try await approve.value == TransferApproved(keepUntilNewUnlock: true))
    }

    /// Before release R the answer is `{}`: the transfer is complete, nothing is kept. Without a confirmed signer the
    /// request has no `signer` member.
    @Test func anEarlierReleaseAnswersEmptyAndNoSignerIsSentUnconfirmed() async throws {
        let h = try await holder(2)
        let approve = Task { try await h.api.transferApprove(transferID: "t-1", pin: "246802", password: "pw") }
        try await ops.answer(h.v, h.d, "credential.utk.get", h.utks)
        let req = try await ops.answer(h.v, h.d, VaultApi.typeTransferApprove, "{}")
        #expect(!(try StrictJson.parseObject(req.body)).has("signer"))
        #expect(try await approve.value == TransferApproved(keepUntilNewUnlock: false))
    }

    /// `signer_unconfirmed` (§11.7.1): a failure with its code; the UTK of that attempt is spent (0.52.0), so the next
    /// approval takes a fresh one, and the blob is not fetched again for it.
    @Test func aSignerUnconfirmedRefusalSpendsTheUTKAndTheNextApprovalUsesAFreshOne() async throws {
        let h = try await holder(3)
        let first = Task { try await h.api.transferApprove(transferID: "t-1", pin: "246802", password: "pw") }
        try await ops.answer(h.v, h.d, "credential.utk.get", h.utks)
        let refused = try await ops.answer(h.v, h.d, VaultApi.typeTransferApprove, code: "signer_unconfirmed", errorBody: "{}")
        do {
            _ = try await first.value
            Issue.record("no error")
        } catch let e as VaultOpError {
            #expect(e.code == "signer_unconfirmed")
        }
        let second = Task { try await h.api.transferApprove(transferID: "t-1", pin: "246802", password: "pw", signer: "google_play") }
        let again = try await ops.answer(h.v, h.d, VaultApi.typeTransferApprove, #"{"unlink":"after_new_unlock"}"#)
        #expect(try StrictJson.parseObject(refused.body).string("utk_id") != StrictJson.parseObject(again.body).string("utk_id"))
        #expect(try StrictJson.parseObject(again.body).string("signer") == "google_play")
        #expect(try await second.value.keepUntilNewUnlock)
    }

    /// Without the blob on this device nothing is sent.
    @Test func theApprovalNeedsTheBlob() async throws {
        let (d, _) = try await ops.base.pairedDevice()
        let api = VaultApi(device: d)
        await #expect(throws: VaultStateError.self) { _ = try await api.transferApprove(transferID: "t-1", pin: "246802", password: "pw") }
    }

    /// §6.7.1 step 5: the new phone fetches the blob the vault kept (`credential.get`), confirms it (`credential.ack`)
    /// and fills its UTK pool (`credential.utk.get`).
    @Test func theNewPhoneTakesTheCredentialOver() async throws {
        let (d, v) = try await ops.base.pairedDevice()
        let api = VaultApi(device: d)
        let (utks, _) = try ops.pool(3)
        let take = Task { try await api.credentialTakeOver() }
        try await ops.answer(v, d, "credential.get", #"{"credential":"AQID","version":4}"#)
        let ack = try await ops.answer(v, d, "credential.ack")
        #expect(VaultJSON.int(VaultJSON.object(ack.body), "version") == 4)
        try await ops.answer(v, d, "credential.utk.get", utks)
        try await take.value
        #expect(d.credentialVersion == 4 && d.utkCount == 3)
    }
}

// swiftlint:enable line_length
