import Testing
import VettIDConnections
@testable import VettIDShell

/// Where the approvals indicator is hidden (ANDROID-PLAN §4 "The approvals indicator" 2; vettid-android
/// `INDICATOR_HIDDEN_ON`): a request's screen, the connect flow's accept and scan screens, pairing, the photo viewer and
/// the move out; Approvals itself is hidden by the shell's root.
@Suite struct ShellIndicatorTests {
    @Test func hiddenOnTheScreensAndroidHidesItOn() {
        let hidden: [ShellRoute] = [
            .approval("auth:a1"), .connect(.scan), .connect(.accept(AcceptInput(link: "scanned"))), .pair(held: false, desktop: true),
            .photo(connectionID: "c", messageID: "m"),
            .transferOut,
        ]
        #expect(hidden.allSatisfy(ShellIndicator.hidden))
    }

    @Test func shownOnEveryOtherScreen() {
        let shown: [ShellRoute] = [
            .connect(.invite), .conversation("c"), .connection("c"), .notifications(archived: false), .vaultStatus, .item("i"),
            .device("d"), .vote(connectionID: "c", proposalID: "p"), .historyEntry(3),
        ]
        #expect(!shown.contains(where: ShellIndicator.hidden))
    }
}
