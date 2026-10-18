#if os(iOS)
@preconcurrency import AVFoundation
import SwiftUI
import UIKit

/// A minimal QR reader (the camera preview with `AVCaptureMetadataOutput` for `.qr`), for the setup code until the
/// shared scanner of IOS-PLAN I2.1 replaces it. Each code's text goes to [onText], the same text at most once every
/// two seconds while it stays in view. Nothing is recorded or kept, and nothing is logged. Mirrors the use of
/// vettid-android core/ui `QrScanner` by `ScannerBox`. Shown only once camera access is granted.
struct QrScannerView: UIViewRepresentable {
    let onText: @MainActor (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onText: onText) }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.videoGravity = .resizeAspectFill
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) { context.coordinator.onText = onText }

    static func dismantleUIView(_ view: PreviewView, coordinator: Coordinator) { coordinator.stop() }

    /// A view whose layer is the camera preview.
    final class PreviewView: UIView {
        override static var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

        // The layer class above makes this cast hold.
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer } // swiftlint:disable:this force_cast
    }

    /// Owns the capture session; the metadata arrives on the main queue.
    @MainActor
    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        var onText: @MainActor (String) -> Void
        private let capture = Capture()
        private var last: (text: String, at: Date)?
        private static let repeatAfter: TimeInterval = 2

        init(onText: @escaping @MainActor (String) -> Void) { self.onText = onText }

        /// Shows the session in [view] (on the main thread) and configures and starts it on the capture queue.
        func attach(to view: PreviewView) {
            view.previewLayer.session = capture.session
            capture.start(delegate: self)
        }

        func stop() { capture.stop() }

        nonisolated func metadataOutput(
            _ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection
        ) {
            let texts = objects.compactMap { ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }
            // The delegate queue is the main queue (attach(to:)).
            MainActor.assumeIsolated {
                for text in texts { deliver(text) }
            }
        }

        private func deliver(_ text: String) {
            let now = Date()
            if let last, last.text == text, now.timeIntervalSince(last.at) < Self.repeatAfter { return }
            last = (text, now)
            onText(text)
        }
    }

    /// The session, configured, started and stopped off the main thread (these calls block), one after the other on
    /// its own queue, which alone touches the session after it is made.
    final class Capture: @unchecked Sendable {
        let session = AVCaptureSession()
        private let queue = DispatchQueue(label: "org.vettid.onboarding.capture")
        private var configured = false

        /// Configures the session once (the camera in, QR codes out to [delegate] on the main queue) and starts it.
        func start(delegate: any AVCaptureMetadataOutputObjectsDelegate & Sendable) {
            queue.async { [self] in
                if !configured {
                    configured = true
                    configure(delegate: delegate)
                }
                if !session.isRunning && !session.inputs.isEmpty { session.startRunning() }
            }
        }

        func stop() { queue.async { [self] in if session.isRunning { session.stopRunning() } } }

        private func configure(delegate: any AVCaptureMetadataOutputObjectsDelegate & Sendable) {
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device)
            else { return }
            session.beginConfiguration()
            defer { session.commitConfiguration() }
            guard session.canAddInput(input) else { return }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(delegate, queue: .main)
            if output.availableMetadataObjectTypes.contains(.qr) { output.metadataObjectTypes = [.qr] }
        }
    }
}
#endif
