import Foundation
import VettIDData

/// The onboarding steps (ANDROID-PLAN §4 "Onboarding"). Mirrors vettid-android `OnboardingStep`.
public enum OnboardingStep: Equatable, Hashable, Sendable, CaseIterable {
    case welcome
    /// Scan the setup QR from the account portal (VAULT-MESSAGING §11.12.1), the primary path.
    case setupScan
    /// Type the short code with the account's email.
    case setupType
    /// The code was redeemed: "Setting up a vault for m***@example.com" (`email_hint`), before the PIN.
    case confirmAccount
    case vaultElsewhere
    case pinCreate
    case pinConfirm
    case password
    case backup
    case progress
    case done
    /// Recovering the vault on this phone (§11.11): the recovery flow runs the steps.
    case recover
    /// Moving VettID here from the old phone (§6.7.1): the transfer flow runs the steps.
    case transferIn
}

/// Why a scanned code or an opened link was not redeemed. Mirrors vettid-android `ScanRefusal`.
public enum ScanRefusal: Equatable, Sendable, CaseIterable {
    /// Not a setup QR.
    case notACode
    /// A recovery QR: it belongs to "I lost my phone".
    case recoveryCode
    /// A setup QR (or link) made by another environment's portal (``OnboardingState/otherApi``).
    case otherEnvironment
}

/// The state of one enrollment step on the progress screen (vettid-android uses core/ui `StepState`; the screens map
/// this to VettIDUI's).
public enum ProgressState: Equatable, Sendable {
    case pending, active, done, failed
}

/// One line of the progress screen.
public struct ProgressEntry: Equatable, Sendable {
    public var step: EnrollStep
    public var state: ProgressState

    public init(_ step: EnrollStep, _ state: ProgressState) {
        self.step = step
        self.state = state
    }
}

/// The state of the onboarding flow. Secrets live here only while the flow needs them, and are never printed: the
/// descriptions name the step only. Mirrors vettid-android `OnboardingUiState`.
public struct OnboardingState: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// The PIN the password step asks for after a restart is the one set at enrollment: the policy was met then.
    public static let minExistingPin = 6

    public var step: OnboardingStep = .welcome
    public var email = ""
    public var emailInvalid = false
    public var codeInput = ""
    /// The typed code has a character a code never contains (0, 1, I, L, O) or is not 8 symbols long.
    public var codeInvalid = false
    public var scanRefusal: ScanRefusal?
    /// The other environment's `api` of a refused QR, shown so the member knows which portal made it.
    public var otherApi: String?
    /// The account the redeemed code belongs to, masked (`email_hint`).
    public var emailHint = ""
    public var pin = ""
    public var pinConfirm = ""
    public var pinProblem: PinPolicy.Problem?
    public var pinMismatch = false
    public var password = ""
    public var passwordConfirm = ""
    /// The password rules of release R (ANDROID-PLAN "Passwords"), as the member types. At enrollment they apply
    /// whatever the vault's release: it is not known before the enrollment, and a password they accept is one every
    /// release accepts.
    public var passwordRule: PasswordRule = .short
    /// ``passwordRule`` is the vault's verdict (`weak_password{reason}`), not the app's.
    public var passwordRefused = false
    public var passwordMismatch = false
    public var backup = true
    public var backupOffAcknowledged = false
    /// Resuming after enrollment: only the credential steps remain (§3.5.7).
    public var credentialOnly = false
    /// (Release R, VAULT-MESSAGING §11.14.9) The credential is created after a restart, without the PIN of this flow in
    /// memory: `credential.create` carries the PIN, which the vault verifies, so the password step asks for it.
    public var askPin = false
    /// The vault came to this phone by a direct transfer: the last screen is the move's (``OnboardingStep/done``).
    public var movedIn = false
    /// (Release R) The move still has to be finished with the PIN on this phone ("Finish the move").
    public var finishMovePending = false
    /// (IOS-PLAN §4.2) "Your vault was deleted…", once, on the welcome screen after a vault was deleted.
    public var deletedNotice = false
    /// The vault has a phone secret (release R): the move's last screen says so in its words.
    public var phoneSecret = false
    public var progress: [ProgressEntry] = []
    public var busy = false
    public var error: FailureKind?
    public var errorCode: String?
    /// When the failed action becomes possible, when the failure says (``FailureKind/enrollmentStarted``).
    public var errorRetryAt: Date?
    public var devHint: String?

    public init(step: OnboardingStep = .welcome, devHint: String? = nil) {
        self.step = step
        self.devHint = devHint
    }

    public var canContinueBackup: Bool { backup || backupOffAcknowledged }
    public var progressFailed: Bool { progress.contains { $0.state == .failed } }

    /// (Release R) The PIN the password step asks for (``askPin``) is entered: digits only, the policy was met at setup.
    public var credentialPinReady: Bool {
        !askPin || pin.count >= Self.minExistingPin && pin.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// The password step can go on: both fields filled, the rules met, the PIN entered when it is asked.
    public var canSubmitPassword: Bool {
        !password.isEmpty && !passwordConfirm.isEmpty && credentialPinReady && passwordRule.passes && !passwordRefused
    }

    public var description: String {
        "OnboardingState(step: \(step), busy: \(busy), error: \(error.map { "\($0)" } ?? "nil"))"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
