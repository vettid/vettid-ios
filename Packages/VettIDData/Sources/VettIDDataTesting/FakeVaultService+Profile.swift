#if DEBUG
import Foundation
import VettIDCrypto
import VettIDTesting

/// TEST ONLY. The member's own profile object as the fake vault keeps it (VAULT-MESSAGING §10.8).
struct FakeProfile {
    var version: UInt64 = 0
    var name = ""
    var photo: [UInt8] = []
    var sets: [FakeVaultService.ProfileSetSeen] = []
}

// TEST ONLY. The shared profile as vettid-vault answers it (VAULT-MESSAGING §10.8, `features/items/profile.go`):
// `profile.get` with the profile object and the read-only core (the names of the stored account snapshot, the vault's
// identity key); `profile.set` checked in vettid-vault's order (the version's form, the core refused, the display name of
// at most 128 bytes, the photo a JPEG or PNG of at most 65,536 bytes, then the version against the current one), with
// `sync.event{profile.changed}`.
extension FakeVaultService {
    /// §10.8: at most 65,536 bytes of image, a display name of at most 128 bytes.
    static let maxProfilePhoto = 65_536
    static let maxDisplayName = 128

    /// What the vault received in one `profile.set`: the members present ([photo] decoded; empty for `""`).
    public struct ProfileSetSeen: Sendable {
        public let version: UInt64
        public let name: String?
        public let photo: [UInt8]?
    }

    public var profileSets: [ProfileSetSeen] { locked { profile.sets } }
    /// The profile object's photo as the vault keeps it (empty: none).
    public var profilePhoto: [UInt8] { locked { profile.photo } }
    public var profileName: String { locked { profile.name } }
    public var profileVersion: UInt64 { locked { profile.version } }

    /// The profile object changed on another of the member's devices: [name] and [photo] stored, a new version, and
    /// `sync.event{profile.changed}` when the vault is open.
    public func profileChangedElsewhere(name: String? = nil, photo: [UInt8]? = nil) {
        locked {
            if let name { profile.name = name }
            if let photo { profile.photo = photo }
            profile.version += 1
            if vaultOpen { try? reply("sync.event", #"{"kind":"profile.changed","version":\#(profile.version)}"#) }
        }
    }

    // MARK: - The requests (callers hold ``cond``)

    func profileRequest(_ m: Inner, _ body: JsonObject) throws {
        if m.type == "profile.get" { try profileGet(m) } else { try profileSet(m, body) }
    }

    func profileGet(_ m: Inner) throws {
        let b = JsonBuilder().uint("version", profile.version)
        if !profile.name.isEmpty { b.string("name", profile.name) }
        if !profile.photo.isEmpty { b.base64("photo", profile.photo) }
        if let names = snapshotNames() { b.string("first_name", names.first).string("last_name", names.last) }
        try reply(m.type, b.base64("ik", ik.publicKey).build(), re: m.id)
    }

    func profileSet(_ m: Inner, _ body: JsonObject) throws {
        guard let version = try? body.uint("version", min: 0, max: StrictJson.maxSafeInteger) else {
            return try reply(m.type, "{}", re: m.id, error: "bad_request")
        }
        // §10.8 (0.18.0): the core is read-only.
        if body.has("first_name") || body.has("last_name") || body.has("ik") {
            return try reply(m.type, "{}", re: m.id, error: "bad_request")
        }
        var displayName: String?
        if body.has("name") {
            guard let n = try? body.string("name"), n.utf8.count <= Self.maxDisplayName else {
                return try reply(m.type, "{}", re: m.id, error: "bad_request")
            }
            displayName = n
        }
        guard let photo = Self.photo(body) else { return try reply(m.type, "{}", re: m.id, error: "bad_request") }
        profile.sets.append(ProfileSetSeen(version: version, name: displayName, photo: photo))
        guard version == profile.version else { return try reply(m.type, "{}", re: m.id, error: "conflict") }
        if let displayName { profile.name = displayName }
        if let photo { profile.photo = photo }
        profile.version += 1
        try reply("sync.event", #"{"kind":"profile.changed","version":\#(profile.version)}"#)
        try reply(m.type, JsonBuilder().uint("version", profile.version).build(), re: m.id)
    }

    /// `profile.set`'s photo as vettid-vault's `parsePhoto`: `.some(nil)` when absent, `[]` for `""` (removes it), the image
    /// (a JPEG or PNG of at most 65,536 bytes); nil when it breaks the rule.
    static func photo(_ body: JsonObject) -> [UInt8]?? {
        guard body.has("photo") else { return .some(nil) }
        guard let text = try? body.string("photo") else { return nil }
        if text.isEmpty { return .some([]) }
        guard let b = try? Base64s.decodeStd(text), b.count <= maxProfilePhoto, isImage(b) else { return nil }
        return .some(b)
    }

    /// A JPEG or a PNG by its first bytes, as vettid-vault's `isImage`.
    static func isImage(_ b: [UInt8]) -> Bool {
        b.starts(with: [0xFF, 0xD8, 0xFF]) || b.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    }

    /// The names of the stored account snapshot (the shared profile's core), when it has both.
    private func snapshotNames() -> (first: String, last: String)? {
        guard let json = snapshotJSON, let o = try? StrictJson.parseObject(json),
              let first = try? o.string("first_name"), let last = try? o.string("last_name") else { return nil }
        return (first, last)
    }
}
#endif
