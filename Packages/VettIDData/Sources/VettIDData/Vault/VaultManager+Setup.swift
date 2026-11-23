import Foundation
import VettIDAltChan
import VettIDVault

// The setup code (VAULT-MESSAGING §11.12.1) and starting over.
extension VaultManager {
    // MARK: - The setup code (§11.12.1)

    public func redeemSetupCode(_ code: SetupCodeInput) async throws -> String {
        moveFlags.book.redeeming += 1
        defer { moveFlags.book.redeeming -= 1 }
        let r: Redeemed = try await guarded {
            try prepared()
            // IOS-PLAN 0.1.38 §4.9: never while the phone could not tell (a redeem would bind K to another vault).
            if record.value.couldNotTell != nil { throw VaultFailure(.other, code: Self.codeRecoveryOpenSent) }
            // While this phone may hold a vault (``mayHoldVault(_:)``), no code is redeemed, not even the same vault's
            // again: a redeem spends the code and may bind this phone's app key to another vault (§11.12.2), and the
            // record already names the vault (chosen; not in the spec). A phone that holds nothing yet but carries a
            // stale enrollment starts afresh, as on vettid-android.
            let stored = try await storedSession()
            // A transfer under way (a scan being made, a start stored, or a pinned transfer): refused before anything is
            // forgotten and before the code is spent, as the enrollment is (``transferWaitingRefusal(_:)``).
            if let refusal = redeemTransferRefusal(stored?.device) { throw refusal }
            if let refusal = startOverRefusal(stored?.device) { throw refusal }
            if stored != nil { try await dropSession(forget: true) }
            let appKey = try config.keys.appKeys.getOrCreate().spki()
            // Any refusal of the code itself is `404 invalid_code` (``FailureKind/setupCodeInvalid``).
            switch code {
            case .secret(let secret): return try await member.redeemSecret(secret, appKey: appKey)
            case .typed(let email, let typed): return try await member.redeemTyped(email: email, code: typed, appKey: appKey)
            }
        }
        try guardedSync {
            // Checked again now that the code is spent: a transfer scanned while the redeem awaited the member API has
            // written its start and pinned its vault, which the record's reset below would wipe (refused, as it is before
            // the redeem; the spent code is the cost).
            if record.value.transferStartedMs != nil { throw VaultFailure(.enrollmentStarted, code: Self.codeTransferWaiting) }
            if let refusal = startOverRefusal(session?.device) { throw refusal }
            let local = record.value
            if !local.vaultID.isEmpty, r.vaultID == local.vaultID {
                // The same vault's code again (a re-scan): what this phone knows of its enrollment is kept.
                try record.update(since: record.generation) {
                    $0.userGuid = r.userGuid
                    $0.emailHint = r.emailHint
                }
                publishAccount()
            } else {
                try resetRecord(LocalAccount(userGuid: r.userGuid, vaultID: r.vaultID, emailHint: r.emailHint))
            }
        }
        phase = .setup(.newVault)
        return r.emailHint
    }

    /// Why no setup code may be redeemed now, if a transfer to this phone is under way: a scan being made
    /// (``MoveFlags``' `startingIn`), or what ``transferWaitingRefusal(_:)`` refuses (with no device stored: a leftover
    /// start that can't be cleared now).
    func redeemTransferRefusal(_ d: VaultDevice?) -> VaultFailure? {
        if moveFlags.book.startingIn > 0 { return VaultFailure(.enrollmentStarted, code: Self.codeTransferWaiting) }
        if let d { return transferWaitingRefusal(d) }
        guard record.value.transferStartedMs != nil else { return nil }
        // No device stored: nothing was pinned, so the leftover start is cleared now, as a resume clears it; one that
        // can't be cleared (its epoch-1 record not deleted) refuses.
        discardTransferStart(attestKey: nil)
        return record.value.transferStartedMs == nil ? nil : VaultFailure(.enrollmentStarted, code: Self.codeTransferWaiting)
    }

    /// "That is not my account": refused (``FailureKind/enrollmentStarted``, code `enrollment_started`) while this phone may
    /// hold a vault, even a provisional one whose enrollment answer was lost: its keys are kept (chosen; not in the
    /// spec). The stored device is looked at, not only an open session.
    public func forgetSetupCode() async throws {
        try await guarded {
            // The same: K is not replaced, whether or not a device state is stored yet (``dropSession(forget:vaultGone:registrationOnly:)``).
            // K is replaced only when nothing is stored: a record that cannot be read, with a device state on the phone, refuses
            // (``storedSession()`` throws), as the rule does when the record says so.
            if (try? prepared()) != nil, record.value.couldNotTell != nil { throw VaultFailure(.other, code: Self.codeRecoveryOpenSent) }
            if try await storedSession() != nil {
                try await dropSession(forget: true)
            } else {
                // The redeem bound the app key to that vault (§11.12.2): the next setup gets a new one.
                _ = try config.keys.appKeys.regenerate()
            }
            try resetRecord(LocalAccount())
        }
        phase = .signedOut
    }

    public func forgetMissingVault() async throws {
        // Only a phone that holds a vault which the API, asked again now, explicitly says is gone.
        let gone = try await guarded {
            let d = try await openSession().device
            guard d.deviceID != nil, !d.recovering else { return false }
            return try await vaultStatus() == nil
        }
        guard gone else {
            try await refresh()
            return
        }
        try await guarded {
            try await dropSession(forget: true, vaultGone: true)
            try resetRecord(LocalAccount())
        }
        phase = .signedOut
    }
}
