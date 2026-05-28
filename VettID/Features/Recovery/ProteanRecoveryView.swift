import SwiftUI

// MARK: - Protean Recovery View

/// Main view for credential recovery with 24-hour delay
struct ProteanRecoveryView: View {
    @StateObject private var service: ProteanRecoveryService
    @Environment(\.dismiss) private var dismiss

    init(authTokenProvider: @escaping @Sendable () -> String?) {
        _service = StateObject(wrappedValue: ProteanRecoveryService(authTokenProvider: authTokenProvider))
    }

    var body: some View {
        NavigationStack {
            Group {
                switch service.state {
                case .idle:
                    RecoveryRequestView(onScanQr: startQrScanning)

                case .authenticating:
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.5)
                        Text("Authenticating with vault...")
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                case .complete:
                    ProteanRecoveryCompleteView(onDone: { dismiss() })

                case .error:
                    ProteanRecoveryErrorView(
                        error: service.error,
                        onRetry: retryAction,
                        onDismiss: { dismiss() }
                    )

                case .scanningQrCode:
                    RecoveryQrScannerView(
                        onCodeScanned: processQrCode,
                        onCancel: cancelQrScanning
                    )

                case .processingQrCode:
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.5)
                        Text("Processing recovery QR code...")
                            .foregroundColor(.secondary)
                        Text("Connecting to vault...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Credential Recovery")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if service.state == .idle || service.state == .error || service.state == .scanningQrCode {
                        Button("Cancel") {
                            if service.state == .scanningQrCode {
                                cancelQrScanning()
                            } else {
                                dismiss()
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func retryAction() {
        service.reset()
    }

    // MARK: - QR Code Actions (Issue #13)

    private func startQrScanning() {
        service.startQrScanning()
    }

    private func cancelQrScanning() {
        service.cancelQrScanning()
    }

    private func processQrCode(_ content: String) {
        Task {
            await service.processRecoveryQrCode(content)
        }
    }
}

// MARK: - Recovery Request View

private struct RecoveryRequestView: View {
    let onScanQr: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Image(systemName: "qrcode.viewfinder")
                    .font(.system(size: 60))
                    .foregroundStyle(.blue)
                    .padding(.top, 40)

                Text("Recover Your Credential")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Scan the recovery QR code from the Account Portal to restore your credential on this device.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                Spacer()

                Button(action: onScanQr) {
                    HStack(spacing: 8) {
                        Image(systemName: "qrcode.viewfinder")
                        Text("Scan Recovery QR Code")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .padding(.horizontal)
                .padding(.bottom, 40)
            }
        }
    }
}

// MARK: - Recovery Complete View

private struct ProteanRecoveryCompleteView: View {
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "party.popper.fill")
                .font(.system(size: 80))
                .foregroundStyle(.orange)
                .padding(.top, 60)

            Text("Recovery Complete!")
                .font(.title)
                .fontWeight(.bold)

            Text("Your credential has been restored. You can now use VettID normally.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            Spacer()

            Button(action: onDone) {
                Text("Done")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(.horizontal)
            .padding(.bottom, 40)
        }
    }
}

// MARK: - Recovery Error View

private struct ProteanRecoveryErrorView: View {
    let error: ProteanRecoveryError?
    let onRetry: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 80))
                .foregroundStyle(.red)
                .padding(.top, 60)

            Text("Recovery Error")
                .font(.title)
                .fontWeight(.bold)

            Text(error?.localizedDescription ?? "An unknown error occurred.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            Spacer()

            VStack(spacing: 12) {
                Button(action: onRetry) {
                    Text("Try Again")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                Button(action: onDismiss) {
                    Text("Cancel")
                        .frame(maxWidth: .infinity)
                        .padding()
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 40)
        }
    }
}

// MARK: - Recovery QR Scanner View (Issue #13)

private struct RecoveryQrScannerView: View {
    let onCodeScanned: (String) -> Void
    let onCancel: () -> Void

    @StateObject private var viewModel = QRScannerViewModel()

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
                VStack(spacing: 8) {
                    Text("Scan Recovery QR Code")
                        .font(.headline)
                        .foregroundStyle(.white)

                    Text("Position the QR code from the Account Portal within the frame")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                }
                .padding()
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)

                Spacer()
                    .frame(height: 60)
            }

            // Close button overlay (top-left)
            VStack {
                HStack {
                    Button {
                        onCancel()
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
                #if DEBUG
                print("[RecoveryQRScanner] Code scanned: \(code.prefix(50))...")
                #endif
                viewModel.stopScanning()
                onCodeScanned(code)
            }
        }
        .alert("Camera Access Required", isPresented: $viewModel.showPermissionAlert) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) {
                onCancel()
            }
        } message: {
            Text("Please enable camera access in Settings to scan recovery QR codes.")
        }
    }
}

// MARK: - Preview

#Preview {
    ProteanRecoveryView(authTokenProvider: { "mock-token" })
}
