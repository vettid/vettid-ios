import Foundation
import Testing
import VettIDCrypto
@testable import VettIDData
import VettIDDataTesting
@testable import VettIDVault

// Fixtures stay on one line each.
// swiftlint:disable line_length

private let conn = VoteFixture.conn
private let pid = VoteFixture.pid
private let key = VoteFixture.key

/// The published results checked again when a vote's screen opens (owner decision 2026-11-02), of ``VoteSiteTests``.
extension VoteSiteTests {
    /// `vote.get` of the closed, verified vote, with the tally and counts the vault verified.
    func verifiedDetail(tally: String = #"{"abstain":0,"no":0,"yes":1}"#) -> JsonObject {
        voteObj(#"{"proposal_id":"\#(pid)","connection_id":"\#(conn)","title":"Adopt the budget","state":"closed","text":"t","choices":[{"id":"yes","label":"Yes"}],"record_tag":"\#(Base64s.encodeStd(VoteResultsFixture.tag))","extensions":0,"tally":\#(tally),"counts":{"ballots":1,"eligible":2,"removed":0,"unhandled":0}}"#)
    }

    /// The check of the published results again when a vote's screen opens (owner decision 2026-11-02): after a lock has
    /// forgotten what the app found, results that don't add up are found again; its verdict is kept until the next lock
    /// (no second fetch), and an attempt that submits nothing does not undo it; good results pass; numbers other than the
    /// vault's, or no row with a proof, are a problem; a site that can't be reached checks nothing. Nothing is submitted.
    @Test func openingAVerifiedVoteChecksItsResultsAgainWithoutSubmitting() async throws {
        let ops = FakeVoteOps()
        ops.list = listing(summary(state: "closed", extra: #","ballot":{"state":"recorded"},"check":{"state":"verified"}"#))
        ops.detail = verifiedDetail()
        let m = siteManager(ops)
        try await m.refresh()
        VoteResultsFixture.publish(site, pid)
        let doc = try #require(String(bytes: VoteResultsFixture.results, encoding: .utf8))
        let changed = doc.replacingOccurrences(of: #""tally":{"abstain":0,"no":0,"yes":1}"#, with: #""tally":{"abstain":0,"no":1,"yes":0}"#)
        #expect(changed != doc)
        site["p/\(pid)/results.json"] = .found(Array(changed.utf8))
        ops.detail = verifiedDetail(tally: #"{"abstain":0,"no":1,"yes":0}"#)
        m.hint(key) { $0.resultsDontAddUp = true }
        // A lock forgets it.
        m.clear()
        #expect(m.hints[key] == nil)
        try await m.refresh()
        #expect(try await m.recheckResults(key) == .dontAddUp)
        #expect(m.hints[key]?.resultsDontAddUp == true && m.hints[key]?.observerVerdict == false)
        // Kept until the next lock: opening the vote again fetches nothing.
        site.clearReads()
        #expect(try await m.recheckResults(key) == .dontAddUp)
        #expect(site.reads.isEmpty)
        // **Check again** while the site is down submits nothing and leaves the verdict.
        site["p/\(pid)/results.json"] = .unreachable
        #expect(try await m.checkResults(key) == .siteUnreachable)
        #expect(m.hints[key]?.resultsDontAddUp == false && m.hints[key]?.observerVerdict == false)
        // Good results, after a lock.
        VoteResultsFixture.publish(site, pid)
        ops.detail = verifiedDetail()
        m.clear()
        try await m.refresh()
        #expect(try await m.recheckResults(key) == .consistent)
        #expect(m.hints[key]?.observerVerdict == true && m.hints[key]?.resultsDontAddUp == false)
        // A tally other than the one the vault verified (chosen; not in the spec).
        ops.detail = verifiedDetail(tally: #"{"abstain":0,"no":1,"yes":0}"#)
        m.clear()
        try await m.refresh()
        #expect(try await m.recheckResults(key) == .dontAddUp)
        // No row with a proof any more is a problem too.
        ops.detail = verifiedDetail()
        site.put("p/\(pid)/rows.json", #"{"rows":[]}"#)
        m.clear()
        try await m.refresh()
        #expect(try await m.recheckResults(key) == .dontAddUp)
        // The site can't be reached: nothing is checked, and nothing is kept.
        site["p/\(pid)/results.json"] = .unreachable
        m.clear()
        try await m.refresh()
        #expect(try await m.recheckResults(key) == .notChecked)
        #expect(m.hints[key]?.observerVerdict == nil)
        #expect(vault.submits.isEmpty)
    }

    /// A recheck that could not check anything (no tag to look for, results.json over its limit or not reading its
    /// electorate) is "not rechecked" with no number, not "don't add up"; a rows.json over its cap is still a failed check
    /// (its cap comes from a results.json that parsed). Nothing is kept (VAULT-MESSAGING 0.83.6; vettid-android #317 item 2).
    @Test func aRecheckThatCouldCheckNothingIsNotRecheckedAndAnOverCapRowsJsonIsAFailedCheck() async throws {
        let ops = FakeVoteOps()
        ops.list = listing(summary(state: "closed", extra: #","ballot":{"state":"recorded"},"check":{"state":"verified"}"#))
        ops.detail = verifiedDetail()
        let m = siteManager(ops)
        try await m.refresh()
        func fresh() async throws {
            m.clear()
            try await m.refresh()
        }
        // Results over their limit.
        VoteResultsFixture.publish(site, pid)
        site["p/\(pid)/results.json"] = .found([UInt8](repeating: 32, count: VoteSiteLimits.resultsMax + 1))
        try await fresh()
        #expect(try await m.recheckResults(key) == .notChecked && m.hints[key]?.observerVerdict == nil)
        // Results whose electorate does not read, or is out of range.
        for counts in [#"{"counts":{}}"#, #"{"counts":{"eligible":0}}"#, "nope"] {
            site.put("p/\(pid)/results.json", counts)
            try await fresh()
            #expect(try await m.recheckResults(key) == .notChecked && m.hints[key]?.observerVerdict == nil)
        }
        // Results whose electorate reads but that are otherwise unusable (no rows_root) are a failed check, as in
        // vettid-android: "don't add up" with the verdict kept, not "not rechecked".
        site.put("p/\(pid)/results.json", #"{"counts":{"eligible":2}}"#)
        try await fresh()
        #expect(try await m.recheckResults(key) == .dontAddUp)
        #expect(m.hints[key]?.observerVerdict == false && m.hints[key]?.resultsDontAddUp == true && m.hints[key]?.verdictKept == true)
        // No record tag to look for.
        VoteResultsFixture.publish(site, pid)
        ops.detail = voteObj(#"{"proposal_id":"\#(pid)","connection_id":"\#(conn)","title":"t","state":"closed","text":"t","choices":[],"extensions":0}"#)
        try await fresh()
        #expect(try await m.recheckResults(key) == .notChecked)
        // rows.json over the cap of the results is a failed check.
        ops.detail = verifiedDetail()
        site["p/\(pid)/rows.json"] = .found([UInt8](repeating: 32, count: 2 * VoteRows.rowBytes + VoteRows.rowsOverhead + 1))
        try await fresh()
        #expect(try await m.recheckResults(key) == .dontAddUp && m.hints[key]?.observerVerdict == false)
        #expect(vault.submits.isEmpty)
    }

    /// An unconfirmed vote whose check again failed on numbers other than the vault's: **Check again** fetches a copy
    /// that holds together but has the other numbers, and the vault refuses the submission. The attempt's verdict needs
    /// the vault's numbers too, so the numbers stay hidden.
    @Test func anAttemptsVerdictAlsoNeedsTheVaultsNumbers() async throws {
        let ops = FakeVoteOps()
        ops.list = listing(summary(state: "closed", extra: #","ballot":{"state":"waiting"},"check":{"state":"unconfirmed"}"#))
        ops.detail = verifiedDetail(tally: #"{"abstain":0,"no":1,"yes":0}"#)
        let m = siteManager(ops)
        try await m.refresh()
        VoteResultsFixture.publish(site, pid)
        #expect(try await m.recheckResults(key) == .dontAddUp)
        vault.submitRefusal = "bad_request"
        await #expect(throws: (any Error).self) { try await m.checkResults(key) }
        #expect(vault.submits.count == 1)
        #expect(m.hints[key]?.observerVerdict == false && m.hints[key]?.resultsDontAddUp == true)
    }

    /// An attempt whose submission the vault answered `verified` or `unconfirmed` leaves its verdict for the screen, which
    /// does not check again before the next lock; one refused, lost or left pending does not, and the screen checks again.
    @Test func anAttemptsVerdictIsUsedWhenTheScreenOpensOnlyOnceTheVaultJudged() async throws {
        let ops = FakeVoteOps()
        ops.list = listing(closedPending())
        ops.detail = detail()
        let m = siteManager(ops)
        try await m.refresh()
        VoteResultsFixture.publish(site, pid)
        // Refused: the verdict shows, but is not kept.
        vault.submitRefusal = "bad_request"
        await #expect(throws: (any Error).self) { try await m.checkResults(key) }
        #expect(m.hints[key]?.observerVerdict == true && m.hints[key]?.verdictKept == false)
        site.clearReads()
        #expect(try await m.recheckResults(key) == .consistent)
        #expect(!site.reads.isEmpty && m.hints[key]?.verdictKept == true)
        // Left pending: not kept either.
        m.clear()
        try await m.refresh()
        vault.submitAnswer = #"{"proposal_id":"\#(pid)","check":{"state":"pending","reason":"input"}}"#
        #expect(try await m.checkResults(key) == .submitted(.pending))
        #expect(m.hints[key]?.verdictKept == false)
        site.clearReads()
        _ = try await m.recheckResults(key)
        #expect(!site.reads.isEmpty)
        // Verified: kept, nothing fetched again.
        m.clear()
        try await m.refresh()
        vault.submitAnswer = #"{"proposal_id":"\#(pid)","check":{"state":"verified"}}"#
        #expect(try await m.checkResults(key) == .submitted(.verified))
        site.clearReads()
        #expect(try await m.recheckResults(key) == .consistent)
        #expect(site.reads.isEmpty && vault.submits.count == 3)
    }
}

// swiftlint:enable line_length
