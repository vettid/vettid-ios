import SwiftUI

/// View for creating a connection invitation
struct CreateInvitationView: View {
    let authTokenProvider: @Sendable () -> String?

    @StateObject private var viewModel: CreateInvitationViewModel
    @Environment(\.dismiss) private var dismiss

    init(authTokenProvider: @escaping @Sendable () -> String?) {
        self.authTokenProvider = authTokenProvider
        self._viewModel = StateObject(wrappedValue: CreateInvitationViewModel(authTokenProvider: authTokenProvider))
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                switch viewModel.state {
                case .idle:
                    idleContent

                case .creating:
                    creatingContent

                case .created:
                    createdContent

                case .error(let message):
                    errorContent(message)
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Create Invitation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    // MARK: - Idle State

    private var idleContent: some View {
        VStack(spacing: 24) {
            Image(systemName: "person.badge.plus")
                .font(.system(size: 60))
                .foregroundColor(.blue)

            Text("Create an invitation to connect with someone")
                .font(.headline)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 8) {
                Text("Expiration")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Picker("Expiration", selection: $viewModel.expirationMinutes) {
                    ForEach(CreateInvitationViewModel.expirationOptions, id: \.minutes) { option in
                        Text(option.label).tag(option.minutes)
                    }
                }
                .pickerStyle(.segmented)
            }

            Button(action: {
                Task { await viewModel.createInvitation() }
            }) {
                Label("Create Invitation", systemImage: "qrcode")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    // MARK: - Creating State

    private var creatingContent: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Creating invitation...")
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Created State

    private var createdContent: some View {
        VStack(spacing: 20) {
            if let qrData = viewModel.qrCodeData {
                QRCodeView(data: qrData, size: 220)
                    .padding()
                    .background(Color.white)
                    .cornerRadius(16)
                    .shadow(radius: 4)
            }

            Text("Scan this code to connect")
                .font(.headline)

            if let code = viewModel.invitationCode {
                HStack {
                    Text(code)
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.secondary)

                    Button(action: copyCode) {
                        Image(systemName: "doc.on.doc")
                    }
                }
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(8)
            }

            // Expiration timer
            ExpirationTimerView(
                expiresAt: viewModel.timeRemaining().map { Date().addingTimeInterval($0) },
                onExpired: { viewModel.reset() }
            )

            // Share buttons
            HStack(spacing: 16) {
                ShareLink(item: viewModel.deepLinkUrl ?? "") {
                    Label("Share Link", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button(action: { viewModel.reset() }) {
                    Label("New", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
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

            Button("Try Again") {
                viewModel.reset()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Actions

    private func copyCode() {
        if let code = viewModel.invitationCode {
            UIPasteboard.general.string = code
        }
    }
}

// MARK: - Expiration Timer

struct ExpirationTimerView: View {
    let expiresAt: Date?
    let onExpired: () -> Void

    @State private var timeRemaining: TimeInterval = 0
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        if let expiresAt = expiresAt {
            HStack {
                Image(systemName: "clock")
                    .foregroundColor(timeRemaining < 60 ? .red : .secondary)
                Text("Expires in \(formattedTime)")
                    .foregroundColor(timeRemaining < 60 ? .red : .secondary)
            }
            .font(.caption)
            .onReceive(timer) { _ in
                timeRemaining = max(0, expiresAt.timeIntervalSinceNow)
                if timeRemaining <= 0 {
                    onExpired()
                }
            }
            .onAppear {
                timeRemaining = max(0, expiresAt.timeIntervalSinceNow)
            }
        }
    }

    private var formattedTime: String {
        let minutes = Int(timeRemaining) / 60
        let seconds = Int(timeRemaining) % 60
        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        }
        return "\(seconds)s"
    }
}

#if DEBUG
struct CreateInvitationView_Previews: PreviewProvider {
    static var previews: some View {
        CreateInvitationView(authTokenProvider: { "test-token" })
    }
}
#endif
