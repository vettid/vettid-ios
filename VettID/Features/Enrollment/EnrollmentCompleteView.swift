import SwiftUI

/// Success view shown after enrollment completes
struct EnrollmentCompleteView: View {
    let userGuid: String
    let onDismiss: () -> Void

    @State private var showCheckmark = false
    @State private var showContent = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 20) {
                    Spacer().frame(height: 32)

                    successIcon

                    if showContent {
                        VStack(spacing: 8) {
                            Text("Welcome to VettID!")
                                .font(.title2)
                                .fontWeight(.bold)
                                .transition(.opacity.combined(with: .move(edge: .bottom)))

                            Text("Your credential is securely stored on this device.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .transition(.opacity)
                        }

                        featureList
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
            }

            if showContent {
                Button(action: onDismiss) {
                    Text("Get Started")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .onAppear { animateIn() }
    }

    // MARK: - Success Icon

    private var successIcon: some View {
        ZStack {
            Circle()
                .fill(Color.accentColor.opacity(0.15))
                .frame(width: 120, height: 120)
                .scaleEffect(showCheckmark ? 1 : 0.5)
                .opacity(showCheckmark ? 1 : 0)

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 80))
                .foregroundStyle(Color.accentColor)
                .scaleEffect(showCheckmark ? 1 : 0)
                .opacity(showCheckmark ? 1 : 0)
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.6), value: showCheckmark)
    }

    // MARK: - Feature List

    private var featureList: some View {
        VStack(alignment: .leading, spacing: 14) {
            featureRow(
                icon: "lock.shield.fill",
                title: "Encrypted vault",
                description: "Credential stored in iOS Keychain, sealed to this device."
            )

            featureRow(
                icon: "arrow.triangle.2.circlepath",
                title: "Key rotation",
                description: "Transaction keys rotate automatically with each use."
            )

            featureRow(
                icon: "checkmark.shield",
                title: "Hardware attestation",
                description: "Enclave verifies the device on every sensitive operation."
            )
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func featureRow(icon: String, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)

                Text(description)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }

    // MARK: - Animation

    private func animateIn() {
        withAnimation(.easeOut(duration: 0.4)) {
            showCheckmark = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            withAnimation(.easeOut(duration: 0.4)) {
                showContent = true
            }
        }
    }
}

// MARK: - Preview

#Preview {
    EnrollmentCompleteView(
        userGuid: "test-guid-123",
        onDismiss: {}
    )
}
