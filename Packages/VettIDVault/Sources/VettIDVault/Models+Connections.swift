import Foundation
import VettIDCrypto

// Body models of VAULT-MESSAGING §10.4 (connections and invitations). Read from the strict JSON object of the body, so
// that a connection keeps its peer's `profile` as the vault sent it (§10.8, parsed by the data layer). Unknown members
// are ignored (§10.1); a member of another type counts as absent. Mirrors the connection models of vettid-android
// `Models.kt`.

/// A connection (§10.4). `name` and `profile` are the peer's self-asserted values; `alias`, `note`, `tags`, `favorite`
/// and `archived` the owner's own metadata, versioned together (`version` 0 before the first update).
public struct Connection: Sendable {
    public let id: String
    public let kind: String
    public let state: String
    public let name: String
    /// The peer vault's pinned identity key, standard base64.
    public let ik: String
    /// The peer's latest kept `profile.update` body, or the `hs.init` profile before it (§10.4, §10.8).
    public let profile: JsonObject?
    public let createdAt: String?
    public let lastActiveAt: String?
    public let version: Int64
    public let alias: String?
    public let note: String?
    public let tags: [String]
    public let favorite: Bool
    public let archived: Bool
    /// The connection's asks (VAULT-MESSAGING 0.23.0 §10.4.1); nil from an older vault.
    public let asks: ConnectionAsks?

    /// A `<connection>` object; nil without its `id` or `state`.
    public static func of(_ o: JsonObject) -> Connection? {
        guard let id = VaultJSON.string(o, "id"), let state = VaultJSON.string(o, "state") else { return nil }
        let profile: JsonObject? = if case .object(let p)? = o["profile"] { p } else { nil }
        let asks: ConnectionAsks? = if case .object(let a)? = o["asks"] { ConnectionAsks.of(a) } else { nil }
        return Connection(
            id: id, kind: VaultJSON.string(o, "kind") ?? "connection", state: state, name: VaultJSON.string(o, "name") ?? "",
            ik: VaultJSON.string(o, "ik") ?? "", profile: profile, createdAt: VaultJSON.string(o, "created_at"),
            lastActiveAt: VaultJSON.string(o, "last_active_at"), version: VaultJSON.int(o, "version") ?? 0,
            alias: VaultJSON.string(o, "alias"), note: VaultJSON.string(o, "note"), tags: VaultJSON.strings(o, "tags"),
            favorite: VaultJSON.bool(o, "favorite") ?? false, archived: VaultJSON.bool(o, "archived") ?? false, asks: asks
        )
    }
}

/// `<connection>.asks` (§10.4.1, 0.23.0): muted, paused (since `pausedAt`) and the number of cooldowns in force.
public struct ConnectionAsks: Equatable, Sendable {
    public let muted: Bool
    public let paused: Bool
    public let pausedAt: String?
    public let cooldowns: Int

    static func of(_ o: JsonObject) -> ConnectionAsks {
        ConnectionAsks(
            muted: VaultJSON.bool(o, "muted") ?? false, paused: VaultJSON.bool(o, "paused") ?? false,
            pausedAt: VaultJSON.string(o, "paused_at"), cooldowns: Int(clamping: VaultJSON.int(o, "cooldowns") ?? 0)
        )
    }
}

/// `connection.invite.create`'s answer (§10.4): [link] is the bare payload (§6.4) to show as a QR code or share; [exp]
/// RFC 3339 in whole seconds.
public struct Invite: Equatable, Sendable {
    public let inviteID: String
    public let link: String
    public let exp: String
    public let remote: Bool
}

/// `connection.invite.accept`'s answer (§10.4, 0.10.3): an outgoing request in state `waiting`, whose safety code follows
/// in `connection.request.outgoing` once the handshake has run. [name] is the bundle's `hint.name`.
public struct AcceptedInvite: Equatable, Sendable {
    public let connectionID: String
    public let state: String
    public let remote: Bool
    public let exp: String?
    public let name: String?
}

/// What `connection.update` changes (§10.4): at least one member; `""` clears [alias] or [note]; [tags] replaces the list.
public struct ConnectionMetaChange: Equatable, Sendable {
    public var alias: String?
    public var note: String?
    public var tags: [String]?
    public var favorite: Bool?
    public var archived: Bool?

    public init(alias: String? = nil, note: String? = nil, tags: [String]? = nil, favorite: Bool? = nil, archived: Bool? = nil) {
        self.alias = alias
        self.note = note
        self.tags = tags
        self.favorite = favorite
        self.archived = archived
    }

    public var isEmpty: Bool { alias == nil && note == nil && tags == nil && favorite == nil && archived == nil }
}

public extension VaultJSON {
    /// The string elements of the array [k]; empty when absent or not an array.
    static func strings(_ o: JsonObject, _ k: String) -> [String] {
        guard case .array(_, let items)? = o[k] else { return [] }
        return items.compactMap { try? $0.asString() }
    }

    /// The object elements of the array [k]; empty when absent or not an array.
    static func objects(_ o: JsonObject, _ k: String) -> [JsonObject] {
        guard case .array(_, let items)? = o[k] else { return [] }
        return items.compactMap { try? $0.asObject() }
    }

    /// The object member [k]; nil when absent or not an object.
    static func obj(_ o: JsonObject, _ k: String) -> JsonObject? {
        if case .object(let v)? = o[k] { return v }
        return nil
    }
}
