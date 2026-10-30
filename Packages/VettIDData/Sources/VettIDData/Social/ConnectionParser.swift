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
        return r
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

    /// An entry of `connection.invite.list`; nil without its `invite_id`.
    static func invite(_ o: JsonObject) -> OutstandingInvite? {
        guard let id = VaultJSON.string(o, "invite_id") else { return nil }
        return OutstandingInvite(inviteID: id, exp: instant(VaultJSON.string(o, "exp")), remote: VaultJSON.bool(o, "remote") ?? false)
    }
}
