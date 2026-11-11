/// The cipher that encrypts media frames.
public enum FrameCipher: Sendable { case aesGcm }

/// The media suites of VettID calls: one closed, versioned registry (CALLS-PLAN §12). A suite fixes everything two
/// devices must agree on to encrypt a call's media frames: the frame cipher and its key length, the key derivation and
/// its labels, the frame format, and what the suite expects of the transport underneath. Its ``id`` is what the
/// devices negotiate, and it is bound into the keys they derive.
///
/// Adding a suite is one case here, plus the media engine saying that it can do it. An id is never reused or
/// redefined. Mirrors vettid-android `MediaSuite`.
public enum MediaSuite: Int, CaseIterable, Sendable {
    /// AES-128-GCM frames in the media stack's frame-cryptor format. The suite of every call today.
    case aes128Gcm = 1
    /// AES-256-GCM frames in the same format, with a 32-byte frame key. **Not offered or chosen in form 1**
    /// (``formOne(_:)``): VAULT-MESSAGING §10.10 "Call forms", rules 1 and 3.
    case aes256Gcm = 2

    /// The number on the wire, 1 to 65535.
    public var id: Int { rawValue }

    public var frameCipher: FrameCipher { .aesGcm }

    /// The frame key's length in bytes.
    public var frameKeySize: Int {
        switch self {
        case .aes128Gcm: 16
        case .aes256Gcm: 32
        }
    }

    /// The KDF of the direction keys and of the frame key.
    public var kdf: String { "HKDF-SHA-256" }

    /// HKDF salt of the direction keys.
    public var mediaLabel: String { "vettid/vms/2/call-media" }

    /// HKDF salt of the frame key (the frame cryptor's "ratchet salt").
    public var frameLabel: String { "vettid/vms/2/call-frame" }

    /// Whether the suite may only be used over a DTLS handshake with a post-quantum key exchange. No suite asks for
    /// it today: the frame encryption does not rely on DTLS.
    public var pqDtlsRequired: Bool { false }

    /// Every registered suite, the preferred one first.
    public static let preference: [MediaSuite] = [.aes256Gcm, .aes128Gcm]

    /// What a device offers when its engine says nothing else: suite 1, what every engine can do and all form 1 allows.
    public static let `default`: [MediaSuite] = [.aes128Gcm]

    /// What [supported] may offer or choose in **form 1** (the SDP attribute of ``CallMedia``, which nothing signs):
    /// suite 1 only, or nothing if [supported] lacks it (VAULT-MESSAGING §10.10 "Call forms", rules 1 and 3).
    public static func formOne(_ supported: [MediaSuite]) -> [MediaSuite] { supported.filter { $0 == .aes128Gcm } }

    /// The suite with this number, or nil for a number this build does not know.
    public static func byId(_ id: Int) -> MediaSuite? { MediaSuite(rawValue: id) }

    /// [suites] in the order of ``preference``, each once.
    public static func ordered(_ suites: [MediaSuite]) -> [MediaSuite] { preference.filter { suites.contains($0) } }
}
