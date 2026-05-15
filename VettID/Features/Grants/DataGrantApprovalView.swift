import SwiftUI

// MARK: - Data Grant Approval View

/// Full-screen approval for an inbound data / minor-secret request
/// (Phase 3.6, parity with Android `DataGrantApprovalScreen`).
///
/// Layout:
///   - peer identity strip,
///   - requested item + mode + expiry + max-uses,
///   - requester's reason (their justification, italics),
///   - a collapsible "privacy details" disclosure (what gets released,
///     where it lives during the grant's lifetime, when it gets purged),
///   - password field gating Approve.
///
/// Deny is one-tap, no password — denying doesn't release secret material.
struct DataGrantApprovalView: View {

    let request: PendingRequestSummary

    @StateObject private var viewModel = DataGrantApprovalViewModel()
    @Environment(\.dismiss) private var dismiss
    @State private var password: String = ""
    @State private var showPrivacyDetails: Bool = false

    var body: some View {
        Form {
            Section {
                requestHeader
            }

            Section("Details") {
                detailRow("Kind", request.kind.displayName)
                if !request.itemLabel.isEmpty {
                    detailRow("Item", request.itemLabel)
                }
                detailRow("Mode", request.requestedMode.title)
                if let expiry = request.requestedExpiresAt {
                    detailRow("Expires", expiry.formatted(.dateTime.day().month().year()))
                }
                if request.requestedMaxUses > 0 {
                    detailRow("Max uses", "\(request.requestedMaxUses)")
                }
            }

            if !request.reason.isEmpty {
                Section("Reason from \(request.peerLabel.isEmpty ? "requester" : request.peerLabel)") {
                    Text(request.reason)
                        .font(.subheadline)
                        .italic()
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                DisclosureGroup("What gets released?", isExpanded: $showPrivacyDetails) {
                    Text(privacyExplainer)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Password") {
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .submitLabel(.done)
            }

            if let error = viewModel.errorMessage {
                Section {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Approve request")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
                    .disabled(viewModel.isProcessing)
            }
        }
        .safeAreaInset(edge: .bottom) {
            actionBar
        }
    }

    // MARK: - Header

    private var requestHeader: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color.accentColor.opacity(0.15))
                .frame(width: 44, height: 44)
                .overlay(
                    Image(systemName: request.kind.icon)
                        .foregroundStyle(Color.accentColor)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(request.peerLabel.isEmpty ? "Connection" : request.peerLabel)
                    .font(.headline)
                Text("wants \(request.kind.displayName.lowercased())")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.subheadline)
            Spacer()
            Text(value).font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private var privacyExplainer: String {
        switch request.requestedMode {
        case .oneShot:
            return "The vault releases the value once. After the peer fetches it, the grant burns and no further reads succeed. The peer is responsible for what happens to the value on their side."
        case .renewable:
            return "The vault releases the value up to \(request.requestedMaxUses) times, until the expiry. Each fetch is logged on the audit trail; you can revoke the grant at any time."
        case .agentRenewable:
            return "The vault releases the value to the peer AND to their authorized agents (e.g. an automated booking tool). Each fetch is logged; you can revoke the grant at any time."
        }
    }

    // MARK: - Action bar

    private var actionBar: some View {
        HStack(spacing: 12) {
            Button(role: .destructive) {
                Task {
                    await viewModel.deny(requestId: request.requestId)
                    dismiss()
                }
            } label: {
                Text("Deny")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.isProcessing)

            Button {
                Task {
                    let ok = await viewModel.approve(request: request, password: password)
                    if ok { dismiss() }
                }
            } label: {
                if viewModel.isProcessing {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Text("Approve").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(password.isEmpty || viewModel.isProcessing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }
}

// MARK: - View Model

@MainActor
final class DataGrantApprovalViewModel: ObservableObject {

    @Published var isProcessing: Bool = false
    @Published var errorMessage: String?

    private let repository: GrantsRepository

    init(repository: GrantsRepository = .shared) {
        self.repository = repository
    }

    /// Build the password envelope and call `grant.approve` via the
    /// repository. Returns true on success so the caller can dismiss.
    func approve(request: PendingRequestSummary, password: String) async -> Bool {
        isProcessing = true
        errorMessage = nil
        defer { isProcessing = false }
        do {
            let env = try PasswordApprovalEnvelope.build(password: password)
            try await repository.approve(
                requestId: request.requestId,
                expiresAt: request.requestedExpiresAt,
                maxUses: request.requestedMaxUses,
                mode: request.requestedMode,
                encryptedPasswordHash: env.encryptedPasswordHash,
                ephemeralPublicKey: env.ephemeralPublicKey,
                nonce: env.nonce,
                salt: env.salt
            )
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func deny(requestId: String) async {
        isProcessing = true
        errorMessage = nil
        defer { isProcessing = false }
        do {
            try await repository.deny(requestId: requestId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
