import Foundation
import VettIDCrypto

/// `profile.get` (VAULT-MESSAGING §10.8): the profile object (the display [name], absent as "", and the [photo], the
/// standard base64 of a JPEG or PNG) and the shared profile's read-only core: the account's [firstName] and [lastName]
/// from the vault's snapshot and the vault's [ik]. The core is nil from a vault before 0.18.0. Never printed with its
/// photo. Mirrors vettid-android `Profile`.
public struct Profile: Equatable, Sendable, CustomStringConvertible {
    public var version: UInt64
    public var name: String
    public var photo: String?
    public var firstName: String?
    public var lastName: String?
    public var ik: String?

    public init(
        version: UInt64 = 0, name: String = "", photo: String? = nil, firstName: String? = nil, lastName: String? = nil,
        ik: String? = nil
    ) {
        self.version = version
        self.name = name
        self.photo = photo
        self.firstName = firstName
        self.lastName = lastName
        self.ik = ik
    }

    public var description: String { "Profile(version: \(version), photo: \(photo == nil ? "none" : "set"))" }
}

// The member's own shared profile (VAULT-MESSAGING §10.8): the profile object and the read-only core.
extension VaultApi {
    public static let typeProfileGet = "profile.get"
    public static let typeProfileSet = "profile.set"

    /// `profile.get`. Mirrors vettid-android `VaultApi.profileGet`.
    public func profileGet() async throws -> Profile {
        let o = try StrictJson.parseObject(try await device.op(Self.typeProfileGet))
        return Profile(
            version: try o.optUint("version", min: 0, max: StrictJson.maxSafeInteger) ?? 0,
            name: try o.optString("name") ?? "",
            photo: try o.optString("photo"),
            firstName: try o.optString("first_name"),
            lastName: try o.optString("last_name"),
            ik: try o.optString("ik")
        )
    }

    /// `profile.set` against [version]: [name] or [photo] `""` removes it, nil leaves it out. Never names the core
    /// (`first_name`, `last_name`, `ik`): it is read-only and the vault refuses it with `bad_request` (§10.8). Returns the
    /// new version (`conflict` when the profile changed meanwhile). Mirrors vettid-android `VaultApi.profileSet`.
    public func profileSet(version: UInt64, name: String? = nil, photo: String? = nil) async throws -> UInt64 {
        let b = JsonBuilder().uint("version", version)
        if let name { b.string("name", name) }
        if let photo { b.string("photo", photo) }
        let o = try StrictJson.parseObject(try await device.op(Self.typeProfileSet, body: b.bytes()))
        return try o.optUint("version", min: 0, max: StrictJson.maxSafeInteger) ?? 0
    }
}
