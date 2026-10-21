import Foundation
import Testing
@testable import VettIDVault
import VettIDCrypto

// Fixtures (JSON bodies of the fake vault) stay on one line each.
// swiftlint:disable line_length

/// The item calls (VAULT-MESSAGING §10.7) on the wire against the fake vault: a `data` or `secret` item's body as it is; a
/// critical item's content, id and password only in the UTK-sealed payload, with the blob beside them and the new blob
/// kept from `credential_version`; a critical reveal's values sealed to the request's one-time reply key and opened here.
@Suite struct ItemOpsTests {
    let creds = CredentialOpsTests()
    var base: VaultDeviceTests { creds.base }

    /// A paired device holding blob version 1.
    func holder() async throws -> (VaultDevice, FakeVault, VaultApi) { // swiftlint:disable:this large_tuple
        let (d, v) = try await base.pairedDevice()
        let api = VaultApi(device: d)
        let fetch = Task { try await api.credentialFetch() }
        try await creds.answer(v, d, "credential.get", #"{"credential":"AQID","version":1}"#)
        try await creds.answer(v, d, "credential.ack")
        try await fetch.value
        return (d, v, api)
    }

    @Test func aDataItemIsPutAsItIs() async throws {
        let (d, v) = try await base.pairedDevice()
        let api = VaultApi(device: d)
        let content = ItemContent(name: "Passport", category: "identity_document", fields: [ItemField(fieldID: nil, label: "Number", kind: "text", valueJSON: #""X1""#), ItemField(fieldID: "f2", label: "Old", kind: "text", valueJSON: nil)], keepNotes: true)
        let put = Task { try await api.itemPut(content, sensitivity: "secret", tags: ["travel"], itemID: "01A", version: 3) }
        let req = try await creds.answer(v, d, "item.put", #"{"item_id":"01A","version":4,"updated_at":"2026-10-21T00:00:00Z"}"#)
        #expect(String(bytes: req.body, encoding: .utf8) == #"{"item_id":"01A","version":3,"sensitivity":"secret","tags":["travel"],"name":"Passport","category":"identity_document","fields":[{"label":"Number","kind":"text","value":"X1"},{"field_id":"f2","label":"Old","kind":"text"}],"keep_notes":true}"#)
        #expect(try await put.value == ItemRef(itemID: "01A", version: 4, updatedAt: "2026-10-21T00:00:00Z"))
    }

    @Test func aCriticalItemsContentTravelsSealed() async throws {
        let (d, v, api) = try await holder()
        let (utks, keys) = try creds.pool(2)
        let content = ItemContent(name: "Phrase", category: "crypto_wallet", fields: [ItemField(fieldID: nil, label: "Words", kind: "multiline", valueJSON: #""abandon ability""#)])
        let put = Task { try await api.itemPutCritical(password: "pw", content: content, tags: ["cold"], itemID: "01C", version: 2) }
        try await creds.answer(v, d, "credential.utk.get", utks)
        let req = try await creds.answer(v, d, "item.put", #"{"item_id":"01C","version":3,"credential":"BAUG","credential_version":2,"utks":[]}"#)
        let outer = try StrictJson.parseObject(req.body)
        #expect(Set(outer.members.map(\.name)) == ["utk_id", "sealed", "credential", "sensitivity", "version", "tags"])
        #expect(try outer.string("sensitivity") == "critical" && outer.string("credential") == "AQID" && outer.uint("version", min: 0, max: 9) == 2)
        let text = String(bytes: req.body, encoding: .utf8) ?? ""
        #expect(!text.contains("Phrase") && !text.contains("abandon"))
        let p = try creds.payload(req, v.vaultID, keys)
        #expect(p.members.map(\.name) == ["password", "item", "item_id"])
        #expect(try p.string("item_id") == "01C" && p.obj("item").raw == #"{"name":"Phrase","category":"crypto_wallet","fields":[{"label":"Words","kind":"multiline","value":"abandon ability"}]}"#)
        let ack = try await creds.answer(v, d, "credential.ack")
        #expect(VaultJSON.int(VaultJSON.object(ack.body), "version") == 2, "the credential's version, not the item's")
        #expect(try await put.value.version == 3 && d.credentialVersion == 2)
    }

    @Test func aCriticalRevealOpensWithTheReplyKey() async throws {
        let (d, v, api) = try await holder()
        let (utks, keys) = try creds.pool(2)
        let reveal = Task { try await api.itemRevealCritical(password: "pw", itemID: "01C") }
        try await creds.answer(v, d, "credential.utk.get", utks)
        // The vault's side: the payload opened, the values sealed to its reply key for the request's inner id.
        let req = try v.open(try await base.relay.nextDeposit().payload)
        let p = try creds.payload(req, v.vaultID, keys)
        #expect(p.members.map(\.name) == ["password", "item_id", "reply_key"])
        #expect(try p.string("item_id") == "01C")
        #expect(try StrictJson.parseObject(req.body).string("item_id") == "01C")
        let values = #"{"fields":[{"field_id":"f1","value":"abandon ability"}],"notes":"cold"}"#
        let sealed = try CredentialSeal.sealValue(reply: try KemPublicKey.parse(try p.base64("reply_key")), vaultID: v.vaultID, innerID: req.id, value: Array(values.utf8))
        let body = #"{"item_id":"01C","version":2,"values_sealed":"\#(Base64s.encodeStd(sealed))","credential":"BAUG","credential_version":2,"utks":[]}"#
        try await d.handle(v.msg(try #require(v.keyring.current()).seal(Inner(id: Ulid.new(), type: "item.reveal", ts: Date(), re: req.id, status: Inner.statusOK, body: Array(body.utf8)))))
        try await creds.answer(v, d, "credential.ack")
        #expect(try await reveal.value == Array(values.utf8))
    }

    @Test func aDryRunCarriesNoContent() async throws {
        let (d, v) = try await base.pairedDevice()
        let api = VaultApi(device: d)
        let dry = Task { try await api.itemPutDryRun(sensitivity: "data", tags: ["medical"]) }
        let req = try await creds.answer(v, d, "item.put", #"{"shares":[],"withdrawals":[]}"#)
        #expect(String(bytes: req.body, encoding: .utf8) == #"{"dry_run":true,"sensitivity":"data","tags":["medical"]}"#)
        #expect(try await dry.value.has("shares"))
        let list = Task { try await api.itemList(after: "01A", limit: 500) }
        let lreq = try await creds.answer(v, d, "item.list", #"{"items":[{"item_id":"01B","version":2,"name":"Visa","sensitivity":"secret","tags":["travel"],"fields":[{"field_id":"f1","label":"Number","kind":"text"}],"has_notes":true},{"name":"no id"}],"next":null}"#)
        #expect(String(bytes: lreq.body, encoding: .utf8) == #"{"after":"01A","limit":500}"#)
        let page = try await list.value
        #expect(page.next == nil && page.items.map(\.itemID) == ["01B"] && page.items[0].hasNotes && page.items[0].fields[0].valueJSON == nil)
        #expect(page.items[0].category == "other", "the vault's default")
    }
}

// swiftlint:enable line_length
