import SwiftUI
import AVFoundation

/// Delegate protocol for QR code scanner
protocol QRCodeScannerDelegate: AnyObject {
    func didScanCode(_ code: String)
    func didFailWithError(_ error: Error)
}

/// UIViewController for camera-based QR code scanning
class QRCodeScannerViewController: UIViewController {

    weak var delegate: QRCodeScannerDelegate?

    private var captureSession: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var hasScanned = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupCaptureSession()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        hasScanned = false
        startScanning()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopScanning()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    private func setupCaptureSession() {
        let session = AVCaptureSession()
        captureSession = session

        guard let videoCaptureDevice = AVCaptureDevice.default(for: .video) else {
            delegate?.didFailWithError(ScannerError.noCameraAvailable)
            return
        }

        do {
            let videoInput = try AVCaptureDeviceInput(device: videoCaptureDevice)
            if session.canAddInput(videoInput) {
                session.addInput(videoInput)
            } else {
                delegate?.didFailWithError(ScannerError.inputNotSupported)
                return
            }
        } catch {
            delegate?.didFailWithError(error)
            return
        }

        let metadataOutput = AVCaptureMetadataOutput()
        if session.canAddOutput(metadataOutput) {
            session.addOutput(metadataOutput)
            metadataOutput.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
            metadataOutput.metadataObjectTypes = [.qr]
        } else {
            delegate?.didFailWithError(ScannerError.outputNotSupported)
            return
        }

        // Setup preview layer
        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.frame = view.bounds
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)
        self.previewLayer = previewLayer
    }

    func startScanning() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.captureSession?.startRunning()
        }
    }

    func stopScanning() {
        captureSession?.stopRunning()
    }

    func resetScanning() {
        hasScanned = false
    }
}

// MARK: - AVCaptureMetadataOutputObjectsDelegate

extension QRCodeScannerViewController: AVCaptureMetadataOutputObjectsDelegate {
    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !hasScanned else { return }

        if let metadataObject = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
           metadataObject.type == .qr,
           let stringValue = metadataObject.stringValue {
            hasScanned = true
            AudioServicesPlaySystemSound(SystemSoundID(kSystemSoundID_Vibrate))
            delegate?.didScanCode(stringValue)
        }
    }
}

// MARK: - Scanner Errors

enum ScannerError: Error, LocalizedError {
    case noCameraAvailable
    case inputNotSupported
    case outputNotSupported
    case cameraPermissionDenied

    var errorDescription: String? {
        switch self {
        case .noCameraAvailable:
            return "No camera available on this device"
        case .inputNotSupported:
            return "Camera input is not supported"
        case .outputNotSupported:
            return "Metadata output is not supported"
        case .cameraPermissionDenied:
            return "Camera permission was denied"
        }
    }
}

// MARK: - SwiftUI Wrapper

/// SwiftUI wrapper for the QR code scanner
struct QRCodeScannerView: UIViewControllerRepresentable {
    let onScan: (String) -> Void
    let onError: ((Error) -> Void)?

    init(onScan: @escaping (String) -> Void, onError: ((Error) -> Void)? = nil) {
        self.onScan = onScan
        self.onError = onError
    }

    func makeUIViewController(context: Context) -> QRCodeScannerViewController {
        let controller = QRCodeScannerViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: QRCodeScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onScan: onScan, onError: onError)
    }

    class Coordinator: NSObject, QRCodeScannerDelegate {
        let onScan: (String) -> Void
        let onError: ((Error) -> Void)?

        init(onScan: @escaping (String) -> Void, onError: ((Error) -> Void)?) {
            self.onScan = onScan
            self.onError = onError
        }

        func didScanCode(_ code: String) {
            onScan(code)
        }

        func didFailWithError(_ error: Error) {
            onError?(error)
        }
    }
}

// MARK: - Scan Overlay View

/// Overlay for the QR scanner showing scan area
struct ScanOverlayView: View {
    @State private var isAnimating = false

    var body: some View {
        GeometryReader { geometry in
            let scanSize = min(geometry.size.width, geometry.size.height) * 0.7

            ZStack {
                // Dimmed background
                Color.black.opacity(0.5)
                    .ignoresSafeArea()

                // Clear scan area
                RoundedRectangle(cornerRadius: 12)
                    .frame(width: scanSize, height: scanSize)
                    .blendMode(.destinationOut)

                // Corner markers
                ScanCorners(size: scanSize)

                // Scan line animation
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [.clear, .blue.opacity(0.5), .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: scanSize - 20, height: 4)
                    .offset(y: isAnimating ? scanSize / 2 - 20 : -scanSize / 2 + 20)
                    .animation(
                        .easeInOut(duration: 2.0).repeatForever(autoreverses: true),
                        value: isAnimating
                    )

                // Instructions
                VStack {
                    Spacer()
                    Text("Point camera at QR code")
                        .font(.subheadline)
                        .foregroundColor(.white)
                        .padding()
                        .background(Color.black.opacity(0.6))
                        .cornerRadius(8)
                        .padding(.bottom, 50)
                }
            }
            .compositingGroup()
            .onAppear {
                isAnimating = true
            }
        }
    }
}

/// Corner markers for scan area
struct ScanCorners: View {
    let size: CGFloat
    private let cornerLength: CGFloat = 30
    private let lineWidth: CGFloat = 4

    var body: some View {
        ZStack {
            // Top-left corner
            CornerShape(rotation: 0)
                .offset(x: -size / 2 + cornerLength / 2, y: -size / 2 + cornerLength / 2)

            // Top-right corner
            CornerShape(rotation: 90)
                .offset(x: size / 2 - cornerLength / 2, y: -size / 2 + cornerLength / 2)

            // Bottom-left corner
            CornerShape(rotation: 270)
                .offset(x: -size / 2 + cornerLength / 2, y: size / 2 - cornerLength / 2)

            // Bottom-right corner
            CornerShape(rotation: 180)
                .offset(x: size / 2 - cornerLength / 2, y: size / 2 - cornerLength / 2)
        }
    }

    struct CornerShape: View {
        let rotation: Double

        var body: some View {
            Path { path in
                path.move(to: CGPoint(x: 0, y: 20))
                path.addLine(to: CGPoint(x: 0, y: 0))
                path.addLine(to: CGPoint(x: 20, y: 0))
            }
            .stroke(Color.blue, lineWidth: 4)
            .rotationEffect(.degrees(rotation))
        }
    }
}

#if DEBUG
struct QRCodeScannerView_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            Color.gray
            ScanOverlayView()
        }
    }
}
#endif
