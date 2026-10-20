import Foundation

/// The feed item of an ask (ANDROID-PLAN §4 Notifications, §9 question 2): deciding it in Approvals marks its item read,
/// matched by kind and `ref` (VAULT-MESSAGING §10.9 names each kind's `ref`). Mirrors vettid-android `FeedAsks`.
public enum FeedAsks {
    /// `message.received` items: read when their conversation opens.
    public static let messageReceived = "message.received"

    static let deviceKinds: Set<String> = ["approval.pending", "device.session.pending"]

    /// The kinds and `ref` of the feed item for the Approvals entry [key] (``PendingApproval/key``); nil for one without an
    /// item (an outgoing request).
    public static func of(_ key: String) -> (kinds: Set<String>, ref: String)? {
        guard let colon = key.firstIndex(of: ":") else { return nil }
        let type = String(key[..<colon])
        let rest = String(key[key.index(after: colon)...])
        guard !rest.isEmpty else { return nil }
        if let kind = kinds[type] { return ([kind], rest) }
        // `device:<type>:<id>`, the type being the feed kind (`approval.pending`, `device.session.pending`).
        guard type == "device", let last = rest.lastIndex(of: ":") else { return nil }
        let kind = String(rest[..<last])
        guard deviceKinds.contains(kind) else { return nil }
        return ([kind], String(rest[rest.index(after: last)...]))
    }

    /// The feed kind of each approval key's type (but `device`).
    static let kinds: [String: String] = [
        "connection": "connection.request", "auth": "connection.authenticate.requested", "grant": "grant.request",
        "critical": "critical-secret.use.request", "share": "share.pending",
    ]

    /// The approval key of the Approvals entry a feed item of [kind] with [ref] stands for; nil for other kinds.
    public static func approvalKey(_ kind: String, ref: String?) -> String? {
        guard let ref, !ref.isEmpty else { return nil }
        if let type = kinds.first(where: { $0.value == kind })?.key { return "\(type):\(ref)" }
        return deviceKinds.contains(kind) ? "device:\(kind):\(ref)" : nil
    }
}
