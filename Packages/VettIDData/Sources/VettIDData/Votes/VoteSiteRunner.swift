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

/// The vault calls of the work with the public site (VAULT-MESSAGING 0.81.4 §10.19.8): `vote.site.sync` inline or by
/// claim-check blob (§5.5), the blob's upload to the app's own vault, and `vote.results.submit`.
public protocol VoteSiteOps: Sendable {
    func voteSiteSync(body: [UInt8]) async throws -> JsonObject
    func voteSiteSyncBlob(blobID: String, key: [UInt8], sha256: [UInt8], size: Int) async throws -> JsonObject
    func uploadBlob(_ blob: [UInt8]) async throws -> String
    func voteResultsSubmit(body: [UInt8]) async throws -> JsonObject
    /// Discards a blob the vault was not (or could not be) handed, so that it does not hold the single slot.
    func deleteBlob(_ blobID: String) async throws
}

extension VaultApi: VoteSiteOps {}

/// The app's work with the public votes site for ``VotesManager`` (IOS-PLAN §4.16 "The site"; ANDROID-PLAN 0.1.107 "The
/// app's work with the public site"): the service list, the proposals' documents and the results that are due, at the
/// vault's opening, on a return to the foreground and then every hour while the vault is open and unlocked; a vote's
/// documents when its screen opens. There is no background job: a locked vault cannot be handed anything. Runs are one
/// at a time, and so are attempts at the results. A lock, a hold, a wipe or the app leaving cancels what is going on:
/// nothing more is read from the site, sent to the vault or written after it. Parsing and encoding of the site's
/// documents happen off the main actor. Mirrors the site part of vettid-android `VotesManager`.
@MainActor
final class VoteSiteRunner {
    static let syncEvery: Duration = .seconds(3600)
    nonisolated static let codeTooLarge = "payload_too_large"
    static let uploadTries = 2
    static let uploadWait: Duration = .seconds(5)
    static let tagSize = 32
    /// A return to the foreground runs at once only when the last run is at least this old (seconds; chosen; not in the
    /// spec, and not on Android, which does not leave the work in the background); otherwise the hourly wait goes on.
    static let returnAfter: TimeInterval = 600

    private weak var votes: VotesManager?
    let site: any VoteSite
    private let reader: VoteSiteReader
    /// The site calls, over the session already open when [quietly] (a run nobody asked for never opens one).
    private let ops: @MainActor (_ quietly: Bool) async throws -> any VoteSiteOps
    private let every: Duration
    private let sleep: @Sendable (Duration) async throws -> Void

    private var loop: Task<Void, Never>?
    /// The hourly work was started (the vault is open) and not stopped by a lock, a hold or a wipe.
    private(set) var wanted = false
    /// True from ``pause()`` to ``resume()``: no run starts meanwhile.
    private var away = false
    /// When the last run ended without being cancelled.
    private var lastRun: Date?
    private var runs: Task<Void, Never>?
    private var attempts: Task<Void, Never>?
    /// The work going on or queued, to cancel at a lock or when the app leaves.
    private var cancellers: [Int: () -> Void] = [:]
    private var nextWork = 0
    /// The attempts at a vote's results that are on their way: one at a time for a vote.
    private var inflight: [VoteKey: Task<ResultsOutcome, any Error>] = [:]

    init(
        votes: VotesManager, site: any VoteSite, ops: @escaping @MainActor (Bool) async throws -> any VoteSiteOps,
        every: Duration = syncEvery, sleep: @escaping @Sendable (Duration) async throws -> Void
    ) {
        self.votes = votes
        self.site = site
        self.reader = VoteSiteReader(site: site)
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
        restartLoop(readFirst: false, initialDelay: nil)
    }

    /// The vault locked, was held or wiped: no more runs until the next opening, and what goes on is cancelled.
    func stop() {
        wanted = false
        halt()
    }

    /// The app left the foreground: no run while it is away (there is no background job); what goes on is cancelled.
    func pause() {
        away = true
        halt()
    }

    /// The app came back: when the work was started, a run now if the last one is older than ``returnAfter`` and the
    /// hourly wait for what remains of the hour otherwise.
    func resume() {
        away = false
        guard wanted else { return }
        if let last = lastRun, let now = votes?.now() {
            let age = now.timeIntervalSince(last)
            if age >= 0, age < Self.returnAfter {
                restartLoop(readFirst: true, initialDelay: max(.zero, every - .seconds(age)))
                return
            }
        }
        restartLoop(readFirst: true, initialDelay: nil)
    }

    var running: Bool { loop != nil }

    private func halt() {
        loop?.cancel()
        loop = nil
        for cancel in cancellers.values { cancel() }
        cancellers = [:]
    }

    private func restartLoop(readFirst: Bool, initialDelay: Duration?) {
        loop?.cancel()
        let every = every
        let sleep = sleep
        loop = Task { @MainActor [weak self] in
            var read = readFirst
            var delay = initialDelay
            while !Task.isCancelled {
                if delay == nil {
                    // The runner is not held while it waits: a manager let go without a lock ends the loop.
                    guard let self else { return }
                    // Locked, held or unreachable: the next hour (or the next opening) tries again; the screens say what waits.
                    try? await syncOnce(read: read)
                    read = true
                }
                do { try await sleep(delay ?? every) } catch { return }
                delay = nil
            }
        }
    }

    // MARK: A run

    /// One run: the service list, the proposals, and the results that are due, each stage on its own (a refusal of the
    /// vault in one does not starve the others; the first failure is thrown at the end). Not while another run goes on.
    func syncOnce(read: Bool = true) async throws {
        guard site.configured else { return }
        try await serially(.runs) { [self] in
            // Held or due (VAULT-MESSAGING §3.6.3): nothing goes to the vault, the site is not read either.
            guard let votes, !votes.held() else { return }
            if read { try await votes.read(quietly: true) }
            try Task.checkCancellation()
            guard votes.availability == .available, !votes.held() else { return }
            var failure: (any Error)?
            @MainActor func stage(_ run: @MainActor () async throws -> Void) async throws {
                do {
                    try await run()
                } catch is CancellationError {
                    throw CancellationError()
                } catch let f as VaultFailure where f.code == Self.codeTooLarge {
                    // A list the vault refused as too large leaves its held list; the proposals and the results go on.
                } catch {
                    failure = failure ?? error
                }
                try Task.checkCancellation()
            }
            try await stage { try await syncLists() }
            try await stage { try await syncProposals(only: nil) }
            try await stage { try await submitDue() }
            if let failure { throw failure }
            lastRun = votes.now()
        }
    }

    /// A vote's screen opened: its documents and the index, so that the vault can compare them with what it holds.
    func siteCheck(_ key: VoteKey) async throws {
        guard site.configured else { return }
        try await serially(.runs) { [self] in try await syncProposals(only: key.proposalID, quietly: false) }
        votes?.refreshQuietly()
    }

    private func syncLists() async throws {
        guard let votes else { return }
        guard case .found(let doc) = try await reader.get("services.json", VoteSiteLimits.listMax),
              case .found(let sig) = try await reader.get("services.json.sig", VoteSiteLimits.sigMax)
        else { return }
        let version = await Task.detached { VoteSync.versionOf(doc) }.value ?? 0
        let current = VoteSync.ServedList(doc: doc, sig: sig, version: version)
        // A list the vault would refuse the whole call for is not sent (nor the versions after it).
        guard current.sendable else { return }
        let held = votes.listVersion
        let between = try await missingVersions(after: held, upTo: version)
        let heldSha256 = votes.listSha256
        let plan = await Task.detached {
            VoteSync.planLists(current, heldVersion: held, heldSha256: heldSha256, between: between)
        }.value
        switch plan {
        case .nothing: return
        case let .confirm(version, sha256): _ = try await send(VoteSync.confirmCall(version: version, sha256: sha256), quietly: true)
        case .send(let lists):
            // One call at a time: its body is built (off the main actor) just before it is sent.
            for batch in VoteSync.listBatches(lists) {
                let body = await Task.detached { VoteSync.listBody(batch) }.value
                guard try await send(body, quietly: true) != nil else { break }
            }
        }
    }

    /// The versions between the held one and [version] in order, once the site serves them; a copy not there yet (404), or
    /// one the vault would refuse, ends them (a later run goes on). At most ``VoteSync/maxLists`` a run: `version` is the
    /// unverified document's own word, so a huge one cannot loop or fill memory.
    private func missingVersions(after held: Int64?, upTo version: Int64) async throws -> [VoteSync.ServedList] {
        guard let held, version > held + 1 else { return [] }
        var out: [VoteSync.ServedList] = []
        for v in (held + 1)..<min(version, held + 1 + Int64(VoteSync.maxLists)) {
            guard let next = try await reader.servedVersion(v), next.sendable else { break }
            out.append(next)
        }
        return out
    }

    private func syncProposals(only: String?, quietly: Bool = true) async throws {
        guard let votes else { return }
        let held = Self.unique(votes.votes.map(\.proposalID))
        var byID: [String: String] = [:]
        var order: [String] = []
        if case .found(let bytes) = try await reader.get("index.json", VoteSiteLimits.indexMax) {
            var seen = Set<String>()
            for e in await Task.detached(operation: { VoteSync.indexOf(bytes) }).value {
                if seen.insert(e.proposalID).inserted { order.append(e.proposalID) }
                if let json = e.json { byID[e.proposalID] = json } else { byID[e.proposalID] = nil }
            }
        }
        // The held proposals, then the newest the vault lacks (it learns what to ask the service for from them).
        let ids = only.map { [$0] } ?? held + order.filter { !held.contains($0) }.suffix(VoteSync.maxNew)
        var read: [Read] = []
        for id in ids {
            let index = byID[id]
            read.append(Read(id: id, index: index, document: try await reader.readDocument(id, index: index)))
        }
        let items = read
        let calls = await Task.detached {
            VoteSync.entryCalls(items.map { VoteSync.entryJson($0.id, index: $0.index, $0.document) })
        }.value
        for call in calls {
            guard try await send(call, quietly: quietly) != nil else { break }
        }
    }

    /// A proposal's entry as read from the site.
    private struct Read: Sendable {
        let id: String
        let index: String?
        let document: VoteSync.Document
    }

    /// Sends one `vote.site.sync` body within the limits (§10.19.8): inline when its padded inner plaintext fits §5.5's
    /// 245,760 bytes, otherwise as a claim-check blob to the app's own vault, and never over 8,257,532 bytes. Nil when it
    /// was not sent. A blob the vault was not handed after the upload is discarded, as attachments do.
    private func send(_ body: [UInt8], quietly: Bool) async throws -> JsonObject? {
        guard body.count <= VoteSync.bodyMax else { return nil }
        let inline = await Task.detached { VoteSync.fitsInline(body) }.value
        try Task.checkCancellation()
        if inline { return try await guarded { try await self.ops(quietly).voteSiteSync(body: body) } }
        var sealed = try await Task.detached { try ClaimBlob.seal(body) }.value
        defer { sealed.wipe() }
        try Task.checkCancellation()
        let id = try await upload(sealed.blob, quietly: quietly)
        do {
            return try await guarded {
                try await self.ops(quietly).voteSiteSyncBlob(blobID: id, key: sealed.key, sha256: sealed.sha256, size: sealed.size)
            }
        } catch {
            // It would hold the mailbox's single slot until it expires otherwise.
            _ = try? await ops(quietly).deleteBlob(id)
            throw error
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
                try Task.checkCancellation()
            }
        }
    }

    // MARK: The results

    /// The checks that are due: closed, `pending`, and not before the vault's `due_at`; none that is already on its way.
    func submitDue() async throws {
        guard let votes else { return }
        let at = votes.now()
        for v in votes.votes {
            try Task.checkCancellation()
            guard let c = v.check, v.state == .closed, c.state == .pending, c.dueAt.map({ $0 <= at }) ?? true,
                  inflight[v.key] == nil
            else { continue }
            do {
                _ = try await checkResults(v.key, quietly: true)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
        }
    }

    /// The due checks after a `check_due` event: in the line of the runs (cancelled with them).
    func submitDueNow() async {
        guard site.configured else { return }
        try? await serially(.runs) { [self] in try await submitDue() }
    }

    /// The results of a closed vote, fetched, checked as far as the app can (BALLOT-PROTOCOL §8.4: the rows' hash, order
    /// and tree, and the member's row) and handed to the vault (the member's **Check again**, and the run's retry). The
    /// vault alone judges. An attempt already on its way for the vote is joined, not repeated.
    func checkResults(_ key: VoteKey, quietly: Bool) async throws -> ResultsOutcome {
        guard site.configured else { return .siteUnreachable }
        if let running = inflight[key] { return try await running.value }
        let task = Task { @MainActor [self] () -> ResultsOutcome in
            defer { inflight[key] = nil }
            return try await serially(.attempts) { [self] in try await attempt(key, quietly: quietly) }
        }
        inflight[key] = task
        return try await task.value
    }

    private func attempt(_ key: VoteKey, quietly: Bool) async throws -> ResultsOutcome {
        guard let votes else { throw CancellationError() }
        let detail = try await votes.detail(key, quietly: quietly)
        try Task.checkCancellation()
        guard let tag = detail.recordTag.flatMap({ try? Base64s.decodeStd($0, Self.tagSize) }) else { return fail(key, .problem) }
        let files: VoteSiteReader.ResultsFiles
        switch try await reader.fetchResults(key.proposalID) {
        case .tooLarge: return fail(key, .problem, tooLarge: true)
        case .siteDown: return unavailable(key, true)
        case .notPublished: return unavailable(key, false)
        case .files(let f): files = f
        }
        // The vault refuses a signature of another length, and a bundle that is no object, with the whole call.
        guard files.sig.count == VoteSiteLimits.sigLength, let bundle = VoteSync.compactObject(files.bundle) else {
            return fail(key, .problem)
        }
        let doc = files.doc
        let rows = files.rows
        let sig = files.sig
        let own: OwnRow
        do {
            own = try await Task.detached { try VoteRows.ownRow(results: doc, rows: rows, recordTag: tag) }.value
        } catch {
            return fail(key, .problem)
        }
        guard let body = Self.submitBody(key, doc: doc, sig: sig, bundle: bundle, own: own) else { return fail(key, .problem) }
        try Task.checkCancellation()
        let answer = try await guarded { try await self.ops(quietly).voteResultsSubmit(body: body) }
        try Task.checkCancellation()
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
    /// the site has it (its choice included: a receipt cannot be checked without it) and its proof. Nil when the row is
    /// not what the vault reads (a key of other than 32 bytes, a signature of other than 64, a choice id of other than
    /// `[a-z0-9-]{1,32}`): it would refuse the whole call.
    static func submitBody(_ key: VoteKey, doc: [UInt8], sig: [UInt8], bundle: String, own: OwnRow) -> [UInt8]? {
        let row = JsonBuilder()
        if let b = own.ballot {
            guard let vk = try? b.string("vk"), let choice = try? b.string("choice_id"), let bs = try? b.string("ballot_sig"),
                  (try? Base64s.decodeStd(vk, 32)) != nil, (try? Base64s.decodeStd(bs, VoteSiteLimits.sigLength)) != nil,
                  validChoice(choice)
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

    private static func validChoice(_ s: String) -> Bool {
        (1...32).contains(s.utf8.count) && s.utf8.allSatisfy { ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2D }
    }

    /// The site could not be reached, or had no results (yet): which of the two is what a `gave_up` check will say.
    private func unavailable(_ key: VoteKey, _ siteDown: Bool) -> ResultsOutcome {
        siteDown ? fail(key, .siteUnreachable, .site) : fail(key, .notPublished, .unpublished)
    }

    private func fail(_ key: VoteKey, _ outcome: ResultsOutcome, _ why: GaveUpWhy? = nil, tooLarge: Bool = false) -> ResultsOutcome {
        guard !Task.isCancelled else { return outcome }
        votes?.hint(key) {
            $0.gaveUp = why ?? $0.gaveUp
            $0.resultsProblem = outcome == .problem
            $0.resultsTooLarge = tooLarge
        }
        return outcome
    }

    /// For a `gave_up` check the app has no reason for: looks at the site once and remembers which of two things.
    func diagnoseGaveUp(_ key: VoteKey) async {
        guard site.configured, let votes, votes.hints[key]?.gaveUp == nil else { return }
        guard let answer = try? await reader.get("p/\(key.proposalID)/results.json", VoteSiteLimits.resultsMax) else { return }
        switch answer {
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

    /// Runs [work] after the work before it on [chain], one at a time. It is cancelled by ``stop()`` and ``pause()``; work
    /// that was cancelled before it began does not begin.
    private func serially<T: Sendable>(_ chain: Chain, _ work: @escaping @MainActor () async throws -> T) async throws -> T {
        let before = chain == .runs ? runs : attempts
        let id = nextWork
        nextWork += 1
        let task = Task { @MainActor [self] () -> Result<T, any Error> in
            await before?.value
            defer { cancellers[id] = nil }
            if Task.isCancelled { return .failure(CancellationError()) }
            do { return .success(try await work()) } catch { return .failure(error) }
        }
        cancellers[id] = { task.cancel() }
        let link = Task { _ = await task.value }
        if chain == .runs { runs = link } else { attempts = link }
        return try await task.value.get()
    }

    private func guarded<T: Sendable>(_ body: @MainActor () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw VaultFailures.map(error)
        }
    }

    private static func unique(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }
}
