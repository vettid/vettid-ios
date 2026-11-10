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
        Row("devices_empty_title", DeviceStrings.devicesEmptyTitle, "No agents yet"),
        Row("devices_empty_body", DeviceStrings.devicesEmptyBody, "Pair an agent to let an AI assistant on your computer use items you choose. It acts only while you allow it."),
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
    ]

    @Test func everyTextIsWordForWord() {
        #expect(Self.table.count == 54)
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

    /// What differs from master's texts: the empty state is AA1's "No agents yet", not "Nothing paired yet", and there is no
    /// pairing text at all (pairing is AA2).
    @Test func theAA1EmptyStateAndNoPairingTexts() {
        #expect(DeviceStrings.devicesEmptyTitle == "No agents yet")
        #expect(DeviceStrings.devicesEmptyBody == "Pair an agent to let an AI assistant on your computer use items you choose. It acts only while you allow it.")
        #expect(!Self.table.contains { $0.key.hasPrefix("pair_") || $0.key == "devices_pair" || $0.key.hasPrefix("devices_pair_") })
    }
}
// swiftlint:enable line_length
