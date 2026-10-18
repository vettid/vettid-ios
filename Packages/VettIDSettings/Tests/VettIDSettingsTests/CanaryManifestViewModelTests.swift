import Foundation
import Observation
import Testing
import VettIDData
import VettIDDataTesting
@testable import VettIDSettings

/// The canary manifest dialog's view model (VAULT-RELEASES §10.1 step 9): a document from the inbox is checked, shown, and
/// installed only on the member's confirmation; a refusal installs nothing; Attestation shows and removes the installed
/// one. Mirrors vettid-android `CanaryManifestViewModelTest`.
@MainActor
@Suite struct CanaryManifestViewModelTests {
    let inbox = CanaryManifestInbox()
    let repo = FakeCanaryRepository()
    let doc = Array(#"{"manifest":"…"}"#.utf8)
    static let view = CanaryManifestView(
        serial: 8, keyID: "1edbb48b6669decd", sha256: String(repeating: "ab", count: 32),
        releases: [ReleaseView(number: 3, pcr0: String(repeating: "a3", count: 48), status: "active", endsAt: nil, notes: "https://x/3")]
    )

    @Test func aDocumentIsCheckedShownAndInstalledOnlyWhenConfirmed() async {
        let m = CanaryManifestViewModel(inbox: inbox, repo: repo)
        m.receive()
        #expect(m.prompt == nil && repo.checked.isEmpty)
        inbox.offer(doc)
        m.receive()
        #expect(inbox.document == nil, "taken from the inbox")
        await m.settle()
        #expect(m.prompt == .confirm(Self.view))
        #expect(repo.checked == [doc] && repo.installed.isEmpty)
        m.confirm()
        #expect(m.prompt == nil)
        await m.settle()
        #expect(m.prompt == .installed(Self.view) && repo.installed == [doc])
        m.dismiss()
        #expect(m.prompt == nil)
        // Nothing left to confirm.
        m.confirm()
        await m.settle()
        #expect(repo.installed.count == 1)
    }

    @Test func cancellingInstallsNothing() async {
        let m = CanaryManifestViewModel(inbox: inbox, repo: repo)
        inbox.offer(doc)
        m.receive()
        await m.settle()
        m.dismiss()
        m.confirm()
        await m.settle()
        #expect(m.prompt == nil && repo.installed.isEmpty)
    }

    @Test func aRefusalSaysWhyAndInstallsNothing() async {
        repo.refusal = VaultFailure(.manifest, code: CanaryManifestCodes.older)
        let m = CanaryManifestViewModel(inbox: inbox, repo: repo)
        inbox.offer(doc)
        m.receive()
        await m.settle()
        #expect(m.prompt == .refused(code: CanaryManifestCodes.older))
        m.confirm()
        await m.settle()
        #expect(repo.installed.isEmpty)
    }

    /// A wipe of this phone while the dialog asks: it closes, and the document is not installed.
    @Test func aWipeWhileTheDialogIsPendingClosesIt() async {
        let m = CanaryManifestViewModel(inbox: inbox, repo: repo)
        inbox.offer(doc)
        m.inboxChanged()
        await m.settle()
        #expect(m.prompt == .confirm(Self.view))
        inbox.reset()
        m.inboxChanged()
        #expect(m.prompt == nil)
        m.confirm()
        await m.settle()
        #expect(m.prompt == nil && repo.installed.isEmpty)
    }

    /// A wipe while the installation runs: its answer is not shown.
    @Test func aWipeDuringTheInstallationShowsNothing() async {
        let m = CanaryManifestViewModel(inbox: inbox, repo: repo)
        inbox.offer(doc)
        m.inboxChanged()
        await m.settle()
        m.confirm()
        inbox.reset()
        m.inboxChanged()
        await m.settle()
        #expect(m.prompt == nil)
    }

    /// A picked file that could not be read: "It could not be checked", nothing checked or installed.
    @Test func anUnreadableFileIsSaidSo() async {
        let m = CanaryManifestViewModel(inbox: inbox, repo: repo)
        inbox.offerUnreadable()
        m.inboxChanged()
        #expect(m.prompt == .refused(code: nil))
        await m.settle()
        #expect(repo.checked.isEmpty)
        m.dismiss()
        m.inboxChanged()
        #expect(m.prompt == nil, "said once")
    }

    @Test func attestationShowsAndRemovesTheInstalledOne() async {
        let vault = FakeVaultRepository(.unlocked)
        let m = AttestationViewModel(vault: vault, canary: repo)
        #expect(m.canary == nil)
        repo.canaryManifest = Self.view
        #expect(m.canary == Self.view)
        m.removeCanary()
        #expect(m.canary == nil && repo.removals == 1)
        #expect(AttestationViewModel(vault: vault).canary == nil)
    }
}

/// TEST ONLY: a canary manifest repository that answers ``CanaryManifestViewModelTests/view`` or [refusal].
@MainActor
@Observable
final class FakeCanaryRepository: CanaryManifestRepository {
    var canaryManifest: CanaryManifestView?
    @ObservationIgnored var refusal: VaultFailure?
    @ObservationIgnored private(set) var checked: [[UInt8]] = []
    @ObservationIgnored private(set) var installed: [[UInt8]] = []
    @ObservationIgnored private(set) var removals = 0

    func checkCanaryManifest(_ served: [UInt8]) async throws -> CanaryManifestView {
        checked.append(served)
        if let refusal { throw refusal }
        return CanaryManifestViewModelTests.view
    }

    func installCanaryManifest(_ served: [UInt8]) async throws -> CanaryManifestView {
        if let refusal { throw refusal }
        installed.append(served)
        canaryManifest = CanaryManifestViewModelTests.view
        return CanaryManifestViewModelTests.view
    }

    func removeCanaryManifest() {
        removals += 1
        canaryManifest = nil
    }
}
