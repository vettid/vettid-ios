import Foundation
import VettIDData

/// How the Devices & agents screens say a device's facts (ANDROID-PLAN 0.1.53 AA1): the role, the name as the list shows it and
/// as a sentence has it, the access and the last activity. A device's name is its own word, cleaned and never trusted: one that
/// could pass for "This phone" or "VettID" comes with its role. Mirrors vettid-android `DeviceText`.
public enum DeviceTexts {
    /// The longest "N d ago" before a date is shown instead.
    static let daysAsAgo = 30

    /// The role as shown: "Agent", "Desktop", or the vault's own `kind` text for a kind this app does not know (14d).
    public static func role(_ d: DeviceInfo) -> String {
        if d.isAgent { return DeviceStrings.devicesRoleAgent }
        if d.kind == DeviceInfo.kindDesktop { return DeviceStrings.devicesRoleDesktop }
        if d.thisPhone { return DeviceStrings.devicesThisPhone }
        if d.kind == DeviceInfo.kindApp { return DeviceStrings.devicesRolePhone }
        let kind = DeviceWire.cleanName(d.kind)
        return kind.isEmpty ? DeviceStrings.devicesRoleUnknown : kind
    }

    /// The name as shown in a heading or a row: a device with no name is "An agent" or "A desktop", else "Unnamed <role>". A
    /// self-asserted name that could pass for the phone itself or for VettID is shown with its role (compared by a key, so
    /// inner spaces, NBSP, ZWJ, fillers or U+2800 cannot slip past).
    public static func name(_ d: DeviceInfo) -> String {
        var unnamed: String?
        if d.isAgent {
            unnamed = DeviceStrings.devicesAnAgentCap
        } else if d.kind == DeviceInfo.kindDesktop {
            unnamed = DeviceStrings.devicesADesktopCap
        }
        return label(d.name, role: role(d), unnamed: unnamed)
    }

    /// [name] as a heading or a row has it: with no name, [unnamed] (else "Unnamed <role>"); a name that could pass for the phone or
    /// for VettID comes with its [role].
    private static func label(_ name: String, role: String, unnamed: String?) -> String {
        guard !name.isEmpty else { return unnamed ?? DeviceStrings.devicesUnnamed(role.lowercased()) }
        if AccountNames.couldPassFor(name, DeviceStrings.devicesThisPhone) || AccountNames.couldPassFor(name, "VettID") {
            return DeviceStrings.devicesNameWithRole(name, role)
        }
        return name
    }

    /// The agent a pairing shows, by the name it gave (already cleaned): as ``name(_:)``, for an agent not yet listed.
    public static func agentName(_ name: String) -> String {
        label(name, role: DeviceStrings.devicesRoleAgent, unnamed: DeviceStrings.devicesAnAgentCap)
    }

    /// The desktop a pairing shows, by the name it gave (already cleaned): as ``name(_:)``, for a desktop not yet listed.
    public static func desktopName(_ name: String) -> String {
        label(name, role: DeviceStrings.devicesRoleDesktop, unnamed: DeviceStrings.devicesADesktopCap)
    }

    /// The agent a pairing shows, inside a sentence: its name isolated, "an agent" when it gave none (§10.8).
    public static func sentenceAgent(_ name: String) -> String {
        name.isEmpty ? DeviceStrings.devicesAnAgent : AccountNames.isolate(agentName(name))
    }

    /// The desktop a pairing shows, inside a sentence: its name isolated, "a desktop" when it gave none (§10.8).
    public static func sentenceDesktop(_ name: String) -> String {
        name.isEmpty ? DeviceStrings.devicesADesktop : AccountNames.isolate(desktopName(name))
    }

    /// The agent a pairing shows at the start of a title: its name isolated, "An agent" (capital) when it gave none.
    public static func titleAgent(_ name: String) -> String { AccountNames.isolate(agentName(name)) }

    /// The desktop a pairing shows at the start of a title: its name isolated, "A desktop" (capital) when it gave none.
    public static func titleDesktop(_ name: String) -> String { AccountNames.isolate(desktopName(name)) }

    /// The name inside a sentence: bidirectionally isolated (a self-asserted name may run either way, §10.8); "an agent" or
    /// "a desktop" (lower case, no isolate) when it gave none.
    public static func sentenceName(_ d: DeviceInfo) -> String {
        if !d.name.isEmpty { return AccountNames.isolate(name(d)) }
        if d.isAgent { return DeviceStrings.devicesAnAgent }
        if d.kind == DeviceInfo.kindDesktop { return DeviceStrings.devicesADesktop }
        return AccountNames.isolate(name(d))
    }

    /// "Access until 15:40" (the date with it when not today), or "No access". In [calendar]'s zone (the phone's).
    public static func access(_ d: DeviceInfo, now: Date, calendar: Calendar = .current) -> String {
        guard let until = d.sessionExpiresAt, d.hasAccess(now) else { return DeviceStrings.devicesNoAccess }
        let sameDay = calendar.isDate(until, inSameDayAs: now)
        return DeviceStrings.devicesAccessUntil(sameDay ? time(until, calendar) : full(until, calendar))
    }

    /// "Last active 10 min ago", or "Not active yet".
    public static func lastActive(_ d: DeviceInfo, now: Date, calendar: Calendar = .current) -> String {
        guard let at = d.lastActiveAt else { return DeviceStrings.devicesNotActiveYet }
        return DeviceStrings.devicesLastActive(ago(at, now: now, calendar: calendar))
    }

    /// "just now", "5 min ago", "3 h ago", "2 d ago", and from 30 days the date.
    public static func ago(_ at: Date, now: Date, calendar: Calendar = .current) -> String {
        let seconds = now.timeIntervalSince(at)
        let minutes = Int(seconds / 60)
        let hours = Int(seconds / 3_600)
        let days = Int(seconds / 86_400)
        if minutes < 1 { return DeviceStrings.devicesAgoNow }
        if minutes < 60 { return DeviceStrings.devicesAgoMinutes(minutes) }
        if hours < 24 { return DeviceStrings.devicesAgoHours(hours) }
        if days < daysAsAgo { return DeviceStrings.devicesAgoDays(days) }
        return date(at, calendar)
    }

    /// A full date and time (the page's "Paired on", an access end on another day), in [calendar]'s zone.
    public static func full(_ d: Date, _ calendar: Calendar = .current) -> String {
        d.formatted(style(date: .abbreviated, time: .shortened, calendar))
    }

    static func time(_ d: Date, _ calendar: Calendar) -> String { d.formatted(style(date: .omitted, time: .shortened, calendar)) }

    static func date(_ d: Date, _ calendar: Calendar) -> String { d.formatted(style(date: .abbreviated, time: .omitted, calendar)) }

    private static func style(
        date: Date.FormatStyle.DateStyle, time: Date.FormatStyle.TimeStyle, _ calendar: Calendar
    ) -> Date.FormatStyle {
        Date.FormatStyle(date: date, time: time, locale: calendar.locale ?? .current, calendar: calendar, timeZone: calendar.timeZone)
    }
}
