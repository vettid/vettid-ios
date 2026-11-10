import CryptoKit
import Foundation

/// The frame encryption of the AES-GCM media suites (``MediaSuite``), written out in Swift (vettid-android
/// `CallFrames`, read from the media stack's frame cryptor). The app never encrypts media with this: the media stack's
/// own frame cryptor does. It exists so that the format has an executable description with test vectors that another
/// platform can reproduce.
public enum CallFrames {
    public static let tagSize = 16
    public static let ivSize = 12
    /// After the IV: its length (12) and the key index.
    public static let trailerSize = 2
    /// Left in the clear and authenticated: the first byte of an audio frame (for Opus, the TOC byte).
    public static let audioClearSize = 1
    /// What a frame grows by: tag, IV, trailer.
    public static let overhead = tagSize + ivSize + trailerSize
    /// The key index VettID uses: a key ring of one.
    public static let keyIndex: UInt8 = 0
    private static let infoSize = 128
    private static let keySizes = Set(MediaSuite.allCases.map(\.frameKeySize))
    private static let counterModulus: UInt32 = 0xFFFF

    /// The AES-GCM key the frame cryptor derives from a direction key: the first ``MediaSuite/frameKeySize`` bytes of
    /// `HKDF-SHA-256(ikm = material, salt = the suite's frame label, info = 128 zero bytes)`.
    public static func frameKey(_ material: [UInt8], suite: MediaSuite) throws -> [UInt8] {
        try Hkdf.derive(
            ikm: material, salt: Array(suite.frameLabel.utf8), info: [UInt8](repeating: 0, count: infoSize),
            length: suite.frameKeySize
        )
    }

    /// The sender's IV: SSRC, RTP timestamp, and the timestamp minus a per-SSRC frame counter (modulo 65535), each
    /// 32 bits big-endian. The receiver reads the IV from the frame and never recomputes it.
    public static func iv(ssrc: UInt32, timestamp: UInt32, sendCount: UInt32) -> [UInt8] {
        Bytes.uintBE(UInt64(ssrc), 4) + Bytes.uintBE(UInt64(timestamp), 4)
            + Bytes.uintBE(UInt64(timestamp &- (sendCount % counterModulus)), 4)
    }

    /// An encrypted frame: `clear header | ciphertext | tag(16) | IV(12) | 12 | key index`. The header (the first
    /// [clearBytes] of [frame]) is the AEAD's associated data.
    public static func seal(
        frameKey: [UInt8], frame: [UInt8], clearBytes: Int, iv: [UInt8], keyIndex: UInt8 = CallFrames.keyIndex
    ) throws -> [UInt8] {
        guard keySizes.contains(frameKey.count), iv.count == ivSize, (0...frame.count).contains(clearBytes) else {
            throw CryptoError.key("frame sizes")
        }
        let header = Array(frame[0..<clearBytes])
        let box: AES.GCM.SealedBox
        do {
            box = try AES.GCM.seal(
                Data(frame[clearBytes...]), using: SymmetricKey(data: frameKey), nonce: AES.GCM.Nonce(data: iv),
                authenticating: Data(header)
            )
        } catch {
            throw CryptoError.key("frame seal")
        }
        return header + Array(box.ciphertext) + Array(box.tag) + iv + [UInt8(ivSize), keyIndex]
    }

    /// The frame inside [sealed], or nil if it is not a frame encrypted under [frameKey].
    public static func open(frameKey: [UInt8], sealed: [UInt8], clearBytes: Int) -> [UInt8]? {
        let bodyEnd = sealed.count - trailerSize - ivSize
        let shaped = keySizes.contains(frameKey.count) && clearBytes >= 0 && bodyEnd - clearBytes >= tagSize
        guard shaped, sealed[sealed.count - trailerSize] == UInt8(ivSize) else { return nil }
        let iv = Array(sealed[bodyEnd..<bodyEnd + ivSize])
        let header = Array(sealed[0..<clearBytes])
        let tagStart = bodyEnd - tagSize
        do {
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: iv), ciphertext: Data(sealed[clearBytes..<tagStart]),
                tag: Data(sealed[tagStart..<bodyEnd])
            )
            return header + Array(try AES.GCM.open(box, using: SymmetricKey(data: frameKey), authenticating: Data(header)))
        } catch {
            return nil
        }
    }
}
