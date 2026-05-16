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

    /// Phase 1.5: replaced the bespoke avatar/key/wallets/fields stack
    /// with the shared `BusinessCardView`. Same data, same layout,
    /// rendered through the single component used everywhere a peer's
    /// profile shows up.
    private func profileContent(_ profile: PeerProfilePreview) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                BusinessCardView(card: BusinessCardData(from: profile))

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
