import Foundation
import Testing
@testable import VettIDVault
import VettIDCrypto

// Fixtures (JSON bodies of the fake vault) stay on one line each.
// swiftlint:disable line_length

/// The feed, audit and approval calls (VAULT-MESSAGING §10.4, §10.9, §10.12, §10.13) against the fake vault: the request
/// bodies as vettid-vault `features/feed`, `features/audit`, `features/grants`, `features/critical` and
/// `features/connauth` read them, and the answers' models.
@Suite struct ActivityOpsTests {
    let ops = CredentialOpsTests()

    func body(_ req: Inner) -> String { String(bytes: req.body, encoding: .utf8) ?? "" }

    /// §10.9 feed: `feed.list` sends only what is given and reads the items (empty references absent, `count` from 2).
    @Test func feedListUpdateAndDelete() async throws {
        let (d, v) = try await ops.base.pairedDevice()
        let api = VaultApi(device: d)
        let list = Task { try await api.feedList(afterSeq: 40, limit: 500) }
        var req = try await ops.answer(v, d, "feed.list", #"{"items":[{"item_id":"01JFEED000000000000000000A","seq":41,"kind":"grant.request","at":"2026-10-20T12:00:00.000Z","status":"active","priority":"normal","connection_id":"c1","ref":"r1","count":3},{"item_id":"01JFEED000000000000000000B","seq":42,"kind":"guide","at":"2026-10-20T12:00:01.000Z","status":"deleted","priority":"low"},{"seq":43}],"seq":42}"#)
        #expect(body(req) == #"{"after_seq":40,"limit":500}"#)
        let page = try await list.value
        #expect(page.seq == 42 && page.items.count == 2)
        #expect(page.items[0].count == 3 && page.items[0].connectionID == "c1" && page.items[0].ref == "r1" && page.items[0].deviceID == nil)
        #expect(page.items[1].status == "deleted" && page.items[1].priority == "low" && page.items[1].count == nil)

        let update = Task { try await api.feedUpdate("01JFEED000000000000000000A", status: "read") }
        req = try await ops.answer(v, d, "feed.update", #"{"item_id":"01JFEED000000000000000000A","seq":43,"kind":"grant.request","at":"2026-10-20T12:00:00.000Z","status":"read","priority":"normal"}"#)
        #expect(body(req) == #"{"item_id":"01JFEED000000000000000000A","status":"read"}"#)
        #expect(try await update.value.seq == 43)

        let delete = Task { try await api.feedDelete("01JFEED000000000000000000A") }
        req = try await ops.answer(v, d, "feed.delete", "{}")
        #expect(body(req) == #"{"item_id":"01JFEED000000000000000000A"}"#)
        try await delete.value
    }

    /// §10.9 audit: one connection's entries are `connection.audit.list`; the search members only when given; the cursor
    /// and `partial` come back.
    @Test func auditListTypesSearchAndCursors() async throws {
        let (d, v) = try await ops.base.pairedDevice()
        let api = VaultApi(device: d)
        let one = Task { try await api.auditList(connectionID: "c1", kinds: ["message", "call"], beforeSeq: 90, limit: 50, search: AuditSearch(q: "Lee", since: "2026-10-01T00:00:00.000Z")) }
        var req = try await ops.answer(v, d, "connection.audit.list", #"{"entries":[{"entry_id":"e1","seq":89,"at":"2026-10-20T12:00:00.000Z","kind":"message.received","connection_id":"c1","ref":"m1","direction":"in","prev":"p","hash":"h"}],"head":"x","seq":120,"next_before_seq":89,"partial":true}"#)
        #expect(body(req) == #"{"connection_id":"c1","kinds":["message","call"],"q":"Lee","since":"2026-10-01T00:00:00.000Z","before_seq":90,"limit":50}"#)
        let p = try await one.value
        #expect(p.partial && p.nextBeforeSeq == 89 && p.seq == 120 && p.entries.first?.direction == "in" && p.entries.first?.deviceID == nil)

        let all = Task { try await api.auditList(connectionID: "c1", afterSeq: 7) }
        req = try await ops.answer(v, d, "audit.list", #"{"entries":[],"seq":7}"#)
        #expect(body(req) == #"{"connection_id":"c1","after_seq":7}"#)
        #expect(try await all.value.entries.isEmpty)
    }

    /// §10.9 History export: the preview is a plain request; the export seals the PIN alone to a UTK (no blob) with the
    /// filters, `format` and `upto_seq` beside it, and returns the answer's `ts`.
    @Test func exportPreviewThenTheSealedExport() async throws {
        let (d, v) = try await ops.base.pairedDevice()
        let api = VaultApi(device: d)
        let f = AuditExportFilters(kinds: ["credential"], q: "rot")
        let preview = Task { try await api.auditExportPreview(f) }
        var req = try await ops.answer(v, d, "audit.export", #"{"count":2,"more":false,"upto_seq":812,"upto_hash":"aGFzaA==","oldest_seq":700,"newest_seq":790,"oldest_at":"2026-10-01T00:00:00.000Z","newest_at":"2026-10-08T00:00:00.000Z"}"#)
        #expect(body(req) == #"{"kinds":["credential"],"q":"rot","dry_run":true}"#)
        let a = try await preview.value
        #expect(a.count == 2 && a.uptoSeq == 812 && a.oldestSeq == 700 && a.entrySeq == nil && a.answeredAt == nil)

        let (utks, keys) = try ops.pool(1)
        let export = Task { try await api.auditExport(f, format: "csv", uptoSeq: 812, pin: "402817") }
        try await ops.answer(v, d, "credential.utk.get", utks)
        req = try await ops.answer(v, d, "audit.export", #"{"count":2,"more":false,"upto_seq":812,"upto_hash":"aGFzaA==","entry_seq":813}"#)
        let o = try StrictJson.parseObject(req.body)
        #expect(try o.string("format") == "csv" && o.uint("upto_seq", min: 1, max: 10_000) == 812 && o.string("q") == "rot")
        #expect(VaultJSON.string(o, "credential") == nil, "not a credential operation")
        let pt = try ops.payload(req, try #require(d.vaultID), keys)
        #expect(try pt.members.map(\.name) == ["pin"] && pt.string("pin") == "402817")
        let done = try await export.value
        #expect(done.entrySeq == 813 && done.answeredAt != nil)
    }

    /// §10.9's chain, against values computed from the formula independently: an entry altered anywhere breaks it.
    @Test func theAuditChain() {
        let at = { (s: String) -> Int64? in (try? Timestamps.parseMillis(s)).map { Int64(($0.timeIntervalSince1970 * 1000 + 0.001).rounded(.down)) } }
        let e1 = AuditEntry(entryID: "e1", seq: 1, at: "2025-10-09T08:53:20.123Z", kind: "vault.unlocked", deviceID: "01JDEV", prev: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=", hash: "7NybrwafQuOmLtgVUYOtnfIZ4tJntCbdbqjs5IPxQN0=")
        let e2 = AuditEntry(entryID: "e2", seq: 2, at: "2025-10-09T08:53:21.456Z", kind: "message.received", connectionID: "01JCONN", ref: "01JMSG", direction: "in", prev: "7NybrwafQuOmLtgVUYOtnfIZ4tJntCbdbqjs5IPxQN0=", hash: "vyqr4ZQz2t8gvODqDgPB7eOZzyX9w9dzCOVkYRw7PUI=")
        #expect(VaultApi.auditChains([e1, e2], atMillis: at))
        var bad = e2
        bad.ref = "01JMSH"
        #expect(!VaultApi.auditChains([e1, bad], atMillis: at))
        bad = e2
        bad.prev = e2.hash
        #expect(!VaultApi.auditChains([e1, bad], atMillis: at))
        #expect(!VaultApi.auditChains([e2, e1], atMillis: at))
        bad = e1
        bad.at = "2025-10-09T08:53:20Z"
        #expect(!VaultApi.auditChains([bad], atMillis: at))
    }

    /// §10.12 `grant.decide` with indexes, an answer, uses and lifetime; §10.13 the critical use's sealed consent.
    @Test func grantDecideAndCriticalUseApprove() async throws {
        let (d, v) = try await ops.base.pairedDevice()
        let api = VaultApi(device: d)
        let decide = Task { try await api.grantDecide("r1", approve: true, choice: GrantChoice(items: [0, 2], answers: [GrantAnswer(index: 2, itemID: "i9")], uses: 3, expiresIn: 3_600)) }
        var req = try await ops.answer(v, d, "grant.decide", #"{"grants":[]}"#)
        #expect(body(req) == #"{"request_id":"r1","approve":true,"items":[0,2],"answers":[{"index":2,"item_id":"i9"}],"uses":3,"expires_in":3600}"#)
        _ = try await decide.value

        let deny = Task { try await api.grantDecide("r2", approve: false) }
        req = try await ops.answer(v, d, "grant.decide", #"{"grants":[]}"#)
        #expect(body(req) == #"{"request_id":"r2","approve":false}"#)
        _ = try await deny.value

        let share = Task { try await api.shareDecide("rule1", include: ["i1"], decline: []) }
        req = try await ops.answer(v, d, "share.decide", "{}")
        #expect(body(req) == #"{"rule_id":"rule1","include":["i1"]}"#)
        _ = try await share.value
    }

    /// §10.13: the password, the request id and the payload's hash sealed together, `request_id` beside the blob.
    @Test func criticalUseApproveSealsThePayloadHash() async throws {
        let (d, v) = try await ops.base.pairedDevice()
        let api = VaultApi(device: d)
        try await d.keepCredential(blob: "YmxvYg==", version: 1)
        let (utks, keys) = try ops.pool(1)
        let approve = Task { try await api.criticalUseApprove("r7", password: "pw", payloadSha256: Bytes.sha256(Array("x".utf8))) }
        try await ops.answer(v, d, "credential.utk.get", utks)
        let req = try await ops.answer(v, d, "critical-secret-use.approve", #"{"request_id":"r7","status":"ok"}"#)
        let o = try StrictJson.parseObject(req.body)
        #expect(try o.string("request_id") == "r7" && o.string("credential") == "YmxvYg==")
        let pt = try ops.payload(req, try #require(d.vaultID), keys)
        #expect(try pt.string("password") == "pw" && pt.string("request_id") == "r7")
        #expect(try pt.string("payload_sha256") == Base64s.encodeStd(Bytes.sha256(Array("x".utf8))))
        #expect(try await approve.value == "ok")
    }

    /// §10.4.2 (0.70.0): `pending.list{after?, limit?}` sends only what is given, and answers the page with the vault's time
    /// (the response's inner `ts`); an older vault answers `unsupported_type`.
    @Test func pendingListPagesWithTheVaultsTime() async throws {
        let (d, v) = try await ops.base.pairedDevice()
        let api = VaultApi(device: d)
        let first = Task { try await api.pendingListPage() }
        var req = try await ops.answer(v, d, "pending.list", #"{"asks":[{"kind":"authenticate","body":{"request_id":"a1","connection_id":"c1","exp":"2026-10-29T12:00:00.000Z"}}],"next":"k1"}"#)
        #expect(body(req) == "{}")
        let page = try await first.value
        #expect(abs(page.ts.timeIntervalSinceNow) < 30)
        #expect(VaultJSON.objects(page.body, "asks").count == 1 && VaultJSON.string(page.body, "next") == "k1")

        let next = Task { try await api.pendingListPage(after: "k1", limit: 100) }
        req = try await ops.answer(v, d, "pending.list", #"{"asks":[]}"#)
        #expect(body(req) == #"{"after":"k1","limit":100}"#)
        #expect(VaultJSON.string(try await next.value.body, "next") == nil)

        let old = Task { try await api.pendingListPage() }
        _ = try await ops.answer(v, d, "pending.list", code: "unsupported_type", errorBody: "{}")
        await #expect(throws: VaultOpError.self) { _ = try await old.value }
    }
}

// swiftlint:enable line_length
