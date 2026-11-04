import Foundation
import Testing
import VettIDOnboarding
import VettIDSettings
@testable import VettID
import VettIDData

/// A URL the app was opened with goes where it belongs (IOS-PLAN §6.8): an invitation by the Universal Link of
/// `relay.vettid.org` or by `vettid://connect` to the invitation inbox, the portal's setup link to onboarding, anything
/// else to the files; nothing over 4,096 bytes is taken.
@MainActor
struct OpenedLinkTests {
    let link = String(repeating: "A", count: 120)

    /// A link that came while the phase was being read is dropped once it is a phase with a vault, and not kept for a later setup.
    @Test func aQueuedSetupLinkIsDroppedWhenTheVaultIsKnown() {
        let inbox = SetupLinkInbox()
        inbox.offer("link")
        #expect(!AppRoot.dropSetupLink(phase: .starting, inbox: inbox) && inbox.link == "link")
        #expect(!AppRoot.dropSetupLink(phase: .signedOut, inbox: inbox) && inbox.link == "link")
        // A vault being deleted keeps the link for the setup after it.
        #expect(!AppRoot.dropSetupLink(phase: .deleting, inbox: inbox) && inbox.link == "link")
        #expect(AppRoot.dropSetupLink(phase: .locked, inbox: inbox) && inbox.link == nil)
        #expect(!AppRoot.dropSetupLink(phase: .unlocked, inbox: inbox))
        // The vault deleted in the same run: nothing is left for the onboarding to redeem.
        #expect(!AppRoot.dropSetupLink(phase: .signedOut, inbox: inbox) && inbox.link == nil)
    }

    /// A wait the vault asked for survives a lock and a setup stage of the same vault, and ends with a wipe.
    @Test func aWaitSurvivesALockAndEndsWithAWipe() {
        let waits = WaitRegistry()
        _ = waits.record(.rotate, error: VaultFailure(.backoff, code: "backoff", retryAfterSeconds: 600))
        let phases: [AppPhase] = [
            .locked, .unlocked, .starting, .unreachable(.network), .deleting, .setup(.finishing), .setup(.recovering),
            .setup(.needsCredential),
        ]
        for phase in phases {
            if AppRoot.waitsEnd(with: phase) { waits.clearAll() }
            #expect(waits.current(.rotate) != nil, "\(phase)")
        }
        #expect(AppRoot.waitsEnd(with: .signedOut))
        if AppRoot.waitsEnd(with: .signedOut) { waits.clearAll() }
        #expect(waits.current(.rotate) == nil)
    }

    /// "Try again" on the start and unreachable screens is the member's: the closure both are given (`AppRoot.tryAgain`) is forced, so
    /// it reads a known phase too. The screens' use of it is not tested here.
    @Test func theTryAgainOfTheStartAndUnreachableScreensIsForced() async {
        final class Reads { var count = 0 }
        let reads = Reads()
        let reader = PhaseReader(phase: { .locked }, refresh: { reads.count += 1 })
        await AppRoot.tryAgain(reader)()
        #expect(reads.count == 1)
        await reader.ask()
        #expect(reads.count == 1, "the foreground does not read a known phase")
    }

    /// A setup link on a phone that already has a vault is said to be unused, not queued for a later setup.
    @Test func aSetupLinkIsUnusedOnAPhoneWithAVault() {
        for phase in [AppPhase.locked, .unlocked] { #expect(AppRoot.hasVault(phase)) }
        for phase in [AppPhase.starting, .signedOut, .setup(.newVault), .deleting] { #expect(!AppRoot.hasVault(phase)) }
    }

    @Test func invitationsGoToTheInviteInbox() throws {
        for s in [
            "https://relay.vettid.org/connect#\(link)", "https://relay.vettid.org/connect/#\(link)", "vettid://connect#\(link)",
            "https://my-relay.example/connect#\(link)",
        ] {
            #expect(OpenedLink.route(try #require(URL(string: s))) == .invite(s), "\(s.prefix(40))")
        }
    }

    @Test func theSetupLinkGoesToOnboarding() throws {
        let s = "https://account.vettid.org/vault/enroll/#s=ABCDEFGH"
        #expect(OpenedLink.route(try #require(URL(string: s))) == .setup(s))
    }

    @Test func otherAndOverlongUrlsAreNotLinks() throws {
        let long = "https://relay.vettid.org/connect#" + String(repeating: "A", count: OpenedLink.maxLength)
        for s in ["https://relay.vettid.org/other#\(link)", "file:///tmp/manifest.json", long] {
            #expect(OpenedLink.route(try #require(URL(string: s))) == .other)
        }
    }
}
