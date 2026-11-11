import Foundation
import Testing
@testable import VettIDDevices

// The table is long literal rows, one per text.
// swiftlint:disable line_length

/// The texts of ANDROID-PLAN 0.1.53 §4 "Devices & agents" (AA1) word for word, as vettid-android's `feature/devices`
/// `strings.xml` has them (the owner approved them on 2026-10-26; the unnamed agent and desktop are VAULT-MESSAGING 0.76.0 §10.8's;
/// a changed text is the owner's to approve). Every row is a text's key, what its accessor gives with the arguments "Example" (a name)
/// and 5 (a number), and the expected text.
@Suite struct DeviceStringsTests {
    struct Row {
        let key: String
        let got: String
        let want: String

        init(_ key: String, _ got: String, _ want: String) {
            self.key = key
            self.got = got
            self.want = want
        }
    }

    static let table: [Row] = [
        Row("devices_title", DeviceStrings.devicesTitle, "Devices & agents"),
        Row("devices_this_phone", DeviceStrings.devicesThisPhone, "This phone"),
        Row("devices_role_agent", DeviceStrings.devicesRoleAgent, "Agent"),
        Row("devices_role_desktop", DeviceStrings.devicesRoleDesktop, "Desktop"),
        Row("devices_role_phone", DeviceStrings.devicesRolePhone, "Phone"),
        Row("devices_name_with_role", DeviceStrings.devicesNameWithRole("Example", "Example"), "Example (Example)"),
        Row("devices_role_unknown", DeviceStrings.devicesRoleUnknown, "Device"),
        Row("devices_unnamed", DeviceStrings.devicesUnnamed("Example"), "Unnamed Example"),
        Row("devices_access_until", DeviceStrings.devicesAccessUntil("Example"), "Access until Example"),
        Row("devices_no_access", DeviceStrings.devicesNoAccess, "No access"),
        Row("devices_last_active", DeviceStrings.devicesLastActive("Example"), "Last active Example"),
        Row("devices_not_active_yet", DeviceStrings.devicesNotActiveYet, "Not active yet"),
        Row("devices_ago_now", DeviceStrings.devicesAgoNow, "just now"),
        Row("devices_ago_minutes", DeviceStrings.devicesAgoMinutes(5), "5 min ago"),
        Row("devices_ago_hours", DeviceStrings.devicesAgoHours(5), "5 h ago"),
        Row("devices_ago_days", DeviceStrings.devicesAgoDays(5), "5 d ago"),
        Row("devices_paused", DeviceStrings.devicesPaused, "Paused"),
        Row("devices_error_title", DeviceStrings.devicesErrorTitle, "Could not load your devices"),
        Row("devices_retry", DeviceStrings.devicesRetry, "Try again"),
        Row("devices_ok", DeviceStrings.devicesOk, "OK"),
        Row("devices_removed", DeviceStrings.devicesRemoved("Example"), "Example was removed"),
        Row("devices_name_by_agent", DeviceStrings.devicesNameByAgent, "Name given by the agent"),
        Row("devices_name_by_desktop", DeviceStrings.devicesNameByDesktop, "Name given by the desktop"),
        Row("devices_name_by_device", DeviceStrings.devicesNameByDevice, "Name given by the device"),
        Row("devices_about", DeviceStrings.devicesAbout, "About"),
        Row("devices_role", DeviceStrings.devicesRole, "Role"),
        Row("devices_paired_on", DeviceStrings.devicesPairedOn, "Paired on"),
        Row("devices_last_active_label", DeviceStrings.devicesLastActiveLabel, "Last active"),
        Row("devices_key", DeviceStrings.devicesKey, "Key fingerprint"),
        Row("devices_access", DeviceStrings.devicesAccess, "Access"),
        Row("devices_no_access_agent", DeviceStrings.devicesNoAccessAgent, "No access. When the agent needs access, it asks you in Approvals."),
        Row("devices_no_access_desktop", DeviceStrings.devicesNoAccessDesktop, "No access. When the desktop needs access, it asks you in Approvals."),
        Row("devices_agents_rule", DeviceStrings.devicesAgentsRule, "Agents act only while you allow access, and only within the permissions you give them."),
        Row("devices_end_access", DeviceStrings.devicesEndAccess, "End access"),
        Row("devices_access_ended", DeviceStrings.devicesAccessEnded, "Access ended"),
        Row("devices_history", DeviceStrings.devicesHistory, "History"),
        Row("devices_remove", DeviceStrings.devicesRemove, "Remove"),
        Row("devices_end_access_title", DeviceStrings.devicesEndAccessTitle("Example"), "End access for Example?"),
        Row("devices_end_access_body", DeviceStrings.devicesEndAccessBody, "It stops at once, and any of its requests still waiting for you are declined. It can ask for access again; you decide then."),
        Row("devices_end_failed_title", DeviceStrings.devicesEndFailedTitle, "Access not ended"),
        Row("devices_remove_failed_title", DeviceStrings.devicesRemoveFailedTitle, "Not removed"),
        Row("devices_end_failed", DeviceStrings.devicesEndFailed("Example"), "Access for Example could not be ended. Try again."),
        Row("devices_remove_title", DeviceStrings.devicesRemoveTitle("Example"), "Remove Example?"),
        Row("devices_remove_agent_body", DeviceStrings.devicesRemoveAgentBody, "It loses access to your vault at once and cannot connect again. Its permissions and its share rules are deleted."),
        Row("devices_remove_agent_services", DeviceStrings.devicesRemoveAgentServices("Example"), "Services it showed a permission to may accept it for up to Example."),
        Row("devices_remove_agent_again", DeviceStrings.devicesRemoveAgentAgain, "To use this agent again, pair it again."),
        Row("devices_remove_desktop_body", DeviceStrings.devicesRemoveDesktopBody, "It loses access to your vault at once and cannot connect again. To use it again, pair it again."),
        Row("devices_remove_failed", DeviceStrings.devicesRemoveFailed("Example"), "Example could not be removed. Try again."),
        Row("devices_an_agent", DeviceStrings.devicesAnAgent, "an agent"),
        Row("devices_a_desktop", DeviceStrings.devicesADesktop, "a desktop"),
        Row("devices_a_desktop_cap", DeviceStrings.devicesADesktopCap, "A desktop"),
        Row("devices_an_agent_cap", DeviceStrings.devicesAnAgentCap, "An agent"),
        Row("devices_pair", DeviceStrings.devicesPair, "Pair an agent"),
        Row("pair_title", DeviceStrings.pairTitle, "Pair an agent"),
        Row("pair_code_body", DeviceStrings.pairCodeBody, "Copy this code to the computer where the agent runs. It works once and expires in 10 minutes."),
        Row("pair_qr_cd", DeviceStrings.pairQrCd, "Pairing code as a QR code"),
        Row("pair_creating", DeviceStrings.pairCreating, "Making a pairing code"),
        Row("pair_clip_label", DeviceStrings.pairClipLabel, "Pairing code"),
        Row("pair_copy", DeviceStrings.pairCopy, "Copy"),
        Row("pair_copied", DeviceStrings.pairCopied, "Copied"),
        Row("pair_share", DeviceStrings.pairShare, "Share"),
        Row("pair_share_title", DeviceStrings.pairShareTitle, "Send it only to yourself."),
        Row("pair_expires_in", DeviceStrings.pairExpiresIn("Example"), "Expires in Example"),
        Row("pair_expired", DeviceStrings.pairExpired, "This code expired."),
        Row("pair_new_code", DeviceStrings.pairNewCode, "New code"),
        Row("pair_cancel", DeviceStrings.pairCancel, "Cancel"),
        Row("pair_create_failed", DeviceStrings.pairCreateFailed, "A pairing code could not be made. Try again."),
        Row("pair_try_again", DeviceStrings.pairTryAgain, "Try again"),
        Row("pair_check_now", DeviceStrings.pairCheckNow, "Check now"),
        Row("pair_compare_title", DeviceStrings.pairCompareTitle, "Compare the code"),
        Row("pair_compare_body", DeviceStrings.pairCompareBody("Example"), "Does the agent show Example? Approve only if the codes match."),
        Row("pair_calls_itself", DeviceStrings.pairCallsItself("Example"), "It calls itself Example."),
        Row("pair_calls_itself_note", DeviceStrings.pairCallsItselfNote, "The code proves this phone talks to the agent you just gave the code to. The name is only what the agent says about itself."),
        Row("pair_codes_match", DeviceStrings.pairCodesMatch, "The codes match"),
        Row("pair_codes_differ", DeviceStrings.pairCodesDiffer, "They don't match"),
        Row("pair_reject", DeviceStrings.pairReject, "Reject"),
        Row("pair_cannot_compare", DeviceStrings.pairCannotCompare, "This phone can't show a code to compare for this pairing, so it can't be approved. Reject it."),
        Row("pair_rejected_title", DeviceStrings.pairRejectedTitle, "Pairing rejected"),
        Row("pair_rejected_body", DeviceStrings.pairRejectedBody, "The agent is told it was rejected. If you did not expect a code, someone else may have the pairing code; it no longer works."),
        Row("pair_rejected_unsent", DeviceStrings.pairRejectedUnsent, "Nothing is paired. Your vault could not be told, so the pairing ends by itself within 10 minutes. If you did not expect a code, someone else may have the pairing code."),
        Row("pair_done", DeviceStrings.pairDone, "Done"),
        Row("pair_lost_title", DeviceStrings.pairLostTitle, "A device asks to pair"),
        Row("pair_lost_body", DeviceStrings.pairLostBody, "This pairing can't be checked on this phone any more. Let it expire: it ends by itself within 10 minutes and nothing is paired. If you want to pair, start again."),
        Row("pair_allow_title", DeviceStrings.pairAllowTitle, "Allow access now?"),
        Row("pair_allow_body", DeviceStrings.pairAllowBody, "Agents act only while you allow access, and only within the permissions you give them."),
        Row("pair_session_none", DeviceStrings.pairSessionNone, "No access yet"),
        Row("pair_session_15m", DeviceStrings.pairSession15m, "15 minutes"),
        Row("pair_session_1h", DeviceStrings.pairSession1h, "1 hour"),
        Row("pair_session_4h", DeviceStrings.pairSession4h, "4 hours"),
        Row("pair_session_8h", DeviceStrings.pairSession8h, "8 hours"),
        Row("pair_session_24h", DeviceStrings.pairSession24h, "24 hours"),
        Row("pair_confirm", DeviceStrings.pairConfirm, "Pair"),
        Row("pair_ended_title", DeviceStrings.pairEndedTitle, "Not paired"),
        Row("pair_ended", DeviceStrings.pairEnded, "This pairing has ended. Start again from Devices & agents."),
        Row("pair_unconfirmed_title", DeviceStrings.pairUnconfirmedTitle, "Pairing not confirmed"),
        Row("pair_unconfirmed_body", DeviceStrings.pairUnconfirmedBody("Example"), "Your vault did not answer. If Example is listed in Devices & agents, it was paired; if not, start again."),
        Row("pair_paired_title", DeviceStrings.pairPairedTitle("Example"), "Example is paired"),
        Row("pair_paired_body", DeviceStrings.pairPairedBody, "It can't use any of your items yet."),
        Row("pair_open_page", DeviceStrings.pairOpenPage, "Open its page"),
        Row("devices_pair_new", DeviceStrings.devicesPairNew, "Pair an agent or desktop"),
        Row("devices_empty_title_any", DeviceStrings.devicesEmptyTitleAny, "Nothing paired yet"),
        Row("devices_empty_body_any", DeviceStrings.devicesEmptyBodyAny, "Pair VettID on your computer, or pair an agent to let an AI assistant use items you choose. They act only while you allow access."),
        Row("devices_pair_desktop", DeviceStrings.devicesPairDesktop, "Pair a desktop"),
        Row("pair_title_desktop", DeviceStrings.pairTitleDesktop, "Pair a desktop"),
        Row("pair_code_body_desktop", DeviceStrings.pairCodeBodyDesktop, "Copy this code into VettID on your computer. It works once and expires in 10 minutes."),
        Row("pair_compare_body_desktop", DeviceStrings.pairCompareBodyDesktop("Example"), "Does the desktop show Example? Approve only if the codes match."),
        Row("pair_calls_itself_note_desktop", DeviceStrings.pairCallsItselfNoteDesktop, "The code proves this phone talks to the desktop you just gave the code to. The name is only what the desktop says about itself."),
        Row("pair_rejected_body_desktop", DeviceStrings.pairRejectedBodyDesktop, "The desktop is told it was rejected. If you did not expect a code, someone else may have the pairing code; it no longer works."),
        Row("pair_allow_body_desktop", DeviceStrings.pairAllowBodyDesktop, "A desktop acts only while you allow access."),
        Row("pair_paired_body_desktop", DeviceStrings.pairPairedBodyDesktop, "When it asks for access, the request comes to Approvals."),
        Row("pair_minutes_left", DeviceStrings.pairMinutesLeft(5), "5 minutes left"),
    ]

    @Test func everyTextIsWordForWord() {
        #expect(Self.table.count == 111)
        for row in Self.table { #expect(row.got == row.want, "\(row.key)") }
    }

    /// The catalog holds exactly the keys of the table: no text without a row, no row without a text.
    @Test func theTableHoldsEveryKeyOfTheCatalog() throws {
        let doc = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: Self.catalog)) as? [String: Any])
        let keys = Set(try #require((doc["strings"] as? [String: Any])?.keys))
        #expect(keys == Set(Self.table.map(\.key)))
        #expect(Set(Self.table.map(\.key)).count == Self.table.count)
    }

    /// The source catalog.
    static var catalog: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/VettIDDevices/Resources/Localizable.xcstrings")
    }

    /// AA2 replaces AA1's empty state ("No agents yet") with the one of vettid-android #291: "Nothing paired yet", for agents and
    /// desktops alike. Its texts, and every desktop text, are new in #291: not in the plan and not yet approved there.
    @Test func theEmptyStateIsNothingPairedYetAndTheOldOneIsGone() {
        #expect(DeviceStrings.devicesEmptyTitleAny == "Nothing paired yet")
        #expect(DeviceStrings.devicesEmptyBodyAny == "Pair VettID on your computer, or pair an agent to let an AI assistant use items you choose. They act only while you allow access.")
        #expect(!Self.table.contains { $0.key == "devices_empty_title" || $0.key == "devices_empty_body" })
    }

    /// "N minutes left" has its singular (the screen reader's once-a-minute line).
    @Test func theMinutesLeftHasASingularAndAPlural() {
        #expect(DeviceStrings.pairMinutesLeft(1) == "1 minute left")
        #expect(DeviceStrings.pairMinutesLeft(0) == "0 minutes left")
        #expect(DeviceStrings.pairMinutesLeft(10) == "10 minutes left")
    }

    /// AA4's "Choose what it may use" and "Later", and the chooser's "Menu open" and "Menu closed" (a TalkBack workaround; the
    /// iPhone's menu says it is one), are not here.
    @Test func whatIsNotBuiltIsNotThere() {
        for key in ["pair_choose", "pair_later", "devices_pair_menu_open", "devices_pair_menu_closed"] {
            #expect(!Self.table.contains { $0.key == key }, "\(key)")
        }
    }
}
// swiftlint:enable line_length
