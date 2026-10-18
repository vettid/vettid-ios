import Foundation

/// Which enrollment outcomes are definite (chosen; not in the spec): only then are the enrollment's nonces and its
/// pending epoch-1 record dropped and a start-over allowed. The enclave checks the manifest, the attestation, the
/// request and its sealing key before it looks for an existing vault (vettid-vault `Core.enroll`), so after a request
/// whose outcome is unknown (a lost answer, a timeout, an unreadable result, a crash mid-request) every later answer may
/// come from a vault that exists: the keys are then kept until `vault.enrolled` or ``VaultManager/unknownEnrollmentKept``.
enum EnrollOutcomes {
    /// The enrollment failed with none of its requests possibly processed (decided where it failed, not by the error's
    /// type): none was posted, or each posted one certainly never reached the enclave's processing
    /// ([outstanding] counts the others).
    static func neverSent(earlierUnknown: Bool, outstanding: Int) -> Bool { !earlierUnknown && outstanding == 0 }

    /// An opened `vault.enroll.result` that refused (any code, `vault_exists` included once no `vault.enrolled` came
    /// within the grace) is definite only when no earlier request of this enrollment had an unknown outcome.
    static func definite(earlierUnknown: Bool) -> Bool { !earlierUnknown }
}
