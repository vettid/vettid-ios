/// The §6.3 key schedule of one handshake:
///
/// ```
/// th1      = SHA-256("vettid/vms/2/th1" || env_init)
/// th       = SHA-256("vettid/vms/2/th"  || env_init || resp_header)
/// prk      = HKDF-Extract(salt = "vettid/vms/2/session", ikm = K_e || K_s)
/// k_i2r    = HKDF-Expand(prk, "vettid/vms/2/i2r" || th, 32)      … and r2i, kids, rk, epoch_id
/// sas_commit = SHA-256("vettid/vms/2/sas-commit" || n_I)       # in hs.init
/// sas      = uint32be(HKDF-Expand(prk, "vettid/vms/2/sas" || th || n_I || n_R, 4)) mod 1e6   # 0.10.3
/// ```
///
/// Secret; ``destroy()`` wipes it. Mirrors vettid-android `Schedule`.
public final class Schedule: @unchecked Sendable, CustomStringConvertible {
    public let th1: [UInt8]
    public let th: [UInt8]
    private(set) var prk: [UInt8]
    private(set) var kI2R: [UInt8]
    private(set) var kR2I: [UInt8]
    public let kidI2R: Kid
    public let kidR2I: Kid
    private(set) var rk: [UInt8]
    public let epochID: [UInt8]

    init(th1: [UInt8], th: [UInt8], prk: [UInt8], kI2R: [UInt8], kR2I: [UInt8], kidI2R: Kid, kidR2I: Kid, rk: [UInt8], epochID: [UInt8]) {
        self.th1 = th1
        self.th = th
        self.prk = prk
        self.kI2R = kI2R
        self.kR2I = kR2I
        self.kidI2R = kidI2R
        self.kidR2I = kidR2I
        self.rk = rk
        self.epochID = epochID
    }

    public func destroy() {
        Bytes.wipe(&prk)
        Bytes.wipe(&kI2R)
        Bytes.wipe(&kR2I)
        Bytes.wipe(&rk)
    }

    public var description: String { "Schedule[redacted]" }

    /// The persistent form of a responder awaiting hs.fin (``Responder/export()``). Contains secrets.
    @discardableResult
    func export(_ b: JsonBuilder) -> JsonBuilder {
        b.base64("th1", th1).base64("th", th).base64("prk", prk).base64("k_i2r", kI2R).base64("k_r2i", kR2I)
            .base64("kid_i2r", kidI2R.bytes).base64("kid_r2i", kidR2I.bytes).base64("rk", rk).base64("epoch_id", epochID)
    }

    /// Runs §6.3 from K_s, K_e and the transcript hashes.
    public static func derive(ks: [UInt8], ke: [UInt8], th1: [UInt8], th: [UInt8]) throws -> Schedule {
        guard ks.count == Suite.keySize, ke.count == Suite.keySize else { throw CryptoError.key("schedule key size") }
        var ikm = ke + ks
        let prk = Hkdf.extract(salt: Array(Labels.session.utf8), ikm: ikm)
        Bytes.wipe(&ikm)
        func expand(_ label: String, _ n: Int) throws -> [UInt8] { try Hkdf.expand(prk: prk, info: Array(label.utf8) + th, length: n) }
        return Schedule(
            th1: th1,
            th: th,
            prk: prk,
            kI2R: try expand(Labels.i2r, Suite.keySize),
            kR2I: try expand(Labels.r2i, Suite.keySize),
            kidI2R: try Kid(try expand(Labels.kidI2R, Suite.kidSize)),
            kidR2I: try Kid(try expand(Labels.kidR2I, Suite.kidSize)),
            rk: try expand(Labels.rk, Suite.keySize),
            epochID: try expand(Labels.epoch, Suite.epochIDSize)
        )
    }

    public static func th1(_ envInit: [UInt8]) -> [UInt8] { Bytes.labeledHash(Labels.th1, envInit) }

    /// [respHeader] is hs.resp bytes[0:1140].
    public static func th(_ envInit: [UInt8], _ respHeader: [UInt8]) -> [UInt8] { Bytes.labeledHash(Labels.th, envInit, respHeader) }

    /// The commitment to the initiator's SAS nonce (§6.3, 0.10.3): SHA-256("vettid/vms/2/sas-commit" || n_I).
    public static func sasCommit(_ nI: [UInt8]) -> [UInt8] { Bytes.labeledHash(Labels.sasCommit, nI) }

    /// Whether [nI] opens [commit], in constant time.
    public static func checkSasCommit(_ commit: [UInt8], _ nI: [UInt8]) -> Bool {
        nI.count == HsLimits.sasNonceSize && Bytes.constantTimeEquals(sasCommit(nI), commit)
    }

    /// The short authentication string (§6.3, 0.10.3): uint32be(HKDF-Expand(prk, "vettid/vms/2/sas" || th || n_I || n_R,
    /// 4)) mod 1,000,000, as 6 zero-padded digits. It exists only once both nonces are fixed.
    public static func sas(prk: [UInt8], th: [UInt8], nI: [UInt8], nR: [UInt8]) throws -> String {
        guard prk.count == Suite.keySize else { throw CryptoError.key("sas key size") }
        guard nI.count == HsLimits.sasNonceSize, nR.count == HsLimits.sasNonceSize else { throw CryptoError.format("sas nonce") }
        let b = try Hkdf.expand(prk: prk, info: Array(Labels.sas.utf8) + th + nI + nR, length: 4)
        let v = String(Bytes.readUintBE(b, 0, 4) % 1_000_000)
        return String(repeating: "0", count: 6 - v.count) + v
    }

    public static func signResp(_ ikR: Ed25519PrivateKey, th: [UInt8]) throws -> [UInt8] { try ikR.sign(label: Labels.sigResp, th) }

    public static func signFin(_ ikI: Ed25519PrivateKey, th: [UInt8]) throws -> [UInt8] { try ikI.sign(label: Labels.sigFin, th) }

    public static func verifyResp(_ ikR: [UInt8], th: [UInt8], sig: [UInt8]) -> Bool { Ed25519.verify(ikR, label: Labels.sigResp, th, sig) }

    public static func verifyFin(_ ikI: [UInt8], th: [UInt8], sig: [UInt8]) -> Bool { Ed25519.verify(ikI, label: Labels.sigFin, th, sig) }
}
