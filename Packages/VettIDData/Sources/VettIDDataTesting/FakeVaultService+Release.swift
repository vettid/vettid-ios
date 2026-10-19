#if DEBUG
import Foundation
import VettIDCrypto

/// TEST ONLY. The releases the fake vault runs (VAULT-MESSAGING §11.10): release 3, and release 4 when listed; the release
/// the vault is sealed to and routed to; how a `release_update` is answered; and the updates it was sent.
struct FakeReleases {
    var listed4 = false
    var routed: UInt64 = 3
    /// A move recorded and not yet confirmed by the target's first opening.
    var pending: UInt64?
    var answer: FakeVaultService.ReleaseUpdateAnswer = .move
    var updates: [FakeVaultService.UpdateSeen] = []
}

// TEST ONLY. A release update in an unlock (§11.10.3, §11.10.4) as vettid-vault's enclave answers it
// (`vault/unlock.go` `releaseRules`): after the PIN, an approved move to a newer `active` release records the move, seals
// the header to the target and locks without opening (`update: moved`); the next unlock is routed to the target, which
// confirms the move. A refusal (`target`, `downgrade`, `approval`, `seal_key`, `pending`, `write`) still opens the vault.
// The fake does not verify the assertions: it records them for the test to check.
extension FakeVaultService {
    /// How a `release_update` is answered after a right PIN.
    public enum ReleaseUpdateAnswer: Sendable, Equatable {
        /// Moved to the target (`update: moved`), when it is newer than the routed release.
        case move
        /// Refused with the code; the vault opens on its release.
        case refuse(String)
        /// Ignored: the vault opens without an `update` member.
        case ignore
    }

    /// One `release_update` the vault received: its target, and the request's two assertions as sent.
    public struct UpdateSeen: Sendable {
        public let requestID: String
        public let vaultID: String
        public let to: String
        public let toRelease: UInt64
        public let manifestSerial: UInt64
        public let deviceAssertion: JsonObject
        public let approval: JsonObject
    }

    /// The PCR0 of the fake's release [n] (3: ``pcr0``).
    public static func pcr0(_ n: UInt64) -> String { n == 3 ? pcr0 : String(repeating: String(format: "a%x", n % 16), count: 48) }

    /// Whether the manifest also lists release 4 `active` (the update the app offers).
    public var listsRelease4: Bool {
        get { locked { releases.listed4 } }
        set { locked { releases.listed4 = newValue } }
    }

    /// The release the vault is sealed to, and the member API routes to.
    public var routedRelease: UInt64 {
        get { locked { releases.routed } }
        set { locked { releases.routed = newValue } }
    }

    public var releaseUpdateAnswer: ReleaseUpdateAnswer {
        get { locked { releases.answer } }
        set { locked { releases.answer = newValue } }
    }

    public var releaseUpdates: [UpdateSeen] { locked { releases.updates } }

    /// The `release_update` of an unlock request, recorded. Callers hold ``cond``.
    func recordUpdate(_ body: JsonObject, requestID: String) -> UpdateSeen? {
        guard let u = try? body.optObj("release_update"), let to = try? u.string("to"),
              let toRelease = try? u.uint("to_release", min: 1, max: StrictJson.maxSafeInteger),
              let approval = try? u.obj("approval"), let assertion = try? body.obj("device_assertion")
        else { return nil }
        let serial = ((try? body.optUint("manifest_serial", min: 0, max: StrictJson.maxSafeInteger)) ?? nil) ?? 0
        let seen = UpdateSeen(
            requestID: requestID, vaultID: (try? body.string("vault_id")) ?? "", to: to, toRelease: toRelease, manifestSerial: serial,
            deviceAssertion: assertion, approval: approval
        )
        releases.updates.append(seen)
        return seen
    }

    /// The `update` member of an opened vault's result, and whether the vault moved (it then stays locked). Callers hold
    /// ``cond``.
    func updateOutcome(_ u: UpdateSeen?) -> (member: String, moved: Bool) {
        // Confirmation at the new release: its first opening ignores any update (`releaseRules`).
        let confirming = releases.pending == releases.routed
        guard let u, !confirming else { return ("", false) }
        switch releases.answer {
        case .ignore:
            return ("", false)
        case .refuse(let code):
            return (#","update":{"to":"\#(u.to)","result":"refused","code":"\#(code)"}"#, false)
        case .move:
            guard releases.listed4, u.to == Self.pcr0(u.toRelease) else {
                return (#","update":{"to":"\#(u.to)","result":"refused","code":"target"}"#, false)
            }
            guard u.toRelease > releases.routed else {
                return (#","update":{"to":"\#(u.to)","result":"refused","code":"downgrade"}"#, false)
            }
            return (#","update":{"to":"\#(u.to)","result":"moved"}"#, true)
        }
    }
}
#endif
