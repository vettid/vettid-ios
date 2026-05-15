import SwiftUI

// MARK: - Enclave Update Prompt

/// Phase 5.7 follow-up (#56) — pre-PIN prompt shown when the running
/// enclave's PCR0 isn't in the user's trusted set.
///
/// Approving adds the PCR0 to `TrustedPCRStore` and toggles
/// `migrate_consent=true` on the next PIN unlock; the vault re-seals
/// `sealed_material.bin` against the new PCR0 inline. Skipping defers
/// the prompt for this session and warms against the current enclave
/// without consent (the user will see the prompt again on next launch).
///
/// Mirrors the Android `EnclaveUpdateRequired` state on PinUnlockViewModel.
struct EnclaveUpdatePromptView: View {

    let pcr0: String
    let onApprove: () -> Void
    let onSkip: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                Image(systemName: "shield.lefthalf.filled.badge.checkmark")
                    .font(.system(size: 60))
                    .foregroundStyle(.blue)

                VStack(spacing: 8) {
                    Text("Enclave Update Available")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text("A new vault enclave version is running. Approve it before unlocking so the vault can re-seal your credential against the new version.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                pcr0Box

                Spacer()

                VStack(spacing: 10) {
                    Button {
                        onApprove()
                    } label: {
                        Text("Approve & continue")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.blue)
                            .foregroundStyle(.white)
                            .cornerRadius(12)
                    }

                    Button {
                        onSkip()
                    } label: {
                        Text("Not now")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .foregroundStyle(.primary)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
            .navigationTitle("Vault Update")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var pcr0Box: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("New enclave fingerprint (PCR0)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(shortPcr0)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.systemGray6))
                .cornerRadius(8)
        }
        .padding(.horizontal)
    }

    /// PCR0 is 96 hex chars (48 bytes) on Nitro Enclaves — too long to
    /// fit in a phrase. Show head + tail with an ellipsis; the full
    /// value is in the textSelection-enabled view for verification.
    private var shortPcr0: String {
        guard pcr0.count > 24 else { return pcr0 }
        return "\(pcr0.prefix(20))…\(pcr0.suffix(8))"
    }
}

#Preview {
    EnclaveUpdatePromptView(
        pcr0: "abc123def456abc123def456abc123def456abc123def456abc123def456abc123def456abc123def456abc123def4567890",
        onApprove: {},
        onSkip: {}
    )
}
