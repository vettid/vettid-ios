import Foundation
import Observation
import os
import VettIDData
import VettIDMedia

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
    /// A photo taken and encoded (a JPEG of at most 65,536 bytes), shown as a preview until saved or dropped; its bytes
    /// are zeroed then, and whenever the vault is not open (``PendingPhoto/wipe()``).
    public var pendingPhoto: PendingPhoto?
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

/// A taken photo before it is saved (VAULT-MESSAGING §10.8): the JPEG bytes, in memory only. ``wipe()`` zeroes them in
/// place once the photo is saved or dropped, or the vault is no longer open (IOS-PLAN §4.7). Equal only to itself.
/// Never printed. Mirrors vettid-android `PendingPhoto`.
public final class PendingPhoto: Equatable, Sendable, CustomStringConvertible, CustomReflectable {
    /// The bytes for the preview (zeroed by ``wipe()``).
    public let bytes: PhotoBytes

    public init(_ bytes: PhotoBytes) { self.bytes = bytes }

    /// [base64] (``encodeShot(_:)``'s) as bytes, or nil when it is not base64.
    public static func of(_ base64: String) -> PendingPhoto? {
        guard var data = Data(base64Encoded: base64) else { return nil }
        var raw = [UInt8](data)
        data.resetBytes(in: 0..<data.count)
        return PendingPhoto(PhotoBytes(taking: &raw))
    }

    /// The standard base64 `profile.set{photo}` takes, read in place (no copy of the bytes that the zeroing would miss).
    public func base64() -> String {
        bytes.withBytes { b in
            b.withUnsafeBufferPointer { p in
                guard let base = p.baseAddress else { return "" }
                return Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base), count: p.count, deallocator: .none)
                    .base64EncodedString()
            }
        }
    }

    public func wipe() { bytes.wipe() }

    public static func == (a: PendingPhoto, b: PendingPhoto) -> Bool { a === b }

    public var description: String { "PendingPhoto(\(bytes.count))" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Settings → Shared profile (ANDROID-PLAN 0.1.10, VAULT-MESSAGING §10.8): the account's names read-only (changed only
/// through ``ChangeNameViewModel``), the display name edited with `profile.set`, which never names the core, and the
/// profile photo, taken with the app's camera (``PhotoCaptureMachine``), encoded (``encodeShot(_:)``) and sent with
/// `profile.set{photo}`.
///
/// (IOS-PLAN §4.7) The drafts (an edited display name, a taken photo not yet saved, its bytes zeroed) are dropped
/// whenever the vault is not open (the profile forgotten, or the account no longer from the open vault: a lock, the hold
/// or the due state); the member types them again after the unlock. Mirrors vettid-android `SharedProfileViewModel`.
@MainActor
@Observable
public final class SharedProfileViewModel {
    private var local: SharedProfileState

    @ObservationIgnored private let profiles: any ProfileRepository
    @ObservationIgnored private let accounts: any AccountRepository
    @ObservationIgnored private let work = Work()
    @ObservationIgnored private let followers = TaskBag()
    /// The taken photo held now, for the zeroing when the screen goes (`deinit`, vettid-android `onCleared`).
    @ObservationIgnored private let held = OSAllocatedUnfairLock<PendingPhoto?>(initialState: nil)

    public init(profiles: any ProfileRepository, accounts: any AccountRepository) {
        self.profiles = profiles
        self.accounts = accounts
        local = SharedProfileState(account: accounts.account, profile: profiles.profile)
        followers.add(follow(self, read: { $0.accounts.account.shownInShell == nil }, apply: { m, closed in
            if closed { m.dropDrafts() }
        }))
        followers.add(follow(self, read: { $0.profiles.profile == nil }, apply: { m, gone in
            if gone { m.dropDrafts() }
        }))
        work.launch { [weak self] in
            do {
                try await profiles.refreshProfile()
            } catch {
                self?.failed(error)
            }
        }
        work.launch { await accounts.refreshAccount() }
    }

    deinit {
        work.cancelAll()
        followers.cancelAll()
        held.withLock { $0?.wipe() }
    }

    /// The state now: the account and the profile as the repositories have them (observed through them), with this
    /// screen's own; the display name follows the vault's until the member types.
    public var state: SharedProfileState {
        var s = local
        s.account = accounts.account
        // Not the open vault's: nothing of a name request reaches the screen (IOS-PLAN 0.1.21 §4.7).
        if s.account.shownInShell == nil { s.account?.nameRequest = nil }
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
        let photo = base64.flatMap(PendingPhoto.of)
        // Encoded while the vault closed (a lock, the hold or the due state, IOS-PLAN §4.7): zeroed, never kept or sent.
        guard accounts.account.shownInShell != nil, profiles.profile != nil else {
            photo?.wipe()
            local.photoBusy = false
            return
        }
        setPending(photo)
        local.photoBusy = false
        local.photoUnreadable = photo == nil
        if let photo { sendPhoto(photo.base64()) }
    }

    public func discardPhoto() {
        setPending(nil)
        local.photoUnreadable = false
    }

    /// `profile.set{photo}` with the previewed photo.
    public func savePhoto() {
        guard let photo = local.pendingPhoto else { return }
        sendPhoto(photo.base64())
    }

    /// The vault is not open: the edited display name and the taken photo go (its bytes zeroed), and nothing typed is
    /// kept for after the unlock.
    private func dropDrafts() {
        setPending(nil)
        local.displayName = ""
        local.edited = false
        local.photoUnreadable = false
        local.saved = false
    }

    /// [photo] in place of the one held, whose bytes are zeroed.
    private func setPending(_ photo: PendingPhoto?) {
        let old = local.pendingPhoto
        local.pendingPhoto = photo
        held.withLock { $0 = photo }
        if let old, old !== photo { old.wipe() }
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
                setPending(nil)
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
