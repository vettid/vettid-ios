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

/// Matches Android's `WizardStepIndicator` — a compact, single-line
/// "Step X of Y • Label" header above a thin linear progress bar.
/// Replaces the iOS dots-with-icons row, which was visually busier
/// than the Android equivalent for the same data.
struct EnrollmentStepIndicator: View {
    let currentPhase: WizardPhase

    private var progress: CGFloat {
        CGFloat(currentPhase.rawValue + 1) / CGFloat(WizardPhase.totalSteps)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text("Step \(currentPhase.rawValue + 1) of \(WizardPhase.totalSteps)")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(" • ")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text(currentPhase.label)
                    .font(.headline)
                    .foregroundStyle(Color.accentColor)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color(.systemGray5))
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: geo.size.width * progress)
                        .animation(.easeInOut(duration: 0.3), value: progress)
                }
            }
            .frame(height: 4)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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
        case .finalizing, .settingUpNats, .verifyingEnrollment, .confirmProfile,
             .verifyingCredentialEntry, .processingVerify, .verifySuccess:
            return .verify
        case .requestingPermissions:
            return .permissions
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
