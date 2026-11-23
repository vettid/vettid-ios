import Foundation

// swiftlint:disable line_length

/// The texts of "How an agent may use an item" (ANDROID-PLAN 0.1.137 AA7; 0.1.138 for the refusal's fallback): every string of
/// vettid-android `feature/devices` `strings_item_ways.xml` that AA7 uses (those of AA9's folders are not here, and not built),
/// word for word under the same names, in `Localizable.xcstrings`. Each is the plan's NEW text, approved by the owner on
/// 2026-11-22 (GC #16443), or a draft of AGENT-PLAN §11, or marked "new (app)": a text the plan does not give and the owner has not
/// approved. A changed text is the owner's to approve (``ItemWaysStringsTests``).
public enum ItemWaysStrings {
    public static var waysItemsTitle: String {
        String(localized: "ways_items_title", defaultValue: "Items it may use", bundle: .module)
    }

    public static var waysItemGone: String {
        String(localized: "ways_item_gone", defaultValue: "An item you no longer have", bundle: .module)
    }

    /// New (app): a text the plan does not give; not yet approved.
    public static var waysItemLoading: String {
        String(localized: "ways_item_loading", defaultValue: "Loading…", bundle: .module)
    }

    /// New (app): a text the plan does not give; not yet approved.
    public static var waysItemsFailed: String {
        String(localized: "ways_items_failed", defaultValue: "These items could not be loaded.", bundle: .module)
    }

    public static var waysShortUse: String {
        String(localized: "ways_short_use", defaultValue: "Use without seeing it", bundle: .module)
    }

    public static var waysShortRun: String {
        String(localized: "ways_short_run", defaultValue: "Run programs", bundle: .module)
    }

    public static var waysShortProxy: String {
        String(localized: "ways_short_proxy", defaultValue: "Send to an API", bundle: .module)
    }

    public static var waysShortReveal: String {
        String(localized: "ways_short_reveal", defaultValue: "May be shown", bundle: .module)
    }

    public static var waysShortJoin: String {
        String(localized: "ways_short_join", defaultValue: " · ", bundle: .module)
    }

    public static func waysTitle(_ a1: String, _ a2: String) -> String {
        String(localized: "ways_title", defaultValue: "How \(a1) may use \(a2)", bundle: .module)
    }

    public static var waysSave: String {
        String(localized: "ways_save", defaultValue: "Save", bundle: .module)
    }

    public static var waysUse: String {
        String(localized: "ways_use", defaultValue: "Use without seeing it", bundle: .module)
    }

    public static var waysUseNote: String {
        String(localized: "ways_use_note", defaultValue: "Your vault uses the value for the agent and gives it only the result.", bundle: .module)
    }

    public static var waysRun: String {
        String(localized: "ways_run", defaultValue: "Run programs with it", bundle: .module)
    }

    public static var waysProxy: String {
        String(localized: "ways_proxy", defaultValue: "Send it to an API for the agent", bundle: .module)
    }

    public static var waysReveal: String {
        String(localized: "ways_reveal", defaultValue: "May be shown to agents", bundle: .module)
    }

    public static var waysRevealNote: String {
        String(localized: "ways_reveal_note", defaultValue: "Off: the agent can use it without seeing it. On: the agent's app may keep the value in its history.", bundle: .module)
    }

    public static var waysTurnOff: String {
        String(localized: "ways_turn_off", defaultValue: "Turn off", bundle: .module)
    }

    public static var waysTurnOn: String {
        String(localized: "ways_turn_on", defaultValue: "Turn on", bundle: .module)
    }

    public static var waysCancel: String {
        String(localized: "ways_cancel", defaultValue: "Cancel", bundle: .module)
    }

    public static func waysRunOffTitle(_ a1: String) -> String {
        String(localized: "ways_run_off_title", defaultValue: "Stop runs with \(a1)?", bundle: .module)
    }

    public static var waysRunOffBodyFolders: String {
        String(localized: "ways_run_off_body_folders", defaultValue: "The programs you listed, their variables, their recorded fingerprints and the folders runs may use are removed.", bundle: .module)
    }

    public static var waysRunOffBody: String {
        String(localized: "ways_run_off_body", defaultValue: "The programs you listed, their variables and their recorded fingerprints are removed.", bundle: .module)
    }

    public static func waysProxyOffTitle(_ a1: String) -> String {
        String(localized: "ways_proxy_off_title", defaultValue: "Stop sending \(a1) to an API?", bundle: .module)
    }

    public static var waysProxyOffBody: String {
        String(localized: "ways_proxy_off_body", defaultValue: "The hosts and the header you set are removed.", bundle: .module)
    }

    public static func waysRevealOnTitle(_ a1: String, _ a2: String) -> String {
        String(localized: "ways_reveal_on_title", defaultValue: "Let \(a1) see \(a2)?", bundle: .module)
    }

    public static var waysRevealOnBody: String {
        String(localized: "ways_reveal_on_body", defaultValue: "You are asked each time before it sees the value. Once you approve, the value goes to the agent's app, which may keep it in its history or logs. It may also reach the AI service that the agent's app uses. VettID can't remove it from any of these places.", bundle: .module)
    }

    public static var waysProgramsTitle: String {
        String(localized: "ways_programs_title", defaultValue: "Programs it may run", bundle: .module)
    }

    public static var waysProgramsNone: String {
        String(localized: "ways_programs_none", defaultValue: "No programs listed. The agent may ask to run any program, and every run asks you.", bundle: .module)
    }

    public static var waysProgramNoVariables: String {
        String(localized: "ways_program_no_variables", defaultValue: "No variables", bundle: .module)
    }

    public static var waysAddProgram: String {
        String(localized: "ways_add_program", defaultValue: "Add a program", bundle: .module)
    }

    public static var waysProgramField: String {
        String(localized: "ways_program_field", defaultValue: "Program", bundle: .module)
    }

    public static var waysProgramHint: String {
        String(localized: "ways_program_hint", defaultValue: "A full path, such as /usr/bin/git or C:\\Program Files\\Git\\cmd\\git.exe, or a program name the connector finds on its own search path, such as git (on Windows, git.exe).", bundle: .module)
    }

    public static var waysProgramNotPath: String {
        String(localized: "ways_program_not_path", defaultValue: "Give a full path or a program name.", bundle: .module)
    }

    public static var waysProgramCharacters: String {
        String(localized: "ways_program_characters", defaultValue: "This can't hold a control or invisible character.", bundle: .module)
    }

    public static var waysProgramTooLong: String {
        String(localized: "ways_program_too_long", defaultValue: "At most 4,096 bytes.", bundle: .module)
    }

    public static var waysProgramParts: String {
        String(localized: "ways_program_parts", defaultValue: "A path can't hold an empty part, . or .., or a colon after the drive.", bundle: .module)
    }

    public static var waysProgramNetwork: String {
        String(localized: "ways_program_network", defaultValue: "A network path (\\\\server\\…) can't be used.", bundle: .module)
    }

    public static var waysProgramTilde: String {
        String(localized: "ways_program_tilde", defaultValue: "Remove the ~ from the program's name; on Windows, give its full long name.", bundle: .module)
    }

    public static var waysProgramDuplicate: String {
        String(localized: "ways_program_duplicate", defaultValue: "This program is already in the list.", bundle: .module)
    }

    public static var waysProgramTooMany: String {
        String(localized: "ways_program_too_many", defaultValue: "You can add at most 16 programs.", bundle: .module)
    }

    /// New (app): a text the plan does not give; not yet approved.
    public static var waysAdd: String {
        String(localized: "ways_add", defaultValue: "Add", bundle: .module)
    }

    public static var waysVariablesTitle: String {
        String(localized: "ways_variables_title", defaultValue: "Variables it may receive", bundle: .module)
    }

    public static var waysVariablesNone: String {
        String(localized: "ways_variables_none", defaultValue: "None. The agent can't give this program any other variables.", bundle: .module)
    }

    public static var waysRemove: String {
        String(localized: "ways_remove", defaultValue: "Remove", bundle: .module)
    }

    public static var waysAddVariable: String {
        String(localized: "ways_add_variable", defaultValue: "Add a variable", bundle: .module)
    }

    public static var waysVariableField: String {
        String(localized: "ways_variable_field", defaultValue: "Variable name", bundle: .module)
    }

    public static var waysVariableNote: String {
        String(localized: "ways_variable_note", defaultValue: "The agent can then give this program any value it chooses in this variable.", bundle: .module)
    }

    public static var waysVariableForm: String {
        String(localized: "ways_variable_form", defaultValue: "Capital letters, digits and _ only, not starting with a digit, at most 64.", bundle: .module)
    }

    public static var waysVariableTooMany: String {
        String(localized: "ways_variable_too_many", defaultValue: "At most 32 variables.", bundle: .module)
    }

    public static var waysRemoveProgram: String {
        String(localized: "ways_remove_program", defaultValue: "Remove program", bundle: .module)
    }

    public static var waysRemoveLastTitle: String {
        String(localized: "ways_remove_last_title", defaultValue: "Remove the last program?", bundle: .module)
    }

    public static func waysRemoveLastBody(_ a1: String) -> String {
        String(localized: "ways_remove_last_body", defaultValue: "With no programs listed, \(a1) may ask to run any program, and every run asks you.", bundle: .module)
    }

    public static var waysChangeProgramNote: String {
        String(localized: "ways_change_program_note", defaultValue: "Changing the program forgets its fingerprint.", bundle: .module)
    }

    public static func waysPinRecorded(_ a1: String, _ a2: String) -> String {
        String(localized: "ways_pin_recorded", defaultValue: "Fingerprint recorded: \(a1), at \(a2)", bundle: .module)
    }

    public static var waysPinForget: String {
        String(localized: "ways_pin_forget", defaultValue: "Forget fingerprint", bundle: .module)
    }

    public static var waysPinNone: String {
        String(localized: "ways_pin_none", defaultValue: "No fingerprint yet. The first run asks you, and approving it records that file.", bundle: .module)
    }

    public static var waysPinForgetTitle: String {
        String(localized: "ways_pin_forget_title", defaultValue: "Forget this fingerprint?", bundle: .module)
    }

    public static func waysPinForgetBody(_ a1: String) -> String {
        String(localized: "ways_pin_forget_body", defaultValue: "The next run of \(a1) asks you again, and approving it records the file then.", bundle: .module)
    }

    public static var waysPinForgetConfirm: String {
        String(localized: "ways_pin_forget_confirm", defaultValue: "Forget", bundle: .module)
    }

    public static var waysPinForgotten: String {
        String(localized: "ways_pin_forgotten", defaultValue: "Fingerprint forgotten when you save", bundle: .module)
    }

    /// New (app): a text the plan does not give; not yet approved.
    public static var waysPinClose: String {
        String(localized: "ways_pin_close", defaultValue: "Close", bundle: .module)
    }

    public static var waysEach: String {
        String(localized: "ways_each", defaultValue: "Ask me before each run", bundle: .module)
    }

    public static var waysEachNeedsProgram: String {
        String(localized: "ways_each_needs_program", defaultValue: "List a program to turn this off.", bundle: .module)
    }

    public static var waysEachOffTitle: String {
        String(localized: "ways_each_off_title", defaultValue: "Stop asking before each run?", bundle: .module)
    }

    public static func waysEachOffBody(_ a1: String) -> String {
        String(localized: "ways_each_off_body", defaultValue: "Runs of the listed programs then go ahead without asking you. \(a1) chooses the arguments each time, and you won't see them.", bundle: .module)
    }

    public static var waysEachOffHelp: String {
        String(localized: "ways_each_off_help", defaultValue: "A run of a listed program goes ahead without asking when its file matches the recorded fingerprint. A first or changed program, and runs in your folders or with files, still ask you every time. Shells, interpreters and launchers your vault recognizes by name still ask every time. Other programs that can run commands, such as git or npm, do not.", bundle: .module)
    }

    public static func waysRunsCommands(_ a1: String) -> String {
        String(localized: "ways_runs_commands", defaultValue: "\(a1) can run other commands given in its arguments, so the agent could use it to run any command with your secret. Asking before each run is safer for it.", bundle: .module)
    }

    public static var waysBatchFile: String {
        String(localized: "ways_batch_file", defaultValue: "This is a Windows batch file. Its fingerprint covers this file only, not the programs it starts (for an npm tool, node and its packages).", bundle: .module)
    }

    public static var waysHostsTitle: String {
        String(localized: "ways_hosts_title", defaultValue: "Hosts it may be sent to", bundle: .module)
    }

    public static var waysAddHost: String {
        String(localized: "ways_add_host", defaultValue: "Add a host", bundle: .module)
    }

    public static var waysHostField: String {
        String(localized: "ways_host_field", defaultValue: "Host", bundle: .module)
    }

    public static var waysHostHint: String {
        String(localized: "ways_host_hint", defaultValue: "A host name, such as api.example.com, with :port if it is not 443.", bundle: .module)
    }

    public static var waysHostNotHost: String {
        String(localized: "ways_host_not_host", defaultValue: "Give a host name, such as api.example.com.", bundle: .module)
    }

    public static var waysHostIp: String {
        String(localized: "ways_host_ip", defaultValue: "An IP address can't be used; give the host's name.", bundle: .module)
    }

    public static var waysHostLocal: String {
        String(localized: "ways_host_local", defaultValue: "localhost and names without a dot can't be used.", bundle: .module)
    }

    public static var waysHostWildcard: String {
        String(localized: "ways_host_wildcard", defaultValue: "Wildcards can't be used.", bundle: .module)
    }

    public static var waysHostDuplicate: String {
        String(localized: "ways_host_duplicate", defaultValue: "This host is already in the list.", bundle: .module)
    }

    public static var waysHostTooMany: String {
        String(localized: "ways_host_too_many", defaultValue: "You can add at most 8 hosts.", bundle: .module)
    }

    public static var waysHeaderField: String {
        String(localized: "ways_header_field", defaultValue: "Header name", bundle: .module)
    }

    public static var waysHeaderBad: String {
        String(localized: "ways_header_bad", defaultValue: "This header can't carry the key.", bundle: .module)
    }

    public static var waysPrefixField: String {
        String(localized: "ways_prefix_field", defaultValue: "Before the key", bundle: .module)
    }

    public static var waysPrefixBad: String {
        String(localized: "ways_prefix_bad", defaultValue: "At most 32 plain characters: letters, digits, spaces and punctuation.", bundle: .module)
    }

    public static func waysSentAs(_ a1: String, _ a2: String) -> String {
        String(localized: "ways_sent_as", defaultValue: "Sent as: \(a1): \(a2)••••••••", bundle: .module)
    }

    public static var waysSentNote: String {
        String(localized: "ways_sent_note", defaultValue: "The key is sent only to these hosts, over a verified connection. The agent is not given the key.", bundle: .module)
    }

    public static func waysPasswordBody(_ a1: String, _ a2: String) -> String {
        String(localized: "ways_password_body", defaultValue: "Letting \(a1) do more with \(a2) needs your credential password, so only you can do it. Enter your credential password.", bundle: .module)
    }

    public static var waysPasswordTitle: String {
        String(localized: "ways_password_title", defaultValue: "Confirm with your credential password", bundle: .module)
    }

    public static var waysPasswordLabel: String {
        String(localized: "ways_password_label", defaultValue: "Credential password", bundle: .module)
    }

    public static var waysPasswordConfirm: String {
        String(localized: "ways_password_confirm", defaultValue: "Confirm", bundle: .module)
    }

    public static var waysAlarmOpen: String {
        String(localized: "ways_alarm_open", defaultValue: "Open the alarm", bundle: .module)
    }

    public static var waysSaved: String {
        String(localized: "ways_saved", defaultValue: "Saved", bundle: .module)
    }

    public static var waysLockedAgain: String {
        String(localized: "ways_locked_again", defaultValue: "Your credential locked again before the settings were saved. Try again.", bundle: .module)
    }

    public static var waysConflict: String {
        String(localized: "ways_conflict", defaultValue: "Another device changed these settings. Here are the current ones.", bundle: .module)
    }

    public static func waysNotIncluded(_ a1: String) -> String {
        String(localized: "ways_not_included", defaultValue: "\(a1) can no longer use this item: none of its rules includes it.", bundle: .module)
    }

    /// New (plan 0.1.138, GC #16477): the plan's NEW fallback.
    public static func waysBadRequest(_ a1: String) -> String {
        String(localized: "ways_bad_request", defaultValue: "These settings could not be saved. Your vault answered: \(a1).", bundle: .module)
    }

    public static var waysBadRequestFallback: String {
        String(localized: "ways_bad_request_fallback", defaultValue: "These settings could not be saved: your vault refused one of them. Check the programs, the variables, the folders, the hosts, the header name and the prefix.", bundle: .module)
    }

    public static var waysAlarm: String {
        String(localized: "ways_alarm", defaultValue: "Settings can't be widened while a credential alarm is open", bundle: .module)
    }

    public static var waysReadOnly: String {
        String(localized: "ways_read_only", defaultValue: "This item has settings this version of VettID can't show. Update VettID to change them.", bundle: .module)
    }

    public static var waysReadOnlyLocked: String {
        String(localized: "ways_read_only_locked", defaultValue: "Your vault asked for your credential password for this change, so it was not saved. Update VettID to change these settings.", bundle: .module)
    }

    public static var waysChangedElsewhere: String {
        String(localized: "ways_changed_elsewhere", defaultValue: "Another device changed these settings.", bundle: .module)
    }

    public static var waysShowCurrent: String {
        String(localized: "ways_show_current", defaultValue: "Show the current ones", bundle: .module)
    }

    /// New (app): a text the plan does not give; not yet approved.
    public static var waysLoadFailed: String {
        String(localized: "ways_load_failed", defaultValue: "These settings could not be loaded.", bundle: .module)
    }

    /// New (app): a text the plan does not give; not yet approved.
    public static var waysRetry: String {
        String(localized: "ways_retry", defaultValue: "Try again", bundle: .module)
    }

    /// New (app): a text the plan does not give; not yet approved.
    public static var waysWindowTitle: String {
        String(localized: "ways_window_title", defaultValue: "The unlock window may still be open", bundle: .module)
    }

    /// New (app): a text the plan does not give; not yet approved.
    public static var waysWindowPlain: String {
        String(localized: "ways_window_plain", defaultValue: "VettID could not close the credential unlock window after saving these settings. It closes by itself.", bundle: .module)
    }

    /// New (app): a text the plan does not give; not yet approved.
    public static var waysWindowClose: String {
        String(localized: "ways_window_close", defaultValue: "Close it now", bundle: .module)
    }

    /// Android's `core_ui_string_empty` (the string rule of AA8, shared with the approvals).
    public static var waysStringEmpty: String {
        String(localized: "ways_string_empty", defaultValue: "(empty)", bundle: .module)
    }

    /// Android's `core_ui_string_escaped` (the string rule of AA8, shared with the approvals).
    public static func waysStringEscaped(_ a1: String) -> String {
        String(localized: "ways_string_escaped", defaultValue: "escaped character \(a1)", bundle: .module)
    }

    /// Android's `core_ui_string_lookalike` (the string rule of AA8, shared with the approvals).
    public static var waysStringLookalike: String {
        String(localized: "ways_string_lookalike", defaultValue: "Some characters here may look like others.", bundle: .module)
    }

    /// New (app): "…not been used for N minute(s)." (the plural of the catalog).
    public static func waysWindowOpen(_ a1: Int) -> String {
        String(localized: "ways_window_open", defaultValue: "VettID could not close the credential unlock window after saving these settings. It closes by itself once it has not been used for \(a1) minutes.", bundle: .module)
    }

}
// swiftlint:enable line_length
