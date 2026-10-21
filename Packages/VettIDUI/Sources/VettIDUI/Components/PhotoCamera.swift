@preconcurrency import AVFoundation
import SwiftUI
import UIKit

/// Which camera takes the photo.
public enum CameraLens: Sendable {
    case back, front

    var position: AVCaptureDevice.Position { self == .back ? .back : .front }
}

/// What the camera screen asks the preview for: a shot. The preview sets ``take``; the screen calls it.
@MainActor
public final class PhotoCameraHandle {
    /// Takes a shot and hands its encoded bytes (or nil when it failed) to the closure, on the main actor.
    public internal(set) var take: ((@escaping @MainActor ([UInt8]?) -> Void) -> Void)?

    public init() {}
}

/// The app's own camera for a photo (ANDROID-PLAN "Photo attachments", "Take a photo"; IOS-PLAN §4: AVFoundation camera
/// to memory): the preview of [lens] and an `AVCapturePhotoOutput` whose shot is handed over as the bytes of
/// `fileDataRepresentation()`, in memory only: nothing is written to a file, not even briefly, and no location is asked
/// for or added. [onLenses] says whether both cameras exist (the switch is offered then); [onUnavailable]: the camera
/// could not be started. Mirrors vettid-android core/ui `PhotoCamera`.
public struct PhotoCameraView: UIViewRepresentable {
    let lens: CameraLens
    let handle: PhotoCameraHandle
    let onLenses: @MainActor (Bool) -> Void
    let onUnavailable: @MainActor () -> Void

    public init(
        lens: CameraLens, handle: PhotoCameraHandle, onLenses: @escaping @MainActor (Bool) -> Void = { _ in },
        onUnavailable: @escaping @MainActor () -> Void = {}
    ) {
        self.lens = lens
        self.handle = handle
        self.onLenses = onLenses
        self.onUnavailable = onUnavailable
    }

    public func makeCoordinator() -> Coordinator { Coordinator(onUnavailable: onUnavailable) }

    public func makeUIView(context: Context) -> QrScannerView.PreviewView {
        let view = QrScannerView.PreviewView()
        view.previewLayer.videoGravity = .resizeAspect
        view.previewLayer.session = context.coordinator.capture.session
        let both = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil
            && AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) != nil
        onLenses(both)
        context.coordinator.use(lens)
        let coordinator = context.coordinator
        handle.take = { [weak coordinator] done in coordinator?.shoot(done) ?? done(nil) }
        return view
    }

    public func updateUIView(_ view: QrScannerView.PreviewView, context: Context) {
        context.coordinator.onUnavailable = onUnavailable
        context.coordinator.use(lens)
    }

    public static func dismantleUIView(_ view: QrScannerView.PreviewView, coordinator: Coordinator) { coordinator.capture.stop() }

    /// Owns the capture session and the shots on their way.
    @MainActor
    public final class Coordinator: NSObject {
        var onUnavailable: @MainActor () -> Void
        let capture = PhotoCapture()
        private var lens: CameraLens?
        private var shots: [Int64: ShotDelegate] = [:]

        init(onUnavailable: @escaping @MainActor () -> Void) { self.onUnavailable = onUnavailable }

        func use(_ lens: CameraLens) {
            guard lens != self.lens else { return }
            self.lens = lens
            capture.start(lens) { [weak self] in Task { @MainActor in self?.onUnavailable() } }
        }

        func shoot(_ done: @escaping @MainActor ([UInt8]?) -> Void) {
            let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            let id = settings.uniqueID
            let delegate = ShotDelegate { [weak self] bytes in
                Task { @MainActor in
                    self?.shots[id] = nil
                    done(bytes)
                }
            }
            shots[id] = delegate
            capture.shoot(settings, delegate)
        }
    }

    /// Hands the shot's bytes over once (nil when it failed); never a file.
    final class ShotDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
        private let done: @Sendable ([UInt8]?) -> Void

        init(done: @escaping @Sendable ([UInt8]?) -> Void) { self.done = done }

        func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: (any Error)?) {
            finish(error == nil ? photo.fileDataRepresentation().map { [UInt8]($0) } : nil)
        }

        func finish(_ bytes: [UInt8]?) { done(bytes) }
    }

    /// The session and its photo output, configured, started and stopped off the main thread on their own queue.
    public final class PhotoCapture: @unchecked Sendable {
        let session = AVCaptureSession()
        private let output = AVCapturePhotoOutput()
        private let queue = DispatchQueue(label: "org.vettid.ui.photo-capture")
        private var input: AVCaptureDeviceInput?

        func start(_ lens: CameraLens, onFailure: @escaping @Sendable () -> Void) {
            queue.async { [self] in
                guard configure(lens) else { return onFailure() }
                if !session.isRunning { session.startRunning() }
            }
        }

        func stop() { queue.async { [self] in if session.isRunning { session.stopRunning() } } }

        func shoot(_ settings: AVCapturePhotoSettings, _ delegate: ShotDelegate) {
            queue.async { [self] in
                guard session.isRunning, !output.connections.isEmpty else { return delegate.finish(nil) }
                output.capturePhoto(with: settings, delegate: delegate)
            }
        }

        /// The camera of [lens] in, the photo output out (the app is portrait only: the shot is upright in portrait).
        private func configure(_ lens: CameraLens) -> Bool {
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: lens.position),
                  let next = try? AVCaptureDeviceInput(device: device) else { return false }
            session.beginConfiguration()
            defer { session.commitConfiguration() }
            session.sessionPreset = .photo
            if let input { session.removeInput(input) }
            guard session.canAddInput(next) else { return false }
            session.addInput(next)
            input = next
            if !session.outputs.contains(output) {
                guard session.canAddOutput(output) else { return false }
                session.addOutput(output)
            }
            if let c = output.connection(with: .video), c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }
            return true
        }
    }
}
