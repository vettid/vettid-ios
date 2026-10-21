#if os(iOS)
import SwiftUI
import UIKit
import VettIDData
import VettIDSettings
import VettIDUI

/// What the shared-profile screen can ask for. Mirrors vettid-android `SharedProfileActions` (less the `@profile` items,
/// which come with the items of IOS-PLAN §8 I3).
public struct SharedProfileActions {
    public var onBack: @MainActor () -> Void = {}
    public var onDisplayName: @MainActor (String) -> Void = { _ in }
    public var onSave: @MainActor () -> Void = {}
    public var onChangeName: @MainActor () -> Void = {}
    public var onDismiss: @MainActor () -> Void = {}
    /// Opens the in-app camera (the photo is taken, never chosen from the photo library).
    public var onTakePhoto: @MainActor () -> Void = {}
    public var onSavePhoto: @MainActor () -> Void = {}
    public var onDiscardPhoto: @MainActor () -> Void = {}
    public var onRemovePhoto: @MainActor () -> Void = {}

    public init() {}
}

/// The shared profile's glyph (an ID card, vettid-android's Material `Badge`): the screen's header and every row that
/// opens it (Settings, the avatar sheet). Mirrors vettid-android `SharedProfileIcon`.
public let sharedProfileSymbol = VettIDSymbol.badge

/// Settings → Shared profile (ANDROID-PLAN 0.1.10, VAULT-MESSAGING §10.8): the name on the VettID account, read-only
/// (every connection sees it; never called verified) with "Change name"; the optional display name, edited here; the
/// profile photo; the vault key fingerprint connections see. Stateless. Mirrors vettid-android `SharedProfileContent`.
public struct SharedProfileContent: View {
    @Environment(\.vettIDColors) private var colors
    @Environment(\.vettIDTimeScale) private var timeScale
    let state: SharedProfileState
    let actions: SharedProfileActions
    /// The decoded photo to show (the taken one being previewed, else the vault's), decoded by the caller.
    let photo: UIImage?
    let now: Date

    public init(
        state: SharedProfileState, actions: SharedProfileActions = SharedProfileActions(), photo: UIImage? = nil, now: Date = Date()
    ) {
        self.state = state
        self.actions = actions
        self.photo = photo
        self.now = now
    }

    public var body: some View {
        FormScaffold(
            title: ProfileStrings.title, message: ProfileStrings.body, primaryLabel: ProfileStrings.save,
            primaryEnabled: state.saveAllowed, busy: state.busy, onPrimary: actions.onSave, onBack: actions.onBack,
            header: { HeaderGlyph(symbol: sharedProfileSymbol) }
        ) {
            VStack(alignment: .leading, spacing: Spacing.m) {
                namesCard
                displayNameField
                SharedProfilePhotoCard(state: state, actions: actions, photo: photo)
                if state.saved {
                    NoticeCard(.success, title: ProfileStrings.title, message: ProfileStrings.saved) {
                        ProfileTextButton(SettingsStrings.done, action: actions.onDismiss)
                    }
                    .accessibilityIdentifier("display_name_saved")
                }
                if let error = state.error {
                    NoticeCard(.warning, title: ProfileStrings.error, message: Self.errorText(error, state.limit, timeScale: timeScale)) {
                        ProfileTextButton(SettingsStrings.done, action: actions.onDismiss)
                    }
                    .accessibilityIdentifier("profile_error")
                }
                if let fp = state.profile?.fingerprint {
                    DetailCard {
                        Text(ProfileStrings.key).vettIDFont(.labelLarge)
                        Text(fp).vettIDFont(.bodyLarge).monospaced().textSelection(.enabled)
                        Text(ProfileStrings.keyNote).vettIDFont(.bodySmall).foregroundStyle(colors.onSurfaceVariant)
                    }
                    .accessibilityIdentifier("profile_fingerprint")
                }
            }
        }
        .accessibilityIdentifier("shared_profile")
    }

    /// A `limit` error names its limit (VAULT-MESSAGING §10.1: `profile_size`); any other failure its own text.
    static func errorText(_ kind: FailureKind, _ limit: VaultLimit?, timeScale: UInt64) -> String {
        if kind == .limit, let limit { return limit.message }
        return kind.message(timeScale: timeScale)
    }

    private var namesCard: some View {
        DetailCard {
            Text(ProfileStrings.names).vettIDFont(.labelLarge)
            Text(state.fullName ?? ProfileStrings.namesNone)
                .vettIDFont(.titleLarge, weight: .semibold)
                .accessibilityIdentifier("profile_full_name")
            Text(ProfileStrings.namesNote).vettIDFont(.bodySmall).foregroundStyle(colors.onSurfaceVariant)
            if let status = NameStatus.text(state.account, now: now) {
                Text(status).vettIDFont(.bodyMedium).padding(.top, Spacing.s).accessibilityIdentifier("name_status")
            }
            ProfileTextButton(ProfileStrings.changeName, action: actions.onChangeName).accessibilityIdentifier("change_name")
        }
        .accessibilityIdentifier("profile_names")
    }

    private var displayNameField: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(ProfileStrings.displayName)
                .vettIDFont(.labelMedium)
                .foregroundStyle(state.tooLong ? colors.error : colors.onSurfaceVariant)
            TextField("", text: Binding(get: { state.displayName }, set: { actions.onDisplayName($0) }))
                .textInputAutocapitalization(.words)
                .submitLabel(.done)
                .onSubmit { actions.onSave() }
                .disabled(state.profile == nil || state.busy)
                .vettIDFont(.bodyLarge)
                .frame(minHeight: Spacing.touchTarget)
                .padding(.horizontal, Spacing.l)
                .overlay(RoundedRectangle(cornerRadius: VettIDShape.small).stroke(state.tooLong ? colors.error : colors.outline))
                .accessibilityLabel(ProfileStrings.displayName)
                .accessibilityIdentifier("display_name")
            Text(state.tooLong ? ProfileStrings.displayNameTooLong : ProfileStrings.displayNameHint)
                .vettIDFont(.bodySmall)
                .foregroundStyle(state.tooLong ? colors.error : colors.onSurfaceVariant)
        }
    }
}

/// The profile photo (VAULT-MESSAGING §10.8): the vault's, or a taken one as a preview until it is saved; "Take a photo"
/// ("Retake photo" when one is shared) opens the in-app camera (no picture is chosen from the photo library), "Remove
/// photo" (confirmed) sends `photo: ""`. Mirrors vettid-android `PhotoCard`.
struct SharedProfilePhotoCard: View {
    @Environment(\.vettIDColors) private var colors
    let state: SharedProfileState
    let actions: SharedProfileActions
    let photo: UIImage?
    @State private var confirmRemove = false

    /// What the card says about the photo.
    static func status(_ s: SharedProfileState) -> String {
        if s.photoBusy { return ProfileStrings.photoWorking }
        if s.pendingPhoto != nil { return ProfileStrings.photoPreview }
        if s.profile?.photo != nil { return ProfileStrings.photoShared }
        return ProfileStrings.photoNone
    }

    var body: some View {
        let enabled = state.profile != nil && !state.photoBusy && !state.busy
        DetailCard {
            Text(ProfileStrings.photo).vettIDFont(.labelLarge)
            HStack(spacing: Spacing.l) {
                InitialTile(state.fullName ?? "", size: 72, style: .ownAccount, photo: photo)
                Text(Self.status(state))
                    .vettIDFont(.bodyMedium)
                    .foregroundStyle(colors.onSurfaceVariant)
                    .accessibilityIdentifier("profile_photo_status")
                Spacer(minLength: 0)
            }
            .padding(.vertical, Spacing.s)
            HStack(spacing: Spacing.s) {
                if state.pendingPhoto != nil {
                    ProfileTextButton(ProfileStrings.photoSave, enabled: enabled, action: actions.onSavePhoto)
                        .accessibilityIdentifier("photo_save")
                    ProfileTextButton(ProfileStrings.photoDiscard, enabled: enabled, action: actions.onDiscardPhoto)
                } else {
                    let hasPhoto = state.profile?.photo != nil
                    ProfileTextButton(
                        hasPhoto ? ProfileStrings.photoRetake : ProfileStrings.photoTake, enabled: enabled, action: actions.onTakePhoto
                    )
                        .accessibilityIdentifier("photo_take")
                    if hasPhoto {
                        ProfileTextButton(ProfileStrings.photoRemove, enabled: enabled) { confirmRemove = true }
                            .accessibilityIdentifier("photo_remove")
                    }
                }
            }
            if state.photoUnreadable {
                Text(ProfileStrings.photoUnreadable)
                    .vettIDFont(.bodySmall)
                    .foregroundStyle(colors.error)
                    .accessibilityIdentifier("photo_unreadable")
            }
            if state.photoSaved {
                Text(ProfileStrings.photoSaved).vettIDFont(.bodySmall).accessibilityIdentifier("photo_saved")
            }
            Text(ProfileStrings.photoNote).vettIDFont(.bodySmall).foregroundStyle(colors.onSurfaceVariant)
        }
        .accessibilityIdentifier("profile_photo")
        .confirmDialog(
            isPresented: $confirmRemove, title: ProfileStrings.photoRemoveTitle, message: ProfileStrings.photoRemoveBody,
            confirmLabel: ProfileStrings.photoRemove, destructive: true, dismissLabel: SettingsStrings.cancel,
            onConfirm: actions.onRemovePhoto
        )
    }
}

/// A text button (vettid-android's `TextButton`): the primary colour, the touch target's height, dimmed when disabled.
struct ProfileTextButton: View {
    @Environment(\.vettIDColors) private var colors
    let label: String
    let enabled: Bool
    let action: @MainActor () -> Void

    init(_ label: String, enabled: Bool = true, action: @escaping @MainActor () -> Void) {
        self.label = label
        self.enabled = enabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(label)
                .vettIDFont(.labelLarge, weight: .semibold)
                .foregroundStyle(enabled ? colors.primary : colors.onSurfaceVariant)
                .frame(minHeight: Spacing.touchTarget)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}
/// Settings → Shared profile with its view model and the camera, made when it first appears. The profile photo is taken
/// with the in-app camera (``PhotoCaptureScreen``), never chosen from the photo library; the square under the round frame
/// is encoded off the main actor (VAULT-MESSAGING §10.8: at most 65,536 bytes) and the shot zeroed. Leaving the screen
/// drops a shot under review. [onChangeName] opens the name change. Mirrors vettid-android's `SharedProfileRoute`
/// destination.
public struct SharedProfileRoute: View {
    private let profiles: any ProfileRepository
    private let accounts: any AccountRepository
    private let onChangeName: @MainActor () -> Void
    private let onClose: @MainActor () -> Void
    @State private var model: SharedProfileViewModel?
    @State private var machine = PhotoCaptureMachine()
    @State private var capturing = false
    @State private var photo: UIImage?

    public init(
        profiles: any ProfileRepository, accounts: any AccountRepository, onChangeName: @escaping @MainActor () -> Void,
        onClose: @escaping @MainActor () -> Void
    ) {
        self.profiles = profiles
        self.accounts = accounts
        self.onChangeName = onChangeName
        self.onClose = onClose
    }

    public var body: some View {
        let state = model?.state ?? SharedProfileState(account: accounts.account, profile: profiles.profile)
        Group {
            if capturing {
                PhotoCaptureScreen(
                    machine: machine,
                    onClose: {
                        capturing = false
                        machine.reset()
                    },
                    onUse: { selection in
                        capturing = false
                        machine.reset()
                        let m = model
                        m?.photoEncoding()
                        Task {
                            let encoded = await Task.detached { encodeShot(selection) }.value
                            m?.photoTaken(encoded)
                        }
                    }
                )
            } else {
                SharedProfileContent(state: state, actions: actions, photo: photo)
            }
        }
        .onAppear { if model == nil { model = SharedProfileViewModel(profiles: profiles, accounts: accounts) } }
        .onDisappear { machine.reset() }
        .task(id: ShownPhoto(state)) {
            let decoded = await ShownPhoto.decoded(state)
            // A decode that began before the photo changed or was cleared does not show it after.
            guard !Task.isCancelled else { return }
            photo = decoded
        }
    }

    private var actions: SharedProfileActions {
        var a = SharedProfileActions()
        let m = model
        let machine = machine
        a.onBack = onClose
        a.onDisplayName = { m?.setDisplayName($0) }
        a.onSave = { m?.save() }
        a.onChangeName = onChangeName
        a.onDismiss = { m?.dismiss() }
        a.onTakePhoto = {
            machine.reset()
            capturing = true
        }
        a.onSavePhoto = { m?.savePhoto() }
        a.onDiscardPhoto = { m?.discardPhoto() }
        a.onRemovePhoto = { m?.removePhoto() }
        return a
    }
}
/// Which photo the screen shows: the taken one being previewed (its bytes, zeroed when it is saved or dropped), else the
/// vault's. Mirrors vettid-android `rememberShownPhoto`.
struct ShownPhoto: Hashable {
    let pending: ObjectIdentifier?
    let shared: String?

    init(_ s: SharedProfileState) {
        pending = s.pendingPhoto.map { ObjectIdentifier($0) }
        shared = s.pendingPhoto == nil ? s.profile?.photo : nil
    }

    /// The image of the photo [s] shows, decoded off the main actor.
    static func decoded(_ s: SharedProfileState) async -> UIImage? {
        if let pending = s.pendingPhoto {
            return await Task.detached { pending.bytes.withBytes { ProfilePhotos.decodeImage($0) } }.value
        }
        return await ProfilePhotos.decoded(s.profile?.photo)
    }
}
#endif
