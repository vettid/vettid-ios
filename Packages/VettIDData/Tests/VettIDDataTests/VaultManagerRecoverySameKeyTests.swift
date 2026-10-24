import Foundation
import Testing
import VettIDAltChan
import VettIDCrypto
@testable import VettIDData
import VettIDDataTesting
@testable import VettIDVault

/// A new recovery code for the same vault while the verdict on an unanswered open is undecided (owner decision 2026-10-24; spec
/// text to follow): registered with the pending key the open carried, nothing deleted, the mark kept (continues
/// ``VaultManagerRecoveryTests``).
extension VaultManagerRecoveryTests {
    /// An open went out and its answer was lost; the member API answers the recovering key `401`: undecided.
    private func lostOpenThenUndecided(pin openPin: String = "111111") async throws -> FakeVaultService.RecoveryCodeMade {
        let made = try await registered()
        service.recoveryOpenAnswers(.unreadable)
        _ = await vaultFailure { _ = try await m.recoveryOpen(pin: openPin, password: password) }
        service.statusUnauthorized = true
        #expect(m.record.value.recoveryOpenUnanswered)
        return made
    }

    @Test func aNewCodeForTheSameVaultRegistersWithTheSamePendingKey() async throws {
        defer { phone.close() }
        let first = try await lostOpenThenUndecided()
        let pendings = try m.phoneSecrets.records().pendings.map(\.keyID)
        let firstSecret = try #require(service.recoveryOpens.last?.unlockSecret)
        let firstRegister = try #require(service.recoveryRegisters.last)

        let second = try armed()
        #expect(second.vaultID == first.vaultID && second.recoveryID != first.recoveryID)
        // A start over stays refused, whichever way the registration goes.
        #expect(await vaultFailure { try await m.abandonRecovery() }?.code == VaultManager.codeRecoveryOpenUnknown)
        #expect(try await m.registerRecovery(try scanned(second)) == .registered(emailHint: service.emailHint))

        // Nothing deleted: the same pending record and key, the same app key in the register (the attestation is a new one, as
        // for any register).
        #expect(try m.phoneSecrets.records().pendings.map(\.keyID) == pendings && !hasCurrentRecord)
        let register = try #require(service.recoveryRegisters.last)
        #expect(service.recoveryRegisters.count == 2 && register.recoveryID == second.recoveryID)
        #expect(register.apiKey == firstRegister.apiKey)
        #expect(device?.recoveryID == second.recoveryID && device?.recovering == true)
        // The mark is kept for the new record until the new open's answer.
        #expect(m.record.value.recoveryOpenUnanswered && m.record.value.recoveryRegistered && m.record.value.vaultID == second.vaultID)
        #expect(m.record.value.recoveryAttemptsUsed == nil)

        // The new open carries the same secret and its answer clears the mark.
        let outcome = try await m.recoveryOpen(pin: pin, password: password)
        #expect(outcome.ok)
        #expect(service.recoveryOpens.last?.unlockSecret == firstSecret && service.recoveryOpens.last?.recoveryID == second.recoveryID)
        #expect(!m.record.value.recoveryOpenUnanswered && hasCurrentRecord && !pendingRecord)
        // The first handshake names the recovery whose open was answered.
        #expect(service.recoveryHandshakeContexts.last == second.recoveryID)
    }

    @Test func aTypedCodeForTheSameVaultRegistersToo() async throws {
        defer { phone.close() }
        _ = try await lostOpenThenUndecided()
        let pendings = try m.phoneSecrets.records().pendings.map(\.keyID)
        let second = try armed()
        #expect(try await m.registerTypedRecovery(try typed(second)) == .registered(emailHint: service.emailHint))
        #expect(try m.phoneSecrets.records().pendings.map(\.keyID) == pendings && m.record.value.recoveryOpenUnanswered)
        #expect(device?.recoveryID == second.recoveryID)
    }

    @Test func aCodeAfterACountedAttemptRegistersToo() async throws {
        defer { phone.close() }
        let made = try await registered()
        #expect(try await m.recoveryOpen(pin: "111111", password: password).code == "wrong")
        #expect(m.record.value.recoveryAttemptsUsed != nil)
        service.recoveryOpenAnswers(.unreadable)
        _ = await vaultFailure { _ = try await m.recoveryOpen(pin: "222222", password: password) }
        service.statusUnauthorized = true
        let second = try armed()
        #expect(second.vaultID == made.vaultID)
        #expect(try await m.registerRecovery(try scanned(second)) == .registered(emailHint: service.emailHint))
        #expect(m.record.value.recoveryOpenUnanswered)
    }

    @Test func aCodeForAnotherVaultIsStillRefused() async throws {
        defer { phone.close() }
        let first = try await lostOpenThenUndecided()
        let other = RecoveryCode(vaultID: "other-" + first.vaultID, recoveryID: first.recoveryID + "x", code: first.code, api: nil)
        let claims = service.recoveryClaims.count
        let registers = service.recoveryRegisters.count
        let r = await vaultFailure { _ = try await m.registerRecovery(other) }
        #expect(r?.code == VaultManager.codeRecoveryOpenUnknown && service.recoveryClaims.count == claims)
        #expect(service.recoveryRegisters.count == registers && m.record.value.vaultID == first.vaultID)
        #expect(m.record.value.recoveryOpenUnanswered && pendingRecord && device?.recoveryID == first.recoveryID)
    }

    @Test func theStillRegisteredVerdictIsUnchanged() async throws {
        defer { phone.close() }
        // Still registered: the open can be tried again; no new registration.
        let made = try await registered()
        service.recoveryOpenAnswers(.unreadable)
        _ = await vaultFailure { _ = try await m.recoveryOpen(pin: "111111", password: password) }
        #expect(await vaultFailure { _ = try await m.registerRecovery(try scanned(made)) }?.code == VaultManager.codeRecoveryOpenPending)
        #expect(await vaultFailure { try await m.abandonRecovery() }?.code == VaultManager.codeRecoveryOpenPending)
        #expect(device?.recoveryID == made.recoveryID && pendingRecord && m.record.value.recoveryOpenUnanswered)
    }

    @Test func anAdoptedVerdictIsStillRefusedAndTheResumeWorks() async throws {
        defer { phone.close() }
        let made = try await registered()
        service.recoveryOpenAnswers(.answerLost)
        _ = await vaultFailure { _ = try await m.recoveryOpen(pin: pin, password: password) }
        #expect(await vaultFailure { _ = try await m.registerRecovery(try scanned(made)) }?.code == VaultManager.codeRecoveryOpenSent)
        #expect(m.record.value.recoveryOpenUnanswered && pendingRecord)
        #expect(try await m.resumeLostOk(pin: pin).ok)
    }

    /// The new registration is refused: it made no record, so it drops nothing, and the old open stays marked.
    @Test func aRefusedNewRegisterDropsNothing() async throws {
        defer { phone.close() }
        let first = try await lostOpenThenUndecided()
        let pendings = try m.phoneSecrets.records().pendings.map(\.keyID)
        let second = try armed()
        service.recoveryRegisterAnswers(.refused("used"))
        #expect(try await m.registerRecovery(try scanned(second)) == .refused(code: "used"))
        #expect(try m.phoneSecrets.records().pendings.map(\.keyID) == pendings)
        #expect(m.record.value.recoveryOpenUnanswered && m.record.value.recoveryRegistered && device?.recovering == true)
        // The earlier recovery is the registered one again.
        #expect(device?.recoveryID == first.recoveryID)
        #expect(await vaultFailure { try await m.abandonRecovery() }?.code == VaultManager.codeRecoveryOpenUnknown)
    }

    /// The old open was in fact adopted, the status is undecided and the new code is refused by the API: the key and the mark
    /// stay, and the lost-ok resume works with the same key.
    @Test func theResumeStillWorksWhenTheNewCodeIsRefused() async throws {
        defer { phone.close() }
        let made = try await registered()
        service.recoveryOpenAnswers(.answerLost)
        _ = await vaultFailure { _ = try await m.recoveryOpen(pin: pin, password: password) }
        service.statusUnauthorized = true
        #expect(try await m.registerRecovery(try scanned(made)) == .refused(code: VaultManager.codeNoRecovery))
        #expect(m.record.value.recoveryOpenUnanswered && pendingRecord)
        #expect(try await m.resumeLostOk(pin: pin).ok && !m.record.value.recoveryOpenUnanswered)
    }

    /// The old open was in fact adopted (its `ok` lost) and the status is undecided. A new code is refused at the vault: the
    /// earlier recovery is registered again and the lost-ok resume names its id in the first handshake, under which the vault
    /// made the invitation.
    @Test func theResumeAfterARefusedNewRegisterUsesTheEarlierRecoveryID() async throws {
        defer { phone.close() }
        let first = try await registered()
        service.recoveryOpenAnswers(.answerLost)
        _ = await vaultFailure { _ = try await m.recoveryOpen(pin: pin, password: password) }
        service.statusUnauthorized = true
        let second = try armed()
        service.recoveryRegisterAnswers(.refused("used"))
        #expect(try await m.registerRecovery(try scanned(second)) == .refused(code: "used"))
        #expect(device?.recoveryID == first.recoveryID && m.record.value.recoveryOpenUnanswered && m.record.value.recoveryRegistered)
        let out = try await m.resumeLostOk(pin: pin)
        #expect(out.ok && service.recoveryHandshakeContexts.last == first.recoveryID)
        #expect(!m.record.value.recoveryOpenUnanswered)
    }

    /// The new register succeeded and the member takes the lost-ok finish before any new open: the handshake still names the
    /// earlier recovery, and the registered one is kept until a new open is answered.
    @Test func theResumeAfterASuccessfulNewRegisterUsesTheEarlierRecoveryID() async throws {
        defer { phone.close() }
        let first = try await registered()
        service.recoveryOpenAnswers(.answerLost)
        _ = await vaultFailure { _ = try await m.recoveryOpen(pin: pin, password: password) }
        service.statusUnauthorized = true
        let second = try armed()
        #expect(try await m.registerRecovery(try scanned(second)) == .registered(emailHint: service.emailHint))
        #expect(device?.recoveryID == second.recoveryID)
        let out = try await m.resumeLostOk(pin: pin)
        #expect(out.ok && service.recoveryHandshakeContexts.last == first.recoveryID)
    }

    /// A 200 to the status read by the recovering key in a state besides `registered` means that the key is the vault's app key.
    @Test func aStatusInAnyOtherStateIsAnAdoptedVerdict() async throws {
        defer { phone.close() }
        _ = try await registered()
        service.recoveryOpenAnswers(.unreadable)
        _ = await vaultFailure { _ = try await m.recoveryOpen(pin: "111111", password: password) }
        for state in ["pending", "available", "none", "completed"] {
            service.recoveryStatusShows(state)
            #expect(await m.openMarkVerdict() == .adopted, "\(state)")
            #expect(await vaultFailure { try await m.abandonRecovery() }?.code == VaultManager.codeRecoveryOpenSent)
        }
        service.recoveryStatusShows("registered")
        #expect(await m.openMarkVerdict() == .stillRegistered)
        service.recoveryStatusShows("something else")
        #expect(await m.openMarkVerdict() == .undecided)
    }
}
