import SwiftUI

/// Success view shown after enrollment completes
struct EnrollmentCompleteView: View {
    let userGuid: String
    let onDismiss: () -> Void

    @State private var showCheckmark = false
    @State private var showContent = false

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            // Success animation
            successIcon

            // Content
            if showContent {
                VStack(spacing: 16) {
                    Text("Welcome to VettID!")
                        .font(.title)
                        .fontWeight(.bold)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))

                    Text("Your credential has been securely stored on this device.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .transition(.opacity)

                    // Feature highlights
                    featureList
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                .padding(.horizontal)
            }

            Spacer()

            // Continue button
            if showContent {
                Button(action: onDismiss) {
                    Text("Get Started")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }
                .padding(.horizontal)
                .padding(.bottom, 40)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .onAppear {
            animateIn()
        }
    }

    // MARK: - Success Icon

    private var successIcon: some View {
        ZStack {
            // Background circle
            Circle()
                .fill(Color.green.opacity(0.15))
                .frame(width: 140, height: 140)
                .scaleEffect(showCheckmark ? 1 : 0.5)
                .opacity(showCheckmark ? 1 : 0)

            // Outer ring
            Circle()
                .stroke(Color.green, lineWidth: 4)
                .frame(width: 120, height: 120)
                .scaleEffect(showCheckmark ? 1 : 0.5)
                .opacity(showCheckmark ? 1 : 0)

            // Checkmark
            Image(systemName: "checkmark")
                .font(.system(size: 50, weight: .bold))
                .foregroundStyle(.green)
                .scaleEffect(showCheckmark ? 1 : 0)
                .opacity(showCheckmark ? 1 : 0)
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.6), value: showCheckmark)
    }

    // MARK: - Feature List

    private var featureList: some View {
        VStack(alignment: .leading, spacing: 16) {
            featureRow(
                icon: "lock.shield.fill",
                title: "Secure Credential",
                description: "Your credential is encrypted and stored in the Keychain"
            )

            featureRow(
                icon: "faceid",
                title: "Biometric Protection",
                description: "Use Face ID or Touch ID for quick access"
            )

            featureRow(
                icon: "arrow.triangle.2.circlepath",
                title: "Key Rotation",
                description: "Security keys rotate automatically with each use"
            )
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(16)
    }

    private func featureRow(icon: String, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.blue)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)

                Text(description)
                    .font(.caption)
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
