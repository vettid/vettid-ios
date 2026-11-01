import Foundation
import Testing
@testable import VettIDData
@testable import VettIDVotes

// Expected texts stay on one line each.
// swiftlint:disable line_length

/// Which text a state reads as (``VoteTexts``), the owner's two erratum texts, the words no text may use, and the unlock
/// window notice's time. Mirrors vettid-android `VoteTextsTest`.
@Suite struct VoteTextsTests {
    /// The package's `Localizable.xcstrings`.
    static var catalog: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/VettIDVotes/Resources/Localizable.xcstrings")
    }

    @Test func everyKeyOfTheCatalogResolvesToItsOwnText() throws {
        let doc = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: Self.catalog)) as? [String: Any])
        let keys = try #require((doc["strings"] as? [String: Any])?.keys)
        #expect(keys.count == 129)
        let missing = "\u{0}missing"
        for key in keys {
            let text = VoteStrings.bundle.localizedString(forKey: key, value: missing, table: nil)
            #expect(!text.isEmpty && text != key && text != missing, "\(key)")
            #expect(key.hasPrefix("vote"), "\(key)")
        }
    }

    @Test func theConflictFoundAfterAVerifiedCheckIsTheOwnersText() {
        #expect(VoteStrings.voteConflictAfterVerified("Example") == "**Your vote is in the published results.** Example also once showed a different vote under your code. Save the proof and show it to the organisation.")
        #expect(plainText(VoteStrings.voteConflictAfterVerified("Example")) == "Your vote is in the published results. Example also once showed a different vote under your code. Save the proof and show it to the organisation.")
        #expect(VoteTexts.text(.inResultsConflict, service: "Example", time: "") == VoteStrings.voteConflictAfterVerified("Example"))
    }

    @Test func theClockCheckIsTheOwnersText() {
        #expect(VoteStrings.voteCheckingClock == "VettID can't finish checking this vote yet because of a time check on VettID's side. It will try again.")
        #expect(VoteTexts.text(.checkingClock, service: "Example", time: "") == VoteStrings.voteCheckingClock)
    }

    /// Of the service the app says nothing "verified", "safe" or "secret" (the approved "trusted logs" is VettID's own list).
    @Test func noTextEverCallsTheVoteSecretOrVerifiedOrSafe() throws {
        let doc = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: Self.catalog)) as? [String: Any])
        let keys = try #require((doc["strings"] as? [String: Any])?.keys)
        #expect(!keys.isEmpty)
        for key in keys {
            let text = VoteStrings.bundle.localizedString(forKey: key, value: "", table: nil).lowercased()
            for word in ["secret", "verified", "safe"] {
                #expect(text.range(of: "\\b\(word)\\b", options: .regularExpression) == nil, "\(key): \(word)")
            }
        }
    }

    @Test func everyNoteAndEveryChipHasItsText() {
        for n in VoteNote.allCases {
            let text = VoteTexts.text(n, service: "Example", time: "tomorrow", rejected: n == .rejected ? .signature : nil)
            #expect(!text.isEmpty && !text.hasPrefix("vote_"), "\(n)")
        }
        for c in VoteChip.allCases { #expect(!VoteTexts.chip(c).isEmpty) }
        for w in [RejectedWhy.signature, .anchor, .record, .other] { #expect(!VoteTexts.rejectedText(w).isEmpty) }
        // A time is named only where the text names one.
        #expect(VoteTexts.text(.notOpen, service: "Example", time: "tomorrow") == "This vote opens tomorrow.")
        #expect(VoteTexts.text(.rejected, service: "Example", time: "") == VoteStrings.voteRejectedOther)
        #expect(VoteTexts.title(.failed) == "The published results don't match your vote" && VoteTexts.title(.rejected) == "VettID set this vote aside")
        #expect(VoteTexts.title(.waiting) == nil)
    }

    @Test func noNoteTextHoldsABareMarkerOrFormatSpecifier() {
        for n in VoteNote.allCases where n != .inResultsConflict {
            let text = VoteTexts.text(n, service: "Example", time: "tomorrow")
            #expect(!text.contains("**") && !text.contains("%@") && !text.contains("%lld"), "\(n)")
        }
    }

    @Test func theUnlockTimeIsInWholeMinutesRoundedUp() {
        let lead = "VettID could not close the credential unlock window after your vote. It closes by itself once it has not been used for "
        #expect(VoteTexts.windowNotClosed(WindowNotClosed(ttlSeconds: 600)) == lead + "10 minutes.")
        #expect(VoteTexts.windowNotClosed(WindowNotClosed(ttlSeconds: 90)) == lead + "2 minutes.")
        #expect(VoteTexts.windowNotClosed(WindowNotClosed(ttlSeconds: 120)) == lead + "2 minutes.")
        // Up to a minute is one minute, in the singular.
        #expect(VoteTexts.windowNotClosed(WindowNotClosed(ttlSeconds: 30)) == lead + "1 minute.")
        #expect(VoteTexts.windowNotClosed(WindowNotClosed(ttlSeconds: 60)) == lead + "1 minute.")
        #expect(VoteTexts.windowNotClosed(WindowNotClosed(ttlSeconds: 3600)) == lead + "60 minutes.")
        // The setting could not be read.
        #expect(VoteTexts.windowNotClosed(WindowNotClosed(ttlSeconds: nil)) == "VettID could not close the credential unlock window after your vote. It closes by itself.")
    }

    @Test func boldMarkersAreBoldAndNeverShown() {
        let a = boldMarked("**Bold.** Rest")
        #expect(String(a.characters) == "Bold. Rest")
        #expect(a.runs.count == 2 && a.runs.first?.inlinePresentationIntent == .stronglyEmphasized)
        #expect(String(boldMarked("No markers").characters) == "No markers")
        // An unmatched marker is shown as it is rather than swallowing text.
        #expect(String(boldMarked("a ** b").characters) == "a ** b")
    }
}
