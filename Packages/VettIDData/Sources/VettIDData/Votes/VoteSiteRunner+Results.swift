import Foundation
import VettIDCrypto
import VettIDVault

/// What one attempt at a vote's results saw, for its ``ResultsAttempt``.
struct AttemptTrace {
    var gaveUp = false
    var resultsSha256: String?
    var sigSha256: String?
    var bundleSha256: String?
    /// `rows.json`'s bytes were downloaded: such an attempt counts toward the daily limit, whatever follows.
    var rowsDownloaded = false
    /// `rows.json` was fetched with a body (read, or cut at its cap): the time of the last rows download.
    var rowsSpent = false
    /// `rows.json` was had (read, found over its cap, or not needed): false when it was absent or could not be fetched.
    var rowsFetched = false
    /// The rows.json download was deferred on a metered network.
    var deferred = false
    /// The submission carried the member's real row (not `rows_unavailable`).
    var sentRow = false
    /// An ``ResultsOutcome/unchanged`` re-check keeps the last attempt's "answered" (it is the same submission).
    var answered = false
    /// The vault left the check for a reason of its own side.
    var vaultSide = false
}

/// The reasons of a check left on the vault's side: `rows.json` is fetched again after them (§10.19.6).
private let vaultSideReasons: Set<String> = ["trust_root", "service_list", "clock"]

extension VoteSiteRunner {
    /// The results of a closed vote, fetched, checked as an observer does (BALLOT-PROTOCOL §8.4 items 2 to 4: the rows'
    /// hash, order and trees, every ballot's signature and choice, the tally and the member's row) and handed to the vault
    /// (the member's **Check again**, and the run's retry) whenever what the vault itself checks can hold: the results
    /// parse, their signature is one the vault reads, the bundle is an object, and the member's row has a proof to
    /// `rows_root` with `tree_size` = `counts.eligible` (VAULT-MESSAGING 0.83.2 §10.19.6 step 1); any other failure of
    /// the check is ``VoteHint/resultsDontAddUp`` and does not stop the submit. When the member's row cannot be had, a
    /// vault with `vote_rows` is told so (`rows_unavailable`) and one without it is sent nothing (§10.19.6 step 3). The vault
    /// alone judges. An attempt already on its way for the vote is joined, not repeated. [due]: the run's own re-check, not
    /// the member's **Check again**.
    func checkResults(_ key: VoteKey, quietly: Bool, due: Bool = false) async throws -> ResultsOutcome {
        guard site.configured else { return .siteUnreachable }
        if let running = inflight[key] { return try await running.value }
        let generation = haltGeneration
        let task = Task { @MainActor [self] () -> ResultsOutcome in
            defer { inflight[key] = nil }
            // A lock or the app leaving between the call and this start: it does not begin.
            guard generation == haltGeneration else { throw CancellationError() }
            return try await serially(.attempts) { [self] in try await attempt(key, quietly: quietly, due: due) }
        }
        inflight[key] = task
        return try await task.value
    }

    /// One attempt, and the record of it for the daily re-check: kept whatever it came to (a failure too: then `rows.json`
    /// is fetched again next time, since a lost submission may be the cause). One cut off by a lock after it downloaded
    /// `rows.json` still counts toward the daily limit, with only its time and hashes. Never after a wipe (the epoch).
    private func attempt(_ key: VoteKey, quietly: Bool, due: Bool) async throws -> ResultsOutcome {
        guard let votes else { throw CancellationError() }
        let gaveUp = votes.votes.first { $0.key == key }?.check?.state == .gaveUp
        // Looked at again in the line of the attempts, so that two passes that both found it due (a `check_due` event and
        // the hourly run) do not run it back to back.
        if due, gaveUp, !votes.attempts.dailyDue(key, at: votes.now()) { return .unchanged }
        let generation = haltGeneration
        let epoch = votes.attempts.epoch
        var trace = AttemptTrace()
        trace.gaveUp = gaveUp
        var out: ResultsOutcome?
        var cancelled = false
        defer {
            if (!cancelled && haltGeneration == generation) || trace.rowsDownloaded {
                record(key, epoch: epoch, trace, cancelled ? nil : out, due: due)
            }
        }
        do {
            out = try await run(key, quietly: quietly, &trace)
        } catch {
            cancelled = error is CancellationError || Task.isCancelled
            throw error
        }
        return out ?? .problem
    }

    // swiftlint:disable cyclomatic_complexity function_body_length
    private func run(_ key: VoteKey, quietly: Bool, _ trace: inout AttemptTrace) async throws -> ResultsOutcome {
        guard let votes else { throw CancellationError() }
        // `other_rows` and `rows_unavailable` only to a vault that lists `vote_rows` (§10.19.6 step 3, "Version gating").
        let rowsOK = votes.voteRows()
        let detail = try await votes.detail(key, quietly: quietly)
        try Task.checkCancellation()
        guard let tag = detail.recordTag.flatMap({ try? Base64s.decodeStd($0, Self.tagSize) }) else { return fail(key, .problem) }
        let doc: [UInt8]
        let sig: [UInt8]
        let bundleBytes: [UInt8]
        // The signature and the bundle are always fetched (small): a fixed one beside the same results.json is a change.
        switch try await reader.fetchSmall(key.proposalID) {
        case .tooLarge: return fail(key, .problem, tooLarge: true)
        case .siteDown: return unavailable(key, true)
        case .notPublished: return unavailable(key, false)
        case let .files(d, s, b): (doc, sig, bundleBytes) = (d, s, b)
        }
        trace.resultsSha256 = Bytes.hex(Bytes.sha256(doc))
        trace.sigSha256 = Bytes.hex(Bytes.sha256(sig))
        trace.bundleSha256 = Bytes.hex(Bytes.sha256(bundleBytes))
        // A `gave_up` check run again (§10.19.6): with the same results.json, signature and bundle as the last attempt,
        // which had rows.json, was answered and did not end on the vault's side, rows.json is not downloaded again and
        // nothing is sent.
        if trace.gaveUp, votes.attempts.attempt(key)?.skipsRows(
            results: trace.resultsSha256, sig: trace.sigSha256, bundle: trace.bundleSha256
        ) == true {
            trace.rowsFetched = true
            trace.answered = true
            trace.sentRow = true
            return .unchanged
        }
        // The vault refuses a signature of another length, and a bundle that is no object, with the whole call.
        let level = VoteSync.Level.resultsBundle
        let compact = await Task.detached { VoteSync.compactObject(bundleBytes, level: level) }.value
        try Task.checkCancellation()
        guard sig.count == VoteSiteLimits.sigLength, let bundle = compact else { return fail(key, .problem) }
        // The cap on rows.json follows counts.eligible (§10.19.6 step 1). An integer outside 1 to 100,000 cannot bound it:
        // with `vote_rows` the row cannot be had and the vault judges the results themselves (a wrong counts.eligible is a
        // contradiction, step 3), without rows.json being downloaded.
        var rows: [UInt8]?
        switch VoteRows.rowsBound(results: doc) {
        case .unreadable: return fail(key, .problem)
        case .outOfRange:
            guard rowsOK else { return fail(key, .problem) }
            trace.rowsFetched = true
        case .cap(let cap):
            // A `gave_up` record past the 7 days from its first re-check downloads rows.json (up to 51 MB) on a metered
            // network at most weekly (owner decision a, 2026-11-06): otherwise nothing more is done now and nothing is sent;
            // the vote's own state line says where it stands. The daily rule still governs the small fetches.
            if trace.gaveUp, votes.attempts.rowsDeferred(key, at: votes.now(), unmetered: votes.unmetered) {
                trace.deferred = true
                return .deferred
            }
            switch try await reader.fetchRows(key.proposalID, cap: cap) {
            case .rows(let b):
                rows = b
                trace.rowsDownloaded = true
                trace.rowsSpent = true
                trace.rowsFetched = true
            case .tooLarge:
                // More rows than the results can have: no row with a proof.
                trace.rowsSpent = true
                trace.rowsFetched = true
                if !rowsOK { return noRow(key) }
            case .absent:
                // A definite 404 beside the signed results: with `vote_rows` the member's row cannot be had; a timeout or a
                // 5xx is tried again at the next attempt, and rows.json fetched again (it may yet be published).
                if !rowsOK { return unavailable(key, false) }
            case .down: return unavailable(key, true)
            }
        }
        // The heavy part (up to 51 MB: the hash, the reading, the trees, the proof, the signatures) off the main actor.
        var examined: SubmittedRows = .unavailable
        var dontAddUp = true
        if let rows {
            let result = await Task.detached { () -> (SubmittedRows, Bool)? in
                do {
                    let checked = try VoteRows.ownRow(results: doc, rows: rows, recordTag: tag)
                    // Another row under the member's tag (§10.19.6 step 1) goes only to a vault that knows `other_rows`.
                    return (SubmittedRows(own: checked.own, others: rowsOK ? checked.others : []), checked.problem != nil)
                } catch let p as ResultsProblem {
                    // What stops the submit of a row (§10.19.6 step 1): with `vote_rows` the row cannot be had and
                    // `rows_unavailable` is sent; without it nothing is. Results that do not read are never sent.
                    return rowsOK && p.reason != "results" ? (.unavailable, true) : nil
                } catch {
                    return nil
                }
            }.value
            try Task.checkCancellation()
            guard let result else { return noRow(key) }
            (examined, dontAddUp) = result
        }
        // Over the request limit, or a row the vault would refuse as a whole: with `vote_rows`, `rows_unavailable`.
        var body = ResultsBody.build(key, doc: doc, sig: sig, bundle: bundle, rows: examined)
        if body == nil {
            guard rowsOK else { return fail(key, .problem) }
            examined = .unavailable
            dontAddUp = true
            body = ResultsBody.build(key, doc: doc, sig: sig, bundle: bundle, rows: examined)
        }
        if !examined.others.isEmpty, let full = body {
            let rowsNow = examined
            let (sent, fitted) = await Task.detached {
                Self.fitted(rowsNow, full) { ResultsBody.build(key, doc: doc, sig: sig, bundle: bundle, rows: $0) }
            }.value
            (examined, body) = (sent, fitted)
        }
        try Task.checkCancellation()
        guard let body else { return fail(key, .problem) }
        // The site's numbers must also be the ones the vault holds (`vote.get`), as for a check again: a verdict about
        // another copy says nothing of the numbers the screen shows (chosen; not in the spec).
        let sameNumbers = await Task.detached { Self.sameNumbers(doc, detail) }.value
        try Task.checkCancellation()
        trace.sentRow = !examined.isUnavailable
        // A failure of the observer's check outside the four inputs does not hold the row back (VAULT-MESSAGING 0.83.2
        // §10.19.6 step 1): the vault judges it, and the member is told the rest doesn't add up whatever it answers.
        return try await submit(key, body, dontAddUp: dontAddUp || !sameNumbers, quietly: quietly, &trace)
    }
    // swiftlint:enable cyclomatic_complexity function_body_length

    /// [body] when the request fits; else fewer extra rows, the largest dropped first, down to one; else none of them
    /// (`rows_unavailable` is a body that cannot be too large for a row). The rows the request goes with are returned too.
    private nonisolated static func fitted(
        _ rows: SubmittedRows, _ full: [UInt8], build: (SubmittedRows) -> [UInt8]?
    ) -> (SubmittedRows, [UInt8]?) {
        func fits(_ b: [UInt8]) -> Bool { VoteSync.fitsInline(b, type: VaultApi.typeVoteResultsSubmit) }
        if fits(full) { return (rows, full) }
        if let fewer = ResultsBody.fewer(rows, fits: fits, body: build), let b = build(fewer) { return (fewer, b) }
        // One verifying extra row did not fit either: the row alone, or `rows_unavailable` when even that is over.
        let alone = rows.with(others: [])
        if let b = build(alone), fits(b) { return (alone, b) }
        return (.unavailable, build(.unavailable))
    }

    /// No row with a proof: nothing to submit, and results that don't add up for the screens.
    func noRow(_ key: VoteKey) -> ResultsOutcome {
        let outcome = fail(key, .problem)
        if !Task.isCancelled {
            votes?.hint(key) {
                $0.observerVerdict = false
                $0.verdictKept = false
            }
        }
        return outcome
    }

    /// Hands [body] to the vault and keeps what it answered, and whether the rest of the results [dontAddUp], for
    /// the screens.
    private func submit(
        _ key: VoteKey, _ body: [UInt8], dontAddUp: Bool, quietly: Bool, _ trace: inout AttemptTrace
    ) async throws -> ResultsOutcome {
        guard let votes else { throw CancellationError() }
        let answer: JsonObject
        do {
            answer = try await guarded { try await self.ops(quietly).voteResultsSubmit(body: body) }
        } catch {
            // A refused or lost call is kept too: the find is the app's own, whatever the vault made of it (chosen; not in
            // the spec).
            if !Task.isCancelled, !(error is CancellationError) {
                votes.hint(key) {
                    $0.resultsDontAddUp = dontAddUp
                    $0.observerVerdict = !dontAddUp
                    $0.verdictKept = false
                }
            }
            throw error
        }
        try Task.checkCancellation()
        var state = CheckState.unknown
        var reason: String?
        if case .object(let check)? = answer["check"] {
            state = CheckState(rawValue: VaultJSON.string(check, "state") ?? "") ?? .unknown
            reason = VaultJSON.string(check, "reason")
        }
        trace.vaultSide = reason.map(vaultSideReasons.contains) ?? false
        // A submission the vault leaves pending for its input is the problem the screens say.
        let input = state == .pending && reason == "input"
        votes.hint(key) {
            $0.gaveUp = nil
            $0.resultsProblem = input
            $0.resultsTooLarge = false
            $0.resultsDontAddUp = dontAddUp
            $0.observerVerdict = !dontAddUp
            // Kept for the next opening only once the vault judged the results it was handed.
            $0.verdictKept = state == .verified || state == .unconfirmed
        }
        votes.refreshQuietly()
        return .submitted(state)
    }

    /// The site could not be reached, or had no results (yet): which of the two is what a `gave_up` check will say.
    func unavailable(_ key: VoteKey, _ siteDown: Bool) -> ResultsOutcome {
        siteDown ? fail(key, .siteUnreachable, .site) : fail(key, .notPublished, .unpublished)
    }

    func fail(_ key: VoteKey, _ outcome: ResultsOutcome, _ why: GaveUpWhy? = nil, tooLarge: Bool = false) -> ResultsOutcome {
        guard !Task.isCancelled else { return outcome }
        votes?.hint(key) {
            $0.gaveUp = why ?? $0.gaveUp
            $0.resultsProblem = outcome == .problem
            $0.resultsTooLarge = tooLarge
            // Nothing was submitted this time: what the screens say is this attempt's. The verdict of an earlier check
            // (``VoteHint/observerVerdict``) stays: the documents are write-once.
            $0.resultsDontAddUp = false
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

    // MARK: The kept attempts

    /// Keeps what [trace] saw for the daily re-check and the download cap (no choice, row or proof). An attempt that ended in
    /// a failure counts as not having had the rows. A **Check again** that ended unchanged or deferred (nothing sent) keeps
    /// the last attempt's time, so it does not defer the daily re-check (owner decision, #317 item 3); the daily re-check's
    /// own is its attempt of the day.
    private func record(_ key: VoteKey, epoch: Int, _ trace: AttemptTrace, _ out: ResultsOutcome?, due: Bool) {
        guard let votes else { return }
        var final = false
        var submitted = false
        if case .submitted(let s)? = out {
            submitted = true
            final = VotesManager.finalCheck(s)
        }
        let unchanged = out == .unchanged
        let keepTime = !due && (unchanged || out == .deferred)
        let at = Int64(votes.now().timeIntervalSince1970 * 1000)
        let last = votes.attempts.attempt(key)
        var entry = ResultsAttempt(
            key: ResultsAttempts.id(key), atMs: at, resultsSha256: trace.resultsSha256, rowsFetched: trace.rowsFetched && out != nil,
            vaultSide: trace.vaultSide, answered: submitted || (trace.answered && unchanged),
            sentRow: trace.sentRow && (submitted || unchanged), sigSha256: trace.sigSha256, bundleSha256: trace.bundleSha256
        )
        entry.firstRecheckMs = last?.firstRecheckMs ?? (trace.gaveUp ? at : nil)
        entry.lastRowsMs = trace.rowsSpent ? at : last?.lastRowsMs
        // A deferred download keeps what the last attempt knew (the skip's facts and hashes); only its time moves, and not
        // for the member's Check again.
        if trace.deferred, var kept = last {
            kept.atMs = keepTime ? kept.atMs : at
            entry = kept
        } else if keepTime, let last {
            entry.atMs = last.atMs
        }
        votes.attempts.put(key, final ? nil : entry, epoch: epoch)
    }
}
