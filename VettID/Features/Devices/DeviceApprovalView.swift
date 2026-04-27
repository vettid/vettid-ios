import Foundation
import SwiftUI

// MARK: - Approval Request Model

struct DeviceApprovalRequestData: Codable, Equatable {
    let requestId: String
    let connectionId: String
    let deviceName: String
    let hostname: String?
    let operation: String
    let secretName: String?
    let category: String?
    let requestedAt: String

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case connectionId = "connection_id"
        case deviceName = "device_name"
        case hostname, operation
        case secretName = "secret_name"
        case category
        case requestedAt = "requested_at"
    }

    var formattedOperation: String {
        switch operation {
        case "secrets.retrieve": return "Retrieve Secret"
        case "secrets.add": return "Add Secret"
        case "secrets.delete": return "Delete Secret"
        case "connection.create": return "Create Connection"
        case "connection.revoke": return "Revoke Connection"
        case "profile.update": return "Update Profile"
        case "personal-data.get": return "Access Personal Data"
        case "personal-data.update": return "Update Personal Data"
        case "credential.get": return "Access Credential"
        case "credential.update": return "Update Credential"
        case "service.auth.request": return "Service Authentication"
        case "agent.approve": return "Approve Agent"
        default:
            return operation.replacingOccurrences(of: ".", with: " ").capitalized
        }
    }
}

// MARK: - Approval State

enum DeviceApprovalState: Equatable {
    case idle
    case ready(request: DeviceApprovalRequestData, elapsedSeconds: Int)
    case processingApproval
    case processingDenial
    case approved
    case denied
    case timeout
    case error(message: String)
}

// MARK: - Approval ViewModel

@MainActor
final class DeviceApprovalViewModel: ObservableObject {
    @Published private(set) var state: DeviceApprovalState = .idle

    private let ownerSpaceClient: OwnerSpaceClient
    private var elapsedTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private let approvalTimeoutSeconds = 120 // 2 minutes

    init(ownerSpaceClient: OwnerSpaceClient) {
        self.ownerSpaceClient = ownerSpaceClient
    }

    deinit {
        elapsedTask?.cancel()
        timeoutTask?.cancel()
    }

    func loadRequest(_ request: DeviceApprovalRequestData) {
        state = .ready(request: request, elapsedSeconds: 0)
        startElapsedTimer(request)
        startTimeout()
    }

    func approve() {
        guard case .ready(let request, _) = state else { return }
        state = .processingApproval
        Task {
            do {
                try await ownerSpaceClient.sendToVault(
                    ApprovalResponse(requestId: request.requestId, approved: true),
                    topic: "connection.device.approval"
                )
                state = .approved
            } catch {
                state = .error(message: error.localizedDescription)
            }
            stopTimers()
        }
    }

    func deny() {
        guard case .ready(let request, _) = state else { return }
        state = .processingDenial
        Task {
            do {
                try await ownerSpaceClient.sendToVault(
                    ApprovalResponse(requestId: request.requestId, approved: false),
                    topic: "connection.device.approval"
                )
                state = .denied
            } catch {
                state = .error(message: error.localizedDescription)
            }
            stopTimers()
        }
    }

    func dismiss() {
        stopTimers()
        state = .idle
    }

    private func startElapsedTimer(_ request: DeviceApprovalRequestData) {
        elapsedTask?.cancel()
        elapsedTask = Task { [weak self] in
            var elapsed = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                elapsed += 1
                if case .ready(let req, _) = self?.state {
                    self?.state = .ready(request: req, elapsedSeconds: elapsed)
                }
            }
        }
    }

    private func startTimeout() {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(self?.approvalTimeoutSeconds ?? 120) * 1_000_000_000)
            if case .ready = self?.state {
                self?.state = .timeout
            }
            self?.stopTimers()
        }
    }

    private func stopTimers() {
        elapsedTask?.cancel()
        timeoutTask?.cancel()
    }
}

struct ApprovalResponse: Encodable {
    let requestId: String
    let approved: Bool

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case approved
    }
}

// MARK: - Device Approval View

struct DeviceApprovalView: View {
    let ownerSpaceClient: OwnerSpaceClient
    let request: DeviceApprovalRequestData
    @StateObject private var viewModel: DeviceApprovalViewModel
    @Environment(\.dismiss) private var dismiss

    init(ownerSpaceClient: OwnerSpaceClient, request: DeviceApprovalRequestData) {
        self.ownerSpaceClient = ownerSpaceClient
        self.request = request
        self._viewModel = StateObject(wrappedValue: DeviceApprovalViewModel(
            ownerSpaceClient: ownerSpaceClient
        ))
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            switch viewModel.state {
            case .idle:
                ProgressView("Loading...")
                    .onAppear { viewModel.loadRequest(request) }

            case .ready(let req, let elapsed):
                approvalCard(request: req, elapsed: elapsed)

            case .processingApproval:
                ProgressView("Approving...")

            case .processingDenial:
                ProgressView("Denying...")

            case .approved:
                resultView(icon: "checkmark.circle.fill", color: .green,
                           title: "Approved", message: "The operation was approved.")

            case .denied:
                resultView(icon: "xmark.circle.fill", color: .red,
                           title: "Denied", message: "The operation was denied.")

            case .timeout:
                resultView(icon: "clock.badge.exclamationmark", color: .orange,
                           title: "Expired", message: "The request timed out.")

            case .error(let message):
                resultView(icon: "exclamationmark.triangle.fill", color: .red,
                           title: "Error", message: message)
            }

            Spacer()
        }
        .padding(24)
        .navigationTitle("Approve Request")
    }

    private func approvalCard(request: DeviceApprovalRequestData, elapsed: Int) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "iphone.and.arrow.forward")
                .font(.system(size: 48)).foregroundColor(.accentColor)

            Text("Approve on Your Phone")
                .font(.title2).fontWeight(.semibold)

            VStack(spacing: 8) {
                detailRow("Device", request.deviceName)
                if let hostname = request.hostname {
                    detailRow("Hostname", hostname)
                }
                Divider()
                detailRow("Operation", request.formattedOperation)
                if let secretName = request.secretName {
                    detailRow("Secret", secretName)
                }
                if let category = request.category {
                    detailRow("Category", category)
                }
            }
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(12)

            Text("Waiting... \(elapsed)s")
                .font(.caption).foregroundColor(.secondary)

            HStack(spacing: 16) {
                Button(role: .destructive) { viewModel.deny() } label: {
                    Text("Deny").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).controlSize(.large)

                Button { viewModel.approve() } label: {
                    Text("Approve").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
            }
        }
    }

    private func resultView(icon: String, color: Color, title: String, message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 64)).foregroundColor(color)
            Text(title).font(.title2).fontWeight(.semibold)
            Text(message).foregroundColor(.secondary).multilineTextAlignment(.center)
            Button("Done") {
                viewModel.dismiss()
                dismiss()
            }.buttonStyle(.borderedProminent)
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundColor(.secondary)
            Spacer()
            Text(value).fontWeight(.medium)
        }
    }
}
