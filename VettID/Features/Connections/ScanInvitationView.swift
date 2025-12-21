import SwiftUI

/// View for scanning and accepting connection invitations
struct ScanInvitationView: View {
    let authTokenProvider: @Sendable () -> String?
    let prefilledCode: String?

    @StateObject private var viewModel: ScanInvitationViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var manualCode = ""
    @State private var showManualEntry = false

    init(authTokenProvider: @escaping @Sendable () -> String?, prefilledCode: String? = nil) {
        self.authTokenProvider = authTokenProvider
        self.prefilledCode = prefilledCode
        self._viewModel = StateObject(wrappedValue: ScanInvitationViewModel(authTokenProvider: authTokenProvider))
    }

    var body: some View {
        NavigationView {
            ZStack {
                switch viewModel.state {
                case .scanning:
                    scanningContent

                case .processing:
                    processingContent

                case .preview(let peerInfo):
                    previewContent(peerInfo)

                case .success(let connection):
                    successContent(connection)

                case .error(let message):
                    errorContent(message)
                }
            }
            .navigationTitle("Scan Invitation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .sheet(isPresented: $showManualEntry) {
            ManualCodeEntryView(code: $manualCode) { code in
                viewModel.onManualCodeEntered(code)
                showManualEntry = false
            }
        }
        .onAppear {
            // Handle prefilled code from deep link
            if let code = prefilledCode {
                viewModel.onManualCodeEntered(code)
            }
        }
    }

    // MARK: - Scanning State

    private var scanningContent: some View {
        ZStack {
            QRCodeScannerView(
                onScan: { viewModel.onQrCodeScanned($0) },
                onError: { _ in }
            )
            .ignoresSafeArea()

            ScanOverlayView()

            VStack {
                Spacer()

                Button(action: { showManualEntry = true }) {
                    Label("Enter Code Manually", systemImage: "keyboard")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding()
                .padding(.bottom, 20)
            }
        }
    }

    // MARK: - Processing State

    private var processingContent: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Processing...")
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Preview State

    private func previewContent(_ peerInfo: PeerInvitationInfo) -> some View {
        VStack(spacing: 24) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 80))
                .foregroundColor(.blue)

            VStack(spacing: 8) {
                Text("Connect with")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Text(peerInfo.creatorDisplayName)
                    .font(.title2)
                    .fontWeight(.bold)
            }

            VStack(spacing: 12) {
                Text("Accept this connection invitation?")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                if let expiresAt = peerInfo.expiresAt {
                    HStack {
                        Image(systemName: "clock")
                        Text("Expires \(expiresAt, style: .relative)")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
            }

            VStack(spacing: 12) {
                Button(action: {
                    Task { await viewModel.acceptInvitation() }
                }) {
                    Label("Accept", systemImage: "checkmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button(action: { viewModel.cancelPreview() }) {
                    Text("Scan Different Code")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal)

            Spacer()
        }
        .padding()
    }

    // MARK: - Success State

    private func successContent(_ connection: Connection) -> some View {
        VStack(spacing: 24) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 80))
                .foregroundColor(.green)

            Text("Connected!")
                .font(.title)
                .fontWeight(.bold)

            VStack(spacing: 8) {
                if let avatarUrl = connection.peerAvatarUrl,
                   let url = URL(string: avatarUrl) {
                    AsyncImage(url: url) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Image(systemName: "person.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .frame(width: 80, height: 80)
                    .clipShape(Circle())
                } else {
                    Image(systemName: "person.circle.fill")
                        .font(.system(size: 80))
                        .foregroundColor(.secondary)
                }

                Text(connection.peerDisplayName)
                    .font(.title2)
                    .fontWeight(.semibold)
            }

            Button(action: { dismiss() }) {
                Text("Done")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal)

            Spacer()
        }
        .padding()
    }

    // MARK: - Error State

    private func errorContent(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 50))
                .foregroundColor(.red)

            Text("Error")
                .font(.headline)

            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button("Try Again") {
                viewModel.reset()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}

// MARK: - Manual Code Entry

struct ManualCodeEntryView: View {
    @Binding var code: String
    let onSubmit: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                Text("Enter the invitation code")
                    .font(.headline)

                TextField("Invitation code", text: $code)
                    .textFieldStyle(.roundedBorder)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)

                Button(action: { onSubmit(code) }) {
                    Text("Submit")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Spacer()
            }
            .padding()
            .navigationTitle("Enter Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

#if DEBUG
struct ScanInvitationView_Previews: PreviewProvider {
    static var previews: some View {
        ScanInvitationView(authTokenProvider: { "test-token" })
    }
}
#endif
