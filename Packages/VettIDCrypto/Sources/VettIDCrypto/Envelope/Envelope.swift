/// A structurally valid, still-encrypted v2 envelope (§5.2):
///
/// ```
/// 0  1   ver 0x02 | 1 1 suite 0x02 | 2 1 mode | 3 1 flags 0x00
/// 4  8   sender_kid | 12 8 recipient_kid
/// session: 20 24 nonce | 44 n+16 XChaCha20-Poly1305(k, nonce, aad = bytes[0:44], padded)
/// sealed:  20 1120 enc | 1140 n+16 HPKE Seal(aad = bytes[0:1140], padded)
/// ```
///
/// ``parse(_:)`` rejects anything a conforming sender would not produce before any decryption is attempted.
/// Mirrors vettid-android `Envelope`.
public struct Envelope: Sendable {
    private let raw: [UInt8]
    public let mode: Mode
    public let senderKid: Kid
    public let recipientKid: Kid

    public static let version: UInt8 = 0x02
    private static let offVersion = 0
    private static let offSuite = 1
    private static let offMode = 2
    private static let offFlags = 3
    private static let offSenderKid = 4
    private static let offRecipientKid = 12
    private static let offBody = 20
    public static let headerSession = offBody + Suite.xNonceSize // 44
    public static let headerSealed = offBody + Suite.encSize // 1140
    public static let overheadSession = headerSession + Suite.tagSize // 60
    public static let overheadSealed = headerSealed + Suite.tagSize // 1156

    private init(raw: [UInt8], mode: Mode) throws {
        self.raw = raw
        self.mode = mode
        senderKid = try Kid(Array(raw[Self.offSenderKid..<Self.offRecipientKid]))
        recipientKid = try Kid(Array(raw[Self.offRecipientKid..<Self.offBody]))
    }

    public var headerLen: Int { mode == .session ? Self.headerSession : Self.headerSealed }

    /// The header, which is also the AAD.
    public var header: [UInt8] { Array(raw[0..<headerLen]) }
    public var bytes: [UInt8] { raw }
    public var size: Int { raw.count }
    public var paddedLen: Int { raw.count - headerLen - Suite.tagSize }

    var body: [UInt8] { Array(raw[Self.offBody..<headerLen]) }
    var ciphertext: [UInt8] { Array(raw[headerLen...]) }

    /// Validates structure: version 2, suite 2 (suite 1 rejected), mode session or sealed, flags zero, and a
    /// ciphertext of tag + a valid padded size.
    public static func parse(_ b: [UInt8]) throws -> Envelope {
        guard b.count >= offBody else { throw CryptoError.format("envelope truncated") }
        guard b[offVersion] == version else { throw CryptoError.format("envelope version") }
        try Suite.check(Int(b[offSuite]), pinned: 0)
        guard b[offFlags] == 0 else { throw CryptoError.format("envelope flags") }
        guard let mode = Mode(rawValue: b[offMode]) else { throw CryptoError.format("envelope mode") }
        let h = mode == .session ? headerSession : headerSealed
        guard b.count >= h + Suite.tagSize + Padding.minPadded else { throw CryptoError.format("envelope truncated") }
        guard Padding.isValidPaddedLen(b.count - h - Suite.tagSize) else { throw CryptoError.format("envelope length") }
        return try Envelope(raw: b, mode: mode)
    }

    static func header(_ mode: Mode, senderKid: Kid, recipientKid: Kid, body: [UInt8]) -> [UInt8] {
        [version, UInt8(Suite.suite2), mode.rawValue, 0] + senderKid.bytes + recipientKid.bytes + body
    }

    /// A session-mode envelope: a fresh random nonce and XChaCha20-Poly1305 under the epoch's directional key, the
    /// 44-byte header as AAD.
    public static func sealSession(key: [UInt8], senderKid: Kid, recipientKid: Kid, padded: [UInt8]) throws -> [UInt8] {
        guard Padding.isValidPaddedLen(padded.count) else { throw CryptoError.format("length") }
        let nonce = XChaCha20Poly1305.newNonce()
        let h = header(.session, senderKid: senderKid, recipientKid: recipientKid, body: nonce)
        return h + (try XChaCha20Poly1305.seal(key: key, nonce: nonce, aad: h, plaintext: padded))
    }

    /// Decrypts a session-mode envelope and returns the padded inner plaintext.
    public static func openSession(_ e: Envelope, key: [UInt8]) throws -> [UInt8] {
        guard e.mode == .session else { throw CryptoError.protocolViolation("wrong mode") }
        return try XChaCha20Poly1305.open(key: key, nonce: e.body, aad: e.header, ciphertext: e.ciphertext)
    }

    /// SetupBaseS + Seal in one step (§4.3).
    public static func sealSealed(_ recipient: KemPublicKey, senderKid: Kid, padded: [UInt8]) throws -> ([UInt8], HpkeExporter) {
        let s = try Sealer(recipient, senderKid: senderKid)
        return (try s.seal(padded), s)
    }

    /// Decrypts a sealed-mode envelope. recipient_kid must be the key's kid: the caller selects the key by kid and no
    /// other key is tried (§4.4).
    public static func openSealed(_ e: Envelope, key: KemPrivateKey) throws -> ([UInt8], HpkeExporter) {
        guard e.mode == .sealed else { throw CryptoError.protocolViolation("wrong mode") }
        guard e.recipientKid == key.publicKey.kid else { throw CryptoError.protocolViolation("kid does not match the key") }
        let r = try HpkeRecipient.setup(enc: e.body, key: key, info: Array(Labels.sealed.utf8))
        return (try r.open(aad: e.header, ciphertext: e.ciphertext), r)
    }
}

/// Builds one sealed-mode envelope in two steps, so that a caller can read the header (and Export from the HPKE
/// context) before sealing: the handshake's `th` covers hs.resp's header inside hs.resp's own plaintext (§6.3).
/// Mirrors vettid-android `Sealer`.
public final class Sealer: HpkeExporter, @unchecked Sendable {
    private let context: HpkeSender
    public let header: [UInt8]

    public init(_ recipient: KemPublicKey, senderKid: Kid) throws {
        context = try HpkeSender.setup(recipient, info: Array(Labels.sealed.utf8))
        header = Envelope.header(.sealed, senderKid: senderKid, recipientKid: recipient.kid, body: context.enc)
    }

    public func export(_ label: String, _ length: Int) throws -> [UInt8] { try context.export(label, length) }

    /// Encrypts the padded inner plaintext; callable once.
    public func seal(_ padded: [UInt8]) throws -> [UInt8] {
        guard Padding.isValidPaddedLen(padded.count) else { throw CryptoError.format("length") }
        return header + (try context.seal(aad: header, plaintext: padded))
    }
}
