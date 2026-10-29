import Foundation
import Testing
import VettIDCrypto
@testable import VettIDData
@testable import VettIDVault

// Fixtures stay on one line each.
// swiftlint:disable line_length

/// The recovery entries' `ref`s as the vault writes them (VAULT-MESSAGING 0.50.0 §11.14.11; IOS-PLAN §4.1), the attempting
/// phone's self-reported name and its cleaning, and the matching of an attempt to its outcome. Mirrors vettid-android
/// `RecoveryRefsTest`, with more of the name's edge cases.
@Suite struct RecoveryRefsTests {
    let t0 = Date(timeIntervalSince1970: 1_791_115_200)

    @Test func anAttemptsRefIsGenerationNumberOutcomeAndSource() {
        #expect(RecoveryRefs.attempt("2/3/not_success/counter") == .init(generation: 2, n: 3, success: false))
        #expect(RecoveryRefs.attempt("1/10/success/counter") == .init(generation: 1, n: 10, success: true))
        for bad in ["2/3", "2/3/not_success/enclave", "2/3/maybe/counter", "2/0/success/counter", "2/11/success/counter", "0/1/success/counter", "x/1/success/counter", "2/3/success/counter/x", ""] {
            #expect(RecoveryRefs.attempt(bad) == nil, "\(bad)")
        }
        #expect(RecoveryRefs.attempt(nil) == nil)
    }

    @Test func attemptsUsedIsGenerationAndCount() {
        #expect(RecoveryRefs.attemptsUsed("2/4") == 4)
        for bad in ["2/0", "2/11", "4", "0/4", "2/x"] { #expect(RecoveryRefs.attemptsUsed(bad) == nil, "\(bad)") }
        #expect(RecoveryRefs.attemptsUsed(nil) == nil)
    }

    @Test func aClosureIsGenerationReasonAndTheUnconfirmedSuffix() {
        #expect(RecoveryRefs.closure("3/pin") == .init(generation: 3, reason: "pin", unconfirmed: false))
        #expect(RecoveryRefs.closure("5/stale") == .init(generation: 5, reason: "stale", unconfirmed: false))
        #expect(RecoveryRefs.closure("4/rollback") == .init(generation: 4, reason: "rollback", unconfirmed: false))
        #expect(RecoveryRefs.closure("7/delete/unconfirmed") == .init(generation: 7, reason: "delete", unconfirmed: true))
        #expect(RecoveryRefs.closure("7/newer_reason") == .init(generation: 7, reason: "newer_reason", unconfirmed: false))
        for bad in ["7/delete/other", "7/", "pin", "x/pin", "0/pin"] { #expect(RecoveryRefs.closure(bad) == nil, "\(bad)") }
        #expect(RecoveryRefs.closure(nil) == nil)
    }

    /// `stale` is the harmless closure; only `rollback` is the alarm (owner decision of 2026-10-20).
    @Test func onlyARollbackClosureIsOne() {
        #expect(RecoveryRefs.rollback("recovery.generation_closed", ref: "4/rollback"))
        #expect(!RecoveryRefs.rollback("recovery.generation_closed", ref: "4/stale"))
        #expect(!RecoveryRefs.rollback("recovery.attempt", ref: "4/rollback"))
        #expect(!RecoveryRefs.rollback("recovery.generation_closed", ref: nil))
    }

    @Test func anOpenIsRecoveryIdOutcomeAndMaybeAName() {
        #expect(RecoveryRefs.open("01JREC/wrong") == .init(recoveryID: "01JREC", outcome: "wrong"))
        #expect(RecoveryRefs.open("01JREC/attempt_lost") == .init(recoveryID: "01JREC", outcome: "attempt_lost"))
        for bad in ["wrong", "/wrong", "01JREC/", "01JREC/wrong/UGl4ZWwgNw/x"] { #expect(RecoveryRefs.open(bad) == nil, "\(bad)") }
        #expect(RecoveryRefs.open(nil) == nil)
        // VAULT-MESSAGING 0.50.0: the phone's self-reported name, base64url without padding.
        #expect(RecoveryRefs.open("01JREC/wrong/UGl4ZWwgNw") == .init(recoveryID: "01JREC", outcome: "wrong", phoneName: "Pixel 7"))
        // Not base64url (or padded), or empty after cleaning: no name; the outcome still reads.
        #expect(RecoveryRefs.open("01JREC/wrong/!!!") == .init(recoveryID: "01JREC", outcome: "wrong"))
        #expect(RecoveryRefs.open("01JREC/wrong/UGl4ZWwgNw==") == .init(recoveryID: "01JREC", outcome: "wrong"))
        #expect(RecoveryRefs.open("01JREC/wrong/") == .init(recoveryID: "01JREC", outcome: "wrong"))
    }

    private func named(_ name: String) -> String? {
        RecoveryRefs.open("01JREC/wrong/" + Base64s.encodeRawUrl(Array(name.utf8)))?.phoneName
    }

    /// IOS-PLAN §4.1 "Cleaning for display".
    @Test func theNameIsCleanedForDisplay() {
        // A slash, controls and direction overrides: decoded, then cleaned.
        #expect(named("a/b\u{07}\u{202E}c") == "a/bc")
        // Line and paragraph separators, zero-width and other format characters, ALM, U+FEFF, U+FFFD and the quotation marks.
        #expect(named("Pixel\u{2028} 7\u{2029} Pro") == "Pixel 7 Pro")
        #expect(named("Pix\u{200B}el\u{FEFF}7\u{061C}") == "Pixel7")
        #expect(named("Pixel”. Change your PIN now. “\"") == "Pixel. Change your PIN now.")
        #expect(named("Pix\u{FFFD}el") == "Pixel")
        #expect(named("\u{202A}\u{202B}\u{202C}\u{202D}\u{2066}\u{2067}\u{2068}\u{2069}\u{200E}\u{200F}iPhone") == "iPhone")
        #expect(named("Tab\there\nnew") == "Tabherenew")
        // Trimmed; nothing left is no name.
        #expect(named("  iPhone 16e  ") == "iPhone 16e")
        #expect(named(" \u{200B}\u{2028}\"\u{201C} ") == nil)
        #expect(named("") == nil)
        // Other quotation marks and the rest of Unicode stay.
        #expect(named("Sam’s ‘phone’ «x»") == "Sam’s ‘phone’ «x»")
        // Invalid UTF-8 becomes U+FFFD, which goes.
        #expect(RecoveryRefs.open("01JREC/wrong/" + Base64s.encodeRawUrl([0x41, 0xFF, 0x42]))?.phoneName == "AB")
    }

    /// At most 64 code points, never splitting a surrogate pair (or a scalar), trimmed after the cut.
    @Test func theNameIsCappedAt64CodePoints() {
        let phone = "\u{1F4F1}" // one code point, two UTF-16 units
        #expect(named(String(repeating: phone, count: 70)) == String(repeating: phone, count: 64))
        #expect(named(String(repeating: "a", count: 64) + "b") == String(repeating: "a", count: 64))
        #expect(named(String(repeating: "a", count: 63) + " b") == String(repeating: "a", count: 63))
        #expect(named(String(repeating: "\u{200B}", count: 10) + String(repeating: "é", count: 70)) == String(repeating: "é", count: 64))
        for empty in ["\u{3164}", "\u{200D}\u{00A0}", "\u{202E}"] { #expect(RecoveryRefs.cleanName(empty) == nil) }
        #expect(RecoveryRefs.cleanName(String(repeating: phone, count: 64))?.unicodeScalars.count == 64)
    }

    private func record(_ seq: Int64, _ minutes: Double, _ kind: String, _ ref: String) -> AuditRecord {
        AuditRecord(AuditEntry(entryID: "e\(seq)", seq: seq, at: Timestamps.formatMillis(t0.addingTimeInterval(minutes * 60)), kind: kind, ref: ref))
    }

    private func attempt(_ seq: Int64, _ minutes: Double, _ n: Int, success: Bool = false) -> AuditRecord {
        record(seq, minutes, "recovery.attempt", "2/\(n)/\(success ? "success" : "not_success")/counter")
    }

    private func open(_ seq: Int64, _ minutes: Double, _ outcome: String, name: String? = nil) -> AuditRecord {
        record(seq, minutes, "recovery.open", "01JREC/\(outcome)" + (name.map { "/" + Base64s.encodeRawUrl(Array($0.utf8)) } ?? ""))
    }

    @Test func outcomesMatchTheNearestCountedOpenEachUsedOnce() {
        let entries = [
            attempt(20, 0, 1), open(10, 0, "wrong"),
            // Not counted: never an attempt's outcome, however near.
            open(11, 0, "busy"), open(12, 1, "wrong_again"),
            attempt(21, 30, 2), open(13, 29, "attempt_lost"),
            // Attempt 3 is nearest to the open of attempt 2, which is taken: the next nearest within the window.
            attempt(22, 31, 3), open(14, 38, "quiet"),
            // A success has no outcome line; an attempt with no open within 10 minutes has none.
            attempt(23, 60, 4, success: true), attempt(24, 120, 5), open(15, 135, "wait"),
        ]
        #expect(RecoveryRefs.outcomes(entries) == [20: "wrong", 21: "attempt_lost", 22: "quiet"])
    }

    /// An attempt the vault wrote again as `success` takes no outcome and is "later successful".
    @Test func anAttemptWrittenAgainAsSuccessIsNotMatched() {
        let first = attempt(40, 0, 3), again = attempt(41, 0, 3, success: true), other = attempt(42, 20, 4)
        let entries = [first, again, other, open(43, 0, "wrong"), open(44, 20, "attempt_lost")]
        #expect(RecoveryRefs.outcomes(entries) == [42: "attempt_lost"])
        #expect(RecoveryRefs.laterSuccessful(first, in: entries))
        #expect(!RecoveryRefs.laterSuccessful(other, in: entries) && !RecoveryRefs.laterSuccessful(again, in: entries))
        #expect(!RecoveryRefs.laterSuccessful(first, in: [first]))
    }

    @Test func outcomesAreFoundInEitherOrderOfTime() {
        // The counter's clock may run ahead of or behind the enclave's.
        let entries = [attempt(30, 10, 1), open(31, 15, "closed"), attempt(32, 40, 2), open(33, 35, "exhausted")]
        #expect(RecoveryRefs.outcomes(entries) == [30: "closed", 32: "exhausted"])
        #expect(RecoveryRefs.outcomes([attempt(30, 10, 1)]).isEmpty)
        // Exactly 10 minutes is within the window; a second more is not.
        #expect(RecoveryRefs.outcomes([attempt(1, 0, 1), open(2, 10, "wrong")]) == [1: "wrong"])
        #expect(RecoveryRefs.outcomes([attempt(1, 0, 1), open(2, 10 + 1 / 60, "wrong")]).isEmpty)
    }

    /// The matched open carries the phone's self-reported name; it never changes which open is matched.
    @Test func theMatchedOpenCarriesTheName() {
        let entries = [attempt(1, 0, 1), open(2, 1, "wrong", name: "Pixel 7"), attempt(3, 30, 2), open(4, 30, "wait")]
        let m = RecoveryRefs.matches(entries)
        #expect(m[1]?.phoneName == "Pixel 7" && m[1]?.outcome == "wrong")
        #expect(m[3]?.phoneName == nil && m[3]?.outcome == "wait")
    }
}

// swiftlint:enable line_length
