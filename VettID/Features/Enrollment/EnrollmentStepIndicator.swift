import SwiftUI

// MARK: - Wizard Phase

enum WizardPhase: Int, CaseIterable {
    case start = 0
    case verify = 1
    case identity = 2
    case pin = 3
    case password = 4
    case confirm = 5
    case profile = 6
    case done = 7

    var label: String {
        switch self {
        case .start: return "Start"
        case .verify: return "Verify"
        case .identity: return "Identity"
        case .pin: return "PIN"
        case .password: return "Password"
        case .confirm: return "Confirm"
        case .profile: return "Profile"
        case .done: return "Done"
        }
    }

    var icon: String {
        switch self {
        case .start: return "qrcode.viewfinder"
        case .verify: return "checkmark.shield"
        case .identity: return "person.text.rectangle"
        case .pin: return "number.circle"
        case .password: return "key"
        case .confirm: return "person.fill.checkmark"
        case .profile: return "person.crop.circle"
        case .done: return "checkmark.circle.fill"
        }
    }

    static var totalSteps: Int { allCases.count }
}

// MARK: - Enrollment Step Indicator

struct EnrollmentStepIndicator: View {
    let currentPhase: WizardPhase

    var body: some View {
        VStack(spacing: 8) {
            // Progress bar
            GeometryReader { geometry in
                let totalWidth = geometry.size.width
                let progress = CGFloat(currentPhase.rawValue) / CGFloat(WizardPhase.totalSteps - 1)

                ZStack(alignment: .leading) {
                    // Background track
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(.systemGray5))
                        .frame(height: 4)

                    // Progress fill
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.blue)
                        .frame(width: totalWidth * progress, height: 4)
                        .animation(.easeInOut(duration: 0.3), value: progress)
                }
            }
            .frame(height: 4)

            // Step dots with labels
            HStack(spacing: 0) {
                ForEach(WizardPhase.allCases, id: \.rawValue) { phase in
                    stepDot(phase: phase)
                    if phase.rawValue < WizardPhase.totalSteps - 1 {
                        Spacer()
                    }
                }
            }

            // Current step label
            Text("Step \(currentPhase.rawValue + 1) of \(WizardPhase.totalSteps): \(currentPhase.label)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private func stepDot(phase: WizardPhase) -> some View {
        let isComplete = phase.rawValue < currentPhase.rawValue
        let isCurrent = phase == currentPhase

        return VStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(isComplete ? Color.blue : (isCurrent ? Color.blue : Color(.systemGray5)))
                    .frame(width: 24, height: 24)

                if isComplete {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                } else if isCurrent {
                    Image(systemName: phase.icon)
                        .font(.system(size: 10))
                        .foregroundStyle(.white)
                } else {
                    Text("\(phase.rawValue + 1)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Enrollment State to Wizard Phase Mapping

extension EnrollmentViewModel.EnrollmentState {
    var wizardPhase: WizardPhase {
        switch self {
        case .initial, .scanningQR:
            return .start
        case .processingInvitation, .connectingToNats, .requestingAttestation,
             .attestationRequired, .attesting, .attestationComplete:
            return .verify
        case .confirmIdentity, .identityRejected:
            return .identity
        case .settingPIN, .processingPIN:
            return .pin
        case .waitingForVault:
            return .identity
        case .settingPassword, .processingPassword:
            return .password
        case .creatingCredential, .finalizing, .settingUpNats, .verifyingEnrollment:
            return .confirm
        case .confirmProfile:
            return .profile
        case .complete:
            return .done
        case .error:
            return .start
        }
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 40) {
        EnrollmentStepIndicator(currentPhase: .start)
        EnrollmentStepIndicator(currentPhase: .verify)
        EnrollmentStepIndicator(currentPhase: .pin)
        EnrollmentStepIndicator(currentPhase: .password)
        EnrollmentStepIndicator(currentPhase: .done)
    }
    .padding()
}
