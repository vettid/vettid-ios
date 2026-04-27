import Foundation
import SwiftUI

// MARK: - Pairing State

enum DevicePairingState: Equatable {
    case idle
    case creating
    case showingCode(code: String, remainingSeconds: Int)
    case waitingApproval
    case approved(deviceName: String)
    case denied(message: String)
    case timeout
    case error(message: String)

    static func == (lhs: DevicePairingState, rhs: DevicePairingState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.creating, .creating),
             (.waitingApproval, .waitingApproval), (.timeout, .timeout):
            return true
        case (.showingCode(let a, let b), .showingCode(let c, let d)):
            return a == c && b == d
        case (.approved(let a), .approved(let b)):
            return a == b
        case (.denied(let a), .denied(let b)), (.error(let a), .error(let b)):
            return a == b
        default:
            return false
        }
    }
}

// MARK: - Pairing Response Models

struct CreateDeviceInviteResponse: Codable {
    let connectionId: String
    let invitationId: String
    let inviteToken: String
    let vaultPublicKey: String
    let messagespaceUri: String
    let ownerGuid: String

    enum CodingKeys: String, CodingKey {
        case connectionId = "connection_id"
        case invitationId = "invitation_id"
        case inviteToken = "invite_token"
        case vaultPublicKey = "vault_public_key"
        case messagespaceUri = "messagespace_uri"
        case ownerGuid = "owner_guid"
    }
}

struct ShortlinkResponse: Codable {
    let code: String
    let expiresAt: String?

    enum CodingKeys: String, CodingKey {
        case code
        case expiresAt = "expires_at"
    }
}

// MARK: - Pairing ViewModel

@MainActor
final class DevicePairingViewModel: ObservableObject {
    @Published private(set) var state: DevicePairingState = .idle

    private let ownerSpaceClient: OwnerSpaceClient
    private var pairingTask: Task<Void, Never>?
    private var countdownTask: Task<Void, Never>?
    private let pairingTimeoutSeconds = 300 // 5 minutes

    init(ownerSpaceClient: OwnerSpaceClient) {
        self.ownerSpaceClient = ownerSpaceClient
    }

    deinit {
        pairingTask?.cancel()
        countdownTask?.cancel()
    }

    func startPairing() {
        pairingTask?.cancel()
        pairingTask = Task { [weak self] in
            guard let self = self else { return }

            self.state = .creating

            do {
                // Step 1: Create device invitation via NATS
                let inviteResponse: CreateDeviceInviteResponse = try await ownerSpaceClient.request(
                    EmptyPayload(),
                    topic: "connection.device.create-invite",
                    responseType: CreateDeviceInviteResponse.self,
                    timeout: 15
                )

                // Step 2: Create shortlink via API
                let shortlinkResponse = try await createShortlink(
                    invitationId: inviteResponse.invitationId,
                    inviteToken: inviteResponse.inviteToken,
                    vaultPublicKey: inviteResponse.vaultPublicKey,
                    messagespaceUri: inviteResponse.messagespaceUri,
                    ownerGuid: inviteResponse.ownerGuid
                )

                // Step 3: Show code with countdown
                self.state = .showingCode(code: shortlinkResponse.code, remainingSeconds: pairingTimeoutSeconds)
                self.startCountdown()

                // Step 4: Wait for device connection event
                let connectionEvent = try await ownerSpaceClient.waitForEvent(
                    topic: "device.connection.request",
                    timeout: TimeInterval(pairingTimeoutSeconds)
                )

                if let event = connectionEvent {
                    self.countdownTask?.cancel()
                    self.state = .waitingApproval
                    self.state = .approved(deviceName: event.hostname ?? "Desktop")
                } else {
                    self.state = .timeout
                }
            } catch is CancellationError {
                // Cancelled - don't update state
            } catch {
                self.state = .error(message: error.localizedDescription)
            }
        }
    }

    func cancel() {
        pairingTask?.cancel()
        countdownTask?.cancel()
        state = .idle
    }

    private func startCountdown() {
        countdownTask?.cancel()
        countdownTask = Task { [weak self] in
            guard let self = self else { return }
            var remaining = pairingTimeoutSeconds
            while remaining > 0 && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                remaining -= 1
                if case .showingCode(let code, _) = self.state {
                    self.state = .showingCode(code: code, remainingSeconds: remaining)
                }
            }
            if case .showingCode = self.state {
                self.state = .timeout
            }
        }
    }

    private func createShortlink(
        invitationId: String,
        inviteToken: String,
        vaultPublicKey: String,
        messagespaceUri: String,
        ownerGuid: String
    ) async throws -> ShortlinkResponse {
        // POST to API to create shortlink
        let url = URL(string: "https://api.vettid.dev/vault/agent/shortlink")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "invitation_id": invitationId,
            "invite_token": inviteToken,
            "vault_public_key": vaultPublicKey,
            "messagespace_uri": messagespaceUri,
            "owner_guid": ownerGuid,
            "connection_type": "device"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(ShortlinkResponse.self, from: data)
    }
}

// MARK: - Device Pairing View

struct DevicePairingView: View {
    let ownerSpaceClient: OwnerSpaceClient
    @StateObject private var viewModel: DevicePairingViewModel
    @Environment(\.dismiss) private var dismiss

    init(ownerSpaceClient: OwnerSpaceClient) {
        self.ownerSpaceClient = ownerSpaceClient
        self._viewModel = StateObject(wrappedValue: DevicePairingViewModel(
            ownerSpaceClient: ownerSpaceClient
        ))
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            switch viewModel.state {
            case .idle:
                idleView
            case .creating:
                creatingView
            case .showingCode(let code, let remaining):
                codeView(code: code, remaining: remaining)
            case .waitingApproval:
                waitingView
            case .approved(let name):
                approvedView(name: name)
            case .denied(let message):
                deniedView(message: message)
            case .timeout:
                timeoutView
            case .error(let message):
                errorView(message: message)
            }

            Spacer()
        }
        .padding(24)
        .navigationTitle("Pair Desktop")
    }

    private var idleView: some View {
        VStack(spacing: 16) {
            Image(systemName: "desktopcomputer.and.arrow.down")
                .font(.system(size: 60)).foregroundColor(.accentColor)
            Text("Pair a Desktop")
                .font(.title2).fontWeight(.semibold)
            Text("Generate a code to enter on your desktop app.")
                .font(.subheadline).foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button("Generate Code") { viewModel.startPairing() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
    }

    private var creatingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Creating pairing invitation...")
                .foregroundColor(.secondary)
        }
    }

    private func codeView(code: String, remaining: Int) -> some View {
        VStack(spacing: 20) {
            Text("Enter this code on your desktop")
                .font(.headline).foregroundColor(.secondary)

            Text(code)
                .font(.system(size: 44, weight: .bold, design: .monospaced))
                .tracking(8)
                .padding(.horizontal, 32).padding(.vertical, 20)
                .background(Color.accentColor.opacity(0.1))
                .cornerRadius(12)

            HStack {
                Image(systemName: "clock")
                    .foregroundColor(remaining < 60 ? .red : .secondary)
                Text("Expires in \(remaining / 60):\(String(format: "%02d", remaining % 60))")
                    .foregroundColor(remaining < 60 ? .red : .secondary)
            }.font(.subheadline)

            Button("Cancel") { viewModel.cancel() }
                .buttonStyle(.bordered)
        }
    }

    private var waitingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Desktop connected!").font(.headline)
            Text("Setting up the session...").foregroundColor(.secondary)
        }
    }

    private func approvedView(name: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64)).foregroundColor(.green)
            Text("Desktop Paired!").font(.title2).fontWeight(.semibold)
            Text("\(name) is now connected.").foregroundColor(.secondary)
            Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
        }
    }

    private func deniedView(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 64)).foregroundColor(.red)
            Text("Pairing Denied").font(.title2)
            Text(message).foregroundColor(.secondary)
            Button("Try Again") { viewModel.startPairing() }.buttonStyle(.borderedProminent)
        }
    }

    private var timeoutView: some View {
        VStack(spacing: 16) {
            Image(systemName: "clock.badge.exclamationmark")
                .font(.system(size: 64)).foregroundColor(.orange)
            Text("Code Expired").font(.title2)
            Text("Generate a new code.").foregroundColor(.secondary)
            Button("Generate New Code") { viewModel.startPairing() }.buttonStyle(.borderedProminent)
        }
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 64)).foregroundColor(.red)
            Text("Error").font(.title2)
            Text(message).foregroundColor(.red).multilineTextAlignment(.center)
            Button("Retry") { viewModel.startPairing() }.buttonStyle(.borderedProminent)
        }
    }
}
