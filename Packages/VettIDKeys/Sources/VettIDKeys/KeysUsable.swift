import CryptoKit
import Foundation
import VettIDCrypto

/// The "keys usable" check (IOS-PLAN §6.1): after a restore or a migration keychain items may come back while the
/// Secure Enclave keys do not, so the app tests that each key **works** (signs or agrees once), not only that it exists.
public enum KeysUsability: Equatable, Sendable {
    case usable
    /// Lost for good: "this phone no longer holds the keys".
    case lost
    /// Refused for now (the iPhone is locked, or any error that is not a definite loss): keep everything and retry.
    case unavailable
    /// Stored data in a format this app does not know: refuse to start on it, write nothing, wipe nothing, make no key
    /// (VAULT-MESSAGING §11.14.1 rule 9).
    case unknownFormat

    /// The verdict over several keys: an unknown format first, then one lost key loses them all (the three vault keys
    /// are lost together or not at all), and otherwise one refused for now makes the whole check refused for now.
    public static func combine(_ all: [KeysUsability]) -> KeysUsability {
        if all.contains(.unknownFormat) { return .unknownFormat }
        if all.contains(.lost) { return .lost }
        if all.contains(.unavailable) { return .unavailable }
        return .usable
    }

    /// The verdict of a failure: only an explicit ``KeysError/missing(_:)``, ``KeysError/invalid(_:)`` or
    /// ``KeysError/corrupt(_:)`` (a blob that fails authentication while its key works, VAULT-MESSAGING §11.14.1 rule 8;
    /// a key that refuses is never reported as `corrupt`) is a loss; an unknown format is its own verdict; anything else
    /// (a CryptoKit error included) is refused for now.
    public static func of(_ error: any Error) -> KeysUsability {
        switch error as? KeysError {
        case .missing, .invalid, .corrupt: .lost
        case .unknownFormat: .unknownFormat
        default: .unavailable
        }
    }
}

public enum KeysUsableCheck {
    static let probe = Array("vettid/ios/keys-usable/1".utf8)

    /// The app key signs once and the signature verifies under its SPKI.
    public static func appKey(_ store: any AppKeyStore) -> KeysUsability {
        switch store.lookup() {
        case .missing: return .lost
        case .unavailable: return .unavailable
        case .found(let key):
            do {
                let pub = try P256.Signing.PublicKey(derRepresentation: try key.spki())
                let sig = try P256.Signing.ECDSASignature(derRepresentation: try key.sign(probe))
                return pub.isValidSignature(sig, for: probe) ? .usable : .lost
            } catch {
                return KeysUsability.of(error)
            }
        }
    }

    /// The key agrees once with a fresh software key, and both directions give the same shared value.
    public static func agreement(_ lookup: ItemLookup<any KeyAgreementKey>) -> KeysUsability {
        switch lookup {
        case .missing: return .lost
        case .unavailable: return .unavailable
        case .found(let key):
            do {
                let e = P256.KeyAgreement.PrivateKey()
                var ours = try SoftwareECDH.agree(e, try key.publicKey())
                var theirs = try key.agree(Array(e.publicKey.x963Representation))
                defer {
                    Bytes.wipe(&ours)
                    Bytes.wipe(&theirs)
                }
                return Bytes.constantTimeEquals(ours, theirs) ? .usable : .lost
            } catch {
                return KeysUsability.of(error)
            }
        }
    }
}
