import SwiftUI

// MARK: - Identity Verify Approval View

/// Approval surface for a peer's identity-verify challenge
/// (Phase 3.8, parity with Android `IdentityVerifyApprovalScreen`).
///
/// The peer is asking the owner to PROVE it's still them on the other
/// end of the connection. Approving fires `verify.approve` with a
/// password envelope; the vault publishes a positive verdict and the
/// connection's persistent verify-state row flips green on both sides.
///
/// Denying is one-tap — no password — but it sets a negative entry on
/// the connection's verify state, so the requester sees "verification
/// declined" until the next round.
struct IdentityVerifyApprovalView: View {

    let request: IdentityVerifyApprovalView.Input

    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel = IdentityVerifyApprovalViewModel()
    @Environment(\.dismiss) private var dismiss
    @State private var password: String = ""

    struct Input: Identifiable, Hashable {
        let requestId: String
        let peerLabel: String
        /// Optional challenge text from the requester (e.g. "Are you
        /// still on the new phone?"). Empty for routine periodic
        /// verifies.
        let challenge: String

        var id: String { requestId }
    }

    var body: some View {
        Form {
            Section { header }

            if !request.challenge.isEmpty {
                Section("Challenge") {
                    Text(request.challenge)
                        .font(.subheadline)
                        .italic()
                        .foregroundStyle(.secondary)
                }
            }

            Section("What approving means") {
                Text("Approving signals to \(request.peerLabel.isEmpty ? "this connection" : request.peerLabel) that you're still in control of this account. Your identity key signs the verdict inside your vault; no other secret material is released.")
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
        .navigationTitle("Verify identity")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
                    .disabled(viewModel.isProcessing)
            }
        }
        .safeAreaInset(edge: .bottom) { actionBar }
        .onAppear {
            viewModel.client = appState.grantsClient
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color.green.opacity(0.15))
                .frame(width: 44, height: 44)
                .overlay(
                    Image(systemName: "checkmark.shield")
                        .foregroundStyle(.green)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(request.peerLabel.isEmpty ? "Connection" : request.peerLabel)
                    .font(.headline)
                Text("wants to verify your identity")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
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
                    Text("Verify identity").frame(maxWidth: .infinity)
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
final class IdentityVerifyApprovalViewModel: ObservableObject {

    @Published var isProcessing: Bool = false
    @Published var errorMessage: String?

    var client: GrantsClient?

    func approve(requestId: String, password: String) async -> Bool {
        isProcessing = true
        errorMessage = nil
        defer { isProcessing = false }
        guard let client = client else {
            errorMessage = "Grants client not configured"
            return false
        }
        do {
            let env = try PasswordApprovalEnvelope.build(password: password)
            try await client.approveVerify(
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
        guard let client = client else { return }
        do {
            try await client.denyVerify(requestId: requestId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
