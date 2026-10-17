/// An `identity.rotate` statement (§3.4), one link of a rotation chain:
///
/// ```
/// {"v":1,"suite":2,"old_ik","new_ik","new_kem","sig_old","sig_new"}
/// m       = old_ik (32) || new_ik (32) || new_kem (1216)
/// sig_old = Ed25519(old_ik, "vettid/vms/2/rotate" || m)
/// sig_new = Ed25519(new_ik, "vettid/vms/2/rotate" || m)
/// ```
///
/// Mirrors vettid-android `Rotation`.
public struct Rotation: Sendable {
    public let oldIk: [UInt8]
    public let newIk: [UInt8]
    public let newKem: KemPublicKey
    let sigOld: [UInt8]
    let sigNew: [UInt8]

    public init(oldIk: [UInt8], newIk: [UInt8], newKem: KemPublicKey, sigOld: [UInt8], sigNew: [UInt8]) {
        self.oldIk = oldIk
        self.newIk = newIk
        self.newKem = newKem
        self.sigOld = sigOld
        self.sigNew = sigNew
    }

    private var message: [UInt8] { oldIk + newIk + newKem.bytes }

    /// Checks both signatures and that the keys differ.
    public func verify() throws {
        guard oldIk.count == Suite.ed25519PublicSize, newIk.count == Suite.ed25519PublicSize, !Ed25519.equalPublic(oldIk, newIk),
              Ed25519.verify(oldIk, label: Labels.rotate, message, sigOld),
              Ed25519.verify(newIk, label: Labels.rotate, message, sigNew)
        else { throw CryptoError.signature("rotation") }
    }

    public func marshal() -> String {
        JsonBuilder()
            .uint("v", 1)
            .uint("suite", UInt64(Suite.suite2))
            .base64("old_ik", oldIk)
            .base64("new_ik", newIk)
            .base64("new_kem", newKem.bytes)
            .base64("sig_old", sigOld)
            .base64("sig_new", sigNew)
            .build()
    }

    /// Signs a rotation from [old] to [new], announcing [newKem].
    public static func create(old: Ed25519PrivateKey, new: Ed25519PrivateKey, newKem: KemPublicKey) throws -> Rotation {
        guard !Ed25519.equalPublic(old.publicKey, new.publicKey) else { throw CryptoError.signature("rotation") }
        let m = old.publicKey + new.publicKey + newKem.bytes
        return Rotation(
            oldIk: old.publicKey,
            newIk: new.publicKey,
            newKem: newKem,
            sigOld: try old.sign(label: Labels.rotate, m),
            sigNew: try new.sign(label: Labels.rotate, m)
        )
    }

    /// Parses strictly; does not verify.
    public static func parse(_ o: JsonObject) throws -> Rotation {
        _ = try o.uint("v", min: 1, max: 1)
        try Suite.check(Int(try o.uint("suite", min: 0, max: 255)), pinned: 0)
        return Rotation(
            oldIk: try o.base64("old_ik", Suite.ed25519PublicSize),
            newIk: try o.base64("new_ik", Suite.ed25519PublicSize),
            newKem: try KemPublicKey.parse(try o.base64("new_kem", Suite.ekSize)),
            sigOld: try o.base64("sig_old", Suite.ed25519SignatureSize),
            sigNew: try o.base64("sig_new", Suite.ed25519SignatureSize)
        )
    }

    /// Follows a chain from a stored identity key (§3.4, §6.6): each link's old_ik equals the current key and both
    /// signatures verify; at most 32 links. Returns the final ik and the KEM key of the last link (nil for an empty
    /// chain, which resolves to [start]).
    public static func resolveChain(_ start: [UInt8], _ chain: [Rotation]) throws -> (ik: [UInt8], kem: KemPublicKey?) {
        guard start.count == Suite.ed25519PublicSize, chain.count <= HsLimits.maxRotations else {
            throw CryptoError.signature("rotation chain")
        }
        var cur = start
        var kem: KemPublicKey?
        for r in chain {
            try r.verify()
            guard Ed25519.equalPublic(r.oldIk, cur) else { throw CryptoError.signature("rotation chain") }
            cur = r.newIk
            kem = r.newKem
        }
        return (cur, kem)
    }
}
