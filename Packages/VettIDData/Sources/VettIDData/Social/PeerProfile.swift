import Foundation
import VettIDCrypto
import VettIDVault

/// A peer's shared profile as the vault keeps it (VAULT-MESSAGING 0.18.0 §10.4, §10.8): the kept `profile.update`
/// `{version, first_name, last_name, ik, name?, photo?, items}` or, on the inviter's side before the first update and in
/// a connection request, the `hs.init` profile `{first_name, last_name, name?}` (§6.2).
///
/// Parsed strictly: the core names must be 1–160 UTF-8 bytes without control characters, and `ik`, when present, the
/// base64 of 32 bytes; a profile that breaks the core rules yields no names (the title falls back to "Name not shared
/// yet"), never a partial one. The display name, photo and items are self-asserted extras. Mirrors vettid-android
/// `PeerProfile`.
public struct PeerProfile: Equatable, Sendable {
    public var firstName: String?
    public var lastName: String?
    public var displayName: String?
    public var hasPhoto: Bool
    public var items: [SharedProfileItem]
    /// The peer's photo as sent (base64; the UI decodes it defensively and falls back to the initial).
    public var photo: String?

    public var accountName: String? { AccountNames.full(firstName, lastName) }

    /// The display name's limit (§10.8: at most 128 bytes).
    static let maxDisplayNameBytes = 128
    /// Base64 of the photo limit (§10.8: 65,536 bytes of image); a longer one is not kept.
    static let maxPhotoChars = 87_384

    /// Nil for an absent profile.
    public static func parse(_ p: JsonObject?) -> PeerProfile? {
        guard let p else { return nil }
        let coreOK = coreValid(p)
        let photo = VaultJSON.string(p, "photo")
        return PeerProfile(
            firstName: coreOK ? VaultJSON.string(p, "first_name") : nil,
            lastName: coreOK ? VaultJSON.string(p, "last_name") : nil,
            displayName: displayNameOf(p),
            hasPhoto: photo?.isEmpty == false,
            items: itemsOf(p),
            photo: photo.flatMap { !$0.isEmpty && $0.count <= maxPhotoChars ? $0 : nil }
        )
    }

    /// "First Last" of [p] when its core is complete and valid.
    public static func accountName(_ p: JsonObject?) -> String? { parse(p)?.accountName }

    /// The non-empty display name of [p].
    public static func displayName(_ p: JsonObject?) -> String? { p.flatMap(displayNameOf) }

    /// Both names present and valid; `ik`, if present, the base64 of 32 bytes.
    private static func coreValid(_ p: JsonObject) -> Bool {
        guard AccountNames.isValidCore(VaultJSON.string(p, "first_name")), AccountNames.isValidCore(VaultJSON.string(p, "last_name")) else {
            return false
        }
        guard p.has("ik") else { return true }
        guard let ik = VaultJSON.string(p, "ik") else { return false }
        return (try? Base64s.decodeStd(ik, IkFingerprint.ikSize)) != nil
    }

    private static func displayNameOf(_ p: JsonObject) -> String? {
        guard let n = VaultJSON.string(p, "name"), !n.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              n.utf8.count <= maxDisplayNameBytes
        else { return nil }
        return n
    }

    private static func itemsOf(_ p: JsonObject) -> [SharedProfileItem] {
        VaultJSON.objects(p, "items").compactMap { o in
            guard let id = VaultJSON.string(o, "item_id") else { return nil }
            let fields = VaultJSON.objects(o, "fields").compactMap { f -> SharedProfileItem.Field? in
                guard let label = VaultJSON.string(f, "label"), let value = fieldValue(f) else { return nil }
                return SharedProfileItem.Field(label, value)
            }
            return SharedProfileItem(itemID: id, name: VaultJSON.string(o, "name") ?? "", fields: fields)
        }
    }

    /// A string value; an address object is shown by its non-blank text members, joined.
    private static func fieldValue(_ f: JsonObject) -> String? {
        if let s = VaultJSON.string(f, "value") { return s }
        guard let o = VaultJSON.obj(f, "value") else { return nil }
        let parts = o.members.compactMap { m -> String? in
            guard case .string(_, let v) = m.value, !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return v
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}
