import Foundation
import VettIDCrypto

/// A sealed result could not be opened or parsed (or answers another request).
public struct AltResultFailure: Error, Equatable, Sendable, CustomStringConvertible {
    public let what: String

    public var description: String { "alternate channel: \(what)" }
}

/// Sealed results of the alternate channel (VAULT-MESSAGING §11.3, §11.4, §11.11.3). Mirrors vettid-android `AltResults`.
public enum AltResults {
    public static let typeEnrollResult = "vault.enroll.result"
    public static let typeUnlockResult = "vault.unlock.result"
    public static let typeRecoveryResult = "vault.recovery.result"

    /// Opens a 5,252-byte sealed result addressed to [kem]: a sealed envelope whose inner is [type], answers [requestID]
    /// (`re`) and is padded to exactly 4,096 bytes. Returns the body.
    public static func open(_ raw: [UInt8], kem: KemPrivateKey, type: String, requestID: String) throws -> [UInt8] {
        try openInner(raw, kem: kem, type: type, requestID: requestID).body
    }

    /// As ``open(_:kem:type:requestID:)``, returning the whole inner (its `ts` is the enclave's clock when it answered).
    public static func openInner(_ raw: [UInt8], kem: KemPrivateKey, type: String, requestID: String) throws -> Inner {
        guard raw.count == AltChannel.resultEnvelopeSize else { throw AltResultFailure(what: "result size") }
        let inner: Inner
        do {
            let env = try Envelope.parse(raw)
            guard env.mode == .sealed else { throw AltResultFailure(what: "result mode") }
            let (padded, _) = try Envelope.openSealed(env, key: kem)
            inner = try Inner.parse(try Padding.unpadFixed(padded, Padding.altChannel), .sealed)
        } catch is CryptoError {
            throw AltResultFailure(what: "result unreadable")
        }
        guard inner.type == type, inner.re == requestID else { throw AltResultFailure(what: "result does not answer the request") }
        return inner
    }

    static func object(_ b: [UInt8]) throws -> JsonObject {
        do {
            return try StrictJson.parseObject(b)
        } catch is CryptoError {
            throw AltResultFailure(what: "result body")
        }
    }

    /// Runs [parse], reporting any malformed member as a malformed result.
    static func wrap<T>(_ parse: () throws -> T) throws -> T {
        do {
            return try parse()
        } catch is CryptoError {
            throw AltResultFailure(what: "result body")
        }
    }
}

/// `vault.enroll.result` (§11.3); success also arrives as vault.enrolled over the relay.
public struct EnrollResult: Equatable, Sendable {
    public let ok: Bool
    public let code: String?
    public let vaultID: String?

    public static func parse(_ body: [UInt8]) throws -> EnrollResult {
        try AltResults.wrap {
            let o = try AltResults.object(body)
            return try o.bool("ok")
                ? EnrollResult(ok: true, code: nil, vaultID: try o.string("vault_id"))
                : EnrollResult(ok: false, code: try o.string("code"), vaultID: nil)
        }
    }
}

/// `vault.unlock.result` (§11.4).
public struct UnlockResult: Equatable, Sendable {
    /// The `update` member: `moved`, `abandoned` or `refused` (with a code).
    public struct Update: Equatable, Sendable {
        public let to: String
        public let result: String
        public let code: String?
    }

    public var ok: Bool
    public var code: String?
    public var stateSeq: UInt64 = 0
    public var headerSeq: UInt64 = 0
    public var retryAfterSeconds: UInt64 = 0
    public var token: String?
    public var release: String?
    public var releaseNumber: UInt64 = 0
    public var releaseStatus: String?
    public var manifestSerial: UInt64 = 0
    public var update: Update?
    public var recoveryCancelled = false
    public var vaultBundle: [UInt8]?
    /// `credential_backup` (0.10.6, §11.11.5 step 1): in a recovery-registered app's result, whether the vault keeps a
    /// copy of the credential. Nil when absent.
    public var credentialBackup: Bool?
    /// The result's inner `ts`: the enclave's clock when it answered (§11.4). A `vault.locking` not newer than this is
    /// from before the vault opened. Nil when not known.
    public var at: Date?

    public init(ok: Bool, code: String? = nil) {
        self.ok = ok
        self.code = code
    }

    static let maxBundle = 2048

    public static func parse(_ body: [UInt8]) throws -> UnlockResult {
        try AltResults.wrap {
            let o = try AltResults.object(body)
            let max = StrictJson.maxSafeInteger
            let headerSeq = try o.uint("header_seq", min: 0, max: max)
            guard try o.bool("ok") else {
                var r = UnlockResult(ok: false, code: try o.string("code"))
                r.headerSeq = headerSeq
                // `retry_after` is 0 or absent where nothing waits (`signer_refused`, §11.7.1).
                r.retryAfterSeconds = try o.optUint("retry_after", min: 0, max: max) ?? 0
                return r
            }
            let release = try o.string("release")
            guard Descriptor.isValidPcr(release) else { throw AltResultFailure(what: "result release") }
            let bundle = o.has("vault_bundle") ? try o.base64("vault_bundle") : nil
            if let bundle, bundle.count > maxBundle { throw AltResultFailure(what: "result vault_bundle") }
            var r = UnlockResult(ok: true)
            r.stateSeq = try o.uint("state_seq", min: 0, max: max)
            r.headerSeq = headerSeq
            r.token = try o.optString("token")
            r.release = release
            r.releaseNumber = try o.uint("release_number", min: 1, max: max)
            r.releaseStatus = try o.string("release_status")
            r.manifestSerial = try o.uint("manifest_serial", min: 0, max: max)
            if let u = try o.optObj("update") {
                r.update = Update(to: try u.string("to"), result: try u.string("result"), code: try u.optString("code"))
            }
            r.recoveryCancelled = o.has("recovery_cancelled") ? try o.bool("recovery_cancelled") : false
            r.vaultBundle = bundle
            r.credentialBackup = o.has("credential_backup") ? try o.bool("credential_backup") : nil
            return r
        }
    }
}

/// `vault.recovery.result` (§11.11.3).
public struct RecoveryResult: Equatable, Sendable {
    public let ok: Bool
    public let code: String?

    public static func parse(_ body: [UInt8]) throws -> RecoveryResult {
        try AltResults.wrap {
            let o = try AltResults.object(body)
            return try o.bool("ok") ? RecoveryResult(ok: true, code: nil) : RecoveryResult(ok: false, code: try o.string("code"))
        }
    }
}
