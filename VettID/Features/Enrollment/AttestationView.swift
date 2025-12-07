import SwiftUI

/// Device attestation progress view
struct AttestationView: View {
    @ObservedObject var viewModel: EnrollmentViewModel
    let onComplete: () -> Void

    @State private var animationPhase = 0

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            // Animated icon
            attestationIcon

            // Title and description
            VStack(spacing: 12) {
                Text(titleText)
                    .font(.title2)
                    .fontWeight(.bold)

                Text(descriptionText)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            // Progress indicator
            if case .attesting(let progress) = viewModel.state {
                progressSection(progress: progress)
            }

            Spacer()

            // Status message
            statusMessage
        }
        .padding()
        .onAppear {
            startAnimation()
            startAttestation()
        }
    }

    // MARK: - Icon

    private var attestationIcon: some View {
        ZStack {
            // Outer ring
            Circle()
                .stroke(Color.blue.opacity(0.2), lineWidth: 4)
                .frame(width: 120, height: 120)

            // Animated ring
            Circle()
                .trim(from: 0, to: animatedTrimEnd)
                .stroke(
                    Color.blue,
                    style: StrokeStyle(lineWidth: 4, lineCap: .round)
                )
                .frame(width: 120, height: 120)
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 1).repeatForever(autoreverses: true), value: animationPhase)

            // Center icon
            Image(systemName: iconName)
                .font(.system(size: 40))
                .foregroundStyle(iconColor)
                .opacity(isAnimating ? (animationPhase == 0 ? 0.7 : 1.0) : 1.0)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: animationPhase)
        }
    }

    private var animatedTrimEnd: Double {
        switch viewModel.state {
        case .attesting(let progress):
            return progress
        case .attestationComplete:
            return 1.0
        default:
            return 0.3 + Double(animationPhase) * 0.2
        }
    }

    private var iconName: String {
        switch viewModel.state {
        case .attestationComplete:
            return "checkmark.shield.fill"
        case .error:
            return "xmark.shield.fill"
        default:
            return "shield.fill"
        }
    }

    private var iconColor: Color {
        switch viewModel.state {
        case .attestationComplete:
            return .green
        case .error:
            return .red
        default:
            return .blue
        }
    }

    private var isAnimating: Bool {
        switch viewModel.state {
        case .attestationRequired, .attesting:
            return true
        default:
            return false
        }
    }

    // MARK: - Text

    private var titleText: String {
        switch viewModel.state {
        case .attestationRequired:
            return "Device Verification"
        case .attesting:
            return "Verifying Device..."
        case .attestationComplete:
            return "Device Verified"
        case .error:
            return "Verification Failed"
        default:
            return "Device Verification"
        }
    }

    private var descriptionText: String {
        switch viewModel.state {
        case .attestationRequired:
            return "We need to verify your device is secure before proceeding."
        case .attesting(let progress):
            return stepDescription(for: progress)
        case .attestationComplete:
            return "Your device has been verified. Proceeding to password setup..."
        case .error(let message, _):
            return message
        default:
            return "Preparing device verification..."
        }
    }

    private func stepDescription(for progress: Double) -> String {
        switch progress {
        case 0..<0.25:
            return "Initializing secure enclave..."
        case 0.25..<0.5:
            return "Generating attestation key..."
        case 0.5..<0.75:
            return "Creating attestation certificate..."
        case 0.75..<1.0:
            return "Completing verification..."
        default:
            return "Verification complete"
        }
    }

    // MARK: - Progress

    private func progressSection(progress: Double) -> some View {
        VStack(spacing: 8) {
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .tint(.blue)

            Text("\(Int(progress * 100))%")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 40)
    }

    // MARK: - Status

    private var statusMessage: some View {
        Group {
            switch viewModel.state {
            case .attestationRequired:
                Button("Start Verification") {
                    Task {
                        await viewModel.performAttestation()
                    }
                }
                .buttonStyle(.borderedProminent)

            case .error(_, let retryable):
                if retryable {
                    Button("Try Again") {
                        Task {
                            await viewModel.performAttestation()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }

            default:
                EmptyView()
            }
        }
        .padding(.bottom, 40)
    }

    // MARK: - Actions

    private func startAnimation() {
        withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) {
            animationPhase = 1
        }
    }

    private func startAttestation() {
        // Auto-start attestation if in required state
        if case .attestationRequired = viewModel.state {
            Task {
                try? await Task.sleep(nanoseconds: 500_000_000)
                await viewModel.performAttestation()
            }
        }
    }
}

// MARK: - Preview

#Preview {
    AttestationView(viewModel: {
        let vm = EnrollmentViewModel()
        return vm
    }(), onComplete: {})
}
