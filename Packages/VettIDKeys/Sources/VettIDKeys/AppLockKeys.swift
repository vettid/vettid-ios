import Foundation
import LocalAuthentication
import Security

/// How the app lock asks (ANDROID-PLAN D6; IOS-PLAN ID17): Face ID or Touch ID, or the iPhone passcode. Mirrors
/// vettid-android `AppLockMethod` (`BIOMETRICS`, `SCREEN_LOCK`).
public enum AppLockMethod: String, Codable, CaseIterable, Sendable {
    case biometrics
    case passcode
}

/// Why the app-lock key did not open. The app lock is a convenience: whatever iOS answers, it never shuts the member
/// out of the app (a reinstall would destroy the vault's keys).
public enum AppLockKeyError: Error, Equatable, Sendable {
    /// The member cancelled the prompt, or iOS did (the app left the foreground, another prompt took over).
    case cancelled
    /// The key no longer opens, or no longer can: it is gone, the enrolled faces or fingers changed since it was made,
    /// Face ID or Touch ID was turned off for the app or is no longer set up, or the passcode was turned off. The lock turns
    /// itself off.
    case invalidated
    /// Face ID or Touch ID is locked after too many failed attempts: the member unlocks the iPhone with its passcode, then
    /// tries again.
    case lockedOut
    /// Anything else (a failed attempt, the iPhone not ready): the member tries again.
    case failed
}

/// The app-lock key (IOS-PLAN §6.1 "App-lock key", ID17): a convenience layer that gates the unwrap of the app's local
/// data key, never in place of the PIN or the password, and the only key of the app bound to biometry or the passcode.
/// On the iPhone a Secure Enclave key with `.biometryCurrentSet` or `.devicePasscode` per the member's choice
/// (``SecureEnclaveAppLockKeys``); a software stand-in in VettIDKeysTesting for the simulator's tests. Mirrors
/// vettid-android `AppLockKeys`, with the prompt inside ``open(_:reason:)`` (iOS shows it when the private key is used).
public protocol AppLockKeys: KeyEraser {
    /// A fresh key for [method] (any earlier one is replaced). Throws ``KeysError/noSecureHardware`` where the hardware
    /// cannot hold it.
    func create(_ method: AppLockMethod) throws

    /// Whether a key exists (it may still no longer open): false only when iOS answers that there is none; any other
    /// answer throws ``KeysError/unavailable(_:)`` and the lock is kept.
    func exists() throws -> Bool

    /// Seals [plaintext] to the key's public half: no prompt.
    func seal(_ plaintext: [UInt8]) throws -> [UInt8]

    /// Opens [sealed] with the key's private half, after Face ID, Touch ID or the passcode; [reason] is what iOS shows.
    /// Throws ``AppLockKeyError``.
    func open(_ sealed: [UInt8], reason: String) async throws -> [UInt8]

    /// Removes the key.
    func delete() throws
}

public extension AppLockKeys {
    func deleteAll() throws { try delete() }
}

/// The app-lock key in the Secure Enclave: a P-256 key whose private half needs `.biometryCurrentSet` (a new face or
/// finger invalidates it) or `.devicePasscode`, `WhenUnlockedThisDeviceOnly`, never synchronizable; the data key sealed
/// to it with ECIES (`eciesEncryptionCofactorVariableIVX963SHA256AESGCM`). The app uses it wherever it has the Secure
/// Enclave keys (IOS-PLAN §8 I1.4), a refusing placeholder elsewhere.
public final class SecureEnclaveAppLockKeys: AppLockKeys, @unchecked Sendable {
    public static let tag = "com.vettid.applock.v1"
    static let algorithm = SecKeyAlgorithm.eciesEncryptionCofactorVariableIVX963SHA256AESGCM

    private let tag: Data
    /// The method and, for Face ID or Touch ID, the enrolled set (`evaluatedPolicyDomainState`) when the key was made:
    /// a different set later means the key no longer opens, whatever iOS answers then.
    private let made: KeychainItem

    public init(tag: String = SecureEnclaveAppLockKeys.tag) {
        self.tag = Data(tag.utf8)
        made = KeychainItem(account: tag + ".made", accessible: .whenUnlockedThisDeviceOnly)
    }

    private var query: [CFString: Any] {
        [
            kSecClass: kSecClassKey,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrApplicationTag: tag,
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecUseDataProtectionKeychain: true,
        ]
    }

    public func create(_ method: AppLockMethod) throws {
        try delete()
        let flags: SecAccessControlCreateFlags = method == .biometrics
            ? [.privateKeyUsage, .biometryCurrentSet] : [.privateKeyUsage, .devicePasscode]
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, flags, nil) else {
            throw KeysError.unavailable("app lock key")
        }
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256,
            kSecAttrTokenID: kSecAttrTokenIDSecureEnclave,
            kSecUseDataProtectionKeychain: true,
            kSecPrivateKeyAttrs: [
                kSecAttrIsPermanent: true,
                kSecAttrApplicationTag: tag,
                kSecAttrAccessControl: access,
            ] as [CFString: Any],
        ]
        guard SecKeyCreateRandomKey(attributes as CFDictionary, nil) != nil else { throw KeysError.noSecureHardware }
        try made.write(Self.record(method, method == .biometrics ? Self.domainState() : nil))
    }

    /// The enrolled faces or fingers as iOS reports them now (nil when it cannot say).
    static func domainState() -> Data? {
        let c = LAContext()
        _ = c.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return c.evaluatedPolicyDomainState
    }

    /// The method byte, then the domain state (if any).
    static func record(_ method: AppLockMethod, _ state: Data?) -> [UInt8] {
        let kind: UInt8 = method == .biometrics ? 1 : 2
        var out: [UInt8] = [kind]
        if let state { out.append(contentsOf: state) }
        return out
    }

    /// Whether the key, as it was made, can still open: the same method and, for Face ID or Touch ID, the same enrolled set.
    static func stillValid(_ record: [UInt8]?, now state: Data?) -> Bool {
        guard let record, let kind = record.first else { return true }
        guard kind == 1 else { return true }
        let then = Array(record.dropFirst())
        // Without a set to compare (iOS said nothing at either time) the key's own answer decides.
        guard !then.isEmpty, let state else { return true }
        return then == Array(state)
    }

    /// The private key's reference; with [context], its use asks through that context. Nil only when iOS answers that
    /// there is none (`errSecItemNotFound`); any other answer throws ``KeysError/unavailable(_:)``.
    private func key(_ context: LAContext) throws -> SecKey? {
        var q = query
        q[kSecReturnRef] = true
        q[kSecUseAuthenticationContext] = context
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let ref = out else { throw KeysError.unavailable("app lock key (\(status))") }
        // A key reference is what a kSecReturnRef query of kSecClassKey returns.
        return (ref as! SecKey) // swiftlint:disable:this force_cast
    }

    public func exists() throws -> Bool {
        let context = LAContext()
        context.interactionNotAllowed = true
        return try key(context) != nil
    }

    public func seal(_ plaintext: [UInt8]) throws -> [UInt8] {
        let context = LAContext()
        context.interactionNotAllowed = true
        guard let key = try key(context), let pub = SecKeyCopyPublicKey(key) else { throw KeysError.missing("app lock key") }
        guard let out = SecKeyCreateEncryptedData(pub, Self.algorithm, Data(plaintext) as CFData, nil) else {
            throw KeysError.invalid("app lock key")
        }
        return Array(out as Data)
    }

    public func open(_ sealed: [UInt8], reason: String) async throws -> [UInt8] {
        let record: [UInt8]? = if case .found(let r) = made.read() { r } else { nil }
        guard Self.stillValid(record, now: Self.domainState()) else { throw AppLockKeyError.invalidated }
        let context = LAContext()
        context.localizedReason = reason
        // Face ID or Touch ID only: no "Enter Password" button in iOS's prompt (the passcode method asks for it).
        if record?.first == 1 { context.localizedFallbackTitle = "" }
        let key: SecKey
        do {
            guard let k = try self.key(context) else { throw AppLockKeyError.invalidated }
            key = k
        } catch let e as AppLockKeyError {
            throw e
        } catch {
            throw AppLockKeyError.failed
        }
        let box = SecKeyBox(key)
        // iOS shows its prompt while the private key is used, blocking the calling thread: never the main thread.
        return try await Task.detached {
            var error: Unmanaged<CFError>?
            guard let out = SecKeyCreateDecryptedData(box.key, Self.algorithm, Data(sealed) as CFData, &error) else {
                throw Self.classify(error?.takeRetainedValue())
            }
            return Array(out as Data)
        }.value
    }

    /// What a failed use of the key means for the app lock: never a lock the member cannot get past.
    static func classify(_ error: CFError?) -> AppLockKeyError {
        guard let error else { return .failed }
        let code = CFErrorGetCode(error)
        let domain = CFErrorGetDomain(error) as String
        if domain == NSOSStatusErrorDomain {
            switch Int32(truncatingIfNeeded: code) {
            case errSecUserCanceled: return .cancelled
            // The key, or its reference, can no longer be used. A failed Face ID or Touch ID (errSecAuthFailed) is tried
            // again.
            case errSecItemNotFound, errSecInvalidKeyRef, errSecInvalidItemRef: return .invalidated
            default: return .failed
            }
        }
        guard domain == LAErrorDomain else { return .failed }
        switch code {
        case LAError.userCancel.rawValue, LAError.systemCancel.rawValue, LAError.appCancel.rawValue, LAError.userFallback.rawValue:
            return .cancelled
        // Face ID or Touch ID turned off for the app, no longer set up, or the passcode turned off.
        case LAError.passcodeNotSet.rawValue, LAError.biometryNotEnrolled.rawValue, LAError.biometryNotAvailable.rawValue:
            return .invalidated
        case LAError.biometryLockout.rawValue:
            return .lockedOut
        default:
            return .failed
        }
    }

    public func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeysError.unavailable("app lock key") }
        try made.delete()
    }
}

/// A key reference handed to the task that uses it (SecKey is thread-safe).
private struct SecKeyBox: @unchecked Sendable {
    let key: SecKey

    init(_ key: SecKey) { self.key = key }
}
