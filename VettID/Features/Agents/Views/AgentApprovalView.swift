import SwiftUI

/// Agent approval screen for approving/denying agent secret or action requests.
///
/// Flow:
/// 1. Agent sends request to vault
/// 2. Vault sends approval request to app via NATS
/// 3. App shows this screen
/// 4. User approves or denies
/// 5. Decision sent to vault, which fulfills the agent request
struct AgentApprovalView: View {
    let requestId: String

    @StateObject private var viewModel: AgentApprovalViewModel
    @Environment(\.dismiss) private var dismiss

    init(requestId: String, ownerSpaceClient: OwnerSpaceClient? = nil) {
        self.requestId = requestId
        self._viewModel = StateObject(wrappedValue: AgentApprovalViewModel(
            ownerSpaceClient: ownerSpaceClient
        ))
    }

    var body: some View {
        Group {
            switch viewModel.state {
            case .loading:
                loadingContent

            case .ready(let request):
                readyContent(request: request)

            case .processingApproval:
                processingContent(message: "Approving request...")

            case .processingDenial:
                processingContent(message: "Denying request...")

            case .approved:
                resultContent(
                    icon: "checkmark.circle.fill",
                    title: "Request Approved",
                    message: "The agent request has been approved.",
                    isError: false
                )

            case .denied:
                resultContent(
                    icon: "xmark.circle.fill",
                    title: "Request Denied",
                    message: "The agent request has been denied.",
                    isError: false
                )

            case .error(let message):
                resultContent(
                    icon: "exclamationmark.triangle.fill",
                    title: "Error",
                    message: message,
                    isError: true
                )
            }
        }
        .navigationTitle("Agent Request")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") {
                    dismiss()
                }
            }
        }
        .task {
            viewModel.subscribeToApprovalRequests()
            viewModel.loadRequest(requestId: requestId)
        }
    }

    // MARK: - Loading

    private var loadingContent: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Waiting for request...")
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Ready (Request Details)

    private func readyContent(request: AgentApprovalRequest) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 24) {
                    // Agent icon
                    Image(systemName: "cpu")
                        .font(.system(size: 50))
                        .foregroundColor(.accentColor)
                        .padding(.top, 24)

                    VStack(spacing: 8) {
                        Text("Agent Request")
                            .font(.title2)
                            .fontWeight(.bold)

                        Text("\(request.agentName) is requesting access")
                            .font(.body)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    // Request details card
                    VStack(alignment: .leading, spacing: 12) {
                        Text("REQUEST DETAILS")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.accentColor)

                        detailRow(label: "Agent", value: request.agentName)

                        if let operation = request.operation, !operation.isEmpty {
                            detailRow(label: "Action", value: formatOperation(operation))
                        }

                        if let category = request.secretCategory, !category.isEmpty {
                            detailRow(label: "Category", value: formatCategory(category))
                        }

                        if let timestamp = request.timestamp, !timestamp.isEmpty {
                            detailRow(label: "Time", value: formatTimestamp(timestamp))
                        }
                    }
                    .padding(16)
                    .background(Color(.secondarySystemGroupedBackground))
                    .cornerRadius(12)
                    .padding(.horizontal, 24)

                    // Sensitive category warning
                    if isSensitiveCategory(request.secretCategory) {
                        sensitiveWarning
                            .padding(.horizontal, 24)
                    }
                }
            }

            // Action buttons
            VStack(spacing: 12) {
                HStack(spacing: 16) {
                    Button {
                        Task {
                            await viewModel.deny(requestId: request.requestId)
                        }
                    } label: {
                        HStack {
                            Image(systemName: "xmark")
                            Text("Deny")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)

                    Button {
                        Task {
                            await viewModel.approve(requestId: request.requestId)
                        }
                    } label: {
                        HStack {
                            Image(systemName: "checkmark")
                            Text("Approve")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(24)
            .background(Color(.systemGroupedBackground))
        }
    }

    // MARK: - Processing

    private func processingContent(message: String) -> some View {
        VStack(spacing: 24) {
            ProgressView()
                .scaleEffect(1.5)
            Text(message)
                .font(.body)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Result

    private func resultContent(icon: String, title: String, message: String, isError: Bool) -> some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: icon)
                .font(.system(size: 60))
                .foregroundColor(isError ? .red : .accentColor)

            Text(title)
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(isError ? .red : .primary)

            Text(message)
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Button("Done") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 8)

            Spacer()
        }
    }

    // MARK: - Helper Views

    private func detailRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
        }
    }

    private var sensitiveWarning: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.red)

            VStack(alignment: .leading, spacing: 4) {
                Text("Sensitive Category")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.red)

                Text("This secret is in a sensitive category. Only approve if you trust this agent.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(16)
        .background(Color.red.opacity(0.08))
        .cornerRadius(12)
    }

    // MARK: - Helpers

    private func formatOperation(_ operation: String) -> String {
        switch operation {
        case "retrieve": return "Retrieve Secret"
        case "http_request": return "HTTP Request"
        case "sign": return "Sign Data"
        default:
            return operation
                .replacingOccurrences(of: "_", with: " ")
                .prefix(1).uppercased() + operation
                .replacingOccurrences(of: "_", with: " ")
                .dropFirst()
        }
    }

    private func formatCategory(_ category: String) -> String {
        category
            .replacingOccurrences(of: "_", with: " ")
            .prefix(1).uppercased() + category
            .replacingOccurrences(of: "_", with: " ")
            .dropFirst()
    }

    private func formatTimestamp(_ timestamp: String) -> String {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: timestamp) {
            let displayFormatter = DateFormatter()
            displayFormatter.dateStyle = .short
            displayFormatter.timeStyle = .short
            return displayFormatter.string(from: date)
        }
        return timestamp
    }

    private func isSensitiveCategory(_ category: String?) -> Bool {
        guard let category = category else { return false }
        return ["ssh_keys", "certificates", "signing_keys"].contains(category)
    }
}

#if DEBUG
struct AgentApprovalView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            AgentApprovalView(requestId: "test-request-id")
        }
    }
}
#endif
