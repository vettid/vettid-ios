import Foundation
import Testing
@testable import VettIDVault
import VettIDCrypto
import VettIDRelay
import VettIDTesting

// Fixtures (JSON bodies of the fake vault) stay on one line each.
// swiftlint:disable line_length

extension VaultDeviceTests {
    /// (VAULT-MESSAGING 0.56.4 §10.2 "Locks", release L) A bound lock names its unlock; `stale_lock` is its own error; the
    /// device's current unlock is what `vault.status` last said (absent or of another form: none); `exp` is 60 s at most.
    @Test func aBoundLockNamesTheUnlockAndTheStatusSaysWhichIsCurrent() async throws {
        let (d, v) = try await pairedDevice()
        let api = VaultApi(device: d)
        #expect(d.unlockID == nil)
        let id = "00112233445566778899aabbccddeeff"
        let status = Task { try await api.status() }
        let sreq = try v.open(try await relay.nextDeposit().payload)
        try await d.handle(try v.seal("vault.status", #"{"vault_id":"\#(v.vaultID)","unlock_id":"\#(id)"}"#, re: sreq.id, status: Inner.statusOK))
        _ = try await status.value
        #expect(d.unlockID == id)

        let locking = Task { () -> (any Error)? in
            do {
                try await api.lock(unlockID: id, timeout: 5, validFor: 600)
                return nil
            } catch { return error }
        }
        let req = try v.open(try await relay.nextDeposit().payload)
        #expect(req.type == "vault.lock")
        #expect(VaultJSON.string(VaultJSON.object(req.body), "unlock_id") == id)
        #expect(try #require(req.exp) < Date().addingTimeInterval(61)) // at most 60 s, whatever was asked
        try await d.handle(v.msg(try #require(v.keyring.current()).seal(Inner(id: Ulid.new(), type: req.type, ts: Date(), re: req.id, status: Inner.statusError, error: InnerError(VaultApi.codeStaleLock)))))
        let e = try #require(await locking.value as? VaultOpError)
        #expect(e.code == VaultApi.codeStaleLock)

        // A vault before L (or a malformed value): no current unlock.
        for body in [#"{"vault_id":"\#(v.vaultID)"}"#, #"{"vault_id":"\#(v.vaultID)","unlock_id":""}"#, #"{"vault_id":"\#(v.vaultID)","unlock_id":"ABCDEF"}"#] {
            let again = Task { try await api.status() }
            let r = try v.open(try await relay.nextDeposit().payload)
            try await d.handle(try v.seal("vault.status", body, re: r.id, status: Inner.statusOK))
            _ = try await again.value
            #expect(d.unlockID == nil, "\(body)")
        }
    }

    /// A `vault.status` answer is applied only if no opening came between its request and its answer.
    @Test func aStatusAnswerFromBeforeAnOpeningIsNotApplied() async throws {
        let (d, _) = try await pairedDevice()
        let id = "00112233445566778899aabbccddeeff"
        let other = "ffeeddccbbaa99887766554433221100"
        d.noteUnlockID(id, since: d.openingMark())
        #expect(d.unlockID == id)
        let before = d.openingMark()
        d.recoveryOpened(unlockID: other) // an opening this device learned of
        #expect(d.unlockID == other)
        d.noteUnlockID(id, since: before)
        #expect(d.unlockID == other, "a late answer from the opening before is not taken")
        d.recoveryOpened(unlockID: "") // a release before L: none
        #expect(d.unlockID == nil)
        d.noteUnlockID(id, since: d.openingMark())
        #expect(d.unlockID == id, "one asked for since is")
    }
}

// swiftlint:enable line_length
