import Foundation
import VettIDCrypto
import VettIDVault

/// A device of the member's vault as `device.list` shows it (VAULT-MESSAGING §10.3; ANDROID-PLAN 0.1.53 "Devices &
/// agents"). ``kind`` is read as the role (``isAgent``, ``isDesktop``); §10.3 does not list its values, so any other value is
/// listed with the desktops under its own text (decision 14d). ``name`` is the device's own, self-asserted `name`
/// (`profile.name`): the app never renames a device (decision 11). Held in memory only, while the vault is open; never
/// printed. Mirrors vettid-android `DeviceInfo`.
public struct DeviceInfo: Equatable, Sendable, Identifiable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public static let kindAgent = "agent"
    public static let kindDesktop = "desktop"
    public static let kindApp = "app"

    public let id: String
    public let kind: String
    public let name: String
    /// The device's identity key as sent (base64); shown as ``fingerprint``.
    public let ik: String?
    public let createdAt: Date?
    public let lastActiveAt: Date?
    /// When the access session ends; nil without one. Past it, the device has no access (``hasAccess(_:)``).
    public var sessionExpiresAt: Date?
    /// This phone's own entry: listed first, with no actions (it leaves only by a transfer or a recovery, §6.7).
    public let thisPhone: Bool
    /// The vault paused this agent (`leash.grant.list`'s `suspended`, §10.11).
    public var paused: Bool

    public init(
        id: String, kind: String, name: String, ik: String? = nil, createdAt: Date? = nil, lastActiveAt: Date? = nil,
        sessionExpiresAt: Date? = nil, thisPhone: Bool = false, paused: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.ik = ik
        self.createdAt = createdAt
        self.lastActiveAt = lastActiveAt
        self.sessionExpiresAt = sessionExpiresAt
        self.thisPhone = thisPhone
        self.paused = paused
    }

    public var isAgent: Bool { !thisPhone && kind == Self.kindAgent }

    /// Everything that is neither this phone nor an agent: a desktop, or a kind this app does not know.
    public var isDesktop: Bool { !thisPhone && kind != Self.kindAgent }

    /// The key's fingerprint (8 groups of 4 hex digits, as on a connection's page); nil when `ik` does not read.
    public var fingerprint: String? { ik.flatMap { IkFingerprint.formatB64($0) } }

    /// Whether End access and Remove are offered: never for this phone, nor for any other `app` entry (the vault refuses
    /// `device.unlink` of the app with `forbidden`, §10.3).
    public var actionable: Bool { !thisPhone && kind != Self.kindApp }

    /// Whether ``sessionExpiresAt`` is still ahead at [now].
    public func hasAccess(_ now: Date) -> Bool { sessionExpiresAt.map { $0 > now } == true }

    // A device's name is the device's word about itself: never printed, dumped or mirrored.
    public var description: String { "DeviceInfo" }
    public var debugDescription: String { "DeviceInfo" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// `device.list` and `leash.grant.list` bodies (§10.3, §10.11) as models. A body that does not read yields no entry: the
/// list never shows what it cannot name, and never an entry without an `id`. Mirrors vettid-android `DeviceWire`.
public enum DeviceWire {
    /// The longest name shown (code points); longer ones are cut. A self-asserted name is data, not text to trust.
    public static let maxName = 64

    /// [name] as shown: the one cleaning step for received text (``AccountNames/cleaned(_:)``, VAULT-MESSAGING 0.76.0
    /// §10.8), cut at ``maxName`` code points without splitting a grapheme cluster. Empty when nothing shows.
    public static func cleanName(_ name: String?) -> String { AccountNames.cleanedCapped(name, max: maxName) ?? "" }

    private static func instant(_ s: String?) -> Date? { OwnerCheckManager.instant(s) }

    /// The entries of a `device.list` answer, in the vault's order; [selfID] is this phone's device id.
    public static func devices(_ body: JsonObject, selfID: String?, paused: Set<String> = []) -> [DeviceInfo] {
        guard case .array(_, let items)? = body["devices"] else { return [] }
        return items.compactMap { item -> DeviceInfo? in
            guard let d = try? item.asObject(), let id = VaultJSON.string(d, "id"), !id.isEmpty else { return nil }
            let kind = VaultJSON.string(d, "kind") ?? ""
            let profileName = VaultJSON.obj(d, "profile").flatMap { VaultJSON.string($0, "name") }
            let ik = VaultJSON.string(d, "ik")
            return DeviceInfo(
                id: id, kind: kind, name: cleanName(AccountNames.cleaned(VaultJSON.string(d, "name")) ?? profileName),
                ik: ik?.isEmpty == false ? ik : nil, createdAt: instant(VaultJSON.string(d, "created_at")),
                lastActiveAt: instant(VaultJSON.string(d, "last_active_at")),
                sessionExpiresAt: instant(VaultJSON.string(d, "session_expires_at")),
                thisPhone: selfID != nil && id == selfID, paused: kind == DeviceInfo.kindAgent && paused.contains(id)
            )
        }
    }

    /// The order of the list (ANDROID-PLAN 0.1.53 AA1): this phone first, then agents, then desktops, each newest
    /// `created_at` first (an entry without one last, keeping the vault's order).
    public static func ordered(_ devices: [DeviceInfo]) -> [DeviceInfo] {
        func rank(_ d: DeviceInfo) -> Int { d.thisPhone ? 0 : d.isAgent ? 1 : 2 }
        // A stable sort: an index breaks every tie in the vault's order.
        return devices.enumerated().sorted { a, b in
            let (x, y) = (a.element, b.element)
            if rank(x) != rank(y) { return rank(x) < rank(y) }
            switch (x.createdAt, y.createdAt) {
            case let (p?, q?) where p != q: return p > q
            case (nil, _?): return false
            case (_?, nil): return true
            default: return a.offset < b.offset
            }
        }.map(\.element)
    }

    /// `suspended` of a `leash.grant.list` answer (agent ids).
    public static func suspended(_ body: JsonObject) -> Set<String> {
        guard case .array(_, let items)? = body["suspended"] else { return [] }
        return Set(items.compactMap { try? $0.asString() })
    }

    /// The `status_ttl` of each grant in a `leash.grant.list{agent_id}` answer, in seconds (§10.11: 60-3,600, default 900
    /// when absent). A grant that does not read counts as the longest; a body that does not read as a list of grants is
    /// the worst case, never "no permission".
    public static func statusTtls(_ body: JsonObject) -> [Int64] {
        guard case .array(_, let grants)? = body["grants"] else { return [maxStatusTtl] }
        return grants.map { g in
            guard let o = try? g.asObject() else { return maxStatusTtl }
            switch o["status_ttl"] {
            case nil, .object?, .array?: return defaultStatusTtl
            case .number(let raw)?: return Int64(raw).map { min(max($0, minStatusTtl), maxStatusTtl) } ?? maxStatusTtl
            default: return maxStatusTtl // a string, a boolean, null
            }
        }
    }

    public static let minStatusTtl: Int64 = 60
    public static let defaultStatusTtl: Int64 = 900
    public static let maxStatusTtl: Int64 = 3_600

    /// §10.11's revocation bound: `status_ttl` plus 60 s of skew.
    public static let skewSeconds: Int64 = 60
}
