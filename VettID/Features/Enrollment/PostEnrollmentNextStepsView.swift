import SwiftUI

// MARK: - Post-Enrollment Next Steps

/// Phase 5.8 — shown after `EnrollmentCompleteView` to give the user a
/// clear set of next actions before the main app takes over.
///
/// Android wedges a dedicated `PersonalDataCollectionScreen` and
/// `PostEnrollmentScreen` between credential creation and the main UI.
/// On iOS most of that surface already exists (PersonalDataView,
/// EditProfileView, ConnectView, CreateWalletSheet) — the gap is the
/// initial "you just enrolled, here's what to do" moment. This view
/// fills that gap with three direct deep-links and a Skip button that
/// dismisses to the home feed unchanged.
struct PostEnrollmentNextStepsView: View {

    let onDismiss: () -> Void

    @State private var path: NextStepRoute?

    var body: some View {
        VStack(spacing: 24) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 36))
                    .foregroundStyle(.blue)
                Text("Your account is ready")
                    .font(.title2)
                    .fontWeight(.bold)
                Text("A few quick steps to get the most out of VettID.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 24)

            // Step rows
            VStack(spacing: 12) {
                stepRow(
                    icon: "person.crop.rectangle",
                    title: "Add your personal details",
                    subtitle: "Save names, addresses, IDs — only what you choose to share.",
                    tint: .blue
                ) { path = .personalData }

                stepRow(
                    icon: "qrcode.viewfinder",
                    title: "Connect with someone",
                    subtitle: "Scan a connection QR or share your invite link.",
                    tint: .green
                ) { path = .connect }

                stepRow(
                    icon: "bitcoinsign.circle",
                    title: "Create a wallet",
                    subtitle: "Optional — set up a Bitcoin wallet held by your vault.",
                    tint: .orange
                ) { path = .wallet }
            }
            .padding(.horizontal)

            Spacer()

            // Continue button — always available; the steps above are
            // optional first-stops, not gating.
            Button(action: onDismiss) {
                Text("Continue to app")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
            .padding(.horizontal)
            .padding(.bottom, 16)

            Button("Skip for now", action: onDismiss)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.bottom, 24)
        }
        // Each step deep-links via .sheet so the user can preview the
        // destination without leaving the wizard — tapping "Continue"
        // back on the sheet returns here, and "Continue to app"
        // dismisses everything.
        .sheet(item: $path) { route in
            NavigationStack {
                route.destination(onDone: { path = nil })
            }
        }
    }

    // MARK: - Step Row

    private func stepRow(
        icon: String,
        title: String,
        subtitle: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(tint)
                    .frame(width: 36, height: 36)
                    .background(tint.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Deep-link routes

/// Identifiable step destinations. Identifiable lets us drive the
/// `.sheet(item:)` modifier directly off the optional path.
private enum NextStepRoute: String, Identifiable {
    case personalData
    case connect
    case wallet

    var id: String { rawValue }

    @ViewBuilder
    func destination(onDone: @escaping () -> Void) -> some View {
        switch self {
        case .personalData:
            PersonalDataView()
                .navigationTitle("Personal Data")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: onDone)
                    }
                }
        case .connect:
            // Minimal stub — opens the standard connect entry point
            // when one is wired. For now surfaces a guidance panel so
            // the user knows what to do back in the main app.
            ConnectGuidance(onDone: onDone)
        case .wallet:
            WalletGuidance(onDone: onDone)
        }
    }
}

// MARK: - Lightweight guidance panels

private struct ConnectGuidance: View {
    let onDone: () -> Void
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 60))
                .foregroundStyle(.green)
            Text("Connecting with someone")
                .font(.title3)
                .fontWeight(.semibold)
            Text("Open the drawer once you're in the app and tap Connections → New Connection to scan a QR or share your invite link.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Spacer()
            Button("Got it") { onDone() }
                .buttonStyle(.borderedProminent)
                .padding(.bottom, 24)
        }
        .padding()
        .navigationTitle("Connect")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct WalletGuidance: View {
    let onDone: () -> Void
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "bitcoinsign.circle")
                .font(.system(size: 60))
                .foregroundStyle(.orange)
            Text("Create a wallet")
                .font(.title3)
                .fontWeight(.semibold)
            Text("Open the drawer once you're in the app and tap Vault → Wallets → Create. Your wallet keys live inside your vault enclave, never on this device.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Spacer()
            Button("Got it") { onDone() }
                .buttonStyle(.borderedProminent)
                .padding(.bottom, 24)
        }
        .padding()
        .navigationTitle("Wallet")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Preview

#Preview {
    PostEnrollmentNextStepsView(onDismiss: {})
}
