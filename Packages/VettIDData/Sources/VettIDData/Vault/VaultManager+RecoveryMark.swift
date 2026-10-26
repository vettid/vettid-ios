import Foundation
import VettIDAltChan

/// What the member API says of an open that got no answer: whether the vault adopted this phone.
enum OpenMarkVerdict: Equatable, Sendable {
    /// The status is accepted with this key and the recovery is gone (`recovery: null`): the key is the vault's app key
    /// (MEMBER-API "Completed"), so the open was adopted and the resume finishes it.
    case adopted
    /// The status is accepted and still shows the recovery `registered`: the vault has not made this phone its app.
    case stillRegistered
    /// The member API could not say (the network, the service, an answer that decides nothing). A `401` is one: the member API
    /// answers it for many causes besides a recovery that ended without this phone (a clock outside the window, a reused nonce, a
    /// malformed header, a vault deleted or no longer the account's current one), so it proves nothing (MEMBER-API "Recovering
    /// key", VAULT-MESSAGING §11.11.7).
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
        } catch {
            return .undecided
        }
    }

    /// Refuses, while an open went out and got no answer, whatever could delete the key the vault may hold: a start over and a
    /// new registration. Only an answer that shows the vault adopted this phone, or still holds the recovery, changes the guidance; no answer clears the mark.
    func refuseWhileOpenMarked() async throws {
        // The sticky mark of the device counts too: a refusal after an unanswered open proves nothing (IOS-PLAN 0.1.38 §4.10).
        let device = try await storedSession()?.device
        if let device { await convertLegacyUnanswered(device) }
        let sticky = device?.recoveryOpenEverUnanswered ?? false
        guard record.value.recoveryOpenUnanswered || sticky else { return }
        switch await openMarkVerdict() {
        case .adopted: throw VaultFailure(.other, code: Self.codeRecoveryOpenSent)
        case .stillRegistered: throw VaultFailure(.other, code: Self.codeRecoveryOpenPending)
        case .undecided: throw VaultFailure(.other, code: Self.codeRecoveryOpenUnknown)
        }
    }
}
