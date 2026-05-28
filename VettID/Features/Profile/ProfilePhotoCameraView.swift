import SwiftUI
import AVFoundation
import UIKit

// MARK: - Profile Photo Camera (Android-parity)

/// Custom AVFoundation camera matching the Android ProfilePhotoCapture
/// composable: front-camera-only, mirrored live preview, circular
/// framing guide, capture → preview → Retake / Use Photo. Replaces
/// `UIImagePickerController` because the system picker's editing
/// flow shows the un-mirrored frame during cropping, which threw
/// users off.
struct ProfilePhotoCameraView: View {
    let onImageCaptured: (UIImage) -> Void
    let onCancel: () -> Void

    @StateObject private var session = CameraSession()
    @State private var capturedImage: UIImage?
    @State private var permissionDenied = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if permissionDenied {
                permissionView
            } else if let image = capturedImage {
                previewMode(image: image)
            } else {
                captureMode
            }
        }
        .onAppear {
            Task {
                let granted = await session.requestPermission()
                if granted {
                    session.start()
                } else {
                    permissionDenied = true
                }
            }
        }
        .onDisappear {
            session.stop()
        }
    }

    // MARK: - Capture Mode (live preview)

    private var captureMode: some View {
        VStack(spacing: 0) {
            // Top bar: cancel
            HStack {
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .padding(12)
                        .background(Circle().fill(Color.black.opacity(0.4)))
                }
                .padding(.leading, 16)
                .padding(.top, 8)
                Spacer()
            }

            // Live preview with circular framing guide overlay
            ZStack {
                LivePreviewView(session: session)
                    .aspectRatio(3.0/4.0, contentMode: .fit)
                    .clipped()

                CircleFramingOverlay()

                VStack {
                    Text("Position your face in the circle")
                        .font(.subheadline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.black.opacity(0.5)))
                        .padding(.top, 24)
                    Spacer()
                }
            }
            .frame(maxWidth: .infinity)

            Spacer()

            // Capture button
            Button {
                session.capture { image in
                    if let image = image {
                        capturedImage = image
                    }
                }
            } label: {
                ZStack {
                    Circle()
                        .stroke(Color.white, lineWidth: 4)
                        .frame(width: 78, height: 78)
                    Circle()
                        .fill(Color.white)
                        .frame(width: 64, height: 64)
                }
            }
            .padding(.bottom, 32)
        }
    }

    // MARK: - Preview Mode (after capture)

    private func previewMode(image: UIImage) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("Preview")
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)

            Spacer()

            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 280, height: 280)
                .clipShape(Circle())

            Spacer()

            HStack(spacing: 16) {
                Button {
                    capturedImage = nil
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.counterclockwise")
                        Text("Retake")
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                }
                .buttonStyle(.bordered)
                .tint(.white)

                Button {
                    onImageCaptured(image)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark")
                        Text("Use Photo")
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
    }

    // MARK: - Permission Denied View

    private var permissionView: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.fill")
                .font(.system(size: 64))
                .foregroundStyle(.white.opacity(0.7))
            Text("Camera Permission Required")
                .font(.headline)
                .foregroundStyle(.white)
            Text("Enable camera access in Settings to take a profile photo.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Close") { onCancel() }
                .buttonStyle(.borderedProminent)
                .padding(.top, 16)
        }
    }
}

// MARK: - Live Preview Layer Wrapper

/// Hosts `AVCaptureVideoPreviewLayer` in SwiftUI. The connection is
/// mirrored so the user sees themselves the way a mirror would show
/// them (Android `PreviewView` does this for front cameras by default).
private struct LivePreviewView: UIViewRepresentable {
    let session: CameraSession

    func makeUIView(context: Context) -> PreviewContainerView {
        let view = PreviewContainerView()
        view.backgroundColor = .black
        view.previewLayer.session = session.captureSession
        view.previewLayer.videoGravity = .resizeAspectFill
        if let connection = view.previewLayer.connection {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
        return view
    }

    func updateUIView(_ uiView: PreviewContainerView, context: Context) {}

    final class PreviewContainerView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }
    }
}

// MARK: - Circle Framing Overlay

/// Dimmed mask with a circular cutout that shows the user where to
/// position their face. Matches Android `CameraOverlay`.
private struct CircleFramingOverlay: View {
    var body: some View {
        GeometryReader { geo in
            let diameter = min(geo.size.width, geo.size.height) * 0.75
            ZStack {
                Color.black.opacity(0.35)
                    .mask(
                        Rectangle()
                            .overlay(
                                Circle()
                                    .frame(width: diameter, height: diameter)
                                    .blendMode(.destinationOut)
                            )
                            .compositingGroup()
                    )

                Circle()
                    .stroke(Color.white.opacity(0.9), lineWidth: 2)
                    .frame(width: diameter, height: diameter)
            }
        }
    }
}

// MARK: - Camera Session

/// Owns the `AVCaptureSession`, performs front-camera capture, and
/// mirrors the captured frame to match the live preview the user saw.
/// `AVCapturePhotoOutput` returns un-mirrored frames from the front
/// camera, so we have to flip them ourselves — same step Android's
/// `processAndCompressPhoto` does with `matrix.postScale(-1f, 1f)`.
@MainActor
final class CameraSession: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {
    let captureSession = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "vettid.profile-photo.session")
    private var captureCompletion: ((UIImage?) -> Void)?
    private var isConfigured = false

    func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    func start() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            if !self.isConfigured {
                self.configureSession()
                self.isConfigured = true
            }
            if !self.captureSession.isRunning {
                self.captureSession.startRunning()
            }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            if self.captureSession.isRunning {
                self.captureSession.stopRunning()
            }
        }
    }

    private func configureSession() {
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }

        captureSession.sessionPreset = .photo

        guard
            let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
            let input = try? AVCaptureDeviceInput(device: device),
            captureSession.canAddInput(input)
        else {
            return
        }
        captureSession.addInput(input)

        guard captureSession.canAddOutput(photoOutput) else { return }
        captureSession.addOutput(photoOutput)
    }

    func capture(completion: @escaping (UIImage?) -> Void) {
        captureCompletion = completion
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            let settings = AVCapturePhotoSettings()
            settings.flashMode = .off
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    nonisolated func photoOutput(_ output: AVCapturePhotoOutput,
                                  didFinishProcessingPhoto photo: AVCapturePhoto,
                                  error: Error?) {
        let processed: UIImage? = {
            guard error == nil,
                  let data = photo.fileDataRepresentation(),
                  let image = UIImage(data: data) else {
                return nil
            }
            return ProfilePhotoHelper.horizontallyMirrored(image)
        }()
        Task { @MainActor in
            self.captureCompletion?(processed)
            self.captureCompletion = nil
        }
    }
}
