import Foundation
import VettIDCrypto
import VettIDVault

/// Turns the vault's connection bodies (VAULT-MESSAGING §10.4) into the app's models. Bodies come from the member's own
/// vault inside an authenticated session; unknown members are ignored (§10.1) and a body missing a required member
/// yields nil. Mirrors the connection part of vettid-android `ApprovalParser`.
public enum ConnectionParser {
    /// RFC 3339, with or without fractional seconds.
    public static func instant(_ s: String?) -> Date? { OwnerCheckManager.instant(s) }

    /// A safety code as §6.3 shows it: six ASCII digits.
    static func sas(_ s: String?) -> String? {
        guard let s, s.utf8.count == 6, s.utf8.allSatisfy({ (0x30...0x39).contains($0) }) else { return nil }
        return s
    }

    /// `connection.request.pending`, or an entry of `connection.request.list`'s `incoming`: approve after comparing the
    /// safety code. Nil without a `pending_id` or a well-formed `sas`.
    public static func incoming(_ o: JsonObject, at: Date) -> ConnectionRequest? {
        guard let id = VaultJSON.string(o, "pending_id"), let sas = sas(VaultJSON.string(o, "sas")) else { return nil }
        let profile = VaultJSON.obj(o, "profile")
        let name = PeerProfile.accountName(profile)
        var r = ConnectionRequest(
            pendingID: id, sas: sas, remote: VaultJSON.bool(o, "remote") ?? false, name: name,
            receivedAt: instant(VaultJSON.string(o, "created_at")) ?? at,
            exp: instant(VaultJSON.string(o, "exp")) ?? at.addingTimeInterval(connectionRequestTtl)
        )
        r.inviteID = VaultJSON.string(o, "invite_id")
        r.introducedBy = VaultJSON.string(o, "introduced_by")
        r.state = RequestState.of(VaultJSON.string(o, "state"))
        r.peerApproved = VaultJSON.bool(o, "peer_approved") ?? false
        r.displayName = PeerProfile.displayName(profile).flatMap { $0 == name ? nil : $0 }
        return r
    }

    /// `connection.request.outgoing` (the SAS is known), or an entry of `connection.request.list`'s `outgoing` (0.10.3):
    /// without a well-formed `sas` the request is `waiting`, whatever its `state` says. Nil without a `connection_id`.
    public static func outgoing(_ o: JsonObject, at: Date) -> OutgoingRequest? {
        guard let id = VaultJSON.string(o, "connection_id") else { return nil }
        let sas = sas(VaultJSON.string(o, "sas"))
        let wire = RequestState.of(VaultJSON.string(o, "state"))
        let state: RequestState = sas == nil ? .waiting : (wire == .waiting ? .pending : wire)
        var r = OutgoingRequest(
            connectionID: id, sas: sas, remote: VaultJSON.bool(o, "remote") ?? false,
            name: VaultJSON.string(o, "name").flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 },
            state: state, receivedAt: instant(VaultJSON.string(o, "created_at")) ?? at,
            exp: instant(VaultJSON.string(o, "exp"))
        )
        r.peerApproved = VaultJSON.bool(o, "peer_approved") ?? false
        r.introducedBy = VaultJSON.string(o, "introduced_by")
        r.isService = VaultJSON.string(o, "peer_kind") == "service"
        if sas != nil { r.ik = ik(VaultJSON.string(o, "ik")) }
        return r
    }

    /// An outgoing request's `ik` (0.83.7 §10.4): canonical standard base64 of 32 bytes (§5.3), decoded as the connection's
    /// `ik` is (§10.8). Anything else (another alphabet, no or extra padding, non-zero trailing bits, a line break, another
    /// length) is nil: the request is shown as without an `ik`, not refused, since the fingerprint is an extra check and
    /// the safety code still decides (chosen; not in the spec).
    static func ik(_ s: String?) -> [UInt8]? {
        guard let s else { return nil }
        return try? Base64s.decodeStd(s, IkFingerprint.ikSize)
    }

    /// A `<connection>` (§10.4) with its peer's profile (§10.8): the title's names from the profile's core, the display
    /// name from the profile or, before it, the connection's `name`.
    public static func connection(_ c: Connection) -> ConnectionInfo {
        let p = PeerProfile.parse(c.profile)
        var i = ConnectionInfo(id: c.id, name: p?.displayName ?? c.name, state: .of(c.state))
        i.favorite = c.favorite
        i.archived = c.archived
        i.tags = c.tags
        i.version = c.version
        i.firstName = p?.firstName
        i.lastName = p?.lastName
        i.sharedItems = p?.items ?? []
        i.hasPhoto = p?.hasPhoto ?? false
        i.photo = p?.photo
        i.keyFingerprint = IkFingerprint.formatB64(c.ik)
        i.createdAt = instant(c.createdAt)
        i.lastActiveAt = instant(c.lastActiveAt)
        i.asks = c.asks.map {
            AskState(muted: $0.muted, paused: $0.paused, pausedAt: instant($0.pausedAt), cooldowns: max($0.cooldowns, 0))
        }
        i.isService = c.peerKind == "service"
        return i
    }

    /// The `key` member of a `connection.authenticate.list` state, `.result` or `connection.authenticate.key` body
    /// (VAULT-MESSAGING 0.88.1 §10.4): returned as sent when it is canonical standard base64 of exactly 32 bytes (an
    /// Ed25519 public key, §5.3), else nil. Only the encoding and the length are checked: the app does no cryptography
    /// with it (the vault verified the signatures and follows the rotation chains).
    public static func credentialKey(_ o: JsonObject) -> String? {
        guard let k = VaultJSON.string(o, "key"), (try? Base64s.decodeStd(k, 32)) != nil else { return nil }
        return k
    }

    /// One state of `connection.authenticate.list`; nil without its `connection_id`. A malformed `key` is dropped and the
    /// rest kept.
    static func authState(_ o: JsonObject) -> AuthenticationState? {
        guard let id = VaultJSON.string(o, "connection_id") else { return nil }
        return AuthenticationState(
            connectionID: id, verifiedAt: instant(VaultJSON.string(o, "verified_at")), lastResult: VaultJSON.string(o, "last_result"),
            lastAt: instant(VaultJSON.string(o, "last_at")), key: credentialKey(o)
        )
    }

    /// A `connection.authenticate.result` body over the state [previous] (nil without its `connection_id`).
    ///
    /// Only a successful verdict (`authenticated: true`) speaks about the key. Its `key_changed` decides the warning: true
    /// when the key was not the pinned one and the pin did not lead to it (§10.4); false or absent otherwise, including a
    /// response whose `rotations` the vault followed. Its `key`, when sent and well formed, is the key the vault now has
    /// pinned; an absent or malformed one leaves the previous key.
    ///
    /// A `key_changed` that is present but not a boolean decides nothing: the held value stays (it fails closed).
    ///
    /// A failed verdict (`denied`, `bad_signature`) carries no evidence about the key: it keeps the previous `keyChanged`
    /// and `key`. Otherwise the party a key-change warning is about could erase it by declining the member's next
    /// request, and a `key` sent with a failure (which the spec does not define) could pass for a pinned one. A missing
    /// `authenticated` counts as a failure, never as a success.
    static func authResult(_ o: JsonObject, now: Date, previous: AuthenticationState?) -> AuthenticationState? {
        guard let id = VaultJSON.string(o, "connection_id") else { return nil }
        let ok = VaultJSON.bool(o, "authenticated") ?? false
        var s = previous ?? AuthenticationState(connectionID: id)
        if ok {
            s.verifiedAt = now
            s.lastResult = "authenticated"
            // Absent is false, as §10.4 gives it. Present but not a boolean fails closed: the held value stays.
            if let changed = VaultJSON.bool(o, "key_changed") {
                s.keyChanged = changed
            } else if !o.has("key_changed") {
                s.keyChanged = false
            }
            s.key = credentialKey(o) ?? s.key
        } else {
            s.lastResult = VaultJSON.string(o, "reason") ?? "denied"
        }
        s.lastAt = now
        return s
    }

    /// An entry of `connection.invite.list`; nil without its `invite_id`.
    static func invite(_ o: JsonObject) -> OutstandingInvite? {
        guard let id = VaultJSON.string(o, "invite_id") else { return nil }
        return OutstandingInvite(inviteID: id, exp: instant(VaultJSON.string(o, "exp")), remote: VaultJSON.bool(o, "remote") ?? false)
    }
}
