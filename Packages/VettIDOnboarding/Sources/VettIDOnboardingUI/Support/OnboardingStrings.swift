import Foundation

/// The package's texts, from `Resources/Localizable.xcstrings`. Keys are the Android string names
/// (vettid-android `feature/onboarding/src/main/res/values/strings.xml`, with the camera's from the same file); the
/// English values are the same. One extension per screen.
enum OnboardingStrings {}

// The welcome screen.
extension OnboardingStrings {
    static var welcomeTitle: String {
        String(localized: "onboarding_welcome_title", defaultValue: "Your vault, only with you", bundle: .module)
    }
    static var welcomeBody: String {
        String(
            localized: "onboarding_welcome_body",
            defaultValue: """
                VettID keeps your messages, connections and most important secrets in a vault that only you can open.
                """,
            bundle: .module
        )
    }
    static var welcomePointKeys: String {
        String(
            localized: "onboarding_welcome_point_keys",
            defaultValue: """
                Your keys stay on this phone and in your vault's sealed enclave.
                """,
            bundle: .module
        )
    }
    static var welcomePointMember: String {
        String(
            localized: "onboarding_welcome_point_member",
            defaultValue: """
                You need a VettID membership: the account site gives you a code to set up your vault here.
                """,
            bundle: .module
        )
    }
    static var welcomeStart: String {
        String(localized: "onboarding_welcome_start", defaultValue: "Get started", bundle: .module)
    }
    static var welcomeTransfer: String {
        String(localized: "onboarding_welcome_transfer", defaultValue: "Move from my old phone", bundle: .module)
    }
    static var welcomeRecover: String {
        String(localized: "onboarding_welcome_recover", defaultValue: "I lost my phone: recover my vault", bundle: .module)
    }
}

// The setup code: scanned or typed.
extension OnboardingStrings {
    static var setupScanTitle: String {
        String(localized: "onboarding_setup_scan_title", defaultValue: "Scan your setup code", bundle: .module)
    }
    static var setupScanBody: String {
        String(
            localized: "onboarding_setup_scan_body",
            defaultValue: """
                On the account site (Vault, then Set up your vault), get a setup code and scan its QR code with this phone. It works \
                once, for 5 minutes.
                """,
            bundle: .module
        )
    }
    static var setupType: String {
        String(localized: "onboarding_setup_type", defaultValue: "Type the code instead", bundle: .module)
    }
    static var setupOpenSite: String {
        String(localized: "onboarding_setup_open_site", defaultValue: "Open the account site", bundle: .module)
    }
    static var setupRefusedTitle: String {
        String(localized: "onboarding_setup_refused_title", defaultValue: "Not a setup code", bundle: .module)
    }
    static var setupNotCode: String {
        String(
            localized: "onboarding_setup_not_code",
            defaultValue: """
                That is not a VettID setup code. Scan the QR code the account site shows under Set up your vault.
                """,
            bundle: .module
        )
    }
    static var setupRecoveryCode: String {
        String(
            localized: "onboarding_setup_recovery_code",
            defaultValue: """
                That is a recovery code. To recover your vault, go back and choose "I lost my phone".
                """,
            bundle: .module
        )
    }
    static func setupOtherEnvironment(_ api: String) -> String {
        String(
            localized: "onboarding_setup_other_environment",
            defaultValue: """
                That code is from another VettID environment (\(api)), not the one this app uses. Get a code from this app's account \
                site.
                """,
            bundle: .module
        )
    }
    static var setupRedeeming: String {
        String(localized: "onboarding_setup_redeeming", defaultValue: "Checking your code", bundle: .module)
    }
    static var setupRedeemingBody: String {
        String(localized: "onboarding_setup_redeeming_body", defaultValue: "One moment.", bundle: .module)
    }
    static var setupInvalid: String {
        String(
            localized: "onboarding_setup_invalid",
            defaultValue: """
                That code did not work. It may be mistyped, used already, or older than 5 minutes, or the email may not be your \
                account's. Get a new code on the account site.
                """,
            bundle: .module
        )
    }
    static var setupTypeTitle: String {
        String(localized: "onboarding_setup_type_title", defaultValue: "Type your setup code", bundle: .module)
    }
    static var setupTypeBody: String {
        String(
            localized: "onboarding_setup_type_body",
            defaultValue: """
                Enter your account's email address and the 8 characters shown under the QR code on the account site.
                """,
            bundle: .module
        )
    }
    static var setupEmailLabel: String {
        String(localized: "onboarding_setup_email_label", defaultValue: "Email address of your account", bundle: .module)
    }
    static var setupEmailInvalid: String {
        String(localized: "onboarding_setup_email_invalid", defaultValue: "Enter a valid email address.", bundle: .module)
    }
    static var setupCodeLabel: String {
        String(localized: "onboarding_setup_code_label", defaultValue: "Setup code", bundle: .module)
    }
    static var setupCodeHint: String {
        String(localized: "onboarding_setup_code_hint", defaultValue: "8 characters, like ABCD-EFGH", bundle: .module)
    }
    static var setupCodeInvalid: String {
        String(
            localized: "onboarding_setup_code_invalid",
            defaultValue: """
                Codes have 8 characters and never contain 0, 1, I, L or O.
                """,
            bundle: .module
        )
    }
}

// The account to confirm, and a vault that is elsewhere.
extension OnboardingStrings {
    static var confirmAccountTitle: String {
        String(localized: "onboarding_confirm_account_title", defaultValue: "Is this your account?", bundle: .module)
    }
    static func confirmAccountBody(_ emailHint: String) -> String {
        String(
            localized: "onboarding_confirm_account_body",
            defaultValue: """
                You are setting up a vault for \(emailHint). Only continue if this is your own account and you got the code yourself.
                """,
            bundle: .module
        )
    }
    static var confirmAccountHintTitle: String {
        String(localized: "onboarding_confirm_account_hint_title", defaultValue: "Account", bundle: .module)
    }
    static var confirmAccountYes: String {
        String(localized: "onboarding_confirm_account_yes", defaultValue: "Yes, continue", bundle: .module)
    }
    static var confirmAccountNo: String {
        String(localized: "onboarding_confirm_account_no", defaultValue: "That is not my account", bundle: .module)
    }
    static var otherCode: String {
        String(localized: "onboarding_other_code", defaultValue: "Use a different setup code", bundle: .module)
    }
    static var elsewhereTitle: String {
        String(localized: "onboarding_elsewhere_title", defaultValue: "Your account already has a vault", bundle: .module)
    }
    static var elsewhereBody: String {
        String(
            localized: "onboarding_elsewhere_body",
            defaultValue: """
                A vault has exactly one app, which holds its credential. Another phone is that app. Move VettID to this phone from \
                there, or recover the vault if that phone is lost.
                """,
            bundle: .module
        )
    }
    static var elsewhereTransferTitle: String {
        String(localized: "onboarding_elsewhere_transfer_title", defaultValue: "Still have the other phone?", bundle: .module)
    }
    static var elsewhereTransferBody: String {
        String(
            localized: "onboarding_elsewhere_transfer_body",
            defaultValue: """
                Move VettID with a direct transfer: the other phone shows a code, this phone scans it, and you approve there with your \
                PIN and credential password. No waiting.
                """,
            bundle: .module
        )
    }
    static var elsewhereTransfer: String {
        String(localized: "onboarding_elsewhere_transfer", defaultValue: "Move from my old phone", bundle: .module)
    }
    static var elsewhereRecoveryTitle: String {
        String(localized: "onboarding_elsewhere_recovery_title", defaultValue: "Lost it?", bundle: .module)
    }
    static var elsewhereRecoveryBody: String {
        String(
            localized: "onboarding_elsewhere_recovery_body",
            defaultValue: """
                Start a recovery on the account site. After 24 hours it shows a code that this phone scans; then your PIN and credential \
                password move the vault here, and the old phone erases VettID the next time it reaches your vault.
                """,
            bundle: .module
        )
    }
    static var elsewhereRecover: String {
        String(localized: "onboarding_elsewhere_recover", defaultValue: "Recover my vault", bundle: .module)
    }
    static var elsewhereOpen: String {
        String(localized: "onboarding_elsewhere_open", defaultValue: "Open the account site", bundle: .module)
    }
    static var elsewhereAnyway: String {
        String(localized: "onboarding_elsewhere_anyway", defaultValue: "Set up a new vault anyway", bundle: .module)
    }
}

// The vault PIN.
extension OnboardingStrings {
    static var pinTitle: String {
        String(localized: "onboarding_pin_title", defaultValue: "Choose your vault PIN", bundle: .module)
    }
    static var pinBody: String {
        String(
            localized: "onboarding_pin_body",
            defaultValue: """
                Your PIN unlocks your vault. Only your vault's sealed enclave ever checks it, and wrong guesses are slowed down. Use at \
                least 6 digits; avoid dates and simple patterns.
                """,
            bundle: .module
        )
    }
    static var pinLabel: String {
        String(localized: "onboarding_pin_label", defaultValue: "Vault PIN", bundle: .module)
    }
    static var pinConfirmTitle: String {
        String(localized: "onboarding_pin_confirm_title", defaultValue: "Confirm your vault PIN", bundle: .module)
    }
    static var pinConfirmBody: String {
        String(localized: "onboarding_pin_confirm_body", defaultValue: "Enter the same PIN again.", bundle: .module)
    }
    static var pinConfirmLabel: String {
        String(localized: "onboarding_pin_confirm_label", defaultValue: "Vault PIN again", bundle: .module)
    }
    static var pinMismatch: String {
        String(localized: "onboarding_pin_mismatch", defaultValue: "The PINs do not match. Try again.", bundle: .module)
    }
    static var continueLabel: String {
        String(localized: "onboarding_continue", defaultValue: "Continue", bundle: .module)
    }
    static var unlockPinLabel: String {
        String(localized: "unlock_pin_label", defaultValue: "Vault PIN", bundle: .module)
    }
}

// The credential password.
extension OnboardingStrings {
    static var passwordTitle: String {
        String(localized: "onboarding_password_title", defaultValue: "Create your credential password", bundle: .module)
    }
    static var passwordBody: String {
        String(
            localized: "onboarding_password_body",
            defaultValue: """
                It protects your Protean Credential and your critical items, and VettID asks for it at every critical action. Make it \
                different from your PIN. Nobody, VettID included, can reset it.
                """,
            bundle: .module
        )
    }
    static var passwordLabel: String {
        String(localized: "onboarding_password_label", defaultValue: "Credential password", bundle: .module)
    }
    static var passwordConfirmLabel: String {
        String(localized: "onboarding_password_confirm_label", defaultValue: "Password again", bundle: .module)
    }
    static var passwordMismatch: String {
        String(localized: "onboarding_password_mismatch", defaultValue: "The passwords do not match.", bundle: .module)
    }
}

// The backup choice.
extension OnboardingStrings {
    static var backupTitle: String {
        String(localized: "onboarding_backup_title", defaultValue: "Keep a sealed backup?", bundle: .module)
    }
    static var backupBody: String {
        String(
            localized: "onboarding_backup_body",
            defaultValue: """
                Choose where your credential lives. You can change this later in Credential.
                """,
            bundle: .module
        )
    }
    static var backupOn: String {
        String(localized: "onboarding_backup_on", defaultValue: "Backup on (recommended)", bundle: .module)
    }
    static var backupOnBody: String {
        String(
            localized: "onboarding_backup_on_body",
            defaultValue: """
                Your vault keeps a copy sealed to it and to your password. If you lose this phone, a recovery restores your vault on a \
                new one.
                """,
            bundle: .module
        )
    }
    static var backupOff: String {
        String(localized: "onboarding_backup_off", defaultValue: "Backup off", bundle: .module)
    }
    static var backupOffBody: String {
        String(
            localized: "onboarding_backup_off_body",
            defaultValue: """
                Your credential lives only on this phone. No copy exists anywhere else.
                """,
            bundle: .module
        )
    }
    static var backupOffWarningTitle: String {
        String(localized: "onboarding_backup_off_warning_title", defaultValue: "No recovery without this phone", bundle: .module)
    }
    static var backupOffWarningBody: String {
        String(
            localized: "onboarding_backup_off_warning_body",
            defaultValue: """
                If this phone is lost, broken, reset or replaced without a transfer, your vault cannot be recovered. It can only be \
                deleted and replaced by a new one, and everything in it is lost.
                """,
            bundle: .module
        )
    }
    static var backupOffAck: String {
        String(
            localized: "onboarding_backup_off_ack",
            defaultValue: """
                I understand that without this phone my vault cannot be recovered
                """,
            bundle: .module
        )
    }
    static var backupSubmit: String {
        String(localized: "onboarding_backup_submit", defaultValue: "Set up my vault", bundle: .module)
    }
}

// The progress, the end, and the development hint.
extension OnboardingStrings {
    static var progressTitle: String {
        String(localized: "onboarding_progress_title", defaultValue: "Setting up your vault", bundle: .module)
    }
    static var progressBody: String {
        String(localized: "onboarding_progress_body", defaultValue: "This takes a moment. Keep VettID open.", bundle: .module)
    }
    static var stepEnroll: String {
        String(localized: "onboarding_step_enroll", defaultValue: "Verifying the vault service and this phone", bundle: .module)
    }
    static var stepWait: String {
        String(localized: "onboarding_step_wait", defaultValue: "Creating your vault", bundle: .module)
    }
    static var stepHandshake: String {
        String(localized: "onboarding_step_handshake", defaultValue: "Connecting securely", bundle: .module)
    }
    static var stepCredential: String {
        String(localized: "onboarding_step_credential", defaultValue: "Creating your Protean Credential", bundle: .module)
    }
    static var stepBackup: String {
        String(localized: "onboarding_step_backup", defaultValue: "Saving your backup choice", bundle: .module)
    }
    static var stepConfirm: String {
        String(localized: "onboarding_step_confirm", defaultValue: "Confirming your vault", bundle: .module)
    }
    static var progressFailed: String {
        String(localized: "onboarding_progress_failed", defaultValue: "Setup stopped", bundle: .module)
    }
    static var progressRetry: String {
        String(localized: "onboarding_progress_retry", defaultValue: "Try again", bundle: .module)
    }
    static var progressEdit: String {
        String(localized: "onboarding_progress_edit", defaultValue: "Change my choices", bundle: .module)
    }
    static var doneTitle: String {
        String(localized: "onboarding_done_title", defaultValue: "Your vault is ready", bundle: .module)
    }
    static var doneBody: String {
        String(
            localized: "onboarding_done_body",
            defaultValue: """
                Your vault is enrolled, this phone holds its credential, and only your PIN opens it.
                """,
            bundle: .module
        )
    }
    static var doneNextTitle: String {
        String(localized: "onboarding_done_next_title", defaultValue: "Next: your first connection", bundle: .module)
    }
    static var doneNextBody: String {
        String(
            localized: "onboarding_done_next_body",
            defaultValue: """
                Invite someone with a QR code or a link, compare the safety code, and start messaging.
                """,
            bundle: .module
        )
    }
    static var doneGo: String {
        String(localized: "onboarding_done_go", defaultValue: "Go to VettID", bundle: .module)
    }
    static var devTitle: String {
        String(localized: "onboarding_dev_title", defaultValue: "Development build", bundle: .module)
    }
}

// The camera.
extension OnboardingStrings {
    static var recoverScanAllow: String {
        String(localized: "recover_scan_allow", defaultValue: "Allow the camera", bundle: .module)
    }
    static var recoverScanPermissionTitle: String {
        String(localized: "recover_scan_permission_title", defaultValue: "Camera access", bundle: .module)
    }
    static var recoverScanPermissionBody: String {
        String(
            localized: "recover_scan_permission_body",
            defaultValue: """
                VettID uses the camera only to read the code; nothing is recorded.
                """,
            bundle: .module
        )
    }
    static var recoverScanNoCameraTitle: String {
        String(localized: "recover_scan_no_camera_title", defaultValue: "No camera", bundle: .module)
    }
    static var recoverScanNoCameraBody: String {
        String(
            localized: "recover_scan_no_camera_body",
            defaultValue: """
                This phone has no camera that VettID can use. Type the code instead.
                """,
            bundle: .module
        )
    }
    static var moveCdQrScanner: String {
        String(localized: "move_cd_qr_scanner", defaultValue: "Camera view for scanning the code", bundle: .module)
    }
}
