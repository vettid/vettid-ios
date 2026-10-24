import Foundation

/// The recovery screens' own texts: vettid-android's `strings.xml`, word for word, and the iPhone's (`ios_`; chosen; not in the
/// spec).
enum RecoveryScreenStrings {
    static var recoverTitle: String {
        String(localized: "recover_title", defaultValue: "Recover your vault", bundle: .module)
    }

    static func recoverBody(_ a: String) -> String {
        String(
            localized: "recover_body",
            defaultValue: """
                Your account site shows a recovery QR code \(a) after you start a recovery there. Open it \
                (Vault, then Recovery, then Show the code) and scan it with this phone, or type the code shown \
                under it.
                """,
            bundle: .module
        )
    }

    static var recoverNeedBody: String {
        String(
            localized: "recover_need_body",
            defaultValue: """
                The recovery code from the account site, your vault PIN and your credential password. This phone \
                then replaces your old one, which erases VettID the next time it reaches your vault.
                """,
            bundle: .module
        )
    }

    static var recoverScan: String {
        String(localized: "recover_scan", defaultValue: "Scan the code", bundle: .module)
    }

    static var recoverOpenSite: String {
        String(localized: "recover_open_site", defaultValue: "Open the account site", bundle: .module)
    }

    static var recoverScanTitle: String {
        String(localized: "recover_scan_title", defaultValue: "Scan the recovery code", bundle: .module)
    }

    static var recoverScanBody: String {
        String(localized: "recover_scan_body", defaultValue: "Point the camera at the code on the account site.", bundle: .module)
    }

    static var recoverType: String {
        String(localized: "recover_type", defaultValue: "Type the code instead", bundle: .module)
    }

    static var recoverScanInstead: String {
        String(localized: "recover_scan_instead", defaultValue: "Scan instead", bundle: .module)
    }

    static var recoverTypeTitle: String {
        String(localized: "recover_type_title", defaultValue: "Type your recovery code", bundle: .module)
    }

    static var recoverTypeBody: String {
        String(
            localized: "recover_type_body",
            defaultValue: """
                On the account site, under the QR code, there are 12 groups of four characters. Type them all, \
                in order.
                """,
            bundle: .module
        )
    }

    static var recoverTypeLabel: String {
        String(localized: "recover_type_label", defaultValue: "Recovery code", bundle: .module)
    }

    static func recoverTypeGroups(_ a: Int, _ b: Int) -> String {
        String(localized: "recover_type_groups", defaultValue: "\(a) of \(b) groups", bundle: .module)
    }

    static var recoverRegistering: String {
        String(localized: "recover_registering", defaultValue: "Checking the code with your vault", bundle: .module)
    }

    static var recoverRegisteringStarting: String {
        String(
            localized: "recover_registering_starting",
            defaultValue: """
                If your vault was not running, it is starting now. This can take a couple of minutes.
                """,
            bundle: .module
        )
    }

    static var recoverStartOver: String {
        String(localized: "recover_start_over", defaultValue: "Start over", bundle: .module)
    }

    static var recoverStartOverTitle: String {
        String(localized: "recover_start_over_title", defaultValue: "Start over on this phone?", bundle: .module)
    }

    static var recoverStartOverBody: String {
        String(
            localized: "recover_start_over_body",
            defaultValue: """
                This phone forgets the recovery it registered and goes back to the start. There you can recover \
                again, use a setup code or move VettID from your old phone.\n\
                \n\
                The recovery itself is not cancelled by this: it stays open until you cancel it on the account \
                site or it expires, and its code cannot be used a second time. To recover with this phone later, \
                cancel it there and start a new recovery. Your vault is not changed.
                """,
            bundle: .module
        )
    }

    static var recoverNoBackupTitle: String {
        String(localized: "recover_no_backup_title", defaultValue: "This vault cannot be recovered", bundle: .module)
    }

    static var recoverNoBackupBody: String {
        String(
            localized: "recover_no_backup_body",
            defaultValue: """
                Its credential backup was off, so VettID offers no way back into it: nothing in it can be \
                released to a phone without the credential.
                """,
            bundle: .module
        )
    }

    static var recoverNoBackupNotice: String {
        String(
            localized: "recover_no_backup_notice",
            defaultValue: """
                This vault cannot be recovered: its credential backup was off. Delete it on the account site and \
                start over with a new setup code.
                """,
            bundle: .module
        )
    }

    static var recoverNoBackupStartOver: String {
        String(localized: "recover_no_backup_start_over", defaultValue: "Delete my vault and start over", bundle: .module)
    }

    static var recoverNoBackupNewVault: String {
        String(localized: "recover_no_backup_new_vault", defaultValue: "I have a new setup code", bundle: .module)
    }

    static var onboardingOpenTitle: String {
        String(localized: "onboarding_open_title", defaultValue: "Your PIN and your password", bundle: .module)
    }

    static var onboardingOpenPin: String {
        String(localized: "onboarding_open_pin", defaultValue: "Vault PIN", bundle: .module)
    }

    static var onboardingOpenPassword: String {
        String(localized: "onboarding_open_password", defaultValue: "Credential password", bundle: .module)
    }

    static var onboardingOpenTen: String {
        String(
            localized: "onboarding_open_ten",
            defaultValue: """
                Enter both. You have 10 attempts in total for this vault, not 10 a day.
                """,
            bundle: .module
        )
    }

    static var onboardingOpenContinue: String {
        String(localized: "onboarding_open_continue", defaultValue: "Continue", bundle: .module)
    }

    static func onboardingOpenCheck(_ a: String, _ b: String) -> String {
        String(
            localized: "onboarding_open_check",
            defaultValue: """
                This is what will be sent. PIN: \(a). Password: \(b). Look at both. A wrong entry uses one of \
                your attempts.
                """,
            bundle: .module
        )
    }

    static var onboardingOpenSend: String {
        String(localized: "onboarding_open_send", defaultValue: "Send", bundle: .module)
    }

    static var onboardingOpenChange: String {
        String(localized: "onboarding_open_change", defaultValue: "Change", bundle: .module)
    }

    static var onboardingOpenWarningTitle: String {
        String(localized: "onboarding_open_warning_title", defaultValue: "Before you send", bundle: .module)
    }

    static var onboardingOpenTryAgain: String {
        String(localized: "onboarding_open_try_again", defaultValue: "Try again", bundle: .module)
    }

    static var onboardingOpenLostTitle: String {
        String(localized: "onboarding_open_lost_title", defaultValue: "Finish with your PIN", bundle: .module)
    }

    static var onboardingOpenLostBody: String {
        String(
            localized: "onboarding_open_lost_body",
            defaultValue: """
                If your last attempt recovered your vault but its answer was lost, your PIN finishes the \
                recovery on this phone. This does not use any of your attempts.
                """,
            bundle: .module
        )
    }

    static var onboardingOpenBack: String {
        String(localized: "onboarding_open_back", defaultValue: "Back to the recovery", bundle: .module)
    }

    static var onboardingOpenNewRecovery: String {
        String(localized: "onboarding_open_new_recovery", defaultValue: "Start a new recovery", bundle: .module)
    }

    static var onboardingOpenFinishTitle: String {
        String(localized: "onboarding_open_finish_title", defaultValue: "Finish the recovery", bundle: .module)
    }

    static var onboardingOpenFinishBody: String {
        String(
            localized: "onboarding_open_finish_body",
            defaultValue: """
                Your vault was recovered onto this phone, but this phone could not open it yet. Enter your PIN \
                to finish. This does not use any of your attempts.
                """,
            bundle: .module
        )
    }

    static var onboardingOpenFinishGo: String {
        String(localized: "onboarding_open_finish_go", defaultValue: "Finish", bundle: .module)
    }

    static var onboardingOpenFinishGone: String {
        String(
            localized: "onboarding_open_finish_gone",
            defaultValue: """
                Your vault no longer accepts this phone. It may have been recovered onto another phone, or \
                deleted.
                """,
            bundle: .module
        )
    }

    static var onboardingOpenFinishEraseBody: String {
        String(
            localized: "onboarding_open_finish_erase_body",
            defaultValue: """
                This erases VettID's data on this phone only: its keys, your account details and the app's \
                settings. It cannot be undone.\n\
                \n\
                Your vault was recovered onto this phone and may still count on it. Erase only if your vault now \
                works on another phone, or if you are sure it is gone.
                """,
            bundle: .module
        )
    }

    static var iosRecoverGuidanceFinishWithPin: String {
        String(
            localized: "ios_recover_guidance_finish_with_pin",
            defaultValue: """
                An attempt to open your vault was already sent from this phone, and your vault may have accepted \
                it. Finish with your PIN. Do not start over or scan a new code.
                """,
            bundle: .module
        )
    }

    static var iosRecoverGuidanceAlreadyRecovered: String {
        String(
            localized: "ios_recover_guidance_already_recovered",
            defaultValue: """
                This phone has already recovered your vault. Finish the recovery. Do not start over.
                """,
            bundle: .module
        )
    }

    static var iosRecoverGuidanceTryOpenAgain: String {
        String(
            localized: "ios_recover_guidance_try_open_again",
            defaultValue: """
                The recovery is still registered for this phone. Enter your PIN and password again. If your last \
                attempt may have worked, finish with your PIN instead.
                """,
            bundle: .module
        )
    }

    static var iosRecoverGuidanceRetry: String {
        String(
            localized: "ios_recover_guidance_retry",
            defaultValue: """
                VettID could not tell just now whether your vault accepted this phone. Try again in a moment.
                """,
            bundle: .module
        )
    }

    static var iosRecoverGuidanceStartOverFirst: String {
        String(
            localized: "ios_recover_guidance_start_over_first",
            defaultValue: """
                This phone is registered for another recovery. Start over first, then scan this code.
                """,
            bundle: .module
        )
    }

    static var iosRecoverGuidanceGo: String {
        String(localized: "ios_recover_guidance_go", defaultValue: "Go to the recovery", bundle: .module)
    }

    static var iosRecoverStageFailed: String {
        String(
            localized: "ios_recover_stage_failed",
            defaultValue: """
                VettID could not read where your recovery stands, so it shows nothing else yet. Try again.
                """,
            bundle: .module
        )
    }

    static var iosRecoverOpenSending: String {
        String(localized: "ios_recover_open_sending", defaultValue: "Sending to your vault", bundle: .module)
    }
}
