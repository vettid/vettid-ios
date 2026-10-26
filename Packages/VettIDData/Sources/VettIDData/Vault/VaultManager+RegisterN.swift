import Foundation
import VettIDAltChan
import VettIDAttestation
import VettIDCrypto
import VettIDRelay
import VettIDVault

/// One register flow of the new identity N of a phone that could not tell (IOS-PLAN 0.1.38 §4.9 "A failed register"), as it stood
/// before its first POST.
struct RegisterAttempt {
    /// A register POST of N for the same code was made before: every later POST is a repeat, which the member API answers
    /// `409 recovery_not_available` once the first is recorded, and the vault `used` once it applied one.
    let repeated: Bool
    /// A POST for the same code left N maybe registered (a `202`) or unknown.
    let kept: Bool
    /// N never had a registration answered `ok`, left maybe registered, or unknown (for any recovery).
    let firstN: Bool
}

/// The register POSTs of one flow: each request built (and recorded before it is posted), and whether the member API took it.
final class RegisterPosts: @unchecked Sendable {
    private let lock = NSLock()
    private var posts: [Bool] = []

    func built() { lock.withLock { posts.append(false) } }
    func sent() { lock.withLock { if !posts.isEmpty { posts[posts.count - 1] = true } } }
    /// A request was built (and N's new registration made).
    var any: Bool { lock.withLock { !posts.isEmpty } }
    /// An earlier POST of this flow (sealed again after `instance_moved` or an `expired` slot): the last one is a repeat.
    var reposted: Bool { lock.withLock { posts.count > 1 } }
    /// An earlier POST of this flow got a `202`: N was left maybe registered by it.
    var earlierTaken: Bool { lock.withLock { posts.dropLast().contains(true) } }
    /// The member API took the last POST: anything that failed after that may have reached the vault.
    var lastTaken: Bool { lock.withLock { posts.last == true } }
}

/// What the last POST of a register flow of N said of N's registration for its code (IOS-PLAN 0.1.38 §4.9 "A failed register").
enum RegisterPostOutcome: Equatable {
    /// Not registered by this POST: a first POST with no `202`, or a readable refusal.
    case notRegistered
    /// Got a `202` (or is a repeat answered `409 recovery_not_available` or `used`): the status signed with K confirms it.
    case maybe
    /// Any other answer without a `202` (except a `401`): N may have registered.
    case unknown
    /// `401` to the POST itself.
    case unauthorized
}

// The register of N (IOS-PLAN 0.1.38 §4.9; VAULT-MESSAGING 0.63.1 §11.14.6 "Two identities at most"), the first time or again for a
// further recovery: the same K, the same N keys, the new code, and a new App Attest key. Each POST is judged on its own. Mirrors
// vettid-android `registerNewIdentity`.
extension VaultManager {
    /// The sealed `vault.recovery.register` of N, whose POSTs decide whether N registered for this recovery:
    /// - `ok`: registered;
    /// - got no `202` (`503 release_starting` or `vault_unavailable`, `429`, `409 recovery_not_available`, or no answer at all):
    ///   only a first POST for the code is not registered; to a repeat, `409 recovery_not_available` is maybe registered;
    /// - a `202` followed by a failure (the poll fails or times out, `retry`, the unsealed slot `expired`), or a repeat answered
    ///   `used`: maybe registered, confirmed with the status signed with K;
    /// - a readable refusal: that POST is not registered;
    /// - any other answer without a `202`, except a `401`: N is kept as unknown;
    /// - a `401`: N is dropped only when it never had a registration answered `ok`, left maybe registered, or unknown; a new claim
    ///   then says whether K became a key in use.
    /// Not registered, N's registration of before this code is its own again, unless an earlier POST for the code left N maybe
    /// registered or unknown: then that stays.
    func registerN(
        _ s: VaultSession, _ code: RecoveryCode, _ claimed: Claimed, _ attempt: RegisterAttempt,
        claimAgain: @Sendable () async throws -> Claimed
    ) async throws -> RecoveryRegistration {
        // The new recovery's record keeps the rule's identities; the phone-secret record is the earlier open's.
        var account = LocalAccount(userGuid: claimed.userGuid, vaultID: code.vaultID, emailHint: claimed.emailHint)
        account.recoveryRegistered = true
        await convertLegacyUnanswered(s.device)
        try resetRecord(account, carryRule: true)
        publishAccount()
        let rec = record.generation
        let posts = RegisterPosts()
        var outcome: RegisterPostOutcome
        var answer: RecoveryRegistration?
        var failure: (any Error)?
        do {
            let result = try await postRegisterN(s, code, guid: claimed.userGuid, since: rec, posts: posts)
            if result.ok { return try registeredN(claimed, code) }
            let repeated = attempt.repeated || posts.reposted
            outcome = repeated && result.code == "used" ? .maybe : .notRegistered
            answer = .refused(code: result.code ?? "retry")
        } catch {
            failure = error
            (outcome, answer) = Self.registerFailed(error, repeated: attempt.repeated || posts.reposted, taken: posts.lastTaken)
        }
        // A POST for this code that left N maybe registered or unknown, before or in this flow, keeps that registration.
        let kept = attempt.kept || posts.earlierTaken
        return try await settleRegisterN(
            s, code, claimed, outcome, answer: answer, failure: failure, kept: kept, firstN: attempt.firstN, posts: posts,
            claimAgain: claimAgain
        )
    }

    /// N's registration after the last POST of a register flow said [outcome].
    private func settleRegisterN( // swiftlint:disable:this function_parameter_count
        _ s: VaultSession, _ code: RecoveryCode, _ claimed: Claimed, _ outcome: RegisterPostOutcome, answer: RecoveryRegistration?,
        failure: (any Error)?, kept: Bool, firstN: Bool, posts: RegisterPosts, claimAgain: @Sendable () async throws -> Claimed
    ) async throws -> RecoveryRegistration {
        switch outcome {
        case .maybe:
            // One read decides, not the pair of reads (chosen; not in the spec: as vettid-android's `maybeRegistered`).
            if await ruleRead() == .registered { return try registeredN(claimed, code) }
            try noteRegisterKept(code.recoveryID)
            // Not confirmed: a failure after a `202` is said as it is; a repeat's answer is a refusal to try again.
            if let failure, (failure as? MemberApiError).map({ $0.queued }) ?? true { throw failure }
            return .refused(code: "retry")
        case .unknown:
            if posts.any { try noteRegisterKept(code.recoveryID) }
        case .notRegistered:
            // (A `202` this POST got is settled by its readable refusal: nothing is left maybe registered for the code.)
            if posts.any, !kept {
                try await s.device.restoreRecoveryRegistration()
                try persistRecord(record.generation) { $0.couldNotTell?.registerKept = nil }
            }
        case .unauthorized:
            // A re-registered N, or one a POST for this code left maybe registered or unknown, may be the identity the vault
            // adopted: nothing is dropped.
            if !kept { try await notRegisteredAfterUnauthorized(s, firstN: firstN, built: posts.any) }
            return try await claimedAgainAfterUnauthorized(failure, claimAgain: claimAgain)
        }
        if let answer { return answer }
        throw failure ?? VaultFailure(.other, code: "retry")
    }

    /// A `401` to an N with nothing left maybe registered or unknown for this code: an N that never registered goes, another one is
    /// registered as before this code.
    private func notRegisteredAfterUnauthorized(_ s: VaultSession, firstN: Bool, built: Bool) async throws {
        if firstN {
            try await dropNewIdentity()
        } else if built {
            try await s.device.restoreRecoveryRegistration()
        }
    }

    /// What a register flow of N that threw says of its last POST, and the refusal it answers when it has its own text.
    nonisolated static func registerFailed(
        _ error: any Error, repeated: Bool, taken: Bool
    ) -> (RegisterPostOutcome, RecoveryRegistration?) {
        if let f = error as? VaultFailure, f.code == codeNotOffered { return (.notRegistered, .refused(code: codeNotOffered)) }
        let outcome = registerPostOutcome(error, repeated: repeated, taken: taken)
        guard let e = error as? MemberApiError, !e.queued, outcome == .notRegistered || outcome == .unknown else { return (outcome, nil) }
        switch e.code {
        case MemberApiError.recoveryNotAvailable: return (outcome, .refused(code: codeNotAvailable))
        case MemberApiError.recoveryUnavailable: return (outcome, .refused(code: codeNoBackup))
        default: return (outcome, nil)
        }
    }

    /// What a register flow of N that threw says of its last POST.
    nonisolated static func registerPostOutcome(_ error: any Error, repeated: Bool, taken: Bool) -> RegisterPostOutcome {
        if let e = error as? MemberApiError, !e.queued {
            if e.status == 401, e.code == MemberApiError.unauthorized { return .unauthorized }
            // The member API's answers that mean no `202`.
            let no202 = e.status == 503 || e.status == 429 || e.code == MemberApiError.recoveryNotAvailable
            if no202 { return repeated ? (e.code == MemberApiError.recoveryNotAvailable ? .maybe : .notRegistered) : .notRegistered }
            return .unknown
        }
        // After a `202`, anything that fails (the poll's own answers, no answer, a slot that cannot be read) may follow a
        // register the vault applied.
        if taken { return .maybe }
        // No answer at all to the POST: no `202`.
        if error is URLError || error is RelayError || (error as? VaultFailure)?.kind == .network { return .notRegistered }
        return .unknown
    }

    /// The register itself; [posts] notes each request made (with N's new registration, recorded before it is posted) and each the
    /// member API took.
    private func postRegisterN(
        _ s: VaultSession, _ code: RecoveryCode, guid: String, since rec: Int, posts: RegisterPosts
    ) async throws -> RecoveryResult {
        let (secrets, attester) = (phoneSecrets, config.attester)
        return try await s.alt.recoveryRegister(
            vaultID: code.vaultID, attester: attester,
            build: { [weak self] e in
                // IOS-PLAN ID8 (§11.10.9): release R's recovery only, and only with `recovery_offered`.
                let caps = e.descriptor.capabilities
                try ReleasePath.requireR(caps)
                guard ReleasePath.recoveryOffered(caps) else { throw VaultFailure(.notSupported, code: Self.codeNotOffered) }
                var (made, _) = try secrets.reuseOrCreateNoting(keyVault: code.vaultID)
                Bytes.wipe(&made.secret)
                await self?.noteRegistering(e, since: rec)
                let req = try await s.device.prepareRecoveryRegister(
                    userGuid: guid, code: code, enclave: e, attester: attester, keepingHistory: true
                )
                // (IOS-PLAN 0.1.39 §4.9) The key this register attested is written with its `recovery_id` before the POST: the
                // handshake keeps the key of the registration its `ctx` names.
                if let k = req.attestedKeyID { try attester.tag(keyID: k, registration: code.recoveryID) }
                // Each POST is recorded durably before it is posted: every later one for this code is a repeat.
                try await self?.noteRegisterPosting(code.recoveryID)
                posts.built()
                return req
            },
            open: { raw, rid in try s.device.openRecoveryResult(raw, requestID: rid) },
            onSent: { [weak self] in
                posts.sent()
                // A `202`: N may be registered for this code from now on.
                try? await self?.noteRegisterKept(code.recoveryID)
            }
        )
    }

    private func noteRegisterPosting(_ recoveryID: String) throws {
        try persistRecord(record.generation) { $0.couldNotTell?.registerTried = recoveryID }
    }

    private func noteRegisterKept(_ recoveryID: String) throws {
        try persistRecord(record.generation) { $0.couldNotTell?.registerKept = recoveryID }
    }

    /// A claim key that has since become a key in use is no claim key: a new claim says whether. Anything else decides nothing: the
    /// `401` stands, and everything is kept.
    private func claimedAgainAfterUnauthorized(
        _ e: (any Error)?, claimAgain: @Sendable () async throws -> Claimed
    ) async throws -> RecoveryRegistration {
        do {
            _ = try await claimAgain()
        } catch let again as MemberApiError where again.code == MemberApiError.keyInUse {
            return try await claimKeyInUse()
        } catch {
            // Nothing more is known.
        }
        throw e ?? VaultFailure(.unauthorized)
    }

    /// N registered for this recovery: the rule's decisions are made again from the next reads.
    private func registeredN(_ claimed: Claimed, _ code: RecoveryCode) throws -> RecoveryRegistration {
        try persistRecord(record.generation) {
            guard var ct = $0.couldNotTell else { return }
            (ct.ended, ct.unlock, ct.unlockByReads, ct.bothEnded, ct.transferIncomplete) = (false, false, false, false, false)
            (ct.refusalsSinceMs, ct.refusalsForMs) = (nil, nil)
            ct.registerKept = code.recoveryID
            $0.couldNotTell = ct
            $0.couldNotTellRead = nil
        }
        usesPhoneSecret = phoneSecrets.inUse
        config.attestStartOver?.set(recovering: true)
        phase = .setup(.recovering)
        return .registered(emailHint: claimed.emailHint)
    }
}
