import Foundation
import VettIDAltChan

/// What the member API says of an open that got no answer: whether the vault adopted this phone.
enum OpenMarkVerdict: Equatable, Sendable {
    /// The status is accepted with this key and the recovery is gone (`recovery: null`): the key is the vault's app key
    /// (MEMBER-API "Completed"), so the open was adopted and the resume finishes it.
    case adopted
    /// The status is refused `401` with a `Date` that shows the phone's clock right: the recovering key is taken only until the
    /// recovery ends or the vault reports the key as its app key (VAULT-MESSAGING §11.11.7), and a key that is the app key is
    /// accepted. The recovery ended without this phone (chosen reading; not in the spec).
    case notAdopted
    /// The status is accepted and still shows the recovery `registered`: the vault has not made this phone its app.
    case stillRegistered
    /// The member API could not say (the network, the service, an answer that decides nothing).
    case undecided
}

// The `recoveryOpenUnanswered` mark and the member API (VAULT-MESSAGING §11.11.7, §11.14.6 "A lost ok").
extension VaultManager {
    /// The answers that prove the recovery record still existed when the open was read (§11.14.6 steps 1 to 3), so that no
    /// earlier open was adopted. Not `no_recovery`, and not `attestation`, `manifest`, `wrong_release` or `bad_request`, which
    /// may be decided before the record is read. (An answer with `attempts` proves it too.)
    nonisolated static let recordExistedCodes: Set<String> = [
        "busy", "not_armed", "stored_mismatch", "expired", "retry", "wrong_again", "counter_unavailable",
    ]

    /// Asks the member API (`GET /api/vault/status`, signed by this phone's key) whether the vault adopted this phone.
    func openMarkVerdict() async -> OpenMarkVerdict {
        do {
            guard let status = try await vaultStatus() else { return .undecided }
            switch status.recoveryState {
            case nil: return .adopted
            // MEMBER-API "Completed": recorded at the adopted key's first status read.
            case "completed"?: return .adopted
            case "registered"?: return .stillRegistered
            default: return .undecided
            }
        } catch let e as MemberApiError where e.code == MemberApiError.unauthorized && e.dateChecked {
            // (chosen; not in the spec: it gives the recovering key no explicit "ended" signal.) Read as "the recovery ended
            // without this phone" only for a `401` whose `Date` is within the skew limit: a phone whose clock is off, or a proxy
            // that strips the header, decides nothing.
            return .notAdopted
        } catch {
            return .undecided
        }
    }

    /// Refuses, while an open went out and got no answer, whatever could delete the key the vault may hold: a start over and a
    /// new registration. The member API decides first: a recovery that ended without this phone clears the mark.
    func refuseWhileOpenMarked() async throws {
        guard record.value.recoveryOpenUnanswered else { return }
        switch await openMarkVerdict() {
        case .notAdopted: clearOpenMark(since: record.generation)
        case .adopted: throw VaultFailure(.other, code: Self.codeRecoveryOpenSent)
        case .stillRegistered: throw VaultFailure(.other, code: Self.codeRecoveryOpenPending)
        case .undecided: throw VaultFailure(.other, code: Self.codeRecoveryOpenUnknown)
        }
    }
}
