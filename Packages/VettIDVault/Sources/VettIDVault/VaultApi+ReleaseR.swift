import Foundation
import VettIDCrypto

// Release R (VAULT-MESSAGING §11.14.9): the changes of PIN and phone secret, holder credential operations, and the
// decision of a change whose answer was lost ("A lost answer"). Mirrors vettid-android `ReleaseRApi.kt`.
extension VaultApi {
    /// `device.transfer.approve` (§6.7.1 step 3) with the blob and, sealed to a UTK, the PIN and the password. `{}` (before
    /// release R) means the transfer is complete: this app has been removed; release R answers `{"unlink":
    /// "after_new_unlock"}` (``TransferApproved``). [signer] (0.27.0): the new app's signer class, the holder's explicit
    /// confirmation, sent when the pending said `signer_changed`; nil sends no member. Without it the vault answers
    /// `signer_unconfirmed` before it tries the PIN, and the transfer stays open; (0.52.0) the UTK is spent all the same,
    /// and the next approval takes a fresh one. Mirrors vettid-android `VaultApi.transferApprove`.
    public func transferApprove(
        transferID: String, pin: String, password: String, signer: String? = nil
    ) async throws -> TransferApproved {
        var options = CredOpOptions()
        options.outer = [("transfer_id", transferID)] + (signer.map { [("signer", $0)] } ?? [])
        // VAULT-MESSAGING §11.14.10 (0.56.1): before each approval it sends (the first, and after `busy`, `retry` and
        // `stale_credential`) the old app renews the standing token it issued to the vault, and waits for the relay's `201`
        // before it deposits the approval. If the renewal fails the approval is sent all the same, and the vault keeps the
        // previous token.
        let device = device
        options.beforeSend = { _ = try? await device.renewStandingToken() }
        let body = try await credential.credOp(
            Self.typeTransferApprove, [.string("password", password), .string("pin", pin)], options
        )
        return TransferApproved.of(VaultJSON.object(body))
    }

    public static let typeTransferApprove = "device.transfer.approve"

    /// After a direct transfer (§6.7.1 step 5): fetches the blob the vault kept (`credential.get`), confirms it
    /// (`credential.ack`) and fills the UTK pool (`credential.utk.get`). Mirrors vettid-android
    /// `VaultApi.credentialTakeOver`.
    public func credentialTakeOver() async throws {
        try await credential.fetch()
        try await topUpUTKs()
    }

    /// `pin.change`: the current PIN, the new one, the password and the phone's next epoch's secret, sealed to one UTK,
    /// with the blob (``CredentialOps/change(_:_:onMarker:)``): once the request is fixed, [onMarker] stores its marker
    /// and candidate and returns the next secret (wiped here once sealed). Returns the answer's `epoch_advanced`: only
    /// `true` lets the phone move to the next epoch (§11.14.1); anything else leaves the next epoch's record a candidate,
    /// for an unlock to decide. No answer is ``ChangeUnanswered``; `stale_credential` is not retried. [since]:
    /// ``VaultDevice/secretsSent`` as the caller read it before its own checks (nil: read here).
    public func pinChange(
        pin: String, newPin: String, password: String, since: Int? = nil,
        onMarker: @escaping @Sendable (ChangeRequest) async throws -> [UInt8]
    ) async throws -> Bool {
        let fields: [SealedField] = [.string("pin", pin), .string("new_pin", newPin), .string("password", password)]
        let body = try await credential.change(Self.typePinChange, fields, since: since, onMarker: Self.withSecret(onMarker))
        return Self.epochAdvanced(body)
    }

    /// `vault.secret.renew`: a new phone secret with the PIN unchanged (§11.14.9): the PIN, the password and the phone's
    /// next epoch's secret sealed to one UTK, with the blob, after the same steps as a change
    /// (``CredentialOps/renew(_:_:onMarker:onAnswered:)``): [onMarker] stores the renew's record and request (its inner
    /// id, `exp` and confirmed blob version, VAULT-MESSAGING 0.46.0 §11.14.9 step 1) and returns the next secret;
    /// [onAnswered] runs on its own `ok`, before the rotated blob and new UTKs are kept. `stale_credential` is not
    /// retried; a failure once it may have gone out is ``RequestUnanswered``. [since]: ``VaultDevice/secretsSent`` as the
    /// caller read it before its own checks (nil: read here).
    public func secretRenew(
        pin: String, password: String, since: Int? = nil, onMarker: @escaping @Sendable (ChangeRequest) async throws -> [UInt8],
        onAnswered: @escaping @Sendable () async -> Void
    ) async throws {
        let fields: [SealedField] = [.string("pin", pin), .string("password", password)]
        _ = try await credential.renew(
            Self.typeSecretRenew, fields, since: since, onMarker: Self.withSecret(onMarker), onAnswered: onAnswered
        )
    }

    /// [onMarker]'s secret as the `new_unlock_secret` member, the bytes wiped.
    private static func withSecret(
        _ onMarker: @escaping @Sendable (ChangeRequest) async throws -> [UInt8]
    ) -> CredentialOps.OnMarker {
        { change in
            var secret = try await onMarker(change)
            defer { Bytes.wipe(&secret) }
            return [.string("new_unlock_secret", Base64s.encodeStd(secret))]
        }
    }

    /// Whether every credential request of this device is settled (answered, or past its `exp` by more than a minute on
    /// the vault's clock as its answers show it), waiting for at most 30 s (VAULT-MESSAGING 0.46.0 §11.14.9 step 1).
    public func credentialAwaitSettled() async -> Bool {
        await device.awaitCredentialSettled(within: CredentialOps.inFlightWait, sleep: changeWaitSleep)
    }

    /// The `exp` of a request to send now: 10 minutes after the vault's clock as last seen (§11.14.9 "A lost answer" step
    /// 1). In a process that has not heard from the vault yet, `credential.version` is asked first, so that it is counted
    /// on the vault's clock rather than the phone's (chosen; not in the spec); without an answer nothing is sent.
    public func requestExp() async throws -> Date { try await credential.requestExp() }

    public static let typeSecretRenew = "vault.secret.renew"
    public static let typePinChange = "pin.change"
    public static let typePasswordChange = "credential.password.change"

    /// Whether a `pin.change` answer says `epoch_advanced: true`.
    public static func epochAdvanced(_ body: [UInt8]) -> Bool { VaultJSON.bool(VaultJSON.object(body), "epoch_advanced") == true }

    /// A change of PIN or password sent again as the same request (§11.14.9 step 3). Returns the answer's body, its blob
    /// and UTKs kept; a refusal is ``VaultOpError``; no answer ``ChangeUnanswered``.
    public func resendChange(_ held: HeldRequest) async throws -> [UInt8] { try await credential.resendChange(held) }

    /// `credential.version` (§10.6) with the answer's `ts`, by the vault's clock.
    public func credentialVersionStamped() async throws -> StampedCredentialInfo {
        let r = try await device.request("credential.version")
        let body = try VaultDevice.okBody("credential.version", r)
        return StampedCredentialInfo(info: try VaultJSON.decode(CredentialInfo.self, body), ts: r.ts)
    }

    /// A pool of UTKs (`credential.utk.get`), kept (after a change whose answer, and its UTKs, were lost).
    public func topUpUTKs() async throws { try await credential.keep(try await device.op("credential.utk.get")) }
}

/// `credential.version`'s answer and its `ts` (VAULT-MESSAGING §11.14.9 "A lost answer").
public struct StampedCredentialInfo: Equatable, Sendable {
    public let info: CredentialInfo
    public let ts: Date

    public init(info: CredentialInfo, ts: Date) {
        self.info = info
        self.ts = ts
    }
}
