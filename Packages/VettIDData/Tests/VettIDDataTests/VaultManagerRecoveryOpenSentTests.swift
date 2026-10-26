import Foundation
import Testing
import VettIDAltChan
import VettIDCrypto
@testable import VettIDData
import VettIDDataTesting
@testable import VettIDVault

/// An open that may have succeeded is never registered over or abandoned; a register that may have been taken keeps its
/// marks (continues ``VaultManagerRecoveryTests``).
extension VaultManagerRecoveryTests {
    // MARK: - An open that may have succeeded is never registered over or abandoned

    /// The open's answer was lost: the vault may hold this phone's secret, so a new registration (which a refusal would answer
    /// by dropping the key) is refused before anything is claimed, and the resume still works.
    @Test func registeringAgainAfterALostOkIsRefusedAndKeepsTheKey() async throws {
        defer { phone.close() }
        let made = try await registered()
        service.recoveryOpenAnswers(.answerLost)
        _ = await vaultFailure { _ = try await m.recoveryOpen(pin: pin, password: password) }
        let claims = service.recoveryClaims.count
        let f = await vaultFailure { _ = try await m.registerRecovery(try scanned(made)) }
        #expect(f?.code == VaultManager.codeRecoveryOpenSent && service.recoveryClaims.count == claims)
        let t = await vaultFailure { _ = try await m.registerTypedRecovery(try typed(made)) }
        #expect(t?.code == VaultManager.codeRecoveryOpenSent && service.recoveryClaims.count == claims)
        #expect(device?.recovering == true && pendingRecord && m.record.value.recoveryOpenUnanswered)
        #expect(try await m.resumeLostOk(pin: pin).ok)
    }

    /// After a lost ok, another open is answered `no_recovery`, which is the lost-ok signal: the mark stays, so neither a start
    /// over nor a new registration gets through, and the key stays.
    @Test func aNoRecoveryAfterALostOkKeepsTheMark() async throws {
        defer { phone.close() }
        let made = try await registered()
        service.recoveryOpenAnswers(.answerLost)
        _ = await vaultFailure { _ = try await m.recoveryOpen(pin: pin, password: password) }
        let again = try await m.recoveryOpen(pin: pin, password: password)
        #expect(again.code == "no_recovery" && again.afterUnanswered && m.record.value.recoveryOpenUnanswered)
        let a = await vaultFailure { try await m.abandonRecovery() }
        #expect(a?.code == VaultManager.codeRecoveryOpenSent && pendingRecord && m.phase != .signedOut)
        let r = await vaultFailure { _ = try await m.registerRecovery(try scanned(made)) }
        #expect(r?.code == VaultManager.codeRecoveryOpenSent && pendingRecord)
        #expect(try await m.resumeLostOk(pin: pin).ok && !m.record.value.recoveryOpenUnanswered)
    }

    /// The open's answer was lost and the vault did not complete. The member API refuses the recovering key's unlock `403` while
    /// the recovery is active (the open can be tried again). Once the recovery ended it answers a bare `401`, which it also
    /// answers for other causes: it decides nothing (MEMBER-API "Recovering key"), so the mark and the key stay.
    @Test func aRefusalToTheRecoveringKeyDecidesNothingAndKeepsTheMark() async throws {
        defer { phone.close() }
        let made = try await registered()
        service.recoveryOpenAnswers(.unreadable)
        _ = await vaultFailure { _ = try await m.recoveryOpen(pin: "111111", password: password) }
        #expect(m.record.value.recoveryOpenUnanswered)
        // Active: the unlock is refused `403`.
        let active = try await m.resumeLostOk(pin: pin)
        #expect(active == RecoveryOpenOutcome(VaultManager.codeNoBundle, opened: true, attemptUsed: false))
        #expect(m.record.value.recoveryOpenUnanswered)
        service.cancelRecoveryAtApi()
        // Every new open is `no_recovery` and keeps the mark.
        #expect(try await m.recoveryOpen(pin: pin, password: password).code == "no_recovery" && m.record.value.recoveryOpenUnanswered)
        // `401` to the unlock and to the status: undecided, the mark and the key kept.
        _ = await vaultFailure { _ = try await m.resumeLostOk(pin: pin) }
        #expect(m.record.value.recoveryOpenUnanswered)
        let a = await vaultFailure { try await m.abandonRecovery() }
        #expect(a?.code == VaultManager.codeRecoveryOpenUnknown)
        let r = await vaultFailure { _ = try await m.registerRecovery(try scanned(made)) }
        #expect(r?.code == VaultManager.codeRecoveryOpenUnknown)
        #expect(m.record.value.recoveryOpenUnanswered && pendingRecord && device?.recovering == true && m.phase != .signedOut)
    }

    /// The start over and a new registration ask the member API themselves.
    @Test func theMemberApiDecidesAStartOverAndANewRegistration() async throws {
        defer { phone.close() }
        let made = try await registered()
        service.recoveryOpenAnswers(.unreadable)
        _ = await vaultFailure { _ = try await m.recoveryOpen(pin: "111111", password: password) }
        // Still registered, this phone not the app: the open can be tried again.
        #expect(await vaultFailure { try await m.abandonRecovery() }?.code == VaultManager.codeRecoveryOpenPending)
        #expect(await vaultFailure { _ = try await m.registerRecovery(try scanned(made)) }?.code == VaultManager.codeRecoveryOpenPending)
        // The service cannot say: try again, nothing cleared.
        service.status("unlocked", noVault: true)
        #expect(await vaultFailure { try await m.abandonRecovery() }?.code == VaultManager.codeRecoveryOpenUnknown)
        #expect(m.record.value.recoveryOpenUnanswered && pendingRecord)
        service.status("unlocked")
        // A `401` (the recovery ended, or any other cause) decides nothing.
        service.cancelRecoveryAtApi()
        #expect(await vaultFailure { try await m.abandonRecovery() }?.code == VaultManager.codeRecoveryOpenUnknown)
        #expect(m.record.value.recoveryOpenUnanswered && pendingRecord && m.phase != .signedOut)
    }

    /// The mark goes only when the history of the opens leaves none unanswered (IOS-PLAN 0.1.38 §4.10): the answers that prove no
    /// step 1 was stored on their own clear it for a first open; `wrong` and `expired` only with no earlier unanswered open; the
    /// rest (`retry`, `not_armed`, `stored_mismatch`, a code decided before the record is read, …) never do.
    @Test func onlyAnswersThatProveNoStepOneWasStoredClearTheMark() async throws {
        phone.close()
        func clears(_ code: String, earlierUnanswered: Bool) async throws -> Bool {
            let s = try FakeVaultService()
            let p = try TestVaultPhone(service: s, requestTimeout: TestVaultPhone.shortRequestTimeout)
            defer { p.close() }
            let made = try s.armRecovery(pin: pin, password: password)
            _ = try await p.manager.registerRecovery(try scanned(made))
            if earlierUnanswered {
                s.recoveryOpenAnswers(.unreadable)
                _ = await vaultFailure { _ = try await p.manager.recoveryOpen(pin: "111111", password: password) }
            }
            s.recoveryOpenAnswers(.refused(code))
            _ = try await p.manager.recoveryOpen(pin: pin, password: password)
            return !p.manager.record.value.recoveryOpenUnanswered
        }
        // IOS-PLAN 0.1.38 §4.10: `exhausted` and `not_armed` prove it too, and an `attestation` that used no attempt (owner decision
        // of 2026-10-26).
        for code in ["busy", "counter_unavailable", "wait", "quiet", "wrong", "expired", "exhausted", "not_armed", "attestation"] {
            let first = try await clears(code, earlierUnanswered: false)
            #expect(first, "\(code) clears the mark of a first open")
        }
        for code in ["retry", "stored_mismatch", "manifest", "wrong_release", "bad_request", "no_recovery"] {
            let none = try await clears(code, earlierUnanswered: false)
            #expect(!none, "\(code) proves nothing")
        }
        for code in ["wrong", "expired", "retry", "not_armed", "busy", "wrong_again"] {
            let after = try await clears(code, earlierUnanswered: true)
            #expect(!after, "\(code) after an unanswered open leaves the mark")
        }
    }

    /// A register of another recovery would overwrite the registration of one whose register may have been taken.
    @Test func aSecondRegisterForAnotherRecoveryAsksForAStartOverFirst() async throws {
        defer { phone.close() }
        let first = try armed()
        service.recoveryRegisterAnswers(.answerLostAfterRegistering)
        _ = await vaultFailure { _ = try await m.registerRecovery(try scanned(first)) }
        #expect(device?.recoveryID == first.recoveryID && m.record.value.recoveryRegistered)
        let second = try armed()
        let claims = service.recoveryClaims.count
        let f = await vaultFailure { _ = try await m.registerRecovery(try scanned(second)) }
        // Known from the scanned code: refused before the claim, which would use one of the API's claim keys.
        #expect(service.recoveryClaims.count == claims)
        #expect(f?.code == VaultManager.codeRecoveryRegistered && device?.recoveryID == first.recoveryID)
        #expect(m.record.value.vaultID == first.vaultID)
        // The same recovery again is a retry.
        #expect(device?.recovering == true)
        try await m.abandonRecovery()
        #expect(try await m.registerRecovery(try scanned(second)) == .registered(emailHint: service.emailHint))
    }

    @Test func registeringAgainAfterAnAnsweredOpenIsRefusedToo() async throws {
        defer { phone.close() }
        let made = try await registered()
        _ = try await m.recoveryOpen(pin: "111111", password: password)
        let f = await vaultFailure { _ = try await m.registerRecovery(try scanned(made)) }
        #expect(f?.code == VaultManager.codeRecoveryOpenSent && device?.recovering == true && pendingRecord)
    }

    /// A second registration reuses the first one's record; its refusal must not delete a record it did not make.
    @Test func aRefusedRegisterDropsOnlyTheRecordItMade() async throws {
        defer { phone.close() }
        let made = try await registered()
        let key = try m.phoneSecrets.records().pendings.map(\.keyID)
        service.recoveryRegisterAnswers(.refused("no_recovery"))
        #expect(try await m.registerRecovery(try scanned(made)) == .refused(code: "no_recovery"))
        #expect(try m.phoneSecrets.records().pendings.map(\.keyID) == key && key.count == 1)
    }

    /// A register whose answer never came may have bound the key: the start-over gate and the record say so before it is sent.
    @Test func aRegisterThatGotNoAnswerStillMarksTheAttestKey() async throws {
        defer { phone.close() }
        let code = try scanned(try armed())
        service.recoveryRegisterAnswers(.offline)
        _ = await vaultFailure { _ = try await m.registerRecovery(code) }
        #expect(m.record.value.recoveryRegistered && !m.record.value.noVaultHoldsAttestKey && !phone.attestStartOver.value)
        // A retry cannot tell the first request did not reach the vault: its refusal takes nothing back.
        service.recoveryRegisterAnswers(.refused("used"))
        #expect(try await m.registerRecovery(code) == .refused(code: "used"))
        #expect(m.record.value.recoveryRegistered && !phone.attestStartOver.value)
    }

    /// A register whose answer was lost may have bound the key: the retry is answered `used` because it did. The marks, the
    /// registration and the record stay.
    @Test func aRefusalAfterALostRegisterKeepsTheMarksAndTheRegistration() async throws {
        defer { phone.close() }
        let code = try scanned(try armed())
        service.recoveryRegisterAnswers(.answerLostAfterRegistering)
        _ = await vaultFailure { _ = try await m.registerRecovery(code) }
        #expect(service.recoveryRegisters.count == 1 && m.record.value.recoveryRegistered && pendingRecord)
        service.recoveryRegisterAnswers(.refused("used"))
        #expect(try await m.registerRecovery(code) == .refused(code: "used"))
        #expect(m.record.value.recoveryRegistered && !phone.attestStartOver.value && pendingRecord && device?.recovering == true)
    }

    @Test func startingOverIsRefusedWhateverTheRecordsSay() async throws {
        defer { phone.close() }
        _ = try await registered()
        service.loseAnswers(["credential.get"])
        _ = await vaultFailure { _ = try await m.recoveryOpen(pin: pin, password: password) }
        // The phone's records cannot be read now: a pinned vault is still not abandoned.
        phone.protectedData.set(false)
        let f = await vaultFailure { try await m.abandonRecovery() }
        phone.protectedData.set(true)
        #expect(f?.code == MoveCodes.recoveryOpened && device?.hasVault == true && device?.recovering == true)
        #expect(m.phase != .signedOut && hasCurrentRecord)
    }

    @Test func startingOverIsRefusedWhileAnOpenGotNoAnswer() async throws {
        defer { phone.close() }
        _ = try await registered()
        service.recoveryOpenAnswers(.answerLost)
        _ = await vaultFailure { _ = try await m.recoveryOpen(pin: pin, password: password) }
        let f = await vaultFailure { try await m.abandonRecovery() }
        #expect(f?.code == VaultManager.codeRecoveryOpenSent && device?.recovering == true && pendingRecord)
    }

    /// The pending epoch-1 record of the vault the phone recovered becomes current when an earlier run did not get to it.
    @Test func theRecoveredSecretIsMadeCurrentAfterwards() async throws {
        defer { phone.close() }
        _ = try await registered()
        #expect(pendingRecord && !hasCurrentRecord)
        m.confirmRecoveredSecret()
        #expect(!pendingRecord && hasCurrentRecord && m.usesPhoneSecret)
        // Nothing pending: nothing changes.
        m.confirmRecoveredSecret()
        #expect(hasCurrentRecord)
    }

    /// A wipe or a reset during the handshake drops what follows: `enrollConfirmed` never lands in the fresh record.
    @Test func aResetDuringTheHandshakeIsNotWrittenOver() async throws {
        defer { phone.close() }
        _ = try await registered()
        service.holdMessages = true
        let open = Task { try await m.recoveryOpen(pin: pin, password: password) }
        #expect(await eventually { !service.recoveryHandshakeContexts.isEmpty })
        m.record.bumpGeneration()
        service.holdMessages = false
        _ = try? await open.value
        #expect(!m.record.value.enrollConfirmed)
    }
}
