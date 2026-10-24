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

    /// The resume finds the vault does not hold this phone's secret: nothing was adopted, the mark goes, a start over works.
    @Test func aResumeThatFindsNothingAdoptedClearsTheMark() async throws {
        defer { phone.close() }
        _ = try await registered()
        service.recoveryOpenAnswers(.unreadable)
        _ = await vaultFailure { _ = try await m.recoveryOpen(pin: "111111", password: password) }
        #expect(m.record.value.recoveryOpenUnanswered)
        #expect(try await m.resumeLostOk(pin: pin).code == "device_secret")
        #expect(!m.record.value.recoveryOpenUnanswered)
        try await m.abandonRecovery()
        #expect(m.phase == .signedOut)
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
