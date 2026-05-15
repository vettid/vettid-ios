import SwiftUI

// MARK: - Critical Use Approval View

/// Approval surface for a peer's `critical-secret-use.request-use`
/// (Phase 3.7, parity with Android `CriticalUseApprovalScreen`).
///
/// The peer wants the owner's vault to PERFORM AN OPERATION using one
/// of the owner's critical secrets (sign / decrypt / derive / auth).
/// The value never leaves the owner's vault — only the operation
/// result. This screen reflects that: there's no expiry / max-uses
/// because the operation is one-shot by definition, and the privacy
/// disclosure leans on "the secret material does NOT leave your vault".
struct CriticalUseApprovalView: View {

    let request: CriticalUseApprovalView.Input

    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel = CriticalUseApprovalViewModel()
    @Environment(\.dismiss) private var dismiss
    @State private var password: String = ""

    /// Compact input the view needs to render — pulled together by the
    /// caller from a `critical-secret-use.request-use` payload. Kept as
    /// a nested type so other surfaces can build it without a wire
    /// dependency.
    struct Input: Identifiable, Hashable {
        let requestId: String
        let peerLabel: String
        let itemLabel: String
        let operation: String
        let context: String

        var id: String { requestId }
    }

    var body: some View {
        Form {
            Section {
                header
            }
            Section("Operation") {
                detailRow("Secret", request.itemLabel)
                detailRow("Operation", request.operation.uppercased())
                if !request.context.isEmpty {
                    Text(request.context)
                        .font(.subheadline)
                        .italic()
                        .foregroundStyle(.secondary)
                }
            }
            Section("Privacy") {
                Text("The secret material does NOT leave your vault. The vault performs the operation locally and returns only the result. Approving this request authorizes one operation; the peer can't re-use the authorization.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Password") {
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .submitLabel(.done)
            }
            if let error = viewModel.errorMessage {
                Section {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Approve operation")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
                    .disabled(viewModel.isProcessing)
            }
        }
        .safeAreaInset(edge: .bottom) { actionBar }
        .onAppear {
            // Wire the VM's GrantsClient on first appearance — AppState
            // owns the canonical instance built after warm-up.
            viewModel.client = appState.grantsClient
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color.orange.opacity(0.15))
                .frame(width: 44, height: 44)
                .overlay(
                    Image(systemName: "wand.and.stars")
                        .foregroundStyle(.orange)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(request.peerLabel.isEmpty ? "Connection" : request.peerLabel)
                    .font(.headline)
                Text("wants to USE a critical secret")
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

    private var actionBar: some View {
        HStack(spacing: 12) {
            Button(role: .destructive) {
                Task {
                    await viewModel.deny(requestId: request.requestId)
                    dismiss()
                }
            } label: {
                Text("Deny").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.isProcessing)

            Button {
                Task {
                    let ok = await viewModel.approve(requestId: request.requestId, password: password)
                    if ok { dismiss() }
                }
            } label: {
                if viewModel.isProcessing {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Text("Approve operation").frame(maxWidth: .infinity)
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
final class CriticalUseApprovalViewModel: ObservableObject {

    @Published var isProcessing: Bool = false
    @Published var errorMessage: String?

    var client: GrantsClient?

    func approve(requestId: String, password: String) async -> Bool {
        isProcessing = true
        errorMessage = nil
        defer { isProcessing = false }
        guard let client = resolveClient() else {
            errorMessage = "Grants client not configured"
            return false
        }
        do {
            let env = try PasswordApprovalEnvelope.build(password: password)
            try await client.approveCriticalUse(
                requestId: requestId,
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
        guard let client = resolveClient() else { return }
        do {
            try await client.denyCriticalUse(requestId: requestId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Resolve the client. Prefer an externally-set instance; fall back
    /// to nil and surface the not-configured error to the user.
    private func resolveClient() -> GrantsClient? { client }
}
