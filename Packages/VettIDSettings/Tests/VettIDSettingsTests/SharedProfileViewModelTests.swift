import Foundation
import Testing
import VettIDData
import VettIDDataTesting
import VettIDMedia
@testable import VettIDSettings

/// The shared profile (VAULT-MESSAGING §10.8, ANDROID-PLAN 0.1.10): the display name edited and saved within its limit,
/// the taken photo sent with `profile.set` (kept as a preview when refused, its bytes zeroed once saved or dropped),
/// removed with `""`; the drafts dropped whenever the vault is not open (IOS-PLAN §4.7). Mirrors vettid-android
/// `ProfileViewModelsTest`'s shared-profile part.
@MainActor
@Suite struct SharedProfileViewModelTests {
    let repo: FakeVaultRepository

    init() {
        repo = FakeVaultRepository(.unlocked)
        repo.account = AccountInfo(emailHint: "a***@example.com", state: "member", firstName: "Ada", lastName: "Lovelace")
        repo.profile = OwnProfile(
            version: 2, displayName: "", firstName: "Ada", lastName: "Lovelace", fingerprint: "9a1f bb7d 873e eafb 494b ef94 f072 7b25"
        )
    }

    func model() -> SharedProfileViewModel { SharedProfileViewModel(profiles: repo, accounts: repo) }

    @Test func theProfileAndTheAccountAreReadAgainWhenTheScreenOpens() async {
        let m = model()
        await m.settle()
        #expect(repo.calls.contains("refreshProfile") && repo.calls.contains("refreshAccount"))
        #expect(m.state.fullName == "Ada Lovelace" && m.state.profile?.fingerprint != nil)
    }

    @Test func aTakenPhotoIsSentWithProfileSet() async {
        let m = model()
        await m.settle()
        #expect(m.state.profile?.photo == nil)
        m.photoEncoding()
        #expect(m.state.photoBusy)
        m.photoTaken("/9j/4AAQ")
        await m.settle()
        #expect(repo.lastPhoto == "/9j/4AAQ" && repo.profile?.photo == "/9j/4AAQ")
        #expect(m.state.photoSaved && m.state.pendingPhoto == nil && m.state.profile?.photo == "/9j/4AAQ")
    }

    @Test func aRefusedPhotoStaysAsAPreviewToSaveAgain() async {
        let m = model()
        await m.settle()
        repo.fail["setPhoto"] = VaultFailure(.network)
        m.photoTaken("/9j/4AAQ")
        await m.settle()
        #expect(repo.lastPhoto == nil)
        #expect(m.state.pendingPhoto?.base64() == "/9j/4AAQ" && m.state.error == .network)
        m.savePhoto()
        await m.settle()
        #expect(repo.lastPhoto == "/9j/4AAQ" && m.state.pendingPhoto == nil)
    }

    @Test func aPhotoThatCouldNotBeEncodedIsSaidAndNothingSent() async {
        let m = model()
        await m.settle()
        m.photoEncoding()
        m.photoTaken(nil)
        #expect(m.state.photoUnreadable && !m.state.photoBusy)
        m.savePhoto()
        await m.settle()
        #expect(repo.lastPhoto == nil && !repo.calls.contains("setPhoto"))
    }

    @Test func aPreviewCanBeDiscarded() async {
        let m = model()
        await m.settle()
        repo.fail["setPhoto"] = VaultFailure(.network)
        m.photoTaken("/9j/4AAQ")
        await m.settle()
        m.discardPhoto()
        #expect(m.state.pendingPhoto == nil && m.state.profile?.photo == nil)
    }

    @Test func removingThePhotoSendsEmpty() async {
        repo.profile?.photo = "/9j/old"
        let m = model()
        await m.settle()
        #expect(m.state.profile?.photo == "/9j/old")
        m.removePhoto()
        await m.settle()
        #expect(repo.lastPhoto == "" && repo.profile?.photo == nil)
    }

    // MARK: - Drafts dropped whenever the vault is not open (IOS-PLAN §4.7)

    @Test func aLockDropsTheEditedDisplayNameAndThePendingPhotoZeroed() async {
        let m = model()
        await m.settle()
        m.setDisplayName("Countess")
        repo.fail["setPhoto"] = VaultFailure(.network)
        m.photoTaken("/9j/4AAQ")
        await m.settle()
        guard let pending = m.state.pendingPhoto else {
            Issue.record("no pending photo")
            return
        }
        #expect(m.state.edited && !pending.bytes.isWiped)
        // The vault locks: the profile is forgotten.
        repo.profile = nil
        #expect(await eventually { m.state.pendingPhoto == nil })
        #expect(m.state.displayName == "" && !m.state.edited)
        #expect(pending.bytes.isWiped, "zeroed in place")
        // After the unlock nothing typed comes back: the vault's display name, no preview.
        repo.profile = OwnProfile(version: 3, displayName: "Ada", firstName: "Ada", lastName: "Lovelace", fingerprint: nil)
        #expect(await eventually { m.state.displayName == "Ada" })
        #expect(m.state.pendingPhoto == nil)
    }

    @Test func theHoldDropsTheDraftsToo() async {
        let m = model()
        await m.settle()
        m.setDisplayName("Countess")
        repo.fail["setPhoto"] = VaultFailure(.network)
        m.photoTaken("/9j/4AAQ")
        await m.settle()
        let pending = m.state.pendingPhoto
        // Held or due: the account is no longer the open vault's (only the masked hint is left).
        repo.account = AccountInfo(emailHint: "a***@example.com")
        #expect(await eventually { !m.state.edited })
        #expect(m.state.displayName == "" && m.state.pendingPhoto == nil && pending?.bytes.isWiped == true)
    }

    /// The lock lands while the taken photo is being encoded (off the main actor): the photo that arrives after it is
    /// zeroed, never kept or sent.
    @Test func aPhotoEncodedAfterTheLockIsNeitherKeptNorSent() async {
        let m = model()
        await m.settle()
        m.photoEncoding()
        repo.profile = nil
        #expect(await eventually { !m.state.photoUnreadable && m.state.pendingPhoto == nil })
        m.photoTaken("/9j/4AAQ")
        await m.settle()
        #expect(m.state.pendingPhoto == nil && !m.state.photoBusy && !repo.calls.contains("setPhoto"))
        // The hold likewise.
        repo.profile = OwnProfile(version: 3, displayName: "", firstName: "Ada", lastName: "Lovelace", fingerprint: nil)
        repo.account = AccountInfo(emailHint: "a***@example.com")
        m.photoEncoding()
        m.photoTaken("/9j/4AAQ")
        await m.settle()
        #expect(m.state.pendingPhoto == nil && !repo.calls.contains("setPhoto"))
    }

    @Test func aDiscardedOrSavedPhotoIsZeroed() async {
        let m = model()
        await m.settle()
        repo.fail["setPhoto"] = VaultFailure(.network)
        m.photoTaken("/9j/4AAQ")
        await m.settle()
        let first = m.state.pendingPhoto
        m.discardPhoto()
        #expect(first?.bytes.isWiped == true)
        repo.fail["setPhoto"] = VaultFailure(.network) // taken once per call
        m.photoTaken("/9j/4AAQ")
        await m.settle()
        let second = m.state.pendingPhoto
        #expect(second?.bytes.isWiped == false)
        m.savePhoto()
        await m.settle()
        #expect(repo.lastPhoto == "/9j/4AAQ" && second?.bytes.isWiped == true)
    }

    @Test func aPhotoTakenOverAPreviewZeroesTheOldOne() async {
        let m = model()
        await m.settle()
        repo.fail["setPhoto"] = VaultFailure(.network)
        m.photoTaken("/9j/4AAQ")
        await m.settle()
        let first = m.state.pendingPhoto
        repo.fail["setPhoto"] = VaultFailure(.network)
        m.photoTaken("/9j/4AAQ")
        await m.settle()
        #expect(first?.bytes.isWiped == true && m.state.pendingPhoto?.bytes.isWiped == false)
    }

    @Test func theScreenGoingZeroesThePendingPhoto() async {
        var m: SharedProfileViewModel? = model()
        await m?.settle()
        repo.fail["setPhoto"] = VaultFailure(.network)
        m?.photoTaken("/9j/4AAQ")
        await m?.settle()
        let pending = m?.state.pendingPhoto
        #expect(pending?.bytes.isWiped == false)
        m = nil
        #expect(await eventually { pending?.bytes.isWiped == true })
    }

    @Test func theDisplayNameIsEditedAndSaved() async {
        let m = model()
        await m.settle()
        #expect(m.state.fullName == "Ada Lovelace")
        #expect(!m.state.saveAllowed, "nothing changed yet")
        m.setDisplayName("  Countess ")
        #expect(m.state.saveAllowed)
        m.save()
        await m.settle()
        #expect(repo.profile?.displayName == "Countess")
        #expect(m.state.saved && !m.state.edited && m.state.displayName == "Countess")
    }

    @Test func theDisplayNameFollowsTheVaultUntilTheMemberTypes() async {
        let m = model()
        await m.settle()
        repo.profile?.displayName = "Ada"
        #expect(m.state.displayName == "Ada")
        m.setDisplayName("Countess")
        repo.profile?.displayName = "Other"
        #expect(m.state.displayName == "Countess")
    }

    @Test func aDisplayNameOverTheLimitIsNotSent() async {
        let m = model()
        await m.settle()
        m.setDisplayName(String(repeating: "é", count: 65)) // 130 bytes
        #expect(m.state.tooLong && !m.state.saveAllowed)
        m.save()
        await m.settle()
        #expect(!repo.calls.contains("setDisplayName"))
        m.setDisplayName(String(repeating: "é", count: 64)) // 128 bytes
        #expect(!m.state.tooLong && m.state.saveAllowed)
    }

    @Test func aRefusedSaveShowsWhy() async {
        repo.fail["setDisplayName"] = VaultFailure(.conflict, code: "conflict")
        let m = model()
        await m.settle()
        m.setDisplayName("Countess")
        m.save()
        await m.settle()
        #expect(m.state.error == .conflict && !m.state.busy)
        m.dismiss()
        #expect(m.state.error == nil)
    }

    @Test func aLimitIsKeptWithTheError() async {
        repo.fail["setPhoto"] = VaultFailure(.limit, code: "limit", limit: VaultLimit("profile_size", max: 196_608, size: 200_000))
        let m = model()
        await m.settle()
        m.photoTaken("/9j/4AAQ")
        await m.settle()
        #expect(m.state.error == .limit && m.state.limit?.name == "profile_size")
    }

    @Test func aFailedReadShowsWhy() async {
        repo.fail["refreshProfile"] = VaultFailure(.network)
        let m = model()
        await m.settle()
        #expect(m.state.error == .network)
    }

    /// The state names no photo when printed.
    @Test func theStateIsNotPrintedWithItsPhotos() {
        let own = OwnProfile(version: 1, displayName: "", firstName: nil, lastName: nil, fingerprint: nil, photo: "/9j/secret")
        var s = SharedProfileState(profile: own)
        s.pendingPhoto = PendingPhoto.of("/9j/4AAQ")
        #expect(!String(describing: s).contains("/9j") && !String(reflecting: s).contains("/9j"))
        #expect(String(reflecting: s.pendingPhoto!) == "PendingPhoto(6)")
        #expect(!String(describing: s.profile!).contains("/9j"))
    }
}
