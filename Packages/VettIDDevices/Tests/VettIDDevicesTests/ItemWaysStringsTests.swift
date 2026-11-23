import Foundation
import Testing
@testable import VettIDDevices

// The table is long literal rows, one per text.
// swiftlint:disable line_length

/// The texts of ANDROID-PLAN 0.1.137 §4 "How an agent may use an item (AA7)" (and 0.1.138's fallback for a refusal) word for word,
/// as vettid-android's `feature/devices` `strings_item_ways.xml` has them on `master` (AA9's folders are not built here). Each is
/// the plan's NEW text approved by the owner on 2026-11-22 (GC #16443), an AGENT-PLAN §11 draft, or marked new (app) and not yet
/// approved; a changed text is the owner's to approve. Every row is a text's key, what its accessor gives with the arguments
/// "Example" (a name) and 5 (a number), and the expected text.
@Suite struct ItemWaysStringsTests {
    typealias Row = DeviceStringsTests.Row

    static let table: [Row] = [
        Row("ways_items_title", ItemWaysStrings.waysItemsTitle, "Items it may use"),
        Row("ways_item_gone", ItemWaysStrings.waysItemGone, "An item you no longer have"),
        Row("ways_item_loading", ItemWaysStrings.waysItemLoading, "Loading…"),
        Row("ways_items_failed", ItemWaysStrings.waysItemsFailed, "These items could not be loaded."),
        Row("ways_short_use", ItemWaysStrings.waysShortUse, "Use without seeing it"),
        Row("ways_short_run", ItemWaysStrings.waysShortRun, "Run programs"),
        Row("ways_short_proxy", ItemWaysStrings.waysShortProxy, "Send to an API"),
        Row("ways_short_reveal", ItemWaysStrings.waysShortReveal, "May be shown"),
        Row("ways_short_join", ItemWaysStrings.waysShortJoin, " · "),
        Row("ways_title", ItemWaysStrings.waysTitle("Example", "Example"), "How Example may use Example"),
        Row("ways_save", ItemWaysStrings.waysSave, "Save"),
        Row("ways_use", ItemWaysStrings.waysUse, "Use without seeing it"),
        Row("ways_use_note", ItemWaysStrings.waysUseNote, "Your vault uses the value for the agent and gives it only the result."),
        Row("ways_run", ItemWaysStrings.waysRun, "Run programs with it"),
        Row("ways_proxy", ItemWaysStrings.waysProxy, "Send it to an API for the agent"),
        Row("ways_reveal", ItemWaysStrings.waysReveal, "May be shown to agents"),
        Row("ways_reveal_note", ItemWaysStrings.waysRevealNote, "Off: the agent can use it without seeing it. On: the agent's app may keep the value in its history."),
        Row("ways_turn_off", ItemWaysStrings.waysTurnOff, "Turn off"),
        Row("ways_turn_on", ItemWaysStrings.waysTurnOn, "Turn on"),
        Row("ways_cancel", ItemWaysStrings.waysCancel, "Cancel"),
        Row("ways_run_off_title", ItemWaysStrings.waysRunOffTitle("Example"), "Stop runs with Example?"),
        Row("ways_run_off_body_folders", ItemWaysStrings.waysRunOffBodyFolders, "The programs you listed, their variables, their recorded fingerprints and the folders runs may use are removed."),
        Row("ways_run_off_body", ItemWaysStrings.waysRunOffBody, "The programs you listed, their variables and their recorded fingerprints are removed."),
        Row("ways_proxy_off_title", ItemWaysStrings.waysProxyOffTitle("Example"), "Stop sending Example to an API?"),
        Row("ways_proxy_off_body", ItemWaysStrings.waysProxyOffBody, "The hosts and the header you set are removed."),
        Row("ways_reveal_on_title", ItemWaysStrings.waysRevealOnTitle("Example", "Example"), "Let Example see Example?"),
        Row("ways_reveal_on_body", ItemWaysStrings.waysRevealOnBody, "You are asked each time before it sees the value. Once you approve, the value goes to the agent's app, which may keep it in its history or logs. It may also reach the AI service that the agent's app uses. VettID can't remove it from any of these places."),
        Row("ways_programs_title", ItemWaysStrings.waysProgramsTitle, "Programs it may run"),
        Row("ways_programs_none", ItemWaysStrings.waysProgramsNone, "No programs listed. The agent may ask to run any program, and every run asks you."),
        Row("ways_program_no_variables", ItemWaysStrings.waysProgramNoVariables, "No variables"),
        Row("ways_add_program", ItemWaysStrings.waysAddProgram, "Add a program"),
        Row("ways_program_field", ItemWaysStrings.waysProgramField, "Program"),
        Row("ways_program_hint", ItemWaysStrings.waysProgramHint, "A full path, such as /usr/bin/git or C:\\Program Files\\Git\\cmd\\git.exe, or a program name the connector finds on its own search path, such as git (on Windows, git.exe)."),
        Row("ways_program_not_path", ItemWaysStrings.waysProgramNotPath, "Give a full path or a program name."),
        Row("ways_program_characters", ItemWaysStrings.waysProgramCharacters, "This can't hold a control or invisible character."),
        Row("ways_program_too_long", ItemWaysStrings.waysProgramTooLong, "At most 4,096 bytes."),
        Row("ways_program_parts", ItemWaysStrings.waysProgramParts, "A path can't hold an empty part, . or .., or a colon after the drive."),
        Row("ways_program_network", ItemWaysStrings.waysProgramNetwork, "A network path (\\\\server\\…) can't be used."),
        Row("ways_program_tilde", ItemWaysStrings.waysProgramTilde, "Remove the ~ from the program's name; on Windows, give its full long name."),
        Row("ways_program_duplicate", ItemWaysStrings.waysProgramDuplicate, "This program is already in the list."),
        Row("ways_program_too_many", ItemWaysStrings.waysProgramTooMany, "You can add at most 16 programs."),
        Row("ways_add", ItemWaysStrings.waysAdd, "Add"),
        Row("ways_variables_title", ItemWaysStrings.waysVariablesTitle, "Variables it may receive"),
        Row("ways_variables_none", ItemWaysStrings.waysVariablesNone, "None. The agent can't give this program any other variables."),
        Row("ways_remove", ItemWaysStrings.waysRemove, "Remove"),
        Row("ways_add_variable", ItemWaysStrings.waysAddVariable, "Add a variable"),
        Row("ways_variable_field", ItemWaysStrings.waysVariableField, "Variable name"),
        Row("ways_variable_note", ItemWaysStrings.waysVariableNote, "The agent can then give this program any value it chooses in this variable."),
        Row("ways_variable_form", ItemWaysStrings.waysVariableForm, "Capital letters, digits and _ only, not starting with a digit, at most 64."),
        Row("ways_variable_too_many", ItemWaysStrings.waysVariableTooMany, "At most 32 variables."),
        Row("ways_remove_program", ItemWaysStrings.waysRemoveProgram, "Remove program"),
        Row("ways_remove_last_title", ItemWaysStrings.waysRemoveLastTitle, "Remove the last program?"),
        Row("ways_remove_last_body", ItemWaysStrings.waysRemoveLastBody("Example"), "With no programs listed, Example may ask to run any program, and every run asks you."),
        Row("ways_change_program_note", ItemWaysStrings.waysChangeProgramNote, "Changing the program forgets its fingerprint."),
        Row("ways_pin_recorded", ItemWaysStrings.waysPinRecorded("Example", "Example"), "Fingerprint recorded: Example, at Example"),
        Row("ways_pin_forget", ItemWaysStrings.waysPinForget, "Forget fingerprint"),
        Row("ways_pin_none", ItemWaysStrings.waysPinNone, "No fingerprint yet. The first run asks you, and approving it records that file."),
        Row("ways_pin_forget_title", ItemWaysStrings.waysPinForgetTitle, "Forget this fingerprint?"),
        Row("ways_pin_forget_body", ItemWaysStrings.waysPinForgetBody("Example"), "The next run of Example asks you again, and approving it records the file then."),
        Row("ways_pin_forget_confirm", ItemWaysStrings.waysPinForgetConfirm, "Forget"),
        Row("ways_pin_forgotten", ItemWaysStrings.waysPinForgotten, "Fingerprint forgotten when you save"),
        Row("ways_pin_close", ItemWaysStrings.waysPinClose, "Close"),
        Row("ways_each", ItemWaysStrings.waysEach, "Ask me before each run"),
        Row("ways_each_needs_program", ItemWaysStrings.waysEachNeedsProgram, "List a program to turn this off."),
        Row("ways_each_off_title", ItemWaysStrings.waysEachOffTitle, "Stop asking before each run?"),
        Row("ways_each_off_body", ItemWaysStrings.waysEachOffBody("Example"), "Runs of the listed programs then go ahead without asking you. Example chooses the arguments each time, and you won't see them."),
        Row("ways_each_off_help", ItemWaysStrings.waysEachOffHelp, "A run of a listed program goes ahead without asking when its file matches the recorded fingerprint. A first or changed program, and runs in your folders or with files, still ask you every time. Shells, interpreters and launchers your vault recognizes by name still ask every time. Other programs that can run commands, such as git or npm, do not."),
        Row("ways_runs_commands", ItemWaysStrings.waysRunsCommands("Example"), "Example can run other commands given in its arguments, so the agent could use it to run any command with your secret. Asking before each run is safer for it."),
        Row("ways_batch_file", ItemWaysStrings.waysBatchFile, "This is a Windows batch file. Its fingerprint covers this file only, not the programs it starts (for an npm tool, node and its packages)."),
        Row("ways_hosts_title", ItemWaysStrings.waysHostsTitle, "Hosts it may be sent to"),
        Row("ways_add_host", ItemWaysStrings.waysAddHost, "Add a host"),
        Row("ways_host_field", ItemWaysStrings.waysHostField, "Host"),
        Row("ways_host_hint", ItemWaysStrings.waysHostHint, "A host name, such as api.example.com, with :port if it is not 443."),
        Row("ways_host_not_host", ItemWaysStrings.waysHostNotHost, "Give a host name, such as api.example.com."),
        Row("ways_host_ip", ItemWaysStrings.waysHostIp, "An IP address can't be used; give the host's name."),
        Row("ways_host_local", ItemWaysStrings.waysHostLocal, "localhost and names without a dot can't be used."),
        Row("ways_host_wildcard", ItemWaysStrings.waysHostWildcard, "Wildcards can't be used."),
        Row("ways_host_duplicate", ItemWaysStrings.waysHostDuplicate, "This host is already in the list."),
        Row("ways_host_too_many", ItemWaysStrings.waysHostTooMany, "You can add at most 8 hosts."),
        Row("ways_header_field", ItemWaysStrings.waysHeaderField, "Header name"),
        Row("ways_header_bad", ItemWaysStrings.waysHeaderBad, "This header can't carry the key."),
        Row("ways_prefix_field", ItemWaysStrings.waysPrefixField, "Before the key"),
        Row("ways_prefix_bad", ItemWaysStrings.waysPrefixBad, "At most 32 plain characters: letters, digits, spaces and punctuation."),
        Row("ways_sent_as", ItemWaysStrings.waysSentAs("Example", "Example"), "Sent as: Example: Example••••••••"),
        Row("ways_sent_note", ItemWaysStrings.waysSentNote, "The key is sent only to these hosts, over a verified connection. The agent is not given the key."),
        Row("ways_password_body", ItemWaysStrings.waysPasswordBody("Example", "Example"), "Letting Example do more with Example needs your credential password, so only you can do it. Enter your credential password."),
        Row("ways_password_title", ItemWaysStrings.waysPasswordTitle, "Confirm with your credential password"),
        Row("ways_password_label", ItemWaysStrings.waysPasswordLabel, "Credential password"),
        Row("ways_password_confirm", ItemWaysStrings.waysPasswordConfirm, "Confirm"),
        Row("ways_alarm_open", ItemWaysStrings.waysAlarmOpen, "Open the alarm"),
        Row("ways_saved", ItemWaysStrings.waysSaved, "Saved"),
        Row("ways_locked_again", ItemWaysStrings.waysLockedAgain, "Your credential locked again before the settings were saved. Try again."),
        Row("ways_conflict", ItemWaysStrings.waysConflict, "Another device changed these settings. Here are the current ones."),
        Row("ways_not_included", ItemWaysStrings.waysNotIncluded("Example"), "Example can no longer use this item: none of its rules includes it."),
        Row("ways_bad_request", ItemWaysStrings.waysBadRequest("Example"), "These settings could not be saved. Your vault answered: Example."),
        Row("ways_bad_request_fallback", ItemWaysStrings.waysBadRequestFallback, "These settings could not be saved: your vault refused one of them. Check the programs, the variables, the folders, the hosts, the header name and the prefix."),
        Row("ways_alarm", ItemWaysStrings.waysAlarm, "Settings can't be widened while a credential alarm is open"),
        Row("ways_read_only", ItemWaysStrings.waysReadOnly, "This item has settings this version of VettID can't show. Update VettID to change them."),
        Row("ways_read_only_locked", ItemWaysStrings.waysReadOnlyLocked, "Your vault asked for your credential password for this change, so it was not saved. Update VettID to change these settings."),
        Row("ways_changed_elsewhere", ItemWaysStrings.waysChangedElsewhere, "Another device changed these settings."),
        Row("ways_show_current", ItemWaysStrings.waysShowCurrent, "Show the current ones"),
        Row("ways_load_failed", ItemWaysStrings.waysLoadFailed, "These settings could not be loaded."),
        Row("ways_retry", ItemWaysStrings.waysRetry, "Try again"),
        Row("ways_window_title", ItemWaysStrings.waysWindowTitle, "The unlock window may still be open"),
        Row("ways_window_plain", ItemWaysStrings.waysWindowPlain, "VettID could not close the credential unlock window after saving these settings. It closes by itself."),
        Row("ways_window_close", ItemWaysStrings.waysWindowClose, "Close it now"),
        Row("ways_string_empty", ItemWaysStrings.waysStringEmpty, "(empty)"),
        Row("ways_string_escaped", ItemWaysStrings.waysStringEscaped("Example"), "escaped character Example"),
        Row("ways_string_lookalike", ItemWaysStrings.waysStringLookalike, "Some characters here may look like others."),
        Row("ways_window_open", ItemWaysStrings.waysWindowOpen(5), "VettID could not close the credential unlock window after saving these settings. It closes by itself once it has not been used for 5 minutes."),
    ]

    static var keys: Set<String> { Set(table.map(\.key)) }

    @Test func everyTextIsWordForWord() {
        #expect(Self.table.count == 110)
        for row in Self.table { #expect(row.got == row.want, "\(row.key)") }
    }

    /// The catalog holds the keys of these texts, and AA9's folders have none yet.
    @Test func theCatalogHoldsTheseKeysAndNoFolders() throws {
        let doc = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: DeviceStringsTests.catalog)) as? [String: Any])
        let keys = Set(try #require((doc["strings"] as? [String: Any])?.keys))
        #expect(keys.filter { $0.hasPrefix("ways_") } == Self.keys)
        #expect(!Self.keys.contains { $0.hasPrefix("ways_folder") })
        #expect(Self.keys.count == Self.table.count)
    }

    /// "N minute(s)": the catalog has the singular and the plural.
    @Test func theWindowTextHasASingularAndAPlural() {
        #expect(ItemWaysStrings.waysWindowOpen(1).hasSuffix("not been used for 1 minute."))
        #expect(ItemWaysStrings.waysWindowOpen(2).hasSuffix("not been used for 2 minutes."))
    }

    /// The texts with a name read as the plan's examples do.
    @Test func theSentencesNameTheAgentAndTheItem() {
        #expect(ItemWaysStrings.waysTitle("Claude", "GitHub token") == "How Claude may use GitHub token")
        #expect(ItemWaysStrings.waysRevealOnTitle("Claude", "GitHub token") == "Let Claude see GitHub token?")
        #expect(ItemWaysStrings.waysSentAs("Authorization", "Bearer ") == "Sent as: Authorization: Bearer ••••••••")
        #expect(
            ItemWaysStrings.waysPasswordBody("Claude", "GitHub token")
                == "Letting Claude do more with GitHub token needs your credential password, so only you can do it. Enter your credential password."
        )
        #expect(ItemWaysStrings.waysBadRequest("bad env") == "These settings could not be saved. Your vault answered: bad env.")
        #expect(
            ItemWaysStrings.waysRunsCommands("git")
                == "git can run other commands given in its arguments, so the agent could use it to run any command with your secret. Asking before each run is safer for it."
        )
        #expect(ItemWaysStrings.waysPinRecorded("1a2b 3c4d 5e6f 7a8b", "/usr/bin/git") == "Fingerprint recorded: 1a2b 3c4d 5e6f 7a8b, at /usr/bin/git")
    }
}
// swiftlint:enable line_length
