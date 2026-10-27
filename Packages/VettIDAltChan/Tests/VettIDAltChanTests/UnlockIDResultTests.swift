import Foundation
import Testing
@testable import VettIDAltChan

// Fixtures (JSON bodies of the fake vault) stay on one line each.
// swiftlint:disable line_length

/// The sealed results' `unlock_id` (release L).
@Suite struct UnlockIDResultTests {
    /// (VAULT-MESSAGING 0.56.4 §10.2 "Locks", release L) `unlock_id`: kept when of the form; absent, "" (a release R enclave
    /// before L) or another form: none.
    @Test func theUnlockIDIsKeptOnlyInItsForm() throws {
        let pcr = FakeEnclave.pcr0
        let id = "0123456789abcdef0123456789abcdef"
        let head = #"{"ok":true,"state_seq":3,"header_seq":2,"token":"t","release":"\#(pcr)","release_number":3,"release_status":"active","manifest_serial":7"#
        #expect(try UnlockResult.parse(Array((head + "}").utf8)).unlockID == nil)
        #expect(try UnlockResult.parse(Array((head + #","unlock_id":"\#(id)"}"#).utf8)).unlockID == id)
        for v in [#""""#, #""0123456789ABCDEF0123456789ABCDEF""#, #""0123""#, #""0123456789abcdef0123456789abcdeg""#] {
            #expect(try UnlockResult.parse(Array((head + #","unlock_id":\#(v)}"#).utf8)).unlockID == nil, "\(v)")
        }
        #expect(
            try EnrollResult.parse(Array(#"{"ok":true,"vault_id":"abc","unlock_id":"\#(id)"}"#.utf8))
                == EnrollResult(ok: true, code: nil, vaultID: "abc", unlockID: id)
        )
        #expect(try EnrollResult.parse(Array(#"{"ok":true,"vault_id":"abc","unlock_id":""}"#.utf8)).unlockID == nil)
        #expect(UnlockIds.of(nil) == nil && UnlockIds.of(id) == id)
    }

    /// (VAULT-MESSAGING 0.67.0 §11.4) `invitation_recovery_id`: kept when a string; absent (an older vault), "" or not a string:
    /// none, and the rest of the result stands.
    @Test func theInvitationRecoveryIDIsOptional() throws {
        let pcr = FakeEnclave.pcr0
        let head = #"{"ok":true,"state_seq":3,"header_seq":2,"token":"t","release":"\#(pcr)","release_number":3,"release_status":"active","manifest_serial":7"#
        #expect(try UnlockResult.parse(Array((head + "}").utf8)).invitationRecoveryID == nil)
        let named = try UnlockResult.parse(Array((head + #","invitation_recovery_id":"01J0RECOVERY"}"#).utf8))
        #expect(named.invitationRecoveryID == "01J0RECOVERY" && named.ok && named.stateSeq == 3)
        for v in [#""""#, "7", "true"] {
            let r = try UnlockResult.parse(Array((head + #","invitation_recovery_id":\#(v)}"#).utf8))
            #expect(r.invitationRecoveryID == nil && r.ok, "\(v)")
        }
        // A refusal carries none.
        #expect(try UnlockResult.parse(Array(#"{"ok":false,"code":"bad_pin","header_seq":2}"#.utf8)).invitationRecoveryID == nil)
    }
}

// swiftlint:enable line_length
