import Foundation

/// Every attestation and manifest failure. Descriptions name the kind of failure and never carry input bytes; ``kind``
/// lets callers (and the UI) tell them apart without parsing text. Mirrors vettid-android `AttestationException`.
public enum AttestationError: Error, Equatable, Sendable, CustomStringConvertible {
    case format(String)
    case signature(String)
    case chain
    case pcr(String)
    /// Any of PCR0–2 all zero: a debug-mode enclave.
    case debug
    case stale
    case userData
    case nonce
    case manifestKey
    case manifestSerial
    /// A release rule refused (not listed, wrong status, older than the last unlocked one). `unknown`: the enclave's
    /// own document verified, but its PCR0 is in no entry of the manifest the app trusts ("not listed").
    case release(String, unknown: Bool = false)
    /// The manifest is not the one a request names (hash or serial).
    case hash

    public enum Kind: Sendable {
        case format, signature, chain, pcr, debug, stale, userData, nonce, manifestKey, manifestSerial, release, hash
    }

    public var kind: Kind {
        switch self {
        case .format: .format
        case .signature: .signature
        case .chain: .chain
        case .pcr: .pcr
        case .debug: .debug
        case .stale: .stale
        case .userData: .userData
        case .nonce: .nonce
        case .manifestKey: .manifestKey
        case .manifestSerial: .manifestSerial
        case .release: .release
        case .hash: .hash
        }
    }

    /// The failure is the release manifest's (its document, signature, key, serial or hash), not an enclave's.
    public var isManifest: Bool {
        switch self {
        case .format(let what): what.hasPrefix("manifest") || what.hasPrefix("served manifest")
        case .signature(let what): what == "manifest"
        case .manifestKey, .manifestSerial, .hash: true
        default: false
        }
    }

    public var description: String {
        switch self {
        case .format(let what): "malformed: \(what)"
        case .signature(let what): "signature invalid: \(what)"
        case .chain: "certificate chain invalid"
        case .pcr(let what): "PCR check failed: \(what)"
        case .debug: "debug (all-zero) PCRs"
        case .stale: "attestation too old or from the future"
        case .userData: "user_data mismatch"
        case .nonce: "nonce mismatch"
        case .manifestKey: "manifest: unknown key id"
        case .manifestSerial: "manifest: serial lower than one already seen"
        case .release(let what, _): "release: \(what)"
        case .hash: "manifest does not match the request"
        }
    }
}
