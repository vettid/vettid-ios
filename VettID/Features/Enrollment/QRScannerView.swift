import SwiftUI
import AVFoundation

/// Camera view for scanning enrollment QR codes
struct QRScannerView: View {
    @StateObject private var viewModel = QRScannerViewModel()
    @Environment(\.dismiss) private var dismiss

    let onCodeScanned: (String) -> Void

    var body: some View {
        ZStack {
            // Camera preview - use Color.black as background
            Color.black
                .ignoresSafeArea()

            // Camera preview layer
            CameraPreviewView(viewModel: viewModel)
                .ignoresSafeArea()

            // Overlay
            VStack {
                Spacer()

                // Scan frame
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.white, lineWidth: 3)
                    .frame(width: 250, height: 250)
                    .overlay {
                        if viewModel.isProcessing {
                            ProgressView()
                                .tint(.white)
                        }
                    }

                Spacer()

                // Instructions
                Text("Position the QR code within the frame")
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .padding()
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))

                Spacer()
                    .frame(height: 60)
            }

            // Close button overlay (top-left)
            VStack {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .padding()
                    Spacer()
                }
                Spacer()
            }
        }
        .navigationBarHidden(true)
        .onAppear {
            viewModel.startScanning()
        }
        .onDisappear {
            viewModel.stopScanning()
        }
        .onReceive(viewModel.$scannedCode) { newValue in
            if let code = newValue {
                print("[QRScanner] Code scanned: \(code.prefix(50))...")
                onCodeScanned(code)
                dismiss()
            }
        }
        .alert("Camera Access Required", isPresented: $viewModel.showPermissionAlert) {
            Button("Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) {
                dismiss()
            }
        } message: {
            Text("Please enable camera access in Settings to scan QR codes.")
        }
    }
}

// MARK: - View Model

final class QRScannerViewModel: NSObject, ObservableObject {
    @Published var scannedCode: String?
    @Published var isProcessing = false
    @Published var showPermissionAlert = false
    @Published var isSessionRunning = false

    let captureSession = AVCaptureSession()
    private var metadataOutput = AVCaptureMetadataOutput()
    private var isConfigured = false

    override init() {
        super.init()
    }

    func setupCaptureSession() {
        guard !isConfigured else { return }

        captureSession.beginConfiguration()

        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else {
            captureSession.commitConfiguration()
            return
        }

        if captureSession.canAddInput(input) {
            captureSession.addInput(input)
        }

        if captureSession.canAddOutput(metadataOutput) {
            captureSession.addOutput(metadataOutput)
            metadataOutput.setMetadataObjectsDelegate(self, queue: .main)
            metadataOutput.metadataObjectTypes = [.qr]
        }

        captureSession.commitConfiguration()
        isConfigured = true
    }

    func startScanning() {
        checkCameraPermission()
    }

    private func checkCameraPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setupAndStartSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.setupAndStartSession()
                    } else {
                        self?.showPermissionAlert = true
                    }
                }
            }
        default:
            DispatchQueue.main.async {
                self.showPermissionAlert = true
            }
        }
    }

    private func setupAndStartSession() {
        setupCaptureSession()
        startCaptureSession()
    }

    private func startCaptureSession() {
        guard !captureSession.isRunning else { return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            self.captureSession.startRunning()
            DispatchQueue.main.async {
                self.isSessionRunning = self.captureSession.isRunning
            }
        }
    }

    func stopScanning() {
        guard captureSession.isRunning else { return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            self.captureSession.stopRunning()
            DispatchQueue.main.async {
                self.isSessionRunning = false
            }
        }
    }
}

extension QRScannerViewModel: AVCaptureMetadataOutputObjectsDelegate {
    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              object.type == .qr,
              let code = object.stringValue else {
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.isProcessing = true
            self?.scannedCode = code
        }
    }
}

// MARK: - Camera Preview

struct CameraPreviewView: UIViewRepresentable {
    @ObservedObject var viewModel: QRScannerViewModel

    func makeUIView(context: Context) -> CameraPreviewUIView {
        let view = CameraPreviewUIView()
        view.session = viewModel.captureSession
        return view
    }

    func updateUIView(_ uiView: CameraPreviewUIView, context: Context) {
        uiView.updateSession(viewModel.captureSession)
    }
}

/// UIView subclass that properly handles AVCaptureVideoPreviewLayer
final class CameraPreviewUIView: UIView {
    var session: AVCaptureSession? {
        didSet {
            updatePreviewLayer()
        }
    }

    private var previewLayer: AVCaptureVideoPreviewLayer?

    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateSession(_ session: AVCaptureSession) {
        if let previewLayer = layer as? AVCaptureVideoPreviewLayer {
            previewLayer.session = session
            previewLayer.videoGravity = .resizeAspectFill
        }
    }

    private func updatePreviewLayer() {
        if let previewLayer = layer as? AVCaptureVideoPreviewLayer {
            previewLayer.session = session
            previewLayer.videoGravity = .resizeAspectFill
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let previewLayer = layer as? AVCaptureVideoPreviewLayer {
            previewLayer.frame = bounds
        }
    }
}
