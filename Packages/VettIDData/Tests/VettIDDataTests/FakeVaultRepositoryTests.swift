import Foundation
import Observation
import Testing
import VettIDAltChan
import VettIDData
import VettIDDataTesting

/// The repository-level fake behaves as the view-model tests expect (vettid-android `FakeVault`): calls are recorded,
/// failures scripted once, outcomes queued, and the phase follows what a real repository would do.
@MainActor
@Suite struct FakeVaultRepositoryTests {
    @Test func callsAreRecordedAndTheSetupMovesThePhase() async throws {
        let v = FakeVaultRepository()
        #expect(v.phase == .signedOut)
        #expect(try await v.redeemSetupCode(.secret("s")) == "m***@example.com")
        #expect(v.phase == .setup(.newVault) && v.account == AccountInfo(emailHint: "m***@example.com"))
        var steps: [EnrollStep] = []
        try await v.enroll(pin: "402817") { steps.append($0) }
        try await v.createCredential(password: "pw", backup: true, pin: "402817") { steps.append($0) }
        #expect(steps == EnrollStep.allCases)
        #expect(v.phase == .setup(.finishing) && v.lastPin == "402817" && v.lastPassword == "pw" && v.lastBackup == true)
        #expect(v.lastCredentialPin == nil, "a vault without a phone secret gets no PIN")
        try await v.finishSetup()
        #expect(v.phase == .unlocked)
        #expect(v.calls == ["redeemSetupCode", "enroll", "createCredential", "finishSetup"])
    }

    @Test func aScriptedFailureIsThrownOnce() async throws {
        let v = FakeVaultRepository(.locked)
        v.fail["unlock"] = FakeVaultRepository.failure(.network)
        await #expect(throws: VaultFailure.self) { try await v.unlock(pin: "1") }
        #expect(v.phase == .locked)
        #expect(try await v.unlock(pin: "1") == .success)
        #expect(v.phase == .unlocked)
        #expect(v.calls == ["unlock", "unlock"])
    }

    @Test func unlockOutcomesAreQueued() async throws {
        let v = FakeVaultRepository(.locked)
        v.refusedByVault = true
        v.unlockResults = [.failed(.network, code: nil), .badPin(retryAfterSeconds: 0)]
        #expect(try await v.unlock(pin: "1") == .failed(.network, code: nil))
        #expect(v.refusedByVault, "not a sealed answer")
        #expect(try await v.unlock(pin: "2") == .badPin(retryAfterSeconds: 0))
        #expect(!v.refusedByVault && v.phase == .locked)
        #expect(try await v.finishMove(pin: "3") == .success)
        #expect(v.phase == .unlocked && v.calls.suffix(2) == ["lock", "unlock"])
    }

    @Test func thePhaseIsObservable() async throws {
        let v = FakeVaultRepository(.locked)
        let changed = Changed()
        withObservationTracking { _ = v.phase } onChange: { changed.fire() }
        try await v.forgetSetupCode()
        #expect(changed.fired)
    }

    @Test func aTypedRecoveryRefusalNamesTheClaimedRecovery() async throws {
        let v = FakeVaultRepository()
        let typed = try #require(Self.typedCode())
        v.registrations = [.refused(code: "bad_code"), .refused(code: "no_recovery"), .registered(emailHint: "s***@example.org")]
        #expect(try await v.registerTypedRecovery(typed) == .refused(code: "bad_code", recoveryID: "01JA0RECVERY0000000000001X"))
        #expect(try await v.registerTypedRecovery(typed) == .refused(code: "no_recovery"))
        #expect(v.phase == .signedOut)
        #expect(try await v.registerTypedRecovery(typed) == .registered(emailHint: "s***@example.org"))
        #expect(v.phase == .setup(.recovering) && v.lastTyped == typed)
    }

    @Test func aTransferWaitsForTheTest() async throws {
        let v = FakeVaultRepository()
        #expect(try await v.transferIn(code: "link") == "042817")
        let waiting = Task { try await v.awaitTransferIn() }
        await Task.yield()
        #expect(v.phase == .signedOut)
        v.transferApproval.complete()
        #expect(try await waiting.value)
        #expect(v.phase == .setup(.finishing))
    }

    @Test func anApprovalWithoutTheRequiredSignerIsRefused() async throws {
        let v = FakeVaultRepository(.unlocked)
        v.transferSignerRequired = "google_play"
        await #expect(throws: VaultFailure.self) { try await v.transferApprove(transferID: "t", pin: "1", password: "p") }
        #expect(v.phase == .unlocked)
        #expect(try await v.transferApprove(transferID: "t", pin: "1", password: "p", signer: "google_play"))
        #expect(v.transferSigners == [nil, "google_play"] && v.phase == .signedOut)
    }

    @Test func aCancelledWaitEnds() async throws {
        let v = FakeVaultRepository()
        let waiting = Task { try await v.awaitTransferIn() }
        await Task.yield()
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
        // Cancelled before it began to wait.
        let early = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await v.pendingTransfer.value()
        }
        await #expect(throws: CancellationError.self) { try await early.value }
        #expect(!v.pendingTransfer.isCompleted)
        // A completion afterwards resumes nothing twice.
        v.transferApproval.complete()
        #expect(try await v.awaitTransferIn())
    }

    @Test func theFakeCarriesTheTestOnlyMarker() {
        #expect(FakeVaultRepository.testOnlyMarker.hasPrefix("VETTID TEST ONLY"))
        #expect("\(FakeVaultRepository())" == FakeVaultRepository.testOnlyMarker)
    }

    @Test func theFixtures() {
        let r = FakeVaultRepository.release(3)
        #expect(r.pcr0 == String(repeating: "03", count: 48) && r.fingerprint == "0303 0303 0303 0303")
        #expect(FakeVaultRepository.release(123).pcr0.hasPrefix("123123"))
        #expect(FakeVaultRepository.failure(.backoff, retry: 30).retryAfterSeconds == 30)
    }

    /// A typed code whose check matches the production origin (VAULT-MESSAGING §16, TEST ONLY).
    private static func typedCode() -> TypedRecoveryCode? {
        let typed = "7ZK3M9QX2HTDCDEFGHJKMNPQRSTVWXYZ0123456789ABV3A1"
        if case .ok(let c) = TypedRecoveryCode.parse(typed, api: "https://account.vettid.org") { return c }
        return nil
    }
}

/// Set from Observation's change callback, which may run on another thread.
final class Changed: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var fired: Bool { lock.withLock { value } }
    func fire() { lock.withLock { value = true } }
}
