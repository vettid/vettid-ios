import Foundation
import VettIDCrypto

// The requests of "Devices & agents" (ANDROID-PLAN 0.1.53 AA1 and AA2; VAULT-MESSAGING §10.3, §10.11) beside the device calls of
// ``VaultApi``. None signs and none needs the unlock window. The bodies are returned as the vault sent them; VettIDData
// reads them. Mirrors vettid-android `DevicesApi.kt`.
extension VaultApi {
    /// `device.list{}` (§10.3) as the vault sent it, so that the reader can drop a bad entry and keep the rest: ``deviceList()``
    /// decodes strictly and fails the whole list on one, and lacks `profile`.
    public func deviceListBody() async throws -> JsonObject {
        VaultJSON.object(try await device.op("device.list", body: VaultJSON.empty))
    }

    /// `leash.grant.list{agent_id?}` (§10.11): `{grants, suspended}`. The app reads it for an agent's grants and, without
    /// [agentID] (no `agent_id` key at all), for the agents the vault paused (`suspended`, agent ids). Grants carry more
    /// than the app reads; callers read only what they show.
    public func leashGrantList(agentID: String? = nil) async throws -> JsonObject {
        let b = JsonBuilder()
        if let agentID { b.string("agent_id", agentID) }
        return VaultJSON.object(try await device.op("leash.grant.list", body: b.bytes()))
    }

    /// `device.pair.create{role}` with [role] `agent` or `desktop` (§10.3; "Pair a desktop", owner decision 2026-11-05) as the
    /// vault sent it: `{pairing_id, link, exp}`, the link a bare pairing payload (§6.4). Never `app` (that is a transfer,
    /// §6.7.1): any other role is refused here and nothing is sent. The caller reads and checks the answer. Mirrors vettid-android
    /// `devicePairCreate`; the approval and the rejection are ``pairApprove(_:sessionSeconds:)`` (which never carries `grants`,
    /// so it needs no unlock window) and ``pairReject(_:)``.
    public func devicePairCreate(role: String) async throws -> JsonObject {
        guard role == "agent" || role == "desktop" else { throw VaultStateError(message: "pairing role") }
        return VaultJSON.object(try await device.op("device.pair.create", body: JsonBuilder().string("role", role).bytes()))
    }

    /// `leash.item.list{agent_id, item_id?}` (§10.11, ANDROID-PLAN 0.1.137 AA7): `{items: [<item_ways>]}`, each item the agent's
    /// rules include, as the body's bytes (`{}` when empty). Mirrors vettid-android `leashItemList` over
    /// `VaultDevice.opRaw`; here ``VaultDevice/op(_:body:timeout:innerID:)`` already returns the body's bytes, and a reply with
    /// a duplicate member is refused when the reply is read (``StrictJson``), before it gets here.
    public func leashItemList(agentID: String, itemID: String? = nil) async throws -> [UInt8] {
        let b = JsonBuilder().string("agent_id", agentID)
        if let itemID { b.string("item_id", itemID) }
        return try await device.op("leash.item.list", body: b.bytes())
    }

    /// `leash.item.set{agent_id, item_id, version?, ways, run?, proxy?}` (§10.11): [body] is sent as it is; the `<item_ways>`
    /// saved comes back as the body's bytes. A widening outside the unlock window is `credential_locked`.
    public func leashItemSet(_ body: [UInt8]) async throws -> [UInt8] {
        try await device.op("leash.item.set", body: body)
    }
}
