import Foundation
import Testing
import VettIDAltChan
import VettIDAttestation
import VettIDCrypto
@testable import VettIDData
import VettIDKeys
import VettIDRelay
@testable import VettIDVault

/// The failures of the layers below as the screens get them. Mirrors vettid-android `GuardTest` and `ClockFailureTest`.
@Suite struct VaultFailuresTests {
    func kind(_ e: any Error) -> FailureKind? { (VaultFailures.map(e) as? VaultFailure)?.kind }

    func op(_ code: String, _ body: String? = nil) -> VaultOpError {
        VaultOpError(type: "vault.owner-check", code: code, detail: "", body: body.map { Array($0.utf8) })
    }

    /// A failed check of the vault's software is never the vault refusing this PHONE's attestation.
    @Test func aFailedCheckOfTheVaultsSoftwareIsNeverThePhonesAttestation() {
        #expect(kind(AttestationError.release("not listed", unknown: true)) == .releaseUnknown)
        let manifest: [AttestationError] = [
            .signature("manifest"), .format("manifest order"), .format("served manifest"), .manifestKey, .manifestSerial, .hash,
        ]
        for e in manifest { #expect(kind(e) == .manifest, "\(e)") }
        let enclave: [AttestationError] = [
            .signature("attestation"), .format("COSE_Sign1"), .format("descriptor"), .chain, .pcr("release"), .pcr("manifest"),
            .debug,
            .stale, .userData, .nonce, .release("not active"), .release("rollback"),
        ]
        for e in enclave { #expect(kind(e) == .enclave, "\(e)") }
        for e in manifest + enclave { #expect(kind(e) != .attestation) }
        #expect(VaultFailures.enrollFailure("attestation") == .attestation)
    }

    @Test func aManifestThatCouldNotBeLoadedIsNotAVerificationFailure() {
        for status in [404, 500, 503] {
            #expect(kind(MemberApiError(status: status, code: MemberApiError.manifestUnavailable)) == .manifestUnavailable)
        }
        #expect(kind(URLError(.cannotFindHost)) == .network)
        #expect(kind(URLError(.timedOut)) == .network)
    }

    /// A `401` the phone's clock explains is its own failure (A6 audit N4/N5).
    @Test func a401TheClockExplainsIsNotUnauthorized() {
        #expect(kind(MemberApiError(status: 401, code: MemberApiError.clockSkew)) == .clock)
        #expect(kind(MemberApiError(status: 401, code: MemberApiError.unauthorized)) == .unauthorized)
        #expect(FailureKind.clock.message != FailureKind.unauthorized.message)
    }

    /// The setup screens' failures (§11.12.1, MEMBER-API 1.2.0).
    @Test func theSetupCodesFailures() {
        #expect(kind(MemberApiError(status: 404, code: MemberApiError.invalidCode)) == .setupCodeInvalid)
        #expect(kind(MemberApiError(status: 503, code: MemberApiError.vaultUnavailable, service: "paused")) == .servicePaused)
        #expect(kind(MemberApiError(status: 503, code: MemberApiError.vaultUnavailable)) == .vaultUnavailable)
        #expect(kind(MemberApiError(status: 503, code: MemberApiError.releaseStarting)) == .vaultUnavailable)
        #expect(kind(RelayError(status: 0, code: "transport", message: "")) == .network)
        #expect(VaultFailures.enrollFailure("vault_exists") == .vaultExists)
        #expect(VaultFailures.enrollFailure("release_key") == .manifest && VaultFailures.enrollFailure(nil) == .other)
    }

    /// The keys (IOS-PLAN §6.3): a locked iPhone is never a loss; no secure hardware refuses; the rest is this phone's
    /// stored state.
    @Test func theKeysFailures() {
        #expect(kind(KeysError.unavailable("phone key")) == .phoneLocked)
        #expect(kind(KeysError.noSecureHardware) == .hardwareKeys)
        #expect(kind(AppAttestError.appleUnreachable) == .appleUnreachable)
        #expect(FailureKind.appleUnreachable.message.hasPrefix("VettID couldn't reach Apple to confirm"))
        let a = VaultFailures.map(AppAttestError.failed(7)) as? VaultFailure
        #expect(a?.kind == .other && a?.code == "app_attest")
        let gone = VaultFailures.map(AppAttestError.keyGone) as? VaultFailure
        #expect(gone?.kind == .deviceSecret && gone?.code == "app_attest_key_gone")
        #expect(kind(AppAttestError.pendingFull) == .retry, "temporary: the next request frees the slots")
        let f = VaultFailures.map(KeysError.corrupt("account record")) as? VaultFailure
        #expect(f?.kind == .other && f?.code == VaultFailures.codeKeystore)
        #expect(VaultFailures.map(CancellationError()) is CancellationError)
        #expect(kind(VaultStateError(message: "no vault.enrolled within 90 s")) == .noResponse)
        #expect(kind(VaultStateError(message: "credential.create: no response")) == .noResponse)
        #expect(kind(VaultStateError(message: "not paired with a vault")) == .other)
        #expect(kind(PairingRejected()) == .rejected)
    }

    /// The vault's error codes, with a backoff's `retry_after` and a limit's name (§10.1).
    @Test func theVaultsErrorsCarryTheirBodies() throws {
        let weak = try #require(VaultFailures.map(op("weak_password", #"{"reason":"common"}"#)) as? VaultFailure)
        #expect(weak.kind == .weakPassword && weak.weakPasswordReason == "common")
        #expect((VaultFailures.map(op("backoff", #"{"retry_after":42}"#)) as? VaultFailure)?.retryAfterSeconds == 42)
        #expect((VaultFailures.map(op("backoff", #"{"retry_after":"30"}"#)) as? VaultFailure)?.retryAfterSeconds == 0)
        #expect((VaultFailures.map(op("backoff", #"{"retry_after":-1}"#)) as? VaultFailure)?.retryAfterSeconds == 0)
        #expect((VaultFailures.map(op("backoff")) as? VaultFailure)?.retryAfterSeconds == 0)
        let limit = (VaultFailures.map(op("limit", #"{"limit":"items","max":500}"#)) as? VaultFailure)?.limit
        #expect(limit == VaultLimit("items", max: 500))
        #expect(kind(op("exists")) == .other && kind(op("device_secret")) == .deviceSecret)
    }

    /// IOS-PLAN ID8: only release R; recovery offered as §11.10.9 says.
    @Test func onlyReleaseR() throws {
        #expect(throws: VaultFailure.self) { try ReleasePath.requireR([]) }
        #expect(throws: VaultFailure.self) { try ReleasePath.requireR(["recovery_offered"]) }
        try ReleasePath.requireR(["recovery_r"])
        #expect(ReleasePath.recoveryOffered(["recovery_offered", "recovery_r"]) && !ReleasePath.recoveryOffered(["recovery_r"]))
        #expect(FailureKind.releaseTooOld.message.contains("too old for the iPhone app"))
    }
}
