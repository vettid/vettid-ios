import Foundation
import VettIDCrypto
import VettIDRelay
import VettIDVault

/// What an attempt at a vote's results came to.
public enum ResultsOutcome: Equatable, Sendable {
    /// Handed to the vault, which answered with this check state.
    case submitted(CheckState)
    /// The site had no results yet (HTTP 404).
    case notPublished
    /// The site could not be reached, or answered in a way that is no answer.
    case siteUnreachable
    /// The site's results could not be checked (a problem the app found itself, or results larger than the vault takes).
    case problem
}

/// The vault calls of the work with the public site (VAULT-MESSAGING 0.81.3 §10.19.8): `vote.site.sync` inline or by
/// claim-check blob (§5.5), the blob's upload to the app's own vault, and `vote.results.submit`.
public protocol VoteSiteOps: Sendable {
    func voteSiteSync(body: [UInt8]) async throws -> JsonObject
    func voteSiteSyncBlob(blobID: String, key: [UInt8], sha256: [UInt8], size: Int) async throws -> JsonObject
    func uploadBlob(_ blob: [UInt8]) async throws -> String
    func voteResultsSubmit(body: [UInt8]) async throws -> JsonObject
}

extension VaultApi: VoteSiteOps {}

/// The app's work with the public votes site for ``VotesManager`` (IOS-PLAN §4.16 "The site"; ANDROID-PLAN 0.1.107 "The
/// app's work with the public site"): the service list, the proposals' documents and the results that are due, at the
/// vault's opening, on a return to the foreground and then every hour while the vault is open and unlocked; a vote's
/// documents when its screen opens. There is no background job: a locked vault cannot be handed anything. Runs are one
/// at a time, and so are attempts at the results. Mirrors the site part of vettid-android `VotesManager`.
@MainActor
final class VoteSiteRunner {
    static let syncEvery: Duration = .seconds(3600)
    static let codeTooLarge = "payload_too_large"
    static let uploadTries = 2
    static let uploadWait: Duration = .seconds(5)
    static let tagSize = 32

    private unowned let votes: VotesManager
    let site: any VoteSite
    /// The site calls, over the session already open when [quietly] (a run nobody asked for never opens one).
    private let ops: @MainActor (_ quietly: Bool) async throws -> any VoteSiteOps
    private let every: Duration
    private let sleep: @Sendable (Duration) async throws -> Void

    private var loop: Task<Void, Never>?
    /// The hourly work was started (the vault is open) and not stopped by a lock, a hold or a wipe.
    private(set) var wanted = false
    private var runs: Task<Void, Never>?
    private var attempts: Task<Void, Never>?

    init(
        votes: VotesManager, site: any VoteSite, ops: @escaping @MainActor (Bool) async throws -> any VoteSiteOps,
        every: Duration = syncEvery, sleep: @escaping @Sendable (Duration) async throws -> Void
    ) {
        self.votes = votes
        self.site = site
        self.ops = ops
        self.every = every
        self.sleep = sleep
    }

    // MARK: The schedule

    /// The vault opened (or a hold ended): a run now, then one every hour while this lasts. The opening has just read
    /// the list, so the first run does not read it again.
    func start() {
        wanted = true
        // The app is away (the lists' read outlived the foreground): the run waits for the return.
        guard !away else { return }
        restartLoop(readFirst: false)
    }

    /// The vault locked, was held or wiped: no more runs until the next opening.
    func stop() {
        wanted = false
        loop?.cancel()
        loop = nil
    }

    /// True from ``pause()`` to ``resume()``: no run starts meanwhile.
    private var away = false

    /// The app left the foreground: no run while it is away (there is no background job).
    func pause() {
        away = true
        loop?.cancel()
        loop = nil
    }

    /// The app came back: a run now, then hourly again, when the work was started.
    func resume() {
        away = false
        guard wanted else { return }
        restartLoop(readFirst: true)
    }

    var running: Bool { loop != nil }

    private func restartLoop(readFirst: Bool) {
        loop?.cancel()
        let every = every
        let sleep = sleep
        loop = Task { @MainActor [weak self] in
            var read = readFirst
            while !Task.isCancelled {
                guard let self else { return }
                // Locked, held or unreachable: the next hour (or the next opening) tries again; the screens say what waits.
                try? await syncOnce(read: read)
                read = true
                do { try await sleep(every) } catch { return }
            }
        }
    }

    // MARK: A run

    /// One run: the list, the service list, the proposals, and the results that are due. Not while another run goes on.
    func syncOnce(read: Bool = true) async throws {
        guard site.configured else { return }
        try await serially(.runs) { [self] in
            // Held or due (VAULT-MESSAGING §3.6.3): nothing goes to the vault, the site is not read either.
            guard !votes.held() else { return }
            if read { try await votes.read(quietly: true) }
            guard votes.availability == .available, !votes.held(), !Task.isCancelled else { return }
            do {
                try await syncLists()
            } catch let f as VaultFailure where f.code == Self.codeTooLarge {
                // A list the vault refused as too large leaves its held list; the proposals and the results go on.
            }
            try await syncProposals(only: nil)
            await submitDue()
        }
    }

    /// A vote's screen opened: its documents and the index, so that the vault can compare them with what it holds.
    func siteCheck(_ key: VoteKey) async throws {
        guard site.configured else { return }
        try await serially(.runs) { [self] in try await syncProposals(only: key.proposalID, quietly: false) }
        votes.refreshQuietly()
    }

    private func syncLists() async throws {
        guard case .found(let doc) = await site.get("services.json", maxBytes: VoteSiteLimits.listMax),
              case .found(let sig) = await site.get("services.json.sig", maxBytes: VoteSiteLimits.sigMax)
        else { return }
        let version = VoteSync.versionOf(doc) ?? 0
        let current = VoteSync.ServedList(doc: doc, sig: sig, version: version)
        let held = votes.listVersion
        var between: [VoteSync.ServedList] = []
        if let held, version > held + 1 {
            // The missing versions in order, once the site serves them; a copy not there yet (404) is for a later run. At
            // most ``VoteSync/maxLists`` a run: `version` is the unverified document's own word, so a huge one cannot loop
            // or fill memory; what was fetched is sent and the rest goes on at the next run.
            let last = min(version, held + 1 + Int64(VoteSync.maxLists))
            for v in (held + 1)..<last {
                guard case .found(let d) = await site.get("services/\(v).json", maxBytes: VoteSiteLimits.listMax),
                      case .found(let s) = await site.get("services/\(v).json.sig", maxBytes: VoteSiteLimits.sigMax)
                else { break }
                between.append(VoteSync.ServedList(doc: d, sig: s, version: v))
            }
        }
        let bodies: [[UInt8]] = switch VoteSync.planLists(current, heldVersion: held, heldSha256: votes.listSha256, between: between) {
        case .nothing: []
        case let .confirm(version, sha256): [VoteSync.confirmCall(version: version, sha256: sha256)]
        case .send(let lists): VoteSync.listCalls(lists)
        }
        for b in bodies {
            guard try await send(b, quietly: true) != nil else { break }
        }
    }

    private func syncProposals(only: String?, quietly: Bool = true) async throws {
        let held = Self.unique(votes.votes.map(\.proposalID))
        var byID: [String: String] = [:]
        var order: [String] = []
        if case .found(let bytes) = await site.get("index.json", maxBytes: VoteSiteLimits.indexMax) {
            for e in VoteSync.indexOf(bytes) {
                if byID[e.proposalID] == nil { order.append(e.proposalID) }
                byID[e.proposalID] = e.json
            }
        }
        // The held proposals, then the newest the vault lacks (it learns what to ask the service for from them).
        let ids = only.map { [$0] } ?? held + order.filter { !held.contains($0) }.suffix(VoteSync.maxNew)
        var entries: [String] = []
        for id in ids {
            let index = byID[id]
            entries.append(VoteSync.entryJson(id, index: index, await readDocument(id, index: index)))
        }
        for call in VoteSync.entryCalls(entries) {
            guard try await send(call, quietly: quietly) != nil else { break }
        }
    }

    /// One proposal's documents from the site: `proposal.json` with its signature and bundle, and each extension in order.
    /// A 404 for the proposal is `absent` (sent again at the next run and when the screen opens), a 5xx or a timeout
    /// `unreachable`, an odd body `found`: the vault judges it.
    private func readDocument(_ id: String, index: String?) async -> VoteSync.Document {
        let p: [UInt8]
        switch await site.get("p/\(id)/proposal.json") {
        case .absent: return .absent
        case .unreachable, .tooLarge: return .unreachable
        case .found(let b): p = b
        }
        guard let sig = await optional("p/\(id)/proposal.json.sig", VoteSiteLimits.sigMax),
              let bundle = await optional("p/\(id)/proposal.json.sigstore.json", VoteSiteLimits.bundleMax)
        else { return .unreachable }
        var extensions: [VoteSync.Extension] = []
        let count = VoteSync.extendedOf(index).map { min(max($0, 0), VoteSync.maxExtensions) } ?? VoteSync.maxExtensions
        if count > 0 {
            for n in 1...count {
                let x: [UInt8]
                switch await site.get("p/\(id)/extension-\(n).json") {
                case .absent: return .found(proposal: p, proposalSig: sig.bytes, bundle: bundle.json, extensions: extensions)
                case .unreachable, .tooLarge: return .unreachable
                case .found(let b): x = b
                }
                guard let xs = await optional("p/\(id)/extension-\(n).json.sig", VoteSiteLimits.sigMax),
                      let xb = await optional("p/\(id)/extension-\(n).json.sigstore.json", VoteSiteLimits.bundleMax)
                else { return .unreachable }
                extensions.append(VoteSync.Extension(x, sig: xs.bytes, bundle: xb.json))
            }
        }
        return .found(proposal: p, proposalSig: sig.bytes, bundle: bundle.json, extensions: extensions)
    }

    /// A document that may be missing: nil when the site could not answer (the whole entry is then `unreachable`).
    private func optional(_ path: String, _ max: Int) async -> (bytes: [UInt8]?, json: String?)? {
        switch await site.get(path, maxBytes: max) {
        case .unreachable, .tooLarge: return nil
        case .absent: return (nil, nil)
        case .found(let b): return (b, VoteSync.compactObject(b))
        }
    }

    /// Sends one `vote.site.sync` body within the limits (§10.19.8): inline when its padded inner plaintext fits §5.5's
    /// 245,760 bytes, otherwise as a claim-check blob to the app's own vault, and never over 8,257,532 bytes. Nil when it
    /// was not sent.
    private func send(_ body: [UInt8], quietly: Bool) async throws -> JsonObject? {
        guard body.count <= VoteSync.bodyMax else { return nil }
        if VoteSync.fitsInline(body) { return try await guarded { try await self.ops(quietly).voteSiteSync(body: body) } }
        var sealed = try ClaimBlob.seal(body)
        defer { sealed.wipe() }
        let id = try await upload(sealed.blob, quietly: quietly)
        return try await guarded {
            try await self.ops(quietly).voteSiteSyncBlob(blobID: id, key: sealed.key, sha256: sealed.sha256, size: sealed.size)
        }
    }

    /// The mailbox's single blob slot is shared with photo uploads: once more after a short wait when it is full.
    private func upload(_ blob: [UInt8], quietly: Bool) async throws -> String {
        var attempt = 0
        while true {
            do {
                return try await guarded {
                    do {
                        return try await self.ops(quietly).uploadBlob(blob)
                    } catch let r as RelayError where r.code == RelayError.quotaExceeded {
                        throw VaultFailure(.limit, code: RelayError.quotaExceeded, cause: r)
                    }
                }
            } catch let f as VaultFailure where f.kind == .limit && attempt < Self.uploadTries - 1 {
                attempt += 1
                try await sleep(Self.uploadWait)
            }
        }
    }

    // MARK: The results

    /// The checks that are due: closed, `pending`, and not before the vault's `due_at`.
    func submitDue() async {
        let at = votes.now()
        for v in votes.votes {
            guard let c = v.check, v.state == .closed, c.state == .pending, c.dueAt.map({ $0 <= at }) ?? true else { continue }
            _ = try? await checkResults(v.key, quietly: true)
        }
    }

    /// The results of a closed vote, fetched, checked as far as the app can (BALLOT-PROTOCOL §8.4: the rows' hash, order
    /// and tree, and the member's row) and handed to the vault (the member's **Check again**, and the run's retry). The
    /// vault alone judges.
    func checkResults(_ key: VoteKey, quietly: Bool) async throws -> ResultsOutcome {
        guard site.configured else { return .siteUnreachable }
        return try await serially(.attempts) { [self] in try await attempt(key, quietly: quietly) }
    }

    private func attempt(_ key: VoteKey, quietly: Bool) async throws -> ResultsOutcome {
        let detail = try await votes.detail(key, quietly: quietly)
        guard let tag = detail.recordTag.flatMap({ try? Base64s.decodeStd($0, Self.tagSize) }) else { return fail(key, .problem) }
        var siteDown = false
        var tooLarge = false
        func fetch(_ name: String, _ max: Int) async -> [UInt8]? {
            switch await site.get("p/\(key.proposalID)/\(name)", maxBytes: max) {
            case .found(let b): return b
            case .absent: return nil
            // Over the vault's own limit: results the vault could never take, a problem with them, not a site that is down.
            case .tooLarge:
                tooLarge = true
                return nil
            case .unreachable:
                siteDown = true
                return nil
            }
        }
        let doc = await fetch("results.json", VoteSiteLimits.resultsMax)
        if tooLarge { return fail(key, .problem, tooLarge: true) }
        guard let doc else { return unavailable(key, siteDown) }
        let sig = await fetch("results.json.sig", VoteSiteLimits.sigMax)
        let bundleBytes = await fetch("results.json.sigstore.json", VoteSiteLimits.bundleMax)
        let rows = await fetch("rows.json", VoteSiteLimits.rowsMax)
        if tooLarge { return fail(key, .problem, tooLarge: true) }
        guard let sig, let bundleBytes, let rows else { return unavailable(key, siteDown) }
        guard let bundle = VoteSync.compactObject(bundleBytes) else { return fail(key, .problem) }
        let own: OwnRow
        do {
            own = try VoteRows.ownRow(results: doc, rows: rows, recordTag: tag)
        } catch {
            return fail(key, .problem)
        }
        guard let body = Self.submitBody(key, doc: doc, sig: sig, bundle: bundle, own: own) else { return fail(key, .problem) }
        let answer = try await guarded { try await self.ops(quietly).voteResultsSubmit(body: body) }
        var state = CheckState.unknown
        var reason: String?
        if case .object(let check)? = answer["check"] {
            state = CheckState(rawValue: VaultJSON.string(check, "state") ?? "") ?? .unknown
            reason = VaultJSON.string(check, "reason")
        }
        // A submission the vault leaves pending for its input is the problem the screens say.
        let input = state == .pending && reason == "input"
        votes.hint(key) {
            $0.gaveUp = nil
            $0.resultsProblem = input
            $0.resultsTooLarge = false
        }
        votes.refreshQuietly()
        return .submitted(state)
    }

    /// `vote.results.submit`'s body (§10.19.8): the site's results as the standard base64 of their exact bytes, the row as
    /// the site has it (its choice included: a receipt cannot be checked without it) and its proof.
    static func submitBody(_ key: VoteKey, doc: [UInt8], sig: [UInt8], bundle: String, own: OwnRow) -> [UInt8]? {
        let row = JsonBuilder()
        if let b = own.ballot {
            guard let vk = try? b.string("vk"), let choice = try? b.string("choice_id"), let bs = try? b.string("ballot_sig")
            else { return nil }
            row.raw("ballot", JsonBuilder().string("vk", vk).string("choice_id", choice).string("ballot_sig", bs).build())
        } else {
            row.raw("ballot", "null")
        }
        let proof = JsonBuilder().uint("index", own.index).uint("tree_size", own.treeSize)
            .raw("path", JsonBuilder.array(own.path.map { JsonBuilder.quote(Base64s.encodeStd($0)) }))
        return JsonBuilder().string("connection_id", key.connectionID).string("proposal_id", key.proposalID)
            .base64("results", doc).base64("results_sig", sig).raw("bundle", bundle)
            .raw("row", row.build()).raw("row_proof", proof.build()).bytes()
    }

    /// The site could not be reached, or had no results (yet): which of the two is what a `gave_up` check will say.
    private func unavailable(_ key: VoteKey, _ siteDown: Bool) -> ResultsOutcome {
        siteDown ? fail(key, .siteUnreachable, .site) : fail(key, .notPublished, .unpublished)
    }

    private func fail(_ key: VoteKey, _ outcome: ResultsOutcome, _ why: GaveUpWhy? = nil, tooLarge: Bool = false) -> ResultsOutcome {
        votes.hint(key) {
            $0.gaveUp = why ?? $0.gaveUp
            $0.resultsProblem = outcome == .problem
            $0.resultsTooLarge = tooLarge
        }
        return outcome
    }

    /// For a `gave_up` check the app has no reason for: looks at the site once and remembers which of two things.
    func diagnoseGaveUp(_ key: VoteKey) async {
        guard site.configured, votes.hints[key]?.gaveUp == nil else { return }
        switch await site.get("p/\(key.proposalID)/results.json", maxBytes: VoteSiteLimits.resultsMax) {
        case .absent: votes.hint(key) { $0.gaveUp = .unpublished }
        case .unreachable: votes.hint(key) { $0.gaveUp = .site }
        case .tooLarge: votes.hint(key) {
            $0.resultsProblem = true
            $0.resultsTooLarge = true
        }
        case .found: break // published: **Check again** hands them to the vault
        }
    }

    // MARK: Helpers

    private enum Chain { case runs, attempts }

    /// Runs [work] after the work before it on [chain], one at a time.
    private func serially<T: Sendable>(_ chain: Chain, _ work: @escaping @MainActor () async throws -> T) async throws -> T {
        let before = chain == .runs ? runs : attempts
        let task = Task { @MainActor () -> Result<T, any Error> in
            await before?.value
            do { return .success(try await work()) } catch { return .failure(error) }
        }
        let link = Task { _ = await task.value }
        if chain == .runs { runs = link } else { attempts = link }
        return try await task.value.get()
    }

    private func guarded<T: Sendable>(_ body: @MainActor () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            throw VaultFailures.map(error)
        }
    }

    private static func unique(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }
}
