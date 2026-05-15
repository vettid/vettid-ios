import SwiftUI

// MARK: - Wizard Phase

/// Phase 5.5 — collapsed from 8 to 7 phases to match Android's
/// wizard. The old `verify`/`identity` pair merges into a single
/// REVIEW step (attestation + identity confirmation belong together),
/// `confirm`/`profile` collapse into a single VERIFY-CREDENTIAL step
/// (the profile publish runs silently while the screen shows the
/// verify-success checkmark), and a new PERMISSIONS step lands between
/// verify and done.
enum WizardPhase: Int, CaseIterable {
    case start       = 0
    case review      = 1
    case pin         = 2
    case password    = 3
    case verify      = 4
    case permissions = 5
    case done        = 6

    var label: String {
        switch self {
        case .start:       return "Start"
        case .review:      return "Review"
        case .pin:         return "PIN"
        case .password:    return "Password"
        case .verify:      return "Verify"
        case .permissions: return "Permissions"
        case .done:        return "Done"
        }
    }

    var icon: String {
        switch self {
        case .start:       return "qrcode.viewfinder"
        case .review:      return "person.text.rectangle"
        case .pin:         return "number.circle"
        case .password:    return "key"
        case .verify:      return "checkmark.shield"
        case .permissions: return "bell.badge"
        case .done:        return "checkmark.circle.fill"
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
    /// Phase 5.5 mapping: matches Android's 7-phase wizard. Attestation
    /// states live under `start` (the device is still being introduced
    /// to the supervisor); identity confirmation + rejection both fold
    /// into `review`; credential creation + the silent profile publish
    /// share the `verify` step so the indicator doesn't lurch back to
    /// a "Profile" stop after the user has already entered their
    /// password.
    var wizardPhase: WizardPhase {
        switch self {
        case .initial, .scanningQR,
             .processingInvitation, .connectingToNats,
             .requestingAttestation, .attestationRequired,
             .attesting, .attestationComplete:
            return .start
        case .confirmIdentity, .identityRejected:
            return .review
        case .settingPIN, .processingPIN, .waitingForVault:
            return .pin
        case .settingPassword, .processingPassword, .creatingCredential:
            return .password
        case .finalizing, .settingUpNats, .verifyingEnrollment, .confirmProfile:
            return .verify
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
        EnrollmentStepIndicator(currentPhase: .review)
        EnrollmentStepIndicator(currentPhase: .pin)
        EnrollmentStepIndicator(currentPhase: .password)
        EnrollmentStepIndicator(currentPhase: .verify)
        EnrollmentStepIndicator(currentPhase: .permissions)
        EnrollmentStepIndicator(currentPhase: .done)
    }
    .padding()
}
