#if os(iOS)
import SwiftUI
import VettIDData
import VettIDOnboarding
import VettIDUI

// The pieces the onboarding screens share. Mirrors the private helpers of vettid-android `OnboardingScreens.kt`.

/// The failure of the last action, if any: the failure's own text, or [overrideText] for [override].
struct ErrorNotice: View {
    let state: OnboardingState
    var override: FailureKind?
    var overrideText: String?
    @Environment(\.vettIDTimeScale) private var timeScale

    var body: some View {
        if let kind = state.error {
            let text = override != nil && kind == override
                ? overrideText ?? kind.message(timeScale: timeScale) : Self.message(kind, state.errorRetryAt, timeScale: timeScale)
            NoticeCard(.urgent, title: OnboardingStrings.progressFailed, message: text, announce: .assertive)
                .padding(.top, Spacing.l)
                .accessibilityIdentifier("error")
        }
    }
}

extension ErrorNotice {
    /// The failure's text at the vault's [timeScale]; a refused start-over (iPhone only) says from when it is possible.
    static func message(_ kind: FailureKind, _ retryAt: Date?, timeScale: UInt64) -> String {
        if kind == .enrollmentStarted, let retryAt { return FailureKind.enrollmentStartedText(after: retryAt) }
        return kind.message(timeScale: timeScale)
    }
}

/// The development hint (DevStack builds only).
struct DevHintNotice: View {
    let state: OnboardingState

    var body: some View {
        if let hint = state.devHint {
            NoticeCard(.info, title: OnboardingStrings.devTitle, message: hint).padding(.top, Spacing.l)
        }
    }
}

/// A gold text action at least a touch target high.
struct TextLink: View {
    @Environment(\.vettIDColors) private var colors
    let label: String
    var identifier: String?
    let action: @MainActor () -> Void

    init(_ label: String, identifier: String? = nil, action: @escaping @MainActor () -> Void) {
        self.label = label
        self.identifier = identifier
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(label).vettIDFont(.labelLarge).foregroundStyle(colors.primary).multilineTextAlignment(.leading)
        }
        .buttonStyle(.plain)
        .frame(minHeight: Spacing.touchTarget)
        .accessibilityIdentifier(identifier ?? "")
    }
}

/// A line of the welcome screen with its icon.
struct WelcomePoint: View {
    @Environment(\.vettIDColors) private var colors
    let symbol: VettIDSymbol
    let text: String

    var body: some View {
        HStack(spacing: Spacing.l) {
            symbol.image.font(.system(size: 22)).foregroundStyle(colors.primary).frame(width: 24).accessibilityHidden(true)
            Text(text).vettIDFont(.bodyLarge)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Why the scan was refused, if it was.
struct ScanRefusalNotice: View {
    let state: OnboardingState

    var body: some View {
        if let r = state.scanRefusal {
            let text = switch r {
            case .notACode: OnboardingStrings.setupNotCode
            case .recoveryCode: OnboardingStrings.setupRecoveryCode
            case .otherEnvironment: OnboardingStrings.setupOtherEnvironment(state.otherApi ?? "")
            }
            NoticeCard(.warning, title: OnboardingStrings.setupRefusedTitle, message: text)
                .padding(.top, Spacing.l)
                .accessibilityIdentifier("scan_refused")
        }
    }
}

/// A text field with its label above and its supporting or error line below. [framed]: outlined as ``SecretField``
/// is (a field that draws its own outline, such as ``VisibleSecretField``, passes false).
struct LabeledField<Field: View>: View {
    @Environment(\.vettIDColors) private var colors
    let label: String
    var supporting: String?
    var isError = false
    var framed = true
    @ViewBuilder let field: () -> Field

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(label).vettIDFont(.labelMedium).foregroundStyle(isError ? colors.error : colors.onSurfaceVariant)
            if framed {
                field()
                    .vettIDFont(.bodyLarge)
                    .frame(minHeight: Spacing.touchTarget)
                    .padding(.horizontal, Spacing.l)
                    .overlay(RoundedRectangle(cornerRadius: VettIDShape.small).stroke(isError ? colors.error : colors.outline))
                    .accessibilityLabel(label)
            } else {
                field()
            }
            if let supporting {
                Text(supporting).vettIDFont(.bodySmall).foregroundStyle(isError ? colors.error : colors.onSurfaceVariant)
            }
        }
    }
}

/// The label over a PIN keypad and, when there is one, the problem under it. Every PIN entry of the app (IOS-PLAN §6.5):
/// onboarding's, the unlock's, the owner check's and those of Settings. [failure]: where the shown error hides while
/// digits are typed, the vault's answer it stands for, spoken to VoiceOver once when it occurs (not again when the keypad
/// is emptied). Without one the shown error is spoken whenever it appears: the phone's own checks, whose failure is set
/// again in the same update as the submit, so that only its reappearance can tell a second failure.
public struct PinEntry: View {
    @Environment(\.vettIDColors) private var colors
    let label: String
    let buffer: PinBuffer
    var error: String?
    var failure: String?
    let identifier: String

    public init(label: String, buffer: PinBuffer, error: String? = nil, failure: String? = nil, identifier: String) {
        self.label = label
        self.buffer = buffer
        self.error = error
        self.failure = failure
        self.identifier = identifier
    }

    public var body: some View {
        VStack(spacing: Spacing.m) {
            Text(label).vettIDFont(.labelLarge).foregroundStyle(colors.onSurfaceVariant)
            // A container: the label and identifier are the keypad's own, and each key keeps its digit and `pin_<d>`.
            PinKeypad(buffer: buffer, length: PinPolicy.minLength)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(label)
                .accessibilityIdentifier(identifier)
            if let error {
                Text(error)
                    .vettIDFont(.bodySmall)
                    .foregroundStyle(colors.error)
                    .multilineTextAlignment(.center)
                    .announced(failure == nil ? error : nil, .assertive)
                    .accessibilityIdentifier("\(identifier)_error")
            }
        }
        .frame(maxWidth: .infinity)
        .announced(failure, .assertive)
    }
}

extension ProgressState {
    var stepState: StepState {
        switch self {
        case .pending: .pending
        case .active: .active
        case .done: .done
        case .failed: .failed
        }
    }
}

extension EnrollStep {
    var label: String {
        switch self {
        case .enroll: OnboardingStrings.stepEnroll
        case .waitForVault: OnboardingStrings.stepWait
        case .handshake: OnboardingStrings.stepHandshake
        case .createCredential: OnboardingStrings.stepCredential
        case .backup: OnboardingStrings.stepBackup
        case .confirm: OnboardingStrings.stepConfirm
        }
    }
}
#endif
