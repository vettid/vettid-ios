import SwiftUI

/// Unified connection review screen for accepting/declining connections.
/// Shows rich peer profile: photo, name, email, public key, wallet addresses, custom fields.
struct ConnectionReviewView: View {

    let connectionId: String
    var connectionsClient: ConnectionsClient?
    var onResult: ((ConnectionReviewViewModel.Effect) -> Void)?

    @StateObject private var viewModel: ConnectionReviewViewModel
    @Environment(\.dismiss) private var dismiss

    init(connectionId: String, connectionsClient: ConnectionsClient? = nil, onResult: ((ConnectionReviewViewModel.Effect) -> Void)? = nil) {
        self.connectionId = connectionId
        self.connectionsClient = connectionsClient
        self.onResult = onResult
        self._viewModel = StateObject(wrappedValue: ConnectionReviewViewModel(connectionId: connectionId))
    }

    var body: some View {
        Group {
            switch viewModel.state {
            case .loading:
                ProgressView("Loading profile...")
            case .loaded(let profile):
                profileContent(profile)
            case .error(let message):
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.orange)
                    Text(message)
                        .foregroundColor(.secondary)
                    Button("Retry") {
                        Task { await viewModel.loadPeerProfile() }
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .navigationTitle("Connection Request")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            viewModel.connectionsClient = connectionsClient
            await viewModel.loadPeerProfile()
        }
    }

    // MARK: - Profile Content

    private func profileContent(_ profile: PeerProfilePreview) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                // Avatar + Name
                VStack(spacing: 8) {
                    if let photoBase64 = profile.photoBase64,
                       let data = Data(base64Encoded: photoBase64),
                       let uiImage = UIImage(data: data) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 80, height: 80)
                            .clipShape(Circle())
                    } else {
                        Circle()
                            .fill(Color.accentColor.opacity(0.15))
                            .frame(width: 80, height: 80)
                            .overlay(
                                Text(String(profile.displayName.prefix(1)).uppercased())
                                    .font(.title.weight(.bold))
                                    .foregroundColor(.accentColor)
                            )
                    }

                    Text(profile.displayName)
                        .font(.title2.weight(.bold))

                    if let email = profile.email {
                        Text(email)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }

                // Public Key
                if let key = profile.publicKey, !key.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Identity Key")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.secondary)
                        Text(key)
                            .font(.system(.caption2, design: .monospaced))
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .padding(8)
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(6)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                }

                // Wallet Addresses
                if !profile.wallets.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Wallet Addresses")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.secondary)

                        ForEach(profile.wallets) { wallet in
                            HStack {
                                Text(wallet.network.capitalized)
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.orange.opacity(0.15))
                                    .foregroundColor(.orange)
                                    .cornerRadius(4)
                                Text(wallet.truncatedAddress)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(.secondary)
                                Spacer()
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                }

                // Profile Fields
                if let fields = profile.profileFields, !fields.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Profile")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.secondary)

                        ForEach(Array(fields.keys.sorted()), id: \.self) { key in
                            if let field = fields[key] {
                                HStack {
                                    Text(field["display_name"] ?? key)
                                        .font(.subheadline)
                                    Spacer()
                                    Text(field["value"] ?? "")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                }

                Spacer(minLength: 20)

                // Actions
                HStack(spacing: 16) {
                    Button(action: {
                        Task {
                            if let effect = await viewModel.decline() {
                                onResult?(effect)
                                dismiss()
                            }
                        }
                    }) {
                        Text("Decline")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.isProcessing)

                    Button(action: {
                        Task {
                            if let effect = await viewModel.accept() {
                                onResult?(effect)
                                dismiss()
                            }
                        }
                    }) {
                        Text("Accept")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.isProcessing)
                }
                .padding(.horizontal)
                .padding(.bottom, 20)
            }
            .padding(.top, 20)
        }
    }
}
