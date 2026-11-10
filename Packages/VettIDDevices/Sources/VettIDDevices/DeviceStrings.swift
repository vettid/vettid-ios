import Foundation

// swiftlint:disable line_length

/// The texts of the Devices & agents screens: every string of vettid-android `feature/devices` `strings.xml` that AA1 (ANDROID-PLAN 0.1.53)
/// uses, with the unnamed agent and desktop of the received-text cleaning (VAULT-MESSAGING 0.76.0 §10.8), word for word under the
/// same names, in `Localizable.xcstrings`. A changed text is the owner's to approve (``DeviceStringsTests``).
public enum DeviceStrings {
    /// The bundle of these texts (the tests read every key from it).
    public static var bundle: Bundle { .module }

    public static var devicesTitle: String {
        String(localized: "devices_title", defaultValue: "Devices & agents", bundle: .module)
    }

    public static var devicesThisPhone: String {
        String(localized: "devices_this_phone", defaultValue: "This phone", bundle: .module)
    }

    public static var devicesRoleAgent: String {
        String(localized: "devices_role_agent", defaultValue: "Agent", bundle: .module)
    }

    public static var devicesRoleDesktop: String {
        String(localized: "devices_role_desktop", defaultValue: "Desktop", bundle: .module)
    }

    public static var devicesRolePhone: String {
        String(localized: "devices_role_phone", defaultValue: "Phone", bundle: .module)
    }

    public static func devicesNameWithRole(_ a1: String, _ a2: String) -> String {
        String(localized: "devices_name_with_role", defaultValue: "\(a1) (\(a2))", bundle: .module)
    }

    public static var devicesRoleUnknown: String {
        String(localized: "devices_role_unknown", defaultValue: "Device", bundle: .module)
    }

    public static func devicesUnnamed(_ a1: String) -> String {
        String(localized: "devices_unnamed", defaultValue: "Unnamed \(a1)", bundle: .module)
    }

    public static func devicesAccessUntil(_ a1: String) -> String {
        String(localized: "devices_access_until", defaultValue: "Access until \(a1)", bundle: .module)
    }

    public static var devicesNoAccess: String {
        String(localized: "devices_no_access", defaultValue: "No access", bundle: .module)
    }

    public static func devicesLastActive(_ a1: String) -> String {
        String(localized: "devices_last_active", defaultValue: "Last active \(a1)", bundle: .module)
    }

    public static var devicesNotActiveYet: String {
        String(localized: "devices_not_active_yet", defaultValue: "Not active yet", bundle: .module)
    }

    public static var devicesAgoNow: String {
        String(localized: "devices_ago_now", defaultValue: "just now", bundle: .module)
    }

    public static func devicesAgoMinutes(_ a1: Int) -> String {
        String(localized: "devices_ago_minutes", defaultValue: "\(a1) min ago", bundle: .module)
    }

    public static func devicesAgoHours(_ a1: Int) -> String {
        String(localized: "devices_ago_hours", defaultValue: "\(a1) h ago", bundle: .module)
    }

    public static func devicesAgoDays(_ a1: Int) -> String {
        String(localized: "devices_ago_days", defaultValue: "\(a1) d ago", bundle: .module)
    }

    public static var devicesPaused: String {
        String(localized: "devices_paused", defaultValue: "Paused", bundle: .module)
    }

    public static var devicesEmptyTitle: String {
        String(localized: "devices_empty_title", defaultValue: "No agents yet", bundle: .module)
    }

    public static var devicesEmptyBody: String {
        String(localized: "devices_empty_body", defaultValue: "Pair an agent to let an AI assistant on your computer use items you choose. It acts only while you allow it.", bundle: .module)
    }

    public static var devicesErrorTitle: String {
        String(localized: "devices_error_title", defaultValue: "Could not load your devices", bundle: .module)
    }

    public static var devicesRetry: String {
        String(localized: "devices_retry", defaultValue: "Try again", bundle: .module)
    }

    public static var devicesOk: String {
        String(localized: "devices_ok", defaultValue: "OK", bundle: .module)
    }

    public static func devicesRemoved(_ a1: String) -> String {
        String(localized: "devices_removed", defaultValue: "\(a1) was removed", bundle: .module)
    }

    public static var devicesNameByAgent: String {
        String(localized: "devices_name_by_agent", defaultValue: "Name given by the agent", bundle: .module)
    }

    public static var devicesNameByDesktop: String {
        String(localized: "devices_name_by_desktop", defaultValue: "Name given by the desktop", bundle: .module)
    }

    public static var devicesNameByDevice: String {
        String(localized: "devices_name_by_device", defaultValue: "Name given by the device", bundle: .module)
    }

    public static var devicesAbout: String {
        String(localized: "devices_about", defaultValue: "About", bundle: .module)
    }

    public static var devicesRole: String {
        String(localized: "devices_role", defaultValue: "Role", bundle: .module)
    }

    public static var devicesPairedOn: String {
        String(localized: "devices_paired_on", defaultValue: "Paired on", bundle: .module)
    }

    public static var devicesLastActiveLabel: String {
        String(localized: "devices_last_active_label", defaultValue: "Last active", bundle: .module)
    }

    public static var devicesKey: String {
        String(localized: "devices_key", defaultValue: "Key fingerprint", bundle: .module)
    }

    public static var devicesAccess: String {
        String(localized: "devices_access", defaultValue: "Access", bundle: .module)
    }

    public static var devicesNoAccessAgent: String {
        String(localized: "devices_no_access_agent", defaultValue: "No access. When the agent needs access, it asks you in Approvals.", bundle: .module)
    }

    public static var devicesNoAccessDesktop: String {
        String(localized: "devices_no_access_desktop", defaultValue: "No access. When the desktop needs access, it asks you in Approvals.", bundle: .module)
    }

    public static var devicesAgentsRule: String {
        String(localized: "devices_agents_rule", defaultValue: "Agents act only while you allow access, and only within the permissions you give them.", bundle: .module)
    }

    public static var devicesEndAccess: String {
        String(localized: "devices_end_access", defaultValue: "End access", bundle: .module)
    }

    public static var devicesAccessEnded: String {
        String(localized: "devices_access_ended", defaultValue: "Access ended", bundle: .module)
    }

    public static var devicesHistory: String {
        String(localized: "devices_history", defaultValue: "History", bundle: .module)
    }

    public static var devicesRemove: String {
        String(localized: "devices_remove", defaultValue: "Remove", bundle: .module)
    }

    public static func devicesEndAccessTitle(_ a1: String) -> String {
        String(localized: "devices_end_access_title", defaultValue: "End access for \(a1)?", bundle: .module)
    }

    public static var devicesEndAccessBody: String {
        String(localized: "devices_end_access_body", defaultValue: "It stops at once, and any of its requests still waiting for you are declined. It can ask for access again; you decide then.", bundle: .module)
    }

    public static var devicesEndFailedTitle: String {
        String(localized: "devices_end_failed_title", defaultValue: "Access not ended", bundle: .module)
    }

    public static var devicesRemoveFailedTitle: String {
        String(localized: "devices_remove_failed_title", defaultValue: "Not removed", bundle: .module)
    }

    public static func devicesEndFailed(_ a1: String) -> String {
        String(localized: "devices_end_failed", defaultValue: "Access for \(a1) could not be ended. Try again.", bundle: .module)
    }

    public static func devicesRemoveTitle(_ a1: String) -> String {
        String(localized: "devices_remove_title", defaultValue: "Remove \(a1)?", bundle: .module)
    }

    public static var devicesRemoveAgentBody: String {
        String(localized: "devices_remove_agent_body", defaultValue: "It loses access to your vault at once and cannot connect again. Its permissions and its share rules are deleted.", bundle: .module)
    }

    public static func devicesRemoveAgentServices(_ a1: String) -> String {
        String(localized: "devices_remove_agent_services", defaultValue: "Services it showed a permission to may accept it for up to \(a1).", bundle: .module)
    }

    public static var devicesRemoveAgentAgain: String {
        String(localized: "devices_remove_agent_again", defaultValue: "To use this agent again, pair it again.", bundle: .module)
    }

    public static var devicesRemoveDesktopBody: String {
        String(localized: "devices_remove_desktop_body", defaultValue: "It loses access to your vault at once and cannot connect again. To use it again, pair it again.", bundle: .module)
    }

    public static func devicesRemoveFailed(_ a1: String) -> String {
        String(localized: "devices_remove_failed", defaultValue: "\(a1) could not be removed. Try again.", bundle: .module)
    }

    public static var devicesAnAgent: String {
        String(localized: "devices_an_agent", defaultValue: "an agent", bundle: .module)
    }

    public static var devicesADesktop: String {
        String(localized: "devices_a_desktop", defaultValue: "a desktop", bundle: .module)
    }

    public static var devicesADesktopCap: String {
        String(localized: "devices_a_desktop_cap", defaultValue: "A desktop", bundle: .module)
    }

    public static var devicesAnAgentCap: String {
        String(localized: "devices_an_agent_cap", defaultValue: "An agent", bundle: .module)
    }
}
// swiftlint:enable line_length
