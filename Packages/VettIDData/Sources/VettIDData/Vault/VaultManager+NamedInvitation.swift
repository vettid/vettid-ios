import Foundation
import VettIDAltChan
import VettIDKeys
import VettIDVault

/// (IOS-PLAN 0.1.40 §4.9, §6.3) What the recovery screens tell of the PIN the pairing keeps (a part of ``MoveRepository``).
@MainActor
public protocol PairingPinKeeper {
    /// The pairing screen left the foreground, or the iPhone locked: the PIN kept in memory for the lost-ok unlock the pairing
    /// may send again is forgotten; that unlock then answers ``VaultManager/codePinNeeded`` and the PIN is asked for again.
    /// Default: nothing.
    func forgetPairingPin()
}

public extension PairingPinKeeper {
    func forgetPairingPin() {}
}

/// The PIN kept for the pairing was forgotten (the app left the foreground) when an unlock needed it.
struct PairingPinForgotten: Error {}

/// The `hs.init` with the named invitation got no `hs.resp`, or failed: the cause of the lost-ok unlock sent again.
struct NamedInvitationUnanswered: Error {}

// The recovered phone's first handshake (IOS-PLAN 0.1.40 §4.9 "Pairing", VAULT-MESSAGING 0.67.0 §11.14.6 "Pairing"). When an
// unlock's `ok` names the invitation (`invitation_recovery_id`) and one of the phone's identities registered it, that identity
// sends a single `hs.init` with it as `ctx`; without an `hs.resp` within the pairing timeout, or on a failure, the lost-ok unlock
// is sent again and one `hs.init` follows with the id its result names: two in all. The same `hs.init` is never sent again on its
// own. Then, or when the id is none of the phone's or the vault names none (an older vault), the walk of IOS-PLAN 0.1.39: each
// remaining `recovery_id` the identity registered for, newest first, then E.
extension VaultManager {
    /// The `hs.init`s with the named invitation, at most.
    nonisolated static let namedPairingTries = 2

    // MARK: - The PIN kept for the pairing

    /// Runs [body] with [pin] kept for the unlocks the pairing may need after the first (the lost-ok unlock sent again), in
    /// memory only and until [body] ends, unless ``forgetPairingPin()`` drops it first.
    func keepingPairingPin<T>(_ pin: String, _ body: () async throws -> T) async rethrows -> T {
        moveFlags.book.pairingPin = pin
        defer { moveFlags.book.pairingPin = nil }
        return try await body()
    }

    /// The PIN kept for the pairing; thrown ``PairingPinForgotten`` when it was forgotten.
    func pairingPinNow() throws -> String {
        guard let pin = moveFlags.book.pairingPin else { throw PairingPinForgotten() }
        return pin
    }

    /// (IOS-PLAN 0.1.40 §4.9, §6.3) The app left the foreground or the iPhone locked: the PIN kept for the pairing is forgotten.
    /// An unlock the pairing still needs then answers ``codePinNeeded``.
    public func forgetPairingPin() { moveFlags.book.pairingPin = nil }

    // MARK: - The pairing

    /// The recovered phone's handshake: with the invitation the vault named, else the walk; unanswered, the earlier identity,
    /// then an unlock with its own key and the walk again. The unlock's refusal code, and the session that paired (the earlier
    /// identity's, for a phone that could not tell whose invitation it was).
    func pairRecovered(_ s: VaultSession, resuming: Bool) async throws -> (String?, VaultSession) {
        guard s.device.namedInvitation != nil else { return try await pairWalking(s, resuming: resuming, skipping: [], named: false) }
        switch try await pairNamed(s, resuming: resuming) {
        case .paired(let p): return (nil, p)
        case .refused(let code, let p): return (code, p)
        case .walk(let p, let skipping): return try await pairWalking(p, resuming: resuming, skipping: skipping, named: true)
        }
    }

    /// The walk (IOS-PLAN 0.1.39 §4.9) without [skipping]; unanswered, the earlier identity, then (unless the named invitation
    /// was tried, [named]) an unlock with this identity's own key and the pairing again.
    private func pairWalking(
        _ s: VaultSession, resuming: Bool, skipping: Set<String>, named: Bool
    ) async throws -> (String?, VaultSession) {
        do {
            try await s.device.completeRecoveryOpen(timeout: handshakeWait(resuming: resuming), skipping: skipping)
            return (nil, s)
        } catch let e as VaultStateError where VaultFailures.noResponse(e) {
            // IOS-PLAN 0.1.38 §4.9: the vault answers a handshake it does not accept with nothing. After the new open's `ok` the
            // invitation may be the earlier identity's, under the earlier `recovery_id`.
            if let earlier = try await pairEarlierIdentity(skipping: skipping) { return earlier }
            // After the named invitation's tries the walk is not run again (chosen; not in the spec).
            guard !named else { throw e }
            // (A switch of identity stopped this session's device: the identity with the `ok` is opened again.)
            let own = record.value.couldNotTell == nil ? s : try await openSession()
            if let refusal = try await unlockOwn(own, pin: try pairingPinNow(), cause: e) { return (refusal, own) }
            // (IOS-PLAN 0.1.40 §4.9) That unlock's `ok` may name the invitation.
            if own.device.namedInvitation != nil { return try await pairNamedThenWalk(own) }
            // (IOS-PLAN 0.1.39 §4.9) That unlock's `ok` is a lost ok: each `recovery_id` this identity registered for is tried.
            try await own.device.completeRecoveryOpen(timeout: handshakeWait(resuming: false))
            return (nil, own)
        }
    }

    /// The named invitation after an unlock of the walk, then the remaining walk once.
    private func pairNamedThenWalk(_ own: VaultSession) async throws -> (String?, VaultSession) {
        switch try await pairNamed(own, resuming: false) {
        case .paired(let p): return (nil, p)
        case .refused(let code, let p): return (code, p)
        case .walk(let p, let skipping):
            try await p.device.completeRecoveryOpen(timeout: handshakeWait(resuming: false), skipping: skipping)
            return (nil, p)
        }
    }

    /// How the pairing with the named invitation ended.
    enum NamedPairing {
        case paired(VaultSession)
        /// An unlock on the way was refused (its code), for the session in use.
        case refused(String, VaultSession)
        /// The walk follows, from the identity that began, without the `recovery_id` whose `hs.init` went since the last unlock.
        case walk(VaultSession, skipping: Set<String>)
    }

    /// (IOS-PLAN 0.1.40 §4.9) The single `hs.init` with the invitation the last unlock named, by the identity that registered it;
    /// without an `hs.resp`, or on a failure, the lost-ok unlock again and one `hs.init` with the id its result names. An `hs.init`
    /// already sent with the named id (before a kill, or before the PIN was asked again) is never sent again without a new unlock.
    /// A result without the member (an older vault, an invitation replaced), or an id none of the phone's identities registered,
    /// goes straight to the walk.
    func pairNamed(_ start: VaultSession, resuming: Bool) async throws -> NamedPairing {
        var s = start
        // The id whose `hs.init` went since the last unlock: the walk leaves it out ("the remaining `recovery_id`s"); after an
        // unlock, which drops the begun handshake, none is left out (chosen; not in the spec).
        var lastSent: String?
        var (sent, unlocks) = (0, 0)
        while sent < Self.namedPairingTries, let named = s.device.namedInvitation,
              let owner = named.sent ? s.identity : namedOwner(named.recoveryID, current: s) {
            if named.sent || owner != s.identity {
                // The lost-ok unlock first: again after an `hs.init` that went (it renews the invitation, uses no attempt and names
                // it again), or the named identity's own, which holds no token yet (chosen; not in the spec).
                guard unlocks < Self.namedPairingTries else { break }
                unlocks += 1
                switch try await unlockForNamed(owner, from: s) {
                case .opened(let o): (s, lastSent) = (o, nil)
                case .refused(let code, let back): return .refused(code, back)
                case .notKey(let back): return try await walkFrom(start, back, skipping: lastSent)
                }
                continue
            }
            (lastSent, sent) = (named.recoveryID, sent + 1)
            if try await pairedNamed(s, named.recoveryID, timeout: handshakeWait(resuming: resuming && unlocks == 0)) {
                return .paired(s)
            }
        }
        return try await walkFrom(start, s, skipping: lastSent)
    }

    /// The single `hs.init` with [id]: false when no `hs.resp` came within [timeout], or it failed.
    private func pairedNamed(_ s: VaultSession, _ id: String, timeout: TimeInterval) async throws -> Bool {
        do {
            try await s.device.pairNamedInvitation(id, timeout: timeout)
            return true
        } catch {
            if error is CancellationError { throw error }
            return false
        }
    }

    /// The walk is the identity's that began (N's `recovery_id`s newest first, then E).
    private func walkFrom(_ start: VaultSession, _ s: VaultSession, skipping lastSent: String?) async throws -> NamedPairing {
        var s = s
        if s.identity != start.identity {
            try await selectIdentity(start.identity)
            s = try await openSession()
        }
        return .walk(s, skipping: Set([lastSent].compactMap { $0 }))
    }

    /// The lost-ok unlock before a named `hs.init`: [owner]'s own when it is the identity in use, else as
    /// ``unlockNamedOwner(_:from:)``.
    private func unlockForNamed(_ owner: IdentitySet, from s: VaultSession) async throws -> OwnerUnlock {
        guard owner == s.identity else { return try await unlockNamedOwner(owner, from: s) }
        if let refusal = try await unlockOwn(s, pin: try pairingPinNow(), cause: NamedInvitationUnanswered()) {
            return .refused(refusal, s)
        }
        return .opened(s)
    }

    /// The identity that registered [id]: the one in use first, then the others' stored states (read without any key). Nil when
    /// none did.
    func namedOwner(_ id: String, current s: VaultSession) -> IdentitySet? {
        if s.device.registeredRecoveryIDs.contains(id) { return s.identity }
        guard let ct = record.value.couldNotTell else { return nil }
        return ct.identities.reversed().first { set in
            guard set != s.identity, let bytes = try? config.file(VaultFiles.device(of: set)).load(),
                  let ids = try? VaultDevice.registeredRecoveryIDs(state: bytes) else { return false }
            return ids.contains(id)
        }
    }

    /// How the named identity's lost-ok unlock ended.
    enum OwnerUnlock {
        /// It holds the vault's `ok` now, and is the identity in use.
        case opened(VaultSession)
        /// A wrong PIN or a wait: the identity that began is in use again.
        case refused(String, VaultSession)
        /// It is not the vault's key: the identity that began is in use again.
        case notKey(VaultSession)
    }

    /// The lost-ok unlock of [owner], the identity that registered the named invitation, as ``pairEarlierIdentity(pin:skipping:)``
    /// does it: the identity to go back to is written down first, so that a kill meanwhile goes back to it.
    private func unlockNamedOwner(_ owner: IdentitySet, from s: VaultSession) async throws -> OwnerUnlock {
        let back = s.identity
        moveFlags.book.trialDepth += 1
        defer { moveFlags.book.trialDepth -= 1 }
        let outer = record.value.couldNotTell?.returnTo
        try persistRecord(record.generation) { $0.couldNotTell?.returnTo = back }
        func goBack() async throws -> VaultSession {
            try await selectIdentity(back)
            try persistRecord(record.generation) { $0.couldNotTell?.returnTo = outer }
            return try await openSession()
        }
        let other: VaultSession
        let u: UnlockOutcome
        do {
            try await selectIdentity(owner)
            other = try await openSession()
            guard other.device.recovering || other.device.recoveryOpenedNotFinished else { return .notKey(try await goBack()) }
            u = try await unlockWithSecret(other, pin: try pairingPinNow(), options: UnlockOptions(), path: .current)
        } catch {
            let backSession = try? await goBack()
            if error is CancellationError || error is PairingPinForgotten { throw error }
            guard let backSession else { throw error }
            return .notKey(backSession)
        }
        guard u.ok else {
            let backSession = try await goBack()
            if let code = u.result.code, code == "bad_pin" || code == "backoff" { return .refused(code, backSession) }
            return .notKey(backSession)
        }
        // No bundle: the vault does not hold this identity as the one a completed recovery made its app.
        guard other.device.recoveryOpenedNotFinished else { return .notKey(try await goBack()) }
        // The `ok` and the token are this identity's now: it stays the one in use (a restart finds it).
        try persistRecord(record.generation) { $0.couldNotTell?.returnTo = outer }
        return .opened(other)
    }
}
