/// Suite 2 of VAULT-MESSAGING §4.1: HPKE (RFC 9180) base mode with KEM MLKEM768X25519 (0x647a), KDF HKDF-SHA256 and
/// AEAD ChaCha20-Poly1305 for sealed mode; XChaCha20-Poly1305 for session mode; HKDF-SHA-256 for derivations; Ed25519
/// for signatures. Also the sizes and downgrade rules (§13.4). Mirrors vettid-android `Suite`.
public enum Suite {
    /// PQC-MIGRATION's classical suite: MUST NOT be sent or accepted.
    public static let suite1 = 1
    /// The suite this code implements.
    public static let suite2 = 2
    /// Reserved for PQC Phase 2.
    public static let suite3 = 3

    public static let kemID = 0x647A
    public static let kdfID = 0x0001
    public static let aeadID = 0x0003

    public static let ekSize = 1216
    public static let encSize = 1120
    public static let seedSize = 32
    public static let kidSize = 8
    public static let keySize = 32
    public static let xNonceSize = 24
    public static let tagSize = 16
    public static let epochIDSize = 16
    public static let hashSize = 32
    public static let ed25519PublicSize = 32
    public static let ed25519SignatureSize = 64

    /// Largest `suites` offer (§6.2).
    public static let maxOffer = 8

    /// Reports whether this implementation speaks suite [s].
    public static func supported(_ s: Int) -> Bool { s == suite2 }

    /// Accepts suite [s] against a record's pinned suite: suite 1 never, suites below the pin are a downgrade, unknown
    /// suites unsupported. Pin 0 means nothing negotiated yet.
    public static func check(_ s: Int, pinned: Int) throws {
        if s == suite1 { throw CryptoError.suite("suite 1 is never accepted") }
        if s < suite2 || s > 255 { throw CryptoError.suite("unsupported") }
        if s < pinned { throw CryptoError.suite("downgrade") }
        if !supported(s) { throw CryptoError.suite("unsupported") }
    }

    /// Checks an hs.init `suites` offer: 1–8 strictly ascending integers in [2, 255], never suite 1.
    public static func validateOffer(_ suites: [Int]) throws {
        if suites.isEmpty || suites.count > maxOffer { throw CryptoError.suite("bad offer") }
        for (i, s) in suites.enumerated() {
            if s == suite1 { throw CryptoError.suite("suite 1 is never accepted") }
            if s < suite2 || s > 255 { throw CryptoError.suite("bad offer") }
            if i > 0, s <= suites[i - 1] { throw CryptoError.suite("bad offer") }
        }
    }

    /// Picks the highest offered suite this implementation supports, not below the pin.
    public static func negotiate(_ offered: [Int], pinned: Int) throws -> Int {
        try validateOffer(offered)
        for s in offered.reversed() where (try? check(s, pinned: pinned)) != nil {
            return s
        }
        throw CryptoError.suite("no common suite")
    }

    /// Verifies a responder's choice: offered, supported, not below the pin.
    public static func checkChosen(_ chosen: Int, offered: [Int], pinned: Int) throws {
        try check(chosen, pinned: pinned)
        if !offered.contains(chosen) { throw CryptoError.suite("no common suite") }
    }
}

/// Protocol labels (§4.1 and the sections that define them). ASCII, no terminator. Mirrors vettid-android `Labels`.
public enum Labels {
    public static let kid = "vettid/vms/2/kid"
    public static let sealed = "vettid/vms/2/sealed"
    public static let hsKS = "vettid/vms/2/hs-ks"
    public static let hsKE = "vettid/vms/2/hs-ke"
    public static let th1 = "vettid/vms/2/th1"
    public static let th = "vettid/vms/2/th"
    public static let session = "vettid/vms/2/session"
    public static let i2r = "vettid/vms/2/i2r"
    public static let r2i = "vettid/vms/2/r2i"
    public static let kidI2R = "vettid/vms/2/kid-i2r"
    public static let kidR2I = "vettid/vms/2/kid-r2i"
    public static let rk = "vettid/vms/2/rk"
    public static let epoch = "vettid/vms/2/epoch"
    public static let sigResp = "vettid/vms/2/sig-resp"
    public static let sigFin = "vettid/vms/2/sig-fin"
    public static let sas = "vettid/vms/2/sas"
    public static let sasCommit = "vettid/vms/2/sas-commit"
    public static let bundle = "vettid/vms/2/bundle"
    public static let etk = "vettid/vms/2/etk"
    public static let vault = "vettid/vms/2/vault"
    public static let devatt = "vettid/vms/2/devatt"
    public static let unlock = "vettid/vms/2/unlock"
    public static let releaseApproval = "vettid/vms/2/release-approval"
    public static let rotate = "vettid/vms/2/rotate"
    public static let credentialRotate = "vettid/vms/2/credential-rotate"
    public static let blob = "vettid/vms/2/blob"
    public static let utk = "vettid/vms/2/utk"
    public static let reply = "vettid/vms/2/reply"
    public static let criticalItem = "vettid/vms/2/critical-item"
    /// The identity-key fingerprint apps show for a connection (VAULT-MESSAGING 0.18.0 §10.8).
    public static let ikFP = "vettid/vms/2/ik-fp"
}
