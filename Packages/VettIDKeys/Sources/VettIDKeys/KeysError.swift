import Foundation

/// A failure of the keys or of the encrypted file store. Messages are fixed strings naming the kind of failure and the
/// item; they never carry key material, secrets or file contents. Mirrors vettid-android `KeystoreException`, split by
/// what the app does next (IOS-PLAN §6.3, "Lost keys against a locked iPhone").
public enum KeysError: Error, Equatable, Sendable, CustomStringConvertible {
    /// Definitely gone: the lookup answered "no such item" or "no such file" while protected data was available before
    /// and after it. Leads to "this phone no longer holds the keys".
    case missing(String)
    /// Refused for now: the iPhone is locked or has not been unlocked since it started, protected data went away during
    /// the lookup, or any other error that may be temporary. Every key and record is kept; the app says "Unlock your
    /// iPhone" and retries.
    case unavailable(String)
    /// The key exists but no longer works: iOS reports it invalid, a signature does not verify, a tag does not match.
    case invalid(String)
    /// A file or blob that does not decrypt (or parse) while its key works: damaged or replaced.
    case corrupt(String)
    /// A blob or file whose format byte this app does not know (written by a newer app): never used, never written over
    /// (VAULT-MESSAGING §11.14.1 rule 9).
    case unknownFormat(String)
    /// This device has no Secure Enclave (or no App Attest): nothing is created, nothing is sent.
    case noSecureHardware

    public var description: String {
        switch self {
        case .missing(let what): "keys: \(what) missing"
        case .unavailable(let what): "keys: \(what) unavailable for now"
        case .invalid(let what): "keys: \(what) invalid"
        case .corrupt(let what): "keys: \(what) corrupt"
        case .unknownFormat(let what): "keys: \(what) in an unknown format"
        case .noSecureHardware: "keys: no secure hardware"
        }
    }

    /// Whether this failure means the keys are lost for good (as opposed to refused for now).
    public var isLoss: Bool {
        switch self {
        case .missing, .invalid, .corrupt: true
        case .unavailable, .unknownFormat, .noSecureHardware: false
        }
    }
}
