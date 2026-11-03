import Foundation
import VettIDCrypto

/// What a check of the published results again, when a vote's screen opens, came to (owner decision 2026-11-02).
public enum RecheckOutcome: Equatable, Sendable {
    /// The observer's check passed: the numbers can be shown.
    case consistent
    /// It failed, or the member's row could not be had: ``VoteHint/resultsDontAddUp`` is set.
    case dontAddUp
    /// The results could not be fetched (or no site is configured): the numbers stay hidden.
    case notChecked
}

extension VoteSiteRunner {
    /// The results of a vote whose check is `verified` or `unconfirmed`, fetched again and checked as an observer does,
    /// when its screen opens (owner decision 2026-11-02): the hint ``VoteHint/resultsDontAddUp`` is kept in memory only,
    /// so after a lock this is how the screen learns it again. Nothing is submitted; nothing is stored. In the line of the
    /// attempts, so a lock cancels it.
    ///
    /// A verdict kept since the vault opened (``VoteHint/verdictKept``: an earlier check again, or a submission the vault
    /// answered `verified` or `unconfirmed`) is used as it is: the documents are write-once, and only a lock loses it.
    /// Cancelling the caller cancels the fetch.
    func recheckResults(_ key: VoteKey) async throws -> RecheckOutcome {
        guard site.configured else { return .notChecked }
        if let hint = votes?.hints[key], hint.verdictKept, let verdict = hint.observerVerdict {
            return verdict ? .consistent : .dontAddUp
        }
        return try await serially(.attempts, followCancel: true) { [self] in try await recheck(key) }
    }

    private func recheck(_ key: VoteKey) async throws -> RecheckOutcome {
        guard let votes else { throw CancellationError() }
        let detail: VoteDetail
        do {
            detail = try await votes.detail(key, quietly: false)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            return .notChecked
        }
        try Task.checkCancellation()
        guard let tag = detail.recordTag.flatMap({ try? Base64s.decodeStd($0, Self.tagSize) }) else { return .notChecked }
        let files: VoteSiteReader.ResultsFiles
        switch try await reader.fetchResults(key.proposalID) {
        case .tooLarge: return keepRecheck(key, consistent: false)
        case .siteDown, .notPublished: return .notChecked
        case .files(let f): files = f
        }
        let doc = files.doc
        let rows = files.rows
        // A failure that leaves no row with a proof is a problem as well: the results no longer hold what was checked.
        // The site's numbers must also be the ones the vault verified (`vote.get`): the site's copy is what is checked
        // here, not the vault's (chosen; not in the spec).
        let consistent = await Task.detached {
            guard Self.sameNumbers(doc, detail) else { return false }
            return (try? VoteRows.ownRow(results: doc, rows: rows, recordTag: tag)).map { $0.problem == nil } ?? false
        }.value
        try Task.checkCancellation()
        return keepRecheck(key, consistent: consistent)
    }

    private func keepRecheck(_ key: VoteKey, consistent: Bool) -> RecheckOutcome {
        votes?.hint(key) {
            $0.resultsDontAddUp = !consistent
            $0.observerVerdict = consistent
            $0.verdictKept = true
        }
        return consistent ? .consistent : .dontAddUp
    }

    /// Whether the site's `tally` and `counts` are the ones [detail] holds from the vault, where it holds them.
    nonisolated static func sameNumbers(_ doc: [UInt8], _ detail: VoteDetail) -> Bool {
        guard let o = try? StrictJson.parseObject(doc) else { return false }
        let most = UInt64(Int64.max)
        if let held = detail.tally {
            guard let t = try? o.obj("tally") else { return false }
            var site: [String: Int64] = [:]
            for (name, value) in t.members {
                guard let n = try? value.asUint(min: 0, max: most) else { return false }
                site[name] = Int64(n)
            }
            if site != held { return false }
        }
        if let held = detail.counts {
            guard let c = try? o.obj("counts") else { return false }
            func n(_ name: String, _ absent: Int64?) -> Int64? {
                if c[name] == nil { return absent }
                return (try? c.uint(name, min: 0, max: most)).map { Int64($0) }
            }
            guard let e = n("eligible", nil), let b = n("ballots", nil), let r = n("removed", 0), let u = n("unhandled", 0) else {
                return false
            }
            let site = VoteCounts(eligible: e, ballots: b, removed: r, unhandled: u)
            if site != held { return false }
        }
        return true
    }
}
