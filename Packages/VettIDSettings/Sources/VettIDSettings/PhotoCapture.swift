import Foundation
import Observation
import VettIDMedia

/// Where the profile-photo capture is (the photo is taken in the app, never chosen). Mirrors vettid-android `CaptureStep`.
public enum CaptureStep: Equatable, Sendable {
    /// The live camera, ready for the shutter.
    case live
    /// The shutter was pressed; the picture is on its way.
    case taking
    /// The shot is shown in the round frame, to zoom and move, with "Reset", "Retake" and "Use photo".
    case review
}

/// Whether the camera may be used for the photo. Mirrors vettid-android `CameraAccess` (`ASK`, `BLOCKED`, `GRANTED`): on
/// the iPhone the system asks once, and after a refusal (or on a phone where the camera is restricted) only the app's
/// page in Settings can allow it, so Android's `DENIED`, a refusal the system would ask about again, has no counterpart.
public enum PhotoCaptureAccess: Equatable, Sendable {
    /// Not asked yet: the screen asks when it opens, and "Allow camera" asks again.
    case ask
    /// Refused or restricted: "Open settings".
    case blocked
    case granted
}

/// Which camera takes the photo. Mirrors vettid-android `CameraLens`.
public enum CaptureLens: Equatable, Sendable {
    case front, back
}

/// The capture screen's state. [shot] lives in memory only: it is never written to storage, and zeroed when dropped.
/// Mirrors vettid-android `PhotoCaptureUiState`.
public struct PhotoCaptureState: Equatable, Sendable {
    public var access: PhotoCaptureAccess = .ask
    /// The phone has no camera the app can open.
    public var noCamera = false
    public var lens: CaptureLens = .front
    /// The cameras the phone has (both assumed until the camera reports).
    public var front = true
    public var back = true
    public var step: CaptureStep = .live
    public var shot: ShotImage?
    /// The last shutter press brought no picture.
    public var failed = false
    /// How the shot under review sits in the round frame (normalised).
    public var framing = Framing()

    public init(access: PhotoCaptureAccess = .ask, noCamera: Bool = false, step: CaptureStep = .live, shot: ShotImage? = nil) {
        self.access = access
        self.noCamera = noCamera
        self.step = step
        self.shot = shot
    }

    /// The camera may be shown.
    public var live: Bool { access == .granted && !noCamera }

    public var canShoot: Bool { live && step == .live }

    public var canSwitch: Bool { canShoot && front && back }

    /// The most the shot under review can be zoomed in (1: none, or no shot).
    public var maxZoom: Double { shot.map { PhotoCrop.maxZoom($0.width, $0.height) } ?? 1 }

    public static func == (a: PhotoCaptureState, b: PhotoCaptureState) -> Bool {
        a.access == b.access && a.noCamera == b.noCamera && a.lens == b.lens && a.front == b.front && a.back == b.back
            && a.step == b.step && a.shot === b.shot && a.failed == b.failed && a.framing == b.framing
    }
}

/// The shot "Use photo" hands over and the square of it to keep (under the round frame). Mirrors vettid-android
/// `PhotoSelection`.
public struct PhotoSelection: Sendable {
    public let shot: ShotImage
    public let crop: CropRect

    public init(shot: ShotImage, crop: CropRect) {
        self.shot = shot
        self.crop = crop
    }

    /// [shot] with the default framing (centred, fitted).
    public static func centred(_ shot: ShotImage) -> PhotoSelection {
        PhotoSelection(shot: shot, crop: PhotoCrop.sourceRect(Framing(), shot.width, shot.height))
    }
}

/// The capture's state machine: the permission, the cameras, the shutter, the shot under review. Pure state; the screen
/// drives the camera. A shot that is retaken or dropped is zeroed; ``use()`` hands it over. Mirrors vettid-android
/// `PhotoCaptureMachine` and `PhotoCaptureViewModel` (the shot dropped with it).
@MainActor
@Observable
public final class PhotoCaptureMachine {
    public private(set) var state = PhotoCaptureState()

    public init() {}

    public func access(_ a: PhotoCaptureAccess) { state.access = a }

    /// The cameras the phone has; a missing lens is swapped for the other, none at all is ``PhotoCaptureState/noCamera``.
    public func lenses(front: Bool, back: Bool) {
        switch (front, back) {
        case (false, false):
            state.front = false
            state.back = false
            state.noCamera = true
        case (false, true) where state.lens == .front:
            state.front = false
            state.back = true
            state.lens = .back
        case (true, false) where state.lens == .back:
            state.front = true
            state.back = false
            state.lens = .front
        default:
            state.front = front
            state.back = back
        }
    }

    /// No camera can be opened (none on the phone, or the camera failed to start).
    public func unavailable() { state.noCamera = true }

    public func switchLens() {
        guard state.canSwitch else { return }
        state.lens = state.lens == .front ? .back : .front
        state.failed = false
    }

    /// The shutter: true when a picture should be taken now.
    public func shutter() -> Bool {
        guard state.canShoot else { return false }
        state.step = .taking
        state.failed = false
        return true
    }

    /// The picture the camera returned (nil: none). Ignored (and zeroed) unless a picture was asked for.
    public func shot(_ s: ShotImage?) {
        guard state.step == .taking else {
            s?.wipe()
            return
        }
        if let s {
            state.step = .review
            state.shot = s
            state.framing = Framing()
        } else {
            state.step = .live
            state.failed = true
        }
    }

    /// The shot under review zoomed or moved: [change] gets the current framing and the shot's width and height; what it
    /// returns is clamped so that the shot covers the frame within the allowed zoom. Ignored without a shot under review.
    public func frame(_ change: (Framing, Int, Int) -> Framing) {
        guard state.step == .review, let shot = state.shot else { return }
        state.framing = PhotoCrop.clamp(change(state.framing, shot.width, shot.height), shot.width, shot.height)
    }

    /// "Reset": the shot under review centred and fitted again.
    public func resetFraming() { frame { _, _, _ in Framing() } }

    /// Back to the live camera; the shot (and its framing) is dropped and zeroed.
    public func retake() {
        let old = state.shot
        state.step = .live
        state.shot = nil
        state.failed = false
        state.framing = Framing()
        old?.wipe()
    }

    /// The shot under review and the square under the round frame, handed over to the caller (who zeroes the shot); nil
    /// when there is none.
    public func use() -> PhotoSelection? {
        guard state.step == .review, let shot = state.shot else { return nil }
        let crop = PhotoCrop.sourceRect(state.framing, shot.width, shot.height)
        state.step = .live
        state.shot = nil
        state.framing = Framing()
        return PhotoSelection(shot: shot, crop: crop)
    }

    /// A fresh capture: the front camera, no shot (the permission is kept). The screen calls it when it opens and closes.
    public func reset() {
        let old = state.shot
        state = PhotoCaptureState(access: state.access)
        old?.wipe()
    }
}

/// The selected square of the shot as `profile.set{photo}` takes it (VAULT-MESSAGING §10.8): exactly the square under the
/// round frame, which ``ProfilePhotoEncoder/encode(_:crop:maxBytes:)`` scales down and re-encodes as a JPEG of at most
/// 65,536 bytes without metadata, in standard base64. Zeroes the shot and the encoded bytes once the text is made. Nil
/// when it cannot be encoded. Blocking: call off the main actor. Mirrors vettid-android `encodeShot`.
public func encodeShot(_ selection: PhotoSelection) -> String? {
    defer { selection.shot.wipe() }
    guard var jpeg = try? ProfilePhotoEncoder.encode(selection.shot.image, crop: selection.crop.rect) else { return nil }
    defer { jpeg.withUnsafeMutableBufferPointer { p in for i in p.indices { p[i] = 0 } } }
    // Read in place (no copy of the bytes that the zeroing would miss).
    return jpeg.withUnsafeMutableBytes { p in
        guard let base = p.baseAddress else { return nil }
        return Data(bytesNoCopy: base, count: p.count, deallocator: .none).base64EncodedString()
    }
}
