#if os(iOS)
import SwiftUI
import UIKit
import VettIDMedia
import VettIDSettings
import VettIDUI

/// What the capture screen can ask for. Mirrors vettid-android `PhotoCaptureActions`.
public struct PhotoCaptureActions {
    public var onClose: @MainActor () -> Void = {}
    public var onAllow: @MainActor () -> Void = {}
    public var onOpenSettings: @MainActor () -> Void = {}
    public var onSwitchLens: @MainActor () -> Void = {}
    public var onShutter: @MainActor () -> Void = {}
    public var onRetake: @MainActor () -> Void = {}
    public var onUse: @MainActor () -> Void = {}
    /// The shot under review zoomed or moved (``PhotoCaptureMachine/frame(_:)``).
    public var onFrame: @MainActor ((Framing, Int, Int) -> Framing) -> Void = { _ in }
    /// "Reset": the default framing.
    public var onResetFraming: @MainActor () -> Void = {}

    public init() {}
}

/// The capture screen's primary button: use the shot, open the settings, allow the camera, or the shutter.
enum CapturePrimary: Equatable {
    case use, openSettings, allow, shutter

    var label: String {
        switch self {
        case .use: ProfileStrings.captureUse
        case .openSettings: ProfileStrings.captureOpenSettings
        case .allow: ProfileStrings.captureAllow
        case .shutter: ProfileStrings.captureShutter
        }
    }

    /// None without a camera. Mirrors vettid-android `primaryAction`.
    static func of(_ s: PhotoCaptureState) -> CapturePrimary? {
        if s.step == .review && s.shot != nil { return .use }
        if s.noCamera { return nil }
        switch s.access {
        case .blocked: return .openSettings
        case .ask: return .allow
        case .granted: return .shutter
        }
    }
}

/// The secondary button: retake the shot, or switch to the other camera when the phone has both.
enum CaptureSecondary: Equatable {
    case retake, toBack, toFront

    var label: String {
        switch self {
        case .retake: ProfileStrings.captureRetake
        case .toBack: ProfileStrings.captureToBack
        case .toFront: ProfileStrings.captureToFront
        }
    }

    /// Mirrors vettid-android `secondaryAction`.
    static func of(_ s: PhotoCaptureState) -> CaptureSecondary? {
        if s.step == .review && s.shot != nil { return .retake }
        if s.canSwitch { return s.lens == .front ? .toBack : .toFront }
        return nil
    }
}

/// The profile photo is taken here, in the app: never chosen from the photo library, never taken by another camera app
/// (which could hand back any picture). The live camera in a square frame (the photo is cropped to a square), the front
/// camera first with a switch to the rear one; the shot is reviewed in a round frame (as the avatar is shown) where it is
/// zoomed and moved, with "Reset", "Retake" and "Use photo". Stateless; [camera] draws the live preview (a stand-in in the
/// tests and the screen catalog). Mirrors vettid-android `PhotoCaptureContent`.
public struct PhotoCaptureContent<Camera: View>: View {
    @Environment(\.vettIDColors) private var colors
    let state: PhotoCaptureState
    let actions: PhotoCaptureActions
    let camera: Camera

    public init(state: PhotoCaptureState, actions: PhotoCaptureActions = PhotoCaptureActions(), @ViewBuilder camera: () -> Camera) {
        self.state = state
        self.actions = actions
        self.camera = camera()
    }

    public var body: some View {
        let review = state.step == .review && state.shot != nil
        let primary = CapturePrimary.of(state)
        let secondary = CaptureSecondary.of(state)
        FormScaffold(
            title: review ? ProfileStrings.captureReviewTitle : ProfileStrings.captureTitle,
            message: review ? ProfileStrings.captureReviewBody : ProfileStrings.captureBody,
            primaryLabel: primary?.label,
            primaryEnabled: review || !state.live || state.canShoot,
            busy: state.step == .taking,
            secondaryLabel: secondary?.label,
            onPrimary: { primary.map(perform) },
            onSecondary: { secondary.map(perform) },
            onBack: review ? actions.onRetake : actions.onClose
        ) {
            VStack(alignment: .leading, spacing: Spacing.m) {
                if review, let shot = state.shot {
                    CropReview(state: state, shot: shot, actions: actions)
                } else {
                    captureBody
                }
                if state.failed && !review {
                    Text(ProfileStrings.captureFailed).vettIDFont(.bodyMedium).foregroundStyle(colors.error)
                        .accessibilityIdentifier("photo_capture_failed")
                }
                Text(ProfileStrings.captureNote).vettIDFont(.bodySmall).foregroundStyle(colors.onSurfaceVariant)
            }
        }
        .accessibilityIdentifier("photo_capture")
    }

    private func perform(_ p: CapturePrimary) {
        switch p {
        case .use: actions.onUse()
        case .openSettings: actions.onOpenSettings()
        case .allow: actions.onAllow()
        case .shutter: actions.onShutter()
        }
    }

    private func perform(_ s: CaptureSecondary) {
        switch s {
        case .retake: actions.onRetake()
        case .toBack, .toFront: actions.onSwitchLens()
        }
    }

    /// The live camera, or why there is no camera.
    @ViewBuilder private var captureBody: some View {
        if state.noCamera {
            NoticeCard(.warning, title: ProfileStrings.captureNoCameraTitle, message: ProfileStrings.captureNoCameraBody)
                .accessibilityIdentifier("photo_capture_no_camera")
        } else if state.access == .blocked {
            NoticeCard(.info, title: ProfileStrings.capturePermissionTitle, message: ProfileStrings.capturePermissionBlocked)
                .accessibilityIdentifier("photo_capture_blocked")
        } else if state.access != .granted {
            NoticeCard(.info, title: ProfileStrings.capturePermissionTitle, message: ProfileStrings.capturePermissionBody)
                .accessibilityIdentifier("photo_capture_permission")
        } else {
            // The square, gold-framed area the live camera is shown in (the photo is a square).
            ZStack {
                camera
                if state.step == .taking { ProgressView() }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(1, contentMode: .fit)
            .clipShape(VettIDShape.card)
            .overlay(VettIDShape.card.stroke(colors.primary, lineWidth: 2))
            .accessibilityIdentifier("photo_capture_live")
        }
    }
}

/// The shot under review in the round frame: pinch to zoom, drag to move, double-tap to zoom in (or back out); the zoom
/// buttons and slider do the same without a pinch, and VoiceOver offers "Show more to the left" (and the other directions)
/// as actions on the frame. Outside the circle the shot is dimmed: only what is inside is kept. Mirrors vettid-android
/// `CropReview`.
struct CropReview: View {
    @Environment(\.vettIDColors) private var colors
    let state: PhotoCaptureState
    let shot: ShotImage
    let actions: PhotoCaptureActions
    @State private var lastDrag = CGSize.zero
    @State private var lastMagnification: CGFloat = 1

    static let dimAlpha = 0.6
    static let ring: CGFloat = 2
    static let zoomEpsilon = 0.01

    /// One VoiceOver move: its label and its step.
    struct Move {
        let label: String
        let dx: Int
        let dy: Int
    }

    /// VoiceOver's moves: one per direction the shot can still move in.
    static func moves(_ f: Framing, _ w: Int, _ h: Int) -> [Move] {
        [
            Move(label: ProfileStrings.cropShowLeft, dx: -1, dy: 0), Move(label: ProfileStrings.cropShowRight, dx: 1, dy: 0),
            Move(label: ProfileStrings.cropShowUp, dx: 0, dy: -1), Move(label: ProfileStrings.cropShowDown, dx: 0, dy: 1),
        ].filter { PhotoCrop.canNudge(f, w, h, dx: $0.dx, dy: $0.dy) }
    }

    /// "Zoomed 1.5 times".
    static func zoomState(_ zoom: Double) -> String { ProfileStrings.cropZoomState(String(format: "%.1f", zoom)) }

    var body: some View {
        let w = shot.width
        let h = shot.height
        let framing = PhotoCrop.clamp(state.framing, w, h)
        VStack(spacing: Spacing.s) {
            GeometryReader { geo in
                let side = geo.size.width
                let scale = PhotoCrop.displayScale(framing, w, h, frame: side)
                let left = side / 2 - framing.centreX * Double(w) * scale
                let top = side / 2 - framing.centreY * Double(h) * scale
                ZStack {
                    // The shot, larger than the frame, placed without changing the frame's size.
                    Color.clear.overlay(alignment: .topLeading) {
                        Image(decorative: shot.image, scale: 1)
                            .resizable()
                            .interpolation(.medium)
                            .frame(width: Double(w) * scale, height: Double(h) * scale)
                            .offset(x: left, y: top)
                    }
                    // Outside the circle the shot is dimmed; the ring is the avatar's edge.
                    ZStack {
                        Color.black.opacity(Self.dimAlpha)
                        Circle().blendMode(.destinationOut)
                    }
                    .compositingGroup()
                    Circle().inset(by: Self.ring / 2).stroke(colors.primary, lineWidth: Self.ring)
                }
                .frame(width: side, height: side)
                .clipped()
                .contentShape(Rectangle())
                .gesture(drag(side))
                .simultaneousGesture(magnify(side))
                .onTapGesture(count: 2) { p in
                    actions.onFrame { f, w, h in PhotoCrop.doubleTap(f, w, h, frame: side, x: p.x, y: p.y) }
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .accessibilityElement()
            .accessibilityLabel(ProfileStrings.cropFrame)
            .accessibilityValue(Self.zoomState(framing.zoom))
            .accessibilityActions {
                ForEach(Self.moves(framing, w, h), id: \.label) { m in
                    Button(m.label) { actions.onFrame { f, w, h in PhotoCrop.nudge(f, w, h, dx: m.dx, dy: m.dy) } }
                }
            }
            .accessibilityIdentifier("photo_capture_review")
            zoomControls(framing)
            ProfileTextButton(ProfileStrings.cropReset, enabled: !framing.isDefault, action: actions.onResetFraming)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("photo_crop_reset")
        }
    }

    /// A drag moves the shot with the finger.
    private func drag(_ side: Double) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { v in
                let pan = CGSize(width: v.translation.width - lastDrag.width, height: v.translation.height - lastDrag.height)
                lastDrag = v.translation
                actions.onFrame { f, w, h in
                    PhotoCrop.gesture(
                        f, w, h, frame: side, centroidX: v.location.x, centroidY: v.location.y, panX: pan.width, panY: pan.height,
                        zoomChange: 1
                    )
                }
            }
            .onEnded { _ in lastDrag = .zero }
    }

    /// A pinch zooms about where it started.
    private func magnify(_ side: Double) -> some Gesture {
        MagnifyGesture()
            .onChanged { v in
                let change = lastMagnification > 0 ? v.magnification / lastMagnification : 1
                lastMagnification = v.magnification
                actions.onFrame { f, w, h in
                    PhotoCrop.gesture(
                        f, w, h, frame: side, centroidX: v.startLocation.x, centroidY: v.startLocation.y, panX: 0, panY: 0,
                        zoomChange: change
                    )
                }
            }
            .onEnded { _ in lastMagnification = 1 }
    }

    /// Zoom out, the zoom slider, zoom in: the pinch without a pinch. Disabled when the shot cannot be zoomed.
    private func zoomControls(_ framing: Framing) -> some View {
        let most = state.maxZoom
        let zoomable = most > 1 + Self.zoomEpsilon
        return HStack(spacing: Spacing.s) {
            IconButton(.zoomOut, label: ProfileStrings.cropZoomOut) {
                actions.onFrame { f, w, h in PhotoCrop.step(f, w, h, zoomIn: false) }
            }
            .disabled(!(zoomable && framing.zoom > 1 + Self.zoomEpsilon))
            .accessibilityIdentifier("photo_crop_zoom_out")
            Slider(
                value: Binding(get: { framing.zoom }, set: { z in actions.onFrame { f, w, h in PhotoCrop.zoomTo(f, w, h, zoom: z) } }),
                in: 1...max(most, 1 + Self.zoomEpsilon)
            )
            .disabled(!zoomable)
            .accessibilityLabel(ProfileStrings.cropZoom)
            .accessibilityIdentifier("photo_crop_zoom")
            IconButton(.zoomIn, label: ProfileStrings.cropZoomIn) {
                actions.onFrame { f, w, h in PhotoCrop.step(f, w, h, zoomIn: true) }
            }
            .disabled(!(zoomable && framing.zoom < most - Self.zoomEpsilon))
            .accessibilityIdentifier("photo_crop_zoom_in")
        }
    }
}

/// A stand-in for the live camera (the tests, the screen catalog): a face on the surface variant colour. Mirrors
/// vettid-android `FakeCameraPreview`.
public struct FakeCameraPreview: View {
    @Environment(\.vettIDColors) private var colors

    public init() {}

    public var body: some View {
        ZStack {
            Rectangle().fill(colors.surfaceVariant)
            VettIDSymbol.face.image.font(.system(size: 120)).foregroundStyle(colors.onSurfaceVariant).accessibilityHidden(true)
        }
    }
}

/// The capture screen with the real camera: asks for the camera when it first opens, explains a refusal (and offers the
/// app's page in Settings, the only place the camera can be allowed again), reports a phone without a camera, and hands
/// the accepted shot and the square under the round frame to [onUse] (which owns the shot from then on). The shot is
/// decoded in memory (``ShotImage/decode(_:mirrored:shortSide:)``: the front camera's mirrored as previewed), the camera's
/// encoded bytes zeroed once decoded. Back from the review retakes; back from the camera closes. Capture hiding (IOS-PLAN
/// §6.4 protection 2) and the app-switcher cover stay on, as everywhere. Mirrors vettid-android `PhotoCaptureScreen`.
public struct PhotoCaptureScreen: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    let machine: PhotoCaptureMachine
    let onClose: @MainActor () -> Void
    let onUse: @MainActor (PhotoSelection) -> Void
    @State private var handle = PhotoCameraHandle()

    public init(
        machine: PhotoCaptureMachine, onClose: @escaping @MainActor () -> Void, onUse: @escaping @MainActor (PhotoSelection) -> Void
    ) {
        self.machine = machine
        self.onClose = onClose
        self.onUse = onUse
    }

    /// The machine's view of iOS's camera access (nil: no camera this app can use).
    static func access(_ a: CameraAccess) -> PhotoCaptureAccess? {
        switch a {
        case .granted: .granted
        case .notDetermined: .ask
        case .denied, .restricted: .blocked
        case .unavailable: nil
        }
    }

    public var body: some View {
        let state = machine.state
        PhotoCaptureContent(state: state, actions: actions) {
            PhotoCameraView(
                lens: state.lens == .front ? .front : .back, handle: handle, onUnavailable: { machine.unavailable() }, fill: true
            )
        }
        .task {
            guard readAccess() == .ask else { return }
            await request()
        }
        // Back from the app's page in Settings: the camera may be allowed now.
        .onChange(of: scenePhase) { _, phase in if phase == .active { _ = readAccess() } }
    }

    /// Reads iOS's camera access and the lenses into the machine; returns the access (nil: no camera).
    @discardableResult
    private func readAccess() -> PhotoCaptureAccess? {
        guard let a = Self.access(CameraAccess.current()) else {
            machine.unavailable()
            return nil
        }
        let lenses = PhotoCameraView.lenses()
        machine.lenses(front: lenses.front, back: lenses.back)
        machine.access(a)
        return a
    }

    private func request() async {
        let a = await CameraAccess.request()
        machine.access(Self.access(a) ?? .blocked)
    }

    private var actions: PhotoCaptureActions {
        var a = PhotoCaptureActions()
        let machine = machine
        let handle = handle
        let onUse = onUse
        a.onClose = onClose
        a.onAllow = { Task { await request() } }
        a.onOpenSettings = { if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) } }
        a.onSwitchLens = { machine.switchLens() }
        a.onShutter = {
            guard machine.shutter() else { return }
            let mirrored = machine.state.lens == .front
            guard let take = handle.take else { return machine.shot(nil) }
            take { bytes in
                guard let bytes else { return machine.shot(nil) }
                let held = PhotoBytes(bytes)
                Task {
                    let shot = await Task.detached {
                        defer { held.wipe() }
                        return held.withBytes { try? ShotImage.decode($0, mirrored: mirrored) }
                    }.value
                    machine.shot(shot)
                }
            }
        }
        a.onRetake = { machine.retake() }
        a.onUse = { if let s = machine.use() { onUse(s) } }
        a.onFrame = { machine.frame($0) }
        a.onResetFraming = { machine.resetFraming() }
        return a
    }
}
#endif
