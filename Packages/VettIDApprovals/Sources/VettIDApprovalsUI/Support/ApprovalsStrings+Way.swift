import Foundation

// The texts of an agent's run and proxy held for approval (ANDROID-PLAN 0.1.137 AA8, 0.1.138), word for word as vettid-android's
// `feature/approvals` `strings_agent_ways.xml` has them, under the same names (the overlay line and AA9's lines are not here: iOS
// has no overlay to say, and the folders and files of a run are AA9's).
extension ApprovalsStrings {
    static func runTitle(_ who: String, _ item: String) -> String {
        String(
            localized: "approvals_run_title",
            defaultValue: "\(who) wants to run a program with \(item)",
            bundle: .module
        )
    }

    static func runSummary(_ arguments: String, _ variables: String, _ size: String) -> String {
        String(
            localized: "approvals_run_summary",
            defaultValue: "\(arguments), \(variables), \(size) in all",
            bundle: .module
        )
    }

    static func wayField(_ field: String) -> String {
        String(
            localized: "approvals_way_field",
            defaultValue: "Field: \(field)",
            bundle: .module
        )
    }

    static var runProgram: String { String(localized: "approvals_run_program", defaultValue: "Program", bundle: .module) }
    static func runFingerprint(_ fingerprint: String) -> String {
        String(
            localized: "approvals_run_fingerprint",
            defaultValue: "Fingerprint: \(fingerprint)",
            bundle: .module
        )
    }

    static var runAskedAs: String { String(localized: "approvals_run_asked_as", defaultValue: "Asked for as:", bundle: .module) }
    static var runArguments: String { String(localized: "approvals_run_arguments", defaultValue: "Arguments", bundle: .module) }
    static var runNoArguments: String {
        String(
            localized: "approvals_run_no_arguments",
            defaultValue: "No arguments",
            bundle: .module
        )
    }

    static var runSecretFile: String {
        String(
            localized: "approvals_run_secret_file",
            defaultValue: "(the secret file's path)",
            bundle: .module
        )
    }

    static var runRunsIn: String { String(localized: "approvals_run_runs_in", defaultValue: "Runs in", bundle: .module) }
    static var runNewFolder: String {
        String(
            localized: "approvals_run_new_folder",
            defaultValue: "A new, empty folder of its own",
            bundle: .module
        )
    }

    static var runSecretGiven: String {
        String(
            localized: "approvals_run_secret_given",
            defaultValue: "Secret given as",
            bundle: .module
        )
    }

    static func runHowEnv(_ name: String) -> String {
        String(
            localized: "approvals_run_how_env",
            defaultValue: "variable \(name)",
            bundle: .module
        )
    }

    static var runHowStdin: String {
        String(
            localized: "approvals_run_how_stdin",
            defaultValue: "standard input",
            bundle: .module
        )
    }

    static func runHowFile(_ name: String) -> String {
        String(
            localized: "approvals_run_how_file",
            defaultValue: "a temporary file, its path in variable \(name)",
            bundle: .module
        )
    }

    static var runOtherVariables: String {
        String(
            localized: "approvals_run_other_variables",
            defaultValue: "Other variables",
            bundle: .module
        )
    }

    static var runNone: String { String(localized: "approvals_run_none", defaultValue: "None", bundle: .module) }
    static var runWarnShell: String {
        String(
            localized: "approvals_run_warn_shell",
            defaultValue: """
            This program can run other programs or code given to it, so the command can do anything \
            with your secret. Read every argument.
            """,
            bundle: .module
        )
    }

    static var runWarnInlineCode: String {
        String(
            localized: "approvals_run_warn_inline_code",
            defaultValue: "This runs code given on the command line. It can do anything with your secret.",
            bundle: .module
        )
    }

    static var runWarnUnbound: String {
        String(
            localized: "approvals_run_warn_unbound",
            defaultValue: "Any program could be asked for. Approve only a command you recognize.",
            bundle: .module
        )
    }

    static func runWarnUnrecorded(_ fingerprint: String) -> String {
        String(
            localized: "approvals_run_warn_unrecorded",
            defaultValue: """
            First run of this program with this item. Fingerprint: \(fingerprint). If you approve, \
            later runs of this exact file may run without asking, as this item's settings allow.
            """,
            bundle: .module
        )
    }

    static func runWarnChanged(_ before: String, _ now: String) -> String {
        String(
            localized: "approvals_run_warn_changed",
            defaultValue: """
            This program has changed since you approved it. Before: \(before). Now: \(now). If you \
            did not update it, deny. If you approve, this file's fingerprint replaces the recorded \
            one, and later runs of it may run without asking, as this item's settings allow.
            """,
            bundle: .module
        )
    }

    static func runWarnMoved(_ path: String, _ was: String, _ before: String, _ now: String) -> String {
        String(
            localized: "approvals_run_warn_moved",
            defaultValue: """
            This program moved to \(path). It was approved at \(was). Before: \(before). Now: \
            \(now). If you did not move or update it, deny. If you approve, this file's fingerprint \
            replaces the recorded one, and later runs of it may run without asking, as this item's \
            settings allow.
            """,
            bundle: .module
        )
    }

    static func runMovedTo(_ path: String) -> String {
        String(
            localized: "approvals_run_moved_to",
            defaultValue: "moved to \(path)",
            bundle: .module
        )
    }

    static func wayKb(_ size: String) -> String {
        String(
            localized: "approvals_way_kb",
            defaultValue: "\(size) KB",
            bundle: .module
        )
    }

    static func wayMb(_ size: String) -> String {
        String(
            localized: "approvals_way_mb",
            defaultValue: "\(size) MB",
            bundle: .module
        )
    }

    static var runApprovedBefore: String {
        String(
            localized: "approvals_run_approved_before",
            defaultValue: "Approved before",
            bundle: .module
        )
    }

    static var runNow: String { String(localized: "approvals_run_now", defaultValue: "Now", bundle: .module) }
    static var runBatchFile: String {
        String(
            localized: "approvals_run_batch_file",
            defaultValue: """
            This is a Windows batch file. Its fingerprint covers this file only, not the programs it \
            starts (for an npm tool, node and its packages).
            """,
            bundle: .module
        )
    }

    static var runRunsCommands: String {
        String(
            localized: "approvals_run_runs_commands",
            defaultValue: "This program can run other commands given in its arguments. Read every argument.",
            bundle: .module
        )
    }

    static var wayApproved: String { String(localized: "approvals_way_approved", defaultValue: "Approved.", bundle: .module) }
    static func runPinRecorded(_ item: String) -> String {
        String(
            localized: "approvals_run_pin_recorded",
            defaultValue: "This program's fingerprint is now recorded for \(item).",
            bundle: .module
        )
    }

    static func proxyTitle(_ who: String, _ item: String, _ host: String, _ length: String) -> String {
        String(
            localized: "approvals_proxy_title",
            defaultValue: "\(who) wants to use \(item) with \(host) for \(length).",
            bundle: .module
        )
    }

    static func proxyBody(_ host: String) -> String {
        String(
            localized: "approvals_proxy_body",
            defaultValue: "The agent will not see it; the key is sent only to \(host).",
            bundle: .module
        )
    }

    static func proxySentAs(_ header: String, _ prefix: String) -> String {
        String(
            localized: "approvals_proxy_sent_as",
            defaultValue: "Sent as: \(header): \(prefix)••••••••",
            bundle: .module
        )
    }

    static func proxyEndsSooner(_ who: String) -> String {
        String(
            localized: "approvals_proxy_ends_sooner",
            defaultValue: "It may end sooner, when \(who)'s access ends.",
            bundle: .module
        )
    }

    static var wayScrollHint: String {
        String(
            localized: "approvals_way_scroll_hint",
            defaultValue: "Scroll to the end to approve.",
            bundle: .module
        )
    }

    static var wayReferred: String {
        String(
            localized: "approvals_way_referred",
            defaultValue: "Not done yet: something changed while you were deciding, so you are asked again.",
            bundle: .module
        )
    }

    static var runAskedAgain: String {
        String(
            localized: "approvals_run_asked_again",
            defaultValue: """
            Asked again. This item's settings or its recorded program changed while you were \
            deciding. Check the details again.
            """,
            bundle: .module
        )
    }

    static var proxyAskedAgain: String {
        String(
            localized: "approvals_proxy_asked_again",
            defaultValue: """
            Asked again. This item's API settings changed while you were deciding. Check the details \
            again.
            """,
            bundle: .module
        )
    }

    static var runProgramNotAllowed: String {
        String(
            localized: "approvals_run_program_not_allowed",
            defaultValue: "Approved, but this item no longer allows that program, so nothing was done.",
            bundle: .module
        )
    }

    static var runEnvNotAllowed: String {
        String(
            localized: "approvals_run_env_not_allowed",
            defaultValue: "Approved, but this program may no longer receive those variables, so nothing was done.",
            bundle: .module
        )
    }

    static var runCwdNotAllowed: String {
        String(
            localized: "approvals_run_cwd_not_allowed",
            defaultValue: "Approved, but that folder or file is no longer allowed for this item, so nothing was done.",
            bundle: .module
        )
    }

    static var runNotFound: String {
        String(
            localized: "approvals_run_not_found",
            defaultValue: "Approved, but the item or its field is gone, so the program was not run.",
            bundle: .module
        )
    }

    static var proxyNotFound: String {
        String(
            localized: "approvals_proxy_not_found",
            defaultValue: "Approved, but the item or its field is gone, so the key was not sent.",
            bundle: .module
        )
    }

    static func wayForbidden(_ who: String) -> String {
        String(
            localized: "approvals_way_forbidden",
            defaultValue: """
            Approved, but your vault refused it, so nothing was done. \(who) may no longer have a \
            permission that covers it, may be paused, or this request was asked again too many \
            times.
            """,
            bundle: .module
        )
    }

    static var wayExpired: String {
        String(
            localized: "approvals_way_expired",
            defaultValue: "This request expired, so nothing was done.",
            bundle: .module
        )
    }

    static func runArgumentsCount(_ count: Int) -> String {
        String(localized: "approvals_run_arguments_count", defaultValue: "\(count) arguments", bundle: .module)
    }

    static func runVariablesCount(_ count: Int) -> String {
        String(localized: "approvals_run_variables_count", defaultValue: "\(count) variables", bundle: .module)
    }

    static func wayBytes(_ count: Int) -> String {
        String(localized: "approvals_way_bytes", defaultValue: "\(count) bytes", bundle: .module)
    }

    static func waySeconds(_ count: Int) -> String {
        String(localized: "approvals_way_seconds", defaultValue: "\(count) seconds", bundle: .module)
    }

    static func durationMinutes(_ count: Int) -> String {
        String(localized: "approvals_duration_minutes", defaultValue: "\(count) minutes", bundle: .module)
    }

    static func durationHours(_ count: Int) -> String {
        String(localized: "approvals_duration_hours", defaultValue: "\(count) hours", bundle: .module)
    }

    /// A string that is empty, inside a sentence (the string rule's inline form puts it between markers).
    static var stringEmpty: String { String(localized: "approvals_string_empty", defaultValue: "(empty)", bundle: .module) }
}
