import Foundation

/// (ANDROID-PLAN 0.1.145, 0.1.146) The connection a desktop's held block or removal names, as the connection list has it: listed
/// as active or stale, with a name the app holds (a person's "First Last", a service's own name), told apart from a namesake by
/// the day it was connected. Pure. Mirrors vettid-android `DesktopTargets`.
public enum DesktopTargets {
    /// How the rows show the connection: its [name] (cleaned), whether it is a [service], and [connectedOn], its `created_at`,
    /// only when another active or stale connection has the same shown name ("(connected <date>)").
    public struct Shown: Equatable, Sendable, CustomStringConvertible {
        public var name: String
        public var service: Bool
        public var connectedOn: Date?

        public init(name: String, service: Bool, connectedOn: Date? = nil) {
            self.name = name
            self.service = service
            self.connectedOn = connectedOn
        }

        /// Compared as bytes (see ``HeldApproval/==(_:_:)``).
        public static func == (a: Shown, b: Shown) -> Bool {
            a.name.sameBytes(b.name) && a.service == b.service && a.connectedOn == b.connectedOn
        }

        /// Never the name.
        public var description: String { "Shown" }
    }

    /// The connection [h] names in [cs], listed as active or stale with a name; nil otherwise.
    public static func target(_ h: DesktopConnection, _ cs: [ConnectionInfo]) -> ConnectionInfo? {
        cs.first { $0.id.sameBytes(h.connectionID) && live($0) }.flatMap { name($0) == nil ? nil : $0 }
    }

    /// The name a connection is shown by, cleaned (VAULT-MESSAGING §10.8): its ``ConnectionInfo/displayName``, a person's
    /// "First Last", a service's "First Last" or else its own name (ANDROID-PLAN 0.1.145). Nil when it has none, or none once
    /// cleaned ("Name not shared yet").
    public static func name(_ c: ConnectionInfo) -> String? { AccountNames.cleaned(c.displayName) }

    /// How [h]'s connection is shown, or nil for the deny-only row: not listed as active or stale, no name, or (0.1.146) a
    /// namesake the date cannot tell apart (a `created_at` of either that is missing, or the same day in [calendar]'s time zone).
    public static func shown(_ h: DesktopConnection, _ cs: [ConnectionInfo], calendar: Calendar = .current) -> Shown? {
        guard let t = target(h, cs), let name = name(t) else { return nil }
        let k = key(name)
        let namesakes = cs.filter { !$0.id.sameBytes(t.id) && live($0) && self.name($0).map(key) == k }
        if namesakes.isEmpty { return Shown(name: name, service: t.isService) }
        // The day in the phone's calendar, as the row shows it; two that read as one day there are not told apart (fail closed).
        guard let on = t.createdAt.map({ day($0, calendar) }) else { return nil }
        let apart = namesakes.allSatisfy { o in o.createdAt.map { day($0, calendar) != on } ?? false }
        return apart ? Shown(name: name, service: t.isService, connectedOn: t.createdAt) : nil
    }

    /// Whether [d] may be approved against [cs] as it is now: true for anything but a desktop's block or removal; for one, it was
    /// shown naming its connection as [target], and [cs] still names it the same way (not gone, renamed, out of active and stale,
    /// nor newly or no longer a namesake's).
    public static func resolved(
        _ d: DeviceRequest, _ target: Shown?, _ cs: [ConnectionInfo], calendar: Calendar = .current
    ) -> Bool {
        guard case .desktopConnection(let h)? = d.held else { return true }
        guard let target, let now = shown(h, cs, calendar: calendar) else { return false }
        return now == target
    }

    /// Two shown names are the same (0.1.146) when equal after cleaning (VAULT-MESSAGING §10.8 steps 1-3, one line), each run of
    /// White_Space one space, Unicode NFC and full case folding ("ẞ", "ß" and "SS" meet as "ss"; a dotless "ı" stays apart from
    /// "i"), as vettid-android's ICU folding.
    public static func key(_ name: String) -> String {
        var out = String.UnicodeScalarView()
        var space = false
        for u in (AccountNames.cleaned(name) ?? "").unicodeScalars {
            if u.properties.isWhitespace {
                space = true
            } else {
                if space, !out.isEmpty { out.append(" ") }
                space = false
                out.append(u)
            }
        }
        return String(out).precomposedStringWithCanonicalMapping
            .folding(options: .caseInsensitive, locale: nil).precomposedStringWithCanonicalMapping
    }

    private static func live(_ c: ConnectionInfo) -> Bool { c.state == .active || c.state == .stale }

    private static func day(_ d: Date, _ calendar: Calendar) -> DateComponents { calendar.dateComponents([.year, .month, .day], from: d) }
}
