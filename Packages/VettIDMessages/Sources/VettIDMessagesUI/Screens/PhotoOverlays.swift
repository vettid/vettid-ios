#if os(iOS)
import SwiftUI
import UIKit
import VettIDData
import VettIDMedia
import VettIDMessages
import VettIDUI

/// The photo screens' content kept out of screenshots and recordings (IOS-PLAN §6.4 protection 3) unless "Allow
/// screenshots" is on, as vettid-android holds its photo screens secure (`SecureWindow`); the app-switcher cover and
/// capture hiding are always on.
struct PhotoSecure<Content: View>: View {
    @Environment(ScreenshotAllowance.self) private var allowance: ScreenshotAllowance?
    @ViewBuilder let content: () -> Content

    var body: some View {
        SecureContainer(isSecure: !(allowance?.allowed ?? false)) { content() }
    }
}

/// The app's own camera for a message photo (ANDROID-PLAN "Take a photo"): the back camera first, with a switch; the shot
/// is taken into memory (never a file), then "Retake" or "Use photo". Camera access is asked when it opens; after a
/// refusal only Settings can allow it. Mirrors vettid-android `PhotoCaptureOverlay`.
struct PhotoCaptureOverlay: View {
    @Environment(\.vettIDColors) private var colors
    @Environment(\.openURL) private var openURL
    let actions: PhotoActions
    @State private var access = CameraAccess.current()
    @State private var lens = CameraLens.back
    @State private var both = false
    @State private var shot: [UInt8]?
    @State private var review: UIImage?
    @State private var unavailable = false
    @State private var handle = PhotoCameraHandle()

    var body: some View {
        PhotoSecure {
            VStack(spacing: 0) {
                HStack {
                    IconButton(.close, label: MessagesStrings.photoCloseCamera, action: close)
                    Spacer()
                    if both, shot == nil {
                        IconButton(.cameraSwitch, label: MessagesStrings.photoSwitchCamera) { lens = lens == .back ? .front : .back }
                    }
                }
                ZStack { viewfinder }.frame(maxWidth: .infinity, maxHeight: .infinity)
                buttons.padding(Spacing.l)
            }
            .background(colors.background)
        }
        .accessibilityIdentifier("photo_camera")
        .task {
            if access == .notDetermined { access = await CameraAccess.request() }
        }
    }

    @ViewBuilder private var viewfinder: some View {
        if let review {
            Image(uiImage: review).resizable().scaledToFit().accessibilityLabel(MessagesStrings.photoReview)
        } else if access != .granted {
            VStack(spacing: Spacing.m) {
                Text(MessagesStrings.photoCameraPermission).vettIDFont(.bodyLarge).multilineTextAlignment(.center)
                if access == .denied {
                    SecondaryButton(MessagesStrings.photoCameraSettings) {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                } else if access == .notDetermined {
                    SecondaryButton(MessagesStrings.photoCameraAllow) { Task { access = await CameraAccess.request() } }
                }
            }
            .padding(Spacing.xl)
        } else if unavailable {
            Text(MessagesStrings.photoNoCamera).vettIDFont(.bodyLarge).multilineTextAlignment(.center).padding(Spacing.xl)
        } else {
            PhotoCameraView(lens: lens, handle: handle, onLenses: { both = $0 }, onUnavailable: { unavailable = true })
        }
    }

    @ViewBuilder private var buttons: some View {
        HStack(spacing: Spacing.m) {
            if let current = shot {
                SecondaryButton(MessagesStrings.photoRetake) { discardShot() }
                PrimaryButton(MessagesStrings.photoUse) {
                    shot = nil
                    review = nil
                    actions.onShot(current)
                }
            } else if access == .granted, !unavailable {
                PrimaryButton(MessagesStrings.photoShutter) { take() }.accessibilityIdentifier("photo_shutter")
            }
        }
    }

    private func take() {
        handle.take? { bytes in
            guard let bytes else { return }
            shot = bytes
            Task { review = await PhotoImages.shot(bytes, edge: 1_440) }
        }
    }

    private func discardShot() {
        if shot != nil { shot?.withUnsafeMutableBufferPointer { p in for i in p.indices { p[i] = 0 } } }
        shot = nil
        review = nil
    }

    private func close() {
        discardShot()
        actions.onCloseCamera()
    }
}

/// The prepared photos before they are sent (ANDROID-PLAN "Preparing it, in memory", step 5): the prepared photo, not the
/// original, with "Location and camera details are removed before sending", the caption, Send and Cancel; Retry after a
/// lost answer. Mirrors vettid-android `PhotoDraftOverlay`.
struct PhotoDraftOverlay: View {
    @Environment(\.vettIDColors) private var colors
    let draft: PhotoDraft
    let name: String
    let actions: PhotoActions

    var body: some View {
        PhotoSecure {
            VStack(alignment: .leading, spacing: Spacing.s) {
                HStack {
                    IconButton(.close, label: MessagesStrings.photoCancel, action: actions.onCancel).disabled(draft.inFlight)
                        .accessibilityIdentifier("photo_cancel_x")
                    Text(MessagesStrings.photoTo(name)).vettIDFont(.titleMedium)
                    Spacer()
                }
                previews.frame(maxWidth: .infinity, maxHeight: .infinity)
                Text(MessagesStrings.photoStripped).vettIDFont(.bodySmall).foregroundStyle(colors.onSurfaceVariant)
                    .padding(.horizontal, Spacing.gutter)
                notes.padding(.horizontal, Spacing.gutter)
                if draft.sent == 0 {
                    TextField("", text: Binding(get: { draft.caption }, set: { actions.onCaption($0) }),
                              prompt: Text(MessagesStrings.photoCaption), axis: .vertical)
                        .lineLimit(1...3)
                        .vettIDFont(.bodyLarge)
                        .padding(Spacing.m)
                        .overlay(RoundedRectangle(cornerRadius: VettIDShape.small).stroke(colors.outline))
                        .padding(.horizontal, Spacing.gutter)
                        .accessibilityIdentifier("photo_caption")
                }
                buttons.padding(Spacing.gutter)
            }
            .background(colors.background)
        }
        .accessibilityIdentifier("photo_draft")
    }

    @ViewBuilder private var previews: some View {
        if draft.preparing {
            ProgressView().tint(colors.primary.color)
        } else {
            TabView {
                ForEach(Array(draft.photos.enumerated()), id: \.offset) { i, p in
                    DraftPreview(photo: p, label: MessagesStrings.photoPreview(i + 1, draft.photos.count))
                }
            }
            .tabViewStyle(.page(indexDisplayMode: draft.photos.count > 1 ? .automatic : .never))
        }
    }

    @ViewBuilder private var notes: some View {
        if let p = draft.problem {
            NoticeCard(.warning, title: MessagesStrings.errorTitle, message: photoProblemText(p)) {
                if draft.photos.isEmpty {
                    Button(MessagesStrings.ok, action: actions.onDismissProblem).accessibilityIdentifier("photo_problem_ok")
                }
            }
            .accessibilityIdentifier("photo_problem")
        }
        if draft.failedPicks > 0 {
            Text(MessagesStrings.photoFailedPicks(draft.failedPicks)).vettIDFont(.bodySmall).foregroundStyle(colors.error)
                .accessibilityIdentifier("photo_failed_picks")
        }
        if draft.sent > 0, !draft.photos.isEmpty {
            Text(MessagesStrings.photoProgress(draft.sent, draft.sent + draft.photos.count)).vettIDFont(.bodySmall)
        }
    }

    private var buttons: some View {
        HStack(spacing: Spacing.m) {
            Spacer()
            SecondaryButton(MessagesStrings.photoCancel, action: actions.onCancel).disabled(draft.inFlight)
                .accessibilityIdentifier("photo_cancel")
            PrimaryButton(draft.retry ? MessagesStrings.photoRetry : MessagesStrings.send, busy: draft.sending, action: actions.onSend)
                .disabled(!draft.canSend)
                .accessibilityIdentifier("photo_send")
        }
    }
}

/// One prepared photo as it will be sent, decoded from its JPEG in memory.
private struct DraftPreview: View {
    let photo: PreparedPhoto
    let label: String
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image { Image(uiImage: image).resizable().scaledToFit().accessibilityLabel(label) }
        }
        .task(id: ObjectIdentifier(photo)) {
            image = nil
            image = await PhotoImages.received(photo.jpeg.copy(), edge: 1_440)
        }
    }
}
#endif
