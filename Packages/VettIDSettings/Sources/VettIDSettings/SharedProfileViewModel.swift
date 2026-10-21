import Foundation
import Observation
import VettIDData

/// The shared-profile screen's state (VAULT-MESSAGING §10.8). Never printed with its photos. Mirrors vettid-android
/// `SharedProfileUiState` (less the `@profile` items, which come with the items of IOS-PLAN §8 I3).
public struct SharedProfileState: Equatable, Sendable, CustomStringConvertible, CustomReflectable {
    /// §10.8: a display name of at most 128 bytes.
    public static let maxDisplayNameBytes = 128

    public var account: AccountInfo?
    public var profile: OwnProfile?
    /// The display name being edited; follows the vault's until the member types.
    public var displayName = ""
    public var edited = false
    public var busy = false
    public var saved = false
    public var error: FailureKind?
    /// The limit a `limit` error named (VAULT-MESSAGING §10.1: `profile_size`).
    public var limit: VaultLimit?
    /// A photo taken and encoded (base64 JPEG, at most 65,536 bytes), shown as a preview until saved or dropped.
    public var pendingPhoto: String?
    /// The taken photo is being encoded, or the photo is being saved.
    public var photoBusy = false
    /// The taken photo could not be encoded.
    public var photoUnreadable = false
    public var photoSaved = false

    public init(account: AccountInfo? = nil, profile: OwnProfile? = nil) {
        self.account = account
        self.profile = profile
        displayName = profile?.displayName ?? ""
    }

    /// The photo to show: the one being previewed, else the vault's.
    public var shownPhoto: String? { pendingPhoto ?? profile?.photo }

    /// The display name's limit (§10.8: at most 128 bytes).
    public var tooLong: Bool { Self.trimmed(displayName).utf8.count > Self.maxDisplayNameBytes }

    public var saveAllowed: Bool {
        guard let profile, !busy, edited, !tooLong else { return false }
        return Self.trimmed(displayName) != profile.displayName
    }

    /// The names on the account: the snapshot's (the account sheet's source), else the profile's core.
    public var fullName: String? { account?.fullName ?? profile?.fullName }

    static func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    public var description: String {
        "SharedProfileState(busy: \(busy), photoBusy: \(photoBusy), pending: \(pendingPhoto != nil), "
            + "error: \(error.map { "\($0)" } ?? "nil"))"
    }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Settings → Shared profile (ANDROID-PLAN 0.1.10, VAULT-MESSAGING §10.8): the account's names read-only (changed only
/// through ``ChangeNameViewModel``), the display name edited with `profile.set`, which never names the core, and the
/// profile photo, taken with the app's camera (``PhotoCaptureMachine``), encoded (``encodeShot(_:)``) and sent with
/// `profile.set{photo}`. Mirrors vettid-android `SharedProfileViewModel`.
@MainActor
@Observable
public final class SharedProfileViewModel {
    private var local: SharedProfileState

    @ObservationIgnored private let profiles: any ProfileRepository
    @ObservationIgnored private let accounts: any AccountRepository
    @ObservationIgnored private let work = Work()

    public init(profiles: any ProfileRepository, accounts: any AccountRepository) {
        self.profiles = profiles
        self.accounts = accounts
        local = SharedProfileState(account: accounts.account, profile: profiles.profile)
        work.launch { [weak self] in
            do {
                try await profiles.refreshProfile()
            } catch {
                self?.failed(error)
            }
        }
        work.launch { await accounts.refreshAccount() }
    }

    deinit { work.cancelAll() }

    /// The state now: the account and the profile as the repositories have them (observed through them), with this
    /// screen's own; the display name follows the vault's until the member types.
    public var state: SharedProfileState {
        var s = local
        s.account = accounts.account
        s.profile = profiles.profile
        if !s.edited { s.displayName = s.profile?.displayName ?? "" }
        return s
    }

    public func setDisplayName(_ v: String) {
        local.displayName = v
        local.edited = true
        local.saved = false
        local.error = nil
    }

    public func save() {
        let s = state
        guard s.saveAllowed else { return }
        let name = SharedProfileState.trimmed(s.displayName)
        local.busy = true
        local.error = nil
        let profiles = profiles
        work.launch { [weak self] in
            do {
                try await profiles.setDisplayName(name)
                guard let self else { return }
                local.busy = false
                local.edited = false
                local.saved = true
                local.displayName = name
            } catch {
                self?.local.busy = false
                self?.failed(error)
            }
        }
    }

    public func dismiss() {
        local.saved = false
        local.error = nil
        local.limit = nil
        local.photoUnreadable = false
        local.photoSaved = false
    }

    /// The taken photo is being encoded (off the main actor, by the screen).
    public func photoEncoding() {
        local.photoBusy = true
        local.photoUnreadable = false
        local.photoSaved = false
        local.error = nil
    }

    /// The photo the member took and accepted ("Use photo"), encoded (``encodeShot(_:)``), sent with
    /// `profile.set{photo}`; it stays as a preview (with "Save photo") if the vault refuses. Nil: it could not be encoded.
    public func photoTaken(_ base64: String?) {
        local.pendingPhoto = base64
        local.photoBusy = false
        local.photoUnreadable = base64 == nil
        if let base64 { sendPhoto(base64) }
    }

    public func discardPhoto() {
        local.pendingPhoto = nil
        local.photoUnreadable = false
    }

    /// `profile.set{photo}` with the previewed photo.
    public func savePhoto() {
        guard let photo = local.pendingPhoto else { return }
        sendPhoto(photo)
    }

    /// `profile.set{photo: ""}`: no photo.
    public func removePhoto() { sendPhoto("") }

    private func sendPhoto(_ photo: String) {
        guard !local.photoBusy else { return }
        local.photoBusy = true
        local.error = nil
        local.photoSaved = false
        let profiles = profiles
        work.launch { [weak self] in
            do {
                try await profiles.setPhoto(photo)
                guard let self else { return }
                local.photoBusy = false
                local.pendingPhoto = nil
                local.photoSaved = true
            } catch {
                self?.local.photoBusy = false
                self?.failed(error)
            }
        }
    }

    private func failed(_ e: any Error) {
        local.error = failureKind(e)
        local.limit = (e as? VaultFailure)?.limit
    }

    /// TEST ONLY: returns once the work started has run.
    func settle() async { await work.settle() }
}
