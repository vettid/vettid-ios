#if DEBUG
import Foundation
import VettIDCrypto
import VettIDTesting

/// TEST ONLY. The releases the fake vault runs (VAULT-MESSAGING §11.10): release 3, and release 4 when listed; the release
/// the vault is sealed to and routed to; how a `release_update` is answered; and the updates it was sent.
struct FakeReleases {
    /// The release a pending move left.
    var oldRelease: UInt64? { pending.map { $0 == 4 ? 3 : 4 } }

    var listed4 = false
    var routed: UInt64 = 3
    /// A move recorded at the old release and not yet confirmed by the target's first opening (`state.release_move`).
    var pending: UInt64?
    /// The release of the instance the last enclave route served (the one that answers the next unlock).
    var serving: UInt64 = 3
    /// After a move, how many enclave routes still serve the release the vault left (the API learns the move late).
    var lagRoutes = 0
    /// The next route asking for a given release answers `409 vault_busy` (an instance of another release holds the
    /// lease) until the vault is locked through the member API.
    var busy = false
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

    /// After the next move, this many enclave routes still serve the release the vault left.
    public var lagRoutesAfterMove: Int {
        get { locked { releases.lagRoutes } }
        set { locked { releases.lagRoutes = newValue } }
    }

    /// The next route that asks for a release answers `409 vault_busy` until a member API lock.
    public var holdsLeaseElsewhere: Bool {
        get { locked { releases.busy } }
        set { locked { releases.busy = newValue } }
    }

    /// The move recorded and not yet confirmed, if any.
    public var pendingMove: UInt64? { locked { releases.pending } }

    /// The release a route asks for (`?release=<pcr0>`, §11.10.5), as a number of this fake.
    static func askedRelease(_ r: FakeHTTPServer.Request) -> UInt64? {
        guard let q = r.query, let item = URLComponents(string: "?" + q)?.queryItems?.first(where: { $0.name == "release" }),
              let pcr = item.value
        else { return nil }
        return [3, 4].first { pcr0($0) == pcr }
    }

    /// The release an enclave route serves: the one asked for, or the vault's (the old one while the API lags behind a
    /// move); nil for `vault_busy`. Callers hold ``cond``.
    func route(asked: UInt64?) -> UInt64? {
        if let asked {
            if releases.busy { return nil }
            releases.serving = asked
        } else if releases.lagRoutes > 0, releases.pending == releases.routed, let old = releases.oldRelease {
            releases.lagRoutes -= 1
            releases.serving = old
        } else {
            releases.serving = releases.routed
        }
        return releases.serving
    }

    /// The vault's release rules after a right PIN (`releaseRules`): the `update` member, whether the vault stays locked
    /// (a move), and the release that answered. Callers hold ``cond``.
    func releaseRules(_ u: UpdateSeen?) -> (member: String, locked: Bool) {
        let serving = releases.serving
        if let target = releases.pending {
            if serving == target {
                // Confirmation at the new release: from here the move is final; any update is ignored.
                releases.pending = nil
                return ("", false)
            }
            if let u, u.to == Self.pcr0(serving), u.toRelease == serving {
                // Abandoning the unconfirmed move: back on this release, open.
                releases.pending = nil
                releases.routed = serving
                return (#","update":{"to":"\#(u.to)","result":"abandoned"}"#, false)
            }
            // Never resume with a pending move: it is completed again (§11.10.4 "Failures").
            return (#","update":{"to":"\#(Self.pcr0(target))","result":"moved"}"#, true)
        }
        let (member, moved) = updateOutcome(u)
        if moved, let u {
            // §11.10.4 steps 6–8: recorded, sealed to the target; the vault locks without opening.
            releases.pending = u.toRelease
            releases.routed = u.toRelease
        }
        return (member, moved)
    }
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
        guard let u else { return ("", false) }
        switch releases.answer {
        case .ignore:
            return ("", false)
        case .refuse(let code):
            return (#","update":{"to":"\#(u.to)","result":"refused","code":"\#(code)"}"#, false)
        case .move:
            guard releases.listed4, u.to == Self.pcr0(u.toRelease) else {
                return (#","update":{"to":"\#(u.to)","result":"refused","code":"target"}"#, false)
            }
            guard u.toRelease > releases.serving else {
                return (#","update":{"to":"\#(u.to)","result":"refused","code":"downgrade"}"#, false)
            }
            return (#","update":{"to":"\#(u.to)","result":"moved"}"#, true)
        }
    }
}
#endif
