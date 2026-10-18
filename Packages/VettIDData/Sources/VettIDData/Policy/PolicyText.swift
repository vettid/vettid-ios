import Foundation

// The member-facing texts of the PIN and password rules (the package's strings `data_pin_problem_*`,
// `data_password_*`, `data_strength_*`). Mirrors vettid-android `core/data` `policy/PolicyText.kt`.

public extension PinPolicy.Problem {
    /// The message for a PIN that breaks ``PinPolicy`` (some with ``messageArg``). Mirrors vettid-android
    /// `PinPolicy.Problem.messageRes`.
    var message: String {
        switch self {
        case .notDigits: DataStrings.pinProblemDigits
        case .tooShort: DataStrings.pinProblemShort(PinPolicy.minLength)
        case .tooLong: DataStrings.pinProblemLong(PinPolicy.maxLength)
        case .repeated: DataStrings.pinProblemRepeated
        case .sequence: DataStrings.pinProblemSequence
        case .pattern: DataStrings.pinProblemPattern
        case .common: DataStrings.pinProblemCommon
        }
    }

    /// The format argument of ``message``, if any.
    var messageArg: Int? {
        switch self {
        case .tooShort: PinPolicy.minLength
        case .tooLong: PinPolicy.maxLength
        default: nil
        }
    }
}

public extension PasswordPolicy.Problem {
    /// Mirrors vettid-android `PasswordPolicy.Problem.messageRes`.
    var message: String {
        switch self {
        case .tooShort: DataStrings.passwordProblemShort
        case .tooLong: DataStrings.passwordProblemLong
        case .tooWeak: DataStrings.passwordProblemWeak
        case .sameAsPin: DataStrings.passwordProblemPin
        case .controlCharacters: DataStrings.passwordProblemControl
        }
    }
}

public extension PasswordPolicy.Strength {
    /// Mirrors vettid-android `PasswordPolicy.Strength.labelRes`.
    var label: String {
        switch self {
        case .tooShort: DataStrings.strengthTooShort
        case .weak: DataStrings.strengthWeak
        case .fair: DataStrings.strengthFair
        case .good: DataStrings.strengthGood
        case .strong: DataStrings.strengthStrong
        }
    }
}

public extension PasswordRule {
    /// The line under a new password for this rule (ANDROID-PLAN "Passwords", verbatim). Mirrors vettid-android
    /// `PasswordRule.messageRes`.
    var message: String {
        switch self {
        case .short: DataStrings.passwordRuleShort
        case .repeated: DataStrings.passwordRuleRepeated
        case .common: DataStrings.passwordRuleCommon
        case .sameAsPin: DataStrings.passwordRulePin
        case .guessable: DataStrings.passwordRuleGuessable
        case .tooLong: DataStrings.passwordProblemLong
        case .controlCharacters: DataStrings.passwordProblemControl
        case .vaultRefused: DataStrings.failureWeakPassword
        case .ok: DataStrings.passwordRuleOk
        }
    }

    /// The estimator's short hint after ``guessable``, else nil. Mirrors vettid-android `PasswordRule.hintRes`.
    var hint: String? { self == .guessable ? DataStrings.passwordRuleGuessableHint : nil }
}
