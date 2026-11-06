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
        guard let detail = try await detailForRecheck(key) else { return .notChecked }
        // Nothing checked (no tag to look for, results.json over the limit or not reading): not a failed observer check but
        // one that could not run, so "not rechecked" and no number, not "don't add up" (#317 item 2).
        guard let tag = detail.recordTag.flatMap({ try? Base64s.decodeStd($0, Self.tagSize) }) else { return .notChecked }
        let doc: [UInt8]
        switch try await reader.fetchSmall(key.proposalID) {
        case .tooLarge, .siteDown, .notPublished: return .notChecked
        case let .files(d, _, _): doc = d
        }
        // A cap that does not read (`counts.eligible` missing or outside 1 to 100,000) checks nothing either.
        guard case .cap(let cap) = VoteRows.rowsBound(results: doc) else { return .notChecked }
        let rows: [UInt8]
        switch try await reader.fetchRows(key.proposalID, cap: cap) {
        case .absent, .down: return .notChecked
        // An over-cap rows.json is still a failed check: its cap comes from a results.json that parsed.
        case .tooLarge: return keepRecheck(key, consistent: false)
        case .rows(let b): rows = b
        }
        // A failure that leaves no row with a proof is a problem as well: the results no longer hold what was checked.
        // The site's numbers must also be the ones the vault verified (`vote.get`): the site's copy is what is checked
        // here, not the vault's (chosen; not in the spec).
        let verdict = await Task.detached { Self.verdict(doc, rows, tag, detail) }.value
        try Task.checkCancellation()
        guard let verdict else { return .notChecked }
        return keepRecheck(key, consistent: verdict)
    }

    /// The vault's `vote.get` of [key]; nil when it cannot be read (nothing is checked then). Cancellation passes through.
    private func detailForRecheck(_ key: VoteKey) async throws -> VoteDetail? {
        guard let votes else { throw CancellationError() }
        do {
            let detail = try await votes.detail(key, quietly: false)
            try Task.checkCancellation()
            return detail
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            return nil
        }
    }

    /// Whether the observer's check of [doc] and [rows] passes, with the vault's numbers; nil when the results do not read at
    /// all (nothing was checked).
    private nonisolated static func verdict(_ doc: [UInt8], _ rows: [UInt8], _ tag: [UInt8], _ detail: VoteDetail) -> Bool? {
        guard sameNumbers(doc, detail) else { return false }
        do {
            return try VoteRows.ownRow(results: doc, rows: rows, recordTag: tag).problem == nil
        } catch let p as ResultsProblem {
            return p.reason == "results" ? nil : false
        } catch {
            return false
        }
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
