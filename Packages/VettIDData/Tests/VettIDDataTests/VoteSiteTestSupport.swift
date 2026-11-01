import Foundation
import Testing
import VettIDCrypto
@testable import VettIDData
import VettIDDataTesting
import VettIDRelay
@testable import VettIDVault

// Fixtures stay on one line each.
// swiftlint:disable line_length

/// TEST ONLY. The public votes site as the tests serve it: [docs] by path under `/v1/`, a missing path a 404; every read is
/// recorded in [reads] (paths only).
final class FakeVoteSite: VoteSite, @unchecked Sendable {
    private let lock = NSLock()
    private var docs: [String: SiteAnswer] = [:]
    private var log: [String] = []
    var configured = true
    /// Called with a path before it is answered (a test holds a read here); not under the lock.
    nonisolated(unsafe) var hold: (@Sendable (String) async -> Void)?

    subscript(path: String) -> SiteAnswer? {
        get { lock.withLock { docs[path] } }
        set { lock.withLock { docs[path] = newValue } }
    }

    func put(_ path: String, _ text: String) { self[path] = .found(Array(text.utf8)) }

    var reads: [String] { lock.withLock { log } }

    func clearReads() { lock.withLock { log = [] } }

    func get(_ path: String, maxBytes: Int) async -> SiteAnswer {
        // As the real site: a read of cancelled work is not made.
        if Task.isCancelled { return .unreachable }
        await hold?(path)
        if Task.isCancelled { return .unreachable }
        return lock.withLock {
            log.append(path)
            guard let a = docs[path] else { return .absent }
            if case .found(let b) = a, b.count > maxBytes { return .tooLarge }
            return a
        }
    }
}

/// TEST ONLY. The vault's side of the work with the site: every `vote.site.sync` body as the vault received it (a
/// claim-check blob opened), the uploads, and every `vote.results.submit` body.
@MainActor
final class FakeVoteSiteOps: VoteSiteOps, @unchecked Sendable {
    var syncs: [[UInt8]] = []
    var blobSyncs = 0
    var inlineSyncs = 0
    var uploads: [String: [UInt8]] = [:]
    var uploadCalls = 0
    var submits: [[UInt8]] = []
    var submitAnswer = #"{"proposal_id":"p","check":{"state":"verified"}}"#
    var syncAnswer = "{}"
    /// Refuses the next uploads with the relay's storage-full answer; [syncRefusal] the next `vote.site.sync` once.
    var quotaRefusals = 0
    var syncRefusal: String?

    nonisolated func voteSiteSync(body: [UInt8]) async throws -> JsonObject {
        try await MainActor.run {
            if let code = syncRefusal {
                syncRefusal = nil
                throw VaultOpError(type: "vote.site.sync", code: code, detail: "", body: nil)
            }
            syncs.append(body)
            inlineSyncs += 1
            return voteObj(syncAnswer)
        }
    }

    nonisolated func voteSiteSyncBlob(blobID: String, key: [UInt8], sha256: [UInt8], size: Int) async throws -> JsonObject {
        try await MainActor.run {
            let blob = try #require(uploads[blobID])
            syncs.append(try ClaimBlob.open(blob, key: key, sha256: sha256, size: UInt64(size)))
            blobSyncs += 1
            return voteObj(syncAnswer)
        }
    }

    nonisolated func uploadBlob(_ blob: [UInt8]) async throws -> String {
        try await MainActor.run {
            uploadCalls += 1
            if quotaRefusals > 0 {
                quotaRefusals -= 1
                throw RelayError(status: 507, code: RelayError.quotaExceeded, message: "")
            }
            let id = "blob-\(uploads.count + 1)"
            uploads[id] = blob
            return id
        }
    }

    nonisolated func voteResultsSubmit(body: [UInt8]) async throws -> JsonObject {
        try await MainActor.run {
            submits.append(body)
            return voteObj(submitAnswer)
        }
    }

    /// The `services` versions of each sync call, in order (nil for a call without them).
    func servicesCalls() throws -> [[Int64]?] {
        try syncs.map { b in
            let o = try StrictJson.parseObject(b)
            guard o.has("services") else { return nil }
            return try VoteSyncTests.services(b)
        }
    }

    func entries() throws -> [JsonObject] {
        try syncs.flatMap { b -> [JsonObject] in
            let o = try StrictJson.parseObject(b)
            return try (o.optArray("entries") ?? []).map { try $0.asObject() }
        }
    }
}

/// TEST ONLY. The hourly wait, released by the test: each wait is recorded and ends when [release] is called.
@MainActor
final class TestSleeper {
    private(set) var waits: [Duration] = []
    private var gates: [TestDeferred<Void>] = []

    func sleep(_ d: Duration) async throws {
        waits.append(d)
        let g = TestDeferred<Void>()
        gates.append(g)
        try await g.value()
    }

    func release() { gates.forEach { $0.complete(()) } }
}

/// The results of a closed vote as a site would publish them: two rows, the member's (tag 0x02…) with a ballot.
enum VoteResultsFixture {
    static let otherTag = [UInt8](repeating: 1, count: 32)
    static let tag = [UInt8](repeating: 2, count: 32)
    static let vk = [UInt8](repeating: 3, count: 32)
    static let ballotSig = [UInt8](repeating: 4, count: 64)

    static func lp(_ x: [UInt8]) -> [UInt8] { [UInt8(x.count >> 8), UInt8(x.count & 0xFF)] + x }

    static var rows: [UInt8] {
        Array(#"{"rows":[{"record_tag":"\#(Base64s.encodeStd(otherTag))","ballot":null},{"record_tag":"\#(Base64s.encodeStd(tag))","ballot":{"vk":"\#(Base64s.encodeStd(vk))","choice_id":"yes","ballot_sig":"\#(Base64s.encodeStd(ballotSig))"}}]}"#.utf8)
    }

    static var results: [UInt8] {
        let leaves = [otherTag, tag + lp(vk) + lp(Array("yes".utf8)) + lp(ballotSig)]
        let root = VoteMerkle.root(leaves)
        return Array(#"{"rows_hash":"\#(Base64s.encodeStd(Bytes.sha256(rows)))","rows_root":"\#(Base64s.encodeStd(root))","counts":{"eligible":2}}"#.utf8)
    }

    /// Serves the results of [pid] on [site].
    static func publish(_ site: FakeVoteSite, _ pid: String) {
        site["p/\(pid)/results.json"] = .found(results)
        site["p/\(pid)/results.json.sig"] = .found([UInt8](repeating: 5, count: 64))
        site.put("p/\(pid)/results.json.sigstore.json", #"{"mediaType":"bundle"}"#)
        site["p/\(pid)/rows.json"] = .found(rows)
    }
}

// swiftlint:enable line_length
