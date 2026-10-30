@preconcurrency import AVFoundation
import SwiftUI
import UIKit

/// Whether the camera can be used to read a QR code (IOS-PLAN §8 I1.6, I2.1). iOS asks once; after a refusal only
/// Settings can allow the camera.
public enum CameraAccess: Equatable, Sendable {
    case granted
    /// Not asked yet: the scan screen asks when it opens.
    case notDetermined
    /// Refused: only the app's page in Settings can allow it now.
    case denied
    /// Not allowed on this phone (Screen Time, a device policy), which the member may not be able to change.
    case restricted
    /// No camera this app can use (the simulator, a camera that failed to start).
    case unavailable

    /// What iOS says now.
    public static func current() -> CameraAccess {
        guard QrCamera.device() != nil else { return .unavailable }
        return of(AVCaptureDevice.authorizationStatus(for: .video))
    }

    static func of(_ status: AVAuthorizationStatus) -> CameraAccess {
        switch status {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        case .denied: .denied
        default: .restricted
        }
    }

    /// Asks iOS (the system prompt, once): granted or denied.
    public static func request() async -> CameraAccess {
        await AVCaptureDevice.requestAccess(for: .video) ? .granted : .denied
    }

    /// Whether only a code typed or pasted can be used here (restricted, or no camera).
    public var cannotScan: Bool { self == .restricted || self == .unavailable }
}

/// The camera a QR code is scanned with: the back one, else the front one (an iPad held the other way), else any; nil
/// without one. Mirrors vettid-android `scanCamera`.
enum QrCamera {
    static func device() -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
            ?? AVCaptureDevice.default(for: .video)
    }
}

/// Which decoded texts reach the caller: each new text at once, the same text again only after ``repeatAfter`` while it
/// stays in view (the camera reads a code many times a second). Nothing else is kept.
public struct QrTextGate: Sendable {
    public static let repeatAfter: TimeInterval = 2
    /// Longer texts are no code of VettID's (an invitation's link is at most a few hundred characters): dropped unread.
    public static let maxLength = 4_096

    private var last: (text: String, at: Date)?

    public init() {}

    /// Whether [text], read at [now], goes to the caller.
    public mutating func admit(_ text: String, at now: Date) -> Bool {
        guard !text.isEmpty, text.utf8.count <= Self.maxLength else { return false }
        if let last, last.text == text, now.timeIntervalSince(last.at) < Self.repeatAfter { return false }
        last = (text, now)
        return true
    }
}

/// The camera preview with a QR reader (`AVCaptureSession` with `AVCaptureMetadataOutput` for `.qr` only), for granted
/// camera access. Each decoded text goes to [onText] as ``QrTextGate`` lets it through; the caller decides what it is.
/// Frames are never stored, kept or logged: only the metadata output's decoded text leaves the session. The session
/// starts when the view appears and stops when it goes (``dismantleUIView(_:coordinator:)``); iOS interrupts it in the
/// background. [onUnavailable]: the camera could not be started. Mirrors vettid-android core/ui `QrScanner`'s preview.
public struct QrScannerView: UIViewRepresentable {
    let onText: @MainActor (String) -> Void
    let onUnavailable: @MainActor () -> Void

    public init(onText: @escaping @MainActor (String) -> Void, onUnavailable: @escaping @MainActor () -> Void = {}) {
        self.onText = onText
        self.onUnavailable = onUnavailable
    }

    public func makeCoordinator() -> Coordinator { Coordinator(onText: onText, onUnavailable: onUnavailable) }

    public func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.videoGravity = .resizeAspectFill
        context.coordinator.attach(to: view)
        return view
    }

    public func updateUIView(_ view: PreviewView, context: Context) {
        context.coordinator.onText = onText
        context.coordinator.onUnavailable = onUnavailable
    }

    public static func dismantleUIView(_ view: PreviewView, coordinator: Coordinator) { coordinator.stop() }

    /// A view whose layer is the camera preview.
    public final class PreviewView: UIView {
        override public static var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

        // The layer class above makes this cast hold.
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer } // swiftlint:disable:this force_cast
    }

    /// Owns the capture session; the metadata arrives on the main queue.
    @MainActor
    public final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        var onText: @MainActor (String) -> Void
        var onUnavailable: @MainActor () -> Void
        private let capture = Capture()
        private var gate = QrTextGate()

        init(onText: @escaping @MainActor (String) -> Void, onUnavailable: @escaping @MainActor () -> Void) {
            self.onText = onText
            self.onUnavailable = onUnavailable
        }

        /// Shows the session in [view] (on the main thread) and configures and starts it on the capture queue.
        func attach(to view: PreviewView) {
            view.previewLayer.session = capture.session
            capture.start(delegate: self) { [weak self] in
                Task { @MainActor in self?.onUnavailable() }
            }
        }

        func stop() { capture.stop() }

        public nonisolated func metadataOutput(
            _ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection
        ) {
            let texts = objects.compactMap { ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }
            // The delegate queue is the main queue (Capture.configure).
            MainActor.assumeIsolated {
                for text in texts where gate.admit(text, at: Date()) { onText(text) }
            }
        }
    }

    /// The session, configured, started and stopped off the main thread (these calls block), one after the other on its
    /// own queue, which alone touches the session after it is made.
    final class Capture: @unchecked Sendable {
        let session = AVCaptureSession()
        private let queue = DispatchQueue(label: "org.vettid.ui.qr-capture")
        private var configured = false
        private var usable = false

        /// Configures the session once (the camera in, QR codes out to [delegate] on the main queue) and starts it;
        /// [onFailure] when there is no camera input or QR output to use.
        func start(delegate: any AVCaptureMetadataOutputObjectsDelegate & Sendable, onFailure: @escaping @Sendable () -> Void) {
            queue.async { [self] in
                if !configured {
                    configured = true
                    usable = configure(delegate: delegate)
                }
                guard usable else { return onFailure() }
                if !session.isRunning { session.startRunning() }
            }
        }

        func stop() { queue.async { [self] in if session.isRunning { session.stopRunning() } } }

        private func configure(delegate: any AVCaptureMetadataOutputObjectsDelegate & Sendable) -> Bool {
            guard let device = QrCamera.device(), let input = try? AVCaptureDeviceInput(device: device) else { return false }
            session.beginConfiguration()
            defer { session.commitConfiguration() }
            guard session.canAddInput(input) else { return false }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return false }
            session.addOutput(output)
            guard output.availableMetadataObjectTypes.contains(.qr) else { return false }
            output.setMetadataObjectsDelegate(delegate, queue: .main)
            output.metadataObjectTypes = [.qr]
            return true
        }
    }
}

/// The scanner for granted camera access, in its ``ScannerFrame`` read as [label]: the preview, or, on a phone without a
/// camera this app can use (or one that fails to start), the note that says to type or paste the code instead. Mirrors
/// vettid-android `QrScanner`.
public struct QrScanner: View {
    let label: String
    let onText: @MainActor (String) -> Void
    /// Whether there is no camera to use; nil until the view appears and asks iOS (once, not at every redraw).
    @State private var failed: Bool?

    /// [access]: the camera access to start from (tests force one; by default what iOS says when the view appears).
    public init(label: String, onText: @escaping @MainActor (String) -> Void, access: CameraAccess? = nil) {
        self.label = label
        self.onText = onText
        _failed = State(initialValue: access.map { $0 == .unavailable })
    }

    public var body: some View {
        switch failed {
        case nil:
            ScannerFrame(label: label) { Color.clear }
                .onAppear { failed = CameraAccess.current() == .unavailable }
        case true?:
            ScannerFrame(label: nil) { ScannerNoCameraNote() }
        case false?:
            ScannerFrame(label: label) { QrScannerView(onText: onText) { failed = true } }
        }
    }
}

/// In place of the preview, when there is no camera this app can use: spoken as it appears. vettid-android's
/// `core_ui_scanner_no_camera`.
public struct ScannerNoCameraNote: View {
    @Environment(\.vettIDColors) private var colors

    public init() {}

    public var body: some View {
        Text(UIStrings.scannerNoCamera)
            .vettIDFont(.bodyMedium)
            .foregroundStyle(colors.onSurfaceVariant)
            .multilineTextAlignment(.center)
            .padding(Spacing.l)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("scanner_no_camera")
            // Appears by itself where the preview would be: spoken (vettid-android's polite live region).
            .announcedOnce(UIStrings.scannerNoCamera)
    }
}

/// The scanner's place on a scan screen: [content] (the camera, or what stands in for it) in a gold-bordered card, 320
/// points high. With [label], read as one element of that name (the camera preview); without, what is inside is read
/// (the note that stands in for the camera). Mirrors vettid-android's scan boxes.
public struct ScannerFrame<Content: View>: View {
    @Environment(\.vettIDColors) private var colors
    let label: String?
    let content: Content

    public static var height: CGFloat { 320 }

    public init(label: String?, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    public var body: some View {
        let framed = content
            .frame(maxWidth: .infinity)
            .frame(height: Self.height)
            .clipShape(VettIDShape.card)
            .padding(2)
            .overlay(VettIDShape.card.stroke(colors.primary, lineWidth: 2))
        if let label {
            framed.accessibilityElement().accessibilityLabel(label).accessibilityIdentifier("scanner")
        } else {
            framed.accessibilityElement(children: .contain).accessibilityIdentifier("scanner")
        }
    }
}
