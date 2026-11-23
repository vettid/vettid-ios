import Foundation
import VettIDCrypto
import VettIDVault

/// TEST ONLY. `leash.item.list` and `leash.item.set` (VAULT-MESSAGING §10.11, ANDROID-PLAN 0.1.137 AA7): the list names one item
/// (`i1`, use only) of the agent asked about; a set answers that item at the next version.
extension FakeVaultService {
    func itemWaysRequest(_ m: Inner, _ body: JsonObject) throws {
        let agent = JsonBuilder.quote((try? body.string("agent_id")) ?? "a1")
        if m.type == "leash.item.list" {
            return try reply(m.type, #"{"items":[{"agent_id":\#(agent),"item_id":"i1","version":1,"ways":["use"]}]}"#, re: m.id)
        }
        let item = JsonBuilder.quote((try? body.string("item_id")) ?? "i1")
        let version = ((try? body.optUint("version", min: 1, max: StrictJson.maxSafeInteger)).flatMap { $0 } ?? 0) + 1
        try reply(m.type, #"{"agent_id":\#(agent),"item_id":\#(item),"version":\#(version),"ways":["use"]}"#, re: m.id)
    }
}
