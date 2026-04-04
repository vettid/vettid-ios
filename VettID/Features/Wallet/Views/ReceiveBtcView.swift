import SwiftUI

struct ReceiveBtcView: View {

    let wallet: WalletInfo
    var walletClient: WalletClient?

    @StateObject private var viewModel = ReceiveBtcViewModel()
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Text(viewModel.walletLabel)
                .font(.headline)

            // QR Code
            if !viewModel.address.isEmpty {
                QRCodeView(data: viewModel.address, size: 240)
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color(.systemBackground))
                            .shadow(color: .black.opacity(0.1), radius: 8, y: 2)
                    )
            } else if viewModel.isLoading {
                ProgressView()
                    .frame(width: 240, height: 240)
            } else if let error = viewModel.errorMessage {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Button("Retry") {
                        Task { await viewModel.loadAddress(wallet: wallet) }
                    }
                    .buttonStyle(.bordered)
                }
                .frame(width: 240, height: 240)
            }

            // Address
            if !viewModel.address.isEmpty {
                Text(viewModel.address)
                    .font(.system(.caption, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(.secondarySystemBackground))
                    )
                    .padding(.horizontal)
            }

            // Actions
            HStack(spacing: 16) {
                Button(action: copyAddress) {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                ShareLink(item: viewModel.address) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal)

            Spacer()
        }
        .navigationTitle("Receive Bitcoin")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }
        .task {
            viewModel.walletClient = walletClient
            await viewModel.loadAddress(wallet: wallet)
        }
    }

    private func copyAddress() {
        SecurePasteboard.copySecure(viewModel.address, expiresIn: 30)
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            copied = false
        }
    }
}
