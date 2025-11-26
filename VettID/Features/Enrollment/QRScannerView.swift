import SwiftUI
import AVFoundation

/// Camera view for scanning enrollment QR codes
struct QRScannerView: View {
    @StateObject private var viewModel = QRScannerViewModel()
    @Environment(\.dismiss) private var dismiss

    let onCodeScanned: (String) -> Void

    var body: some View {
        ZStack {
            // Camera preview
            CameraPreviewView(session: viewModel.captureSession)
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
        }
        .navigationTitle("Scan QR Code")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
            }
        }
        .onAppear {
            viewModel.startScanning()
        }
        .onDisappear {
            viewModel.stopScanning()
        }
        .onChange(of: viewModel.scannedCode) { _, newValue in
            if let code = newValue {
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

@MainActor
final class QRScannerViewModel: NSObject, ObservableObject {
    @Published var scannedCode: String?
    @Published var isProcessing = false
    @Published var showPermissionAlert = false

    let captureSession = AVCaptureSession()
    private var metadataOutput = AVCaptureMetadataOutput()

    override init() {
        super.init()
        setupCaptureSession()
    }

    private func setupCaptureSession() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else {
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
    }

    func startScanning() {
        checkCameraPermission()
    }

    private func checkCameraPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startCaptureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.startCaptureSession()
                    } else {
                        self?.showPermissionAlert = true
                    }
                }
            }
        default:
            showPermissionAlert = true
        }
    }

    private func startCaptureSession() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.captureSession.startRunning()
        }
    }

    func stopScanning() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.captureSession.stopRunning()
        }
    }
}

extension QRScannerViewModel: AVCaptureMetadataOutputObjectsDelegate {
    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              object.type == .qr,
              let code = object.stringValue else {
            return
        }

        Task { @MainActor in
            self.isProcessing = true
            self.scannedCode = code
        }
    }
}

// MARK: - Camera Preview

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)

        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)

        context.coordinator.previewLayer = previewLayer

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.previewLayer?.frame = uiView.bounds
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator {
        var previewLayer: AVCaptureVideoPreviewLayer?
    }
}
