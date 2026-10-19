import Foundation
import VettIDCrypto

// Release R (VAULT-MESSAGING §11.14.9): the changes of PIN and phone secret, holder credential operations, and the
// decision of a change whose answer was lost ("A lost answer"). Mirrors vettid-android `ReleaseRApi.kt`.
extension VaultApi {
    /// `pin.change`: the current PIN, the new one, the password and the phone's next epoch's secret, sealed to one UTK,
    /// with the blob, sent as [change] (its inner id and `exp`, stored before this call). Returns the answer's
    /// `epoch_advanced`: only `true` lets the phone move to the next epoch (§11.14.1); anything else leaves the next
    /// epoch's record a candidate, for an unlock to decide. No answer is ``ChangeUnanswered``; `stale_credential` is not
    /// retried (``CredentialOps/change(_:_:_:)``).
    public func pinChange(
        pin: String, newPin: String, password: String, newUnlockSecret: [UInt8], change: ChangeRequest
    ) async throws -> Bool {
        let fields: [SealedField] = [
            .string("pin", pin), .string("new_pin", newPin), .string("password", password),
            .string("new_unlock_secret", Base64s.encodeStd(newUnlockSecret)),
        ]
        let body = try await credential.change(Self.typePinChange, fields, change)
        return Self.epochAdvanced(body)
    }

    /// `vault.secret.renew`: a new phone secret with the PIN unchanged (§11.14.9): the PIN, the password and the phone's
    /// next epoch's secret sealed to one UTK, with the blob, valid until [exp] (``requestExp()``; chosen, not in the spec:
    /// after it a copy waiting in a locked vault's mailbox never applies). The answer carries the rotated blob and new
    /// UTKs, which are kept; the generation does not change. The caller makes the next epoch's record current on that
    /// answer only. A generic credential operation (§3.5.3): a lost answer is left to the phone's records (IOS-PLAN
    /// §6.3): a retry of the same operation sends the same secret, and an unlock tries the record.
    public func secretRenew(pin: String, password: String, newUnlockSecret: [UInt8], exp: Date) async throws {
        let fields: [SealedField] = [
            .string("pin", pin), .string("password", password),
            .string("new_unlock_secret", Base64s.encodeStd(newUnlockSecret)),
        ]
        _ = try await credential.credOp(Self.typeSecretRenew, fields, CredOpOptions(exp: exp))
    }

    /// The `exp` of a request to send now: 10 minutes after the vault's clock as last seen (§11.14.9 "A lost answer" step
    /// 1). In a process that has not heard from the vault yet, `credential.version` is asked first, so that it is counted
    /// on the vault's clock rather than the phone's (chosen; not in the spec); without an answer nothing is sent.
    public func requestExp() async throws -> Date {
        if !device.knowsVaultTime { _ = try await credentialVersionStamped() }
        return device.vaultNow().addingTimeInterval(ChangeRequest.validFor)
    }

    public static let typeSecretRenew = "vault.secret.renew"
    public static let typePinChange = "pin.change"
    public static let typePasswordChange = "credential.password.change"

    /// Whether a `pin.change` answer says `epoch_advanced: true`.
    public static func epochAdvanced(_ body: [UInt8]) -> Bool { VaultJSON.bool(VaultJSON.object(body), "epoch_advanced") == true }

    /// A change to send now: a new inner id, an `exp` 10 minutes after the vault's clock as last seen, and the blob
    /// version this device holds (§11.14.9 "A lost answer" step 1). In a process that has not heard from the vault yet,
    /// `credential.version` is asked first, so that `exp` is counted on the vault's clock rather than the phone's, which
    /// may be wrong (chosen; not in the spec, which allows the phone's clock then). It fails, and nothing is sent, when
    /// the vault does not answer.
    public func newChange() async throws -> ChangeRequest {
        let exp = try await requestExp()
        guard let version = device.credentialVersion else { throw VaultStateError(message: "no credential on this device") }
        return ChangeRequest(id: device.newRequestID(), exp: exp, version: version)
    }

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
