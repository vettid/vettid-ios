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
}

// swiftlint:enable line_length
