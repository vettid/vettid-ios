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
}
