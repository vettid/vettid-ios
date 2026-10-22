import Foundation
import Testing
@testable import VettIDVault
import VettIDCrypto

// Fixtures (JSON bodies of the fake vault) stay on one line each.
// swiftlint:disable line_length

/// The share rule and grant calls (VAULT-MESSAGING §10.12) against the fake vault: the request bodies as vettid-vault
/// `features/items` and `features/grants` read them, and the fetch's `grant.value`, sealed to the fetch's one-time key.
@Suite struct SharingOpsTests {
    let ops = CredentialOpsTests()

    func body(_ req: Inner) -> String { String(bytes: req.body, encoding: .utf8) ?? "" }

    @Test func ruleSetDeleteAndThePendingList() async throws {
        let (d, v) = try await ops.base.pairedDevice()
        let api = VaultApi(device: d)
        let rule = try StrictJson.parseObject(#"{"subject":{"connection_id":"c1"},"tags":["medical"],"match":"any","access":"read","mode":"ask","include_existing":true,"dry_run":true}"#)
        let set = Task { try await api.shareRuleSet(rule) }
        var req = try await ops.answer(v, d, "share.rule.set", #"{"matches":[{"item_id":"i1","name":"A","category":"other","sensitivity":"data","outcome":"ask"}],"total":1}"#)
        #expect(body(req) == rule.raw)
        #expect(VaultJSON.objects(try await set.value, "matches").count == 1)

        let delete = Task { try await api.shareRuleDelete("01RULE") }
        req = try await ops.answer(v, d, "share.rule.delete", "{}")
        #expect(body(req) == #"{"rule_id":"01RULE"}"#)
        try await delete.value

        let all = Task { try await api.sharePendingList(after: "01R1|01I1", limit: 500) }
        req = try await ops.answer(v, d, "share.pending.list", #"{"pending":[]}"#)
        #expect(body(req) == #"{"after":"01R1|01I1","limit":500}"#)
        _ = try await all.value
        let one = Task { try await api.sharePendingList(ruleID: "01R1") }
        req = try await ops.answer(v, d, "share.pending.list", #"{"pending":[]}"#)
        #expect(body(req) == #"{"rule_id":"01R1"}"#)
        _ = try await one.value
    }

    @Test func grantRequestAndRevoke() async throws {
        let (d, v) = try await ops.base.pairedDevice()
        let api = VaultApi(device: d)
        let item = try StrictJson.parseObject(#"{"kind":"category","ref":"insurance","label":"Your card"}"#)
        let ask = Task { try await api.grantRequest("c1", items: [item], uses: 2, expiresIn: 3_600, reason: "Claim") }
        var req = try await ops.answer(v, d, "grant.request", #"{"request_id":"01REQ"}"#)
        #expect(body(req) == #"{"connection_id":"c1","items":[{"kind":"category","ref":"insurance","label":"Your card"}],"uses":2,"expires_in":3600,"reason":"Claim"}"#)
        #expect(try await ask.value == "01REQ")

        let bare = Task { try await api.grantRequest("c1", items: [item]) }
        req = try await ops.answer(v, d, "grant.request", #"{"request_id":"01REQ2"}"#)
        #expect(body(req) == #"{"connection_id":"c1","items":[{"kind":"category","ref":"insurance","label":"Your card"}]}"#)
        #expect(try await bare.value == "01REQ2")

        // An answer without a request id is the vault's mistake, not an empty id.
        let broken = Task { try await api.grantRequest("c1", items: [item]) }
        _ = try await ops.answer(v, d, "grant.request", "{}")
        await #expect(throws: VaultStateError.self) { _ = try await broken.value }

        let revoke = Task { try await api.grantRevoke("01GRANT") }
        req = try await ops.answer(v, d, "grant.revoke", "{}")
        #expect(body(req) == #"{"grant_id":"01GRANT"}"#)
        try await revoke.value
    }

    /// §10.12: `grant.fetch{grant_id, reply_key}` answers `{fetch_id}`; the content comes in `grant.value`, sealed to the
    /// reply key whose private half lived only for this fetch (grant seal: `grant_id` and `fetch_id` bound).
    @Test func aFetchOpensTheSealedValueAndPassesARefusalOn() async throws {
        let (d, v) = try await ops.base.pairedDevice()
        let api = VaultApi(device: d)
        let content = Array(#"{"item_id":"x9","version":1,"name":"Card","category":"insurance","fields":[]}"#.utf8)
        let fetch = Task { try await api.grantFetch("01GRANT", timeout: 5) }
        var req = try await ops.answer(v, d, "grant.fetch", #"{"fetch_id":"01FETCH"}"#)
        let sent = try StrictJson.parseObject(req.body)
        let granted = try sent.string("grant_id")
        #expect(sent.members.map(\.name) == ["grant_id", "reply_key"] && granted == "01GRANT")
        let key = try KemPublicKey.parse(try sent.base64("reply_key", 1_216))
        let sealed = try GrantSeal.sealValue(reply: key, grantID: "01GRANT", fetchID: "01FETCH", value: content)
        try await d.handle(try v.seal("grant.value", JsonBuilder().string("connection_id", "c1").string("fetch_id", "01FETCH").string("grant_id", "01GRANT").base64("value_sealed", sealed).uint("uses_left", 4).build()))
        let got = try await fetch.value
        #expect(got.error == nil && got.usesLeft == 4 && got.retryAfter == nil && got.takeContent() == content && got.takeContent() == nil)
        #expect(!"\(got)".contains("Card"))

        // Another fetch's answer is not this one's; a refusal is passed on with its `retry_after`.
        let refused = Task { try await api.grantFetch("01GRANT", timeout: 5) }
        req = try await ops.answer(v, d, "grant.fetch", #"{"fetch_id":"01FETCH2"}"#)
        try await d.handle(try v.seal("grant.value", #"{"connection_id":"c1","fetch_id":"01OTHER","grant_id":"01GRANT","error":"revoked"}"#))
        try await d.handle(try v.seal("grant.value", #"{"connection_id":"c1","fetch_id":"01FETCH2","grant_id":"01GRANT","error":"rate_limited","retry_after":720}"#))
        let r = try await refused.value
        #expect(r.error == "rate_limited" && r.retryAfter == 720 && r.takeContent() == nil && r.usesLeft == nil)

        // A value sealed for another fetch does not open.
        let wrong = Task { try await api.grantFetch("01GRANT", timeout: 5) }
        req = try await ops.answer(v, d, "grant.fetch", #"{"fetch_id":"01FETCH3"}"#)
        let other = try GrantSeal.sealValue(reply: try KemPublicKey.parse(try StrictJson.parseObject(req.body).base64("reply_key", 1_216)), grantID: "01GRANT", fetchID: "01ELSE", value: content)
        try await d.handle(try v.seal("grant.value", JsonBuilder().string("connection_id", "c1").string("fetch_id", "01FETCH3").string("grant_id", "01GRANT").base64("value_sealed", other).build()))
        await #expect(throws: CryptoError.self) { _ = try await wrong.value }

        // No answer from the connection: the wait ends.
        let silent = Task { try await api.grantFetch("01GRANT", timeout: 0.3) }
        _ = try await ops.answer(v, d, "grant.fetch", #"{"fetch_id":"01FETCH4"}"#)
        await #expect(throws: VaultStateError.self) { _ = try await silent.value }
    }
}

// swiftlint:enable line_length
