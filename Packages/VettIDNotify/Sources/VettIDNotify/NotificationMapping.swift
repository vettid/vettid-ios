import Foundation
import VettIDData
import VettIDVault

/// How loud a notification is (IOS-PLAN §6.7, the categories' table): `UNNotificationInterruptionLevel`, kept apart from
/// UserNotifications so that the mapping stays plain and tested.
public enum NotifyLevel: Equatable, Sendable {
    case passive, active, timeSensitive
}

/// The notification categories (IOS-PLAN §6.7; vettid-android `Channels`, ANDROID-PLAN §4 Notification modes 6): each
/// with its sound (a bundled `.caf`, set locally, never from a payload; nil: none), its level, and what the lock screen
/// says when previews are hidden. Calls, the connection notice and release notices are not posted by the feed.
public enum NotifyCategory: String, CaseIterable, Sendable {
    case messages
    case requests
    case missedCalls = "missed_calls"
    case security
    case ownerCheck = "owner_check"
    case activity

    /// The `UNNotificationCategory` identifier.
    public var identifier: String { "vettid.\(rawValue)" }

    /// IOS-PLAN §6.7: the message sound for messages and missed calls, the urgent sound for requests, security alarms
    /// and the daily check; Vault activity is silent.
    public var sound: String? {
        switch self {
        case .messages, .missedCalls: "vettid_message.caf"
        case .requests, .security, .ownerCheck: "vettid_urgent.caf"
        case .activity: nil
        }
    }

    /// IOS-PLAN §6.7: security alarms and the daily check `timeSensitive`, Vault activity `passive`, the rest `active`.
    public var level: NotifyLevel {
        switch self {
        case .messages, .missedCalls, .requests: .active
        case .security, .ownerCheck: .timeSensitive
        case .activity: .passive
        }
    }

    /// Security and Daily check say "VettID needs your attention" on the lock screen; the others "New activity in VettID".
    /// Mirrors vettid-android `NotificationMapping.urgentChannel`.
    public var urgent: Bool { self == .security || self == .ownerCheck }

    /// What the lock screen shows while previews are hidden.
    public var publicTitle: String { urgent ? NotifyStrings.publicAttention : NotifyStrings.publicActivity }
}

/// Which feed items notify, and in which category (ANDROID-PLAN §4 Notification modes 7). Feed items are the one source of
/// notifications, so read state stays shared: a notification's identifier is its item's `item_id`. Items of priority
/// `low`, `guide` items and the History-only kinds never notify; a kind this app does not know notifies on Vault activity
/// from priority `normal` up. Mirrors vettid-android `NotificationMapping`.
public enum NotificationMapping {
    /// (VAULT-MESSAGING §10.5.1) A photo that failed or was refused is about a message too.
    static let messages: Set<String> = ["message.received", "message.attachment_failed", "message.attachment_refused"]
    static let requests: Set<String> = [
        "connection.request", "connection.authenticate.requested", "grant.request", "share.pending",
        "critical-secret.use.request", "device.pair.pending", "device.session.pending", "approval.pending",
        "action.request", "intro.request", "location.request",
    ]
    static let missedCalls: Set<String> = ["call.missed"]
    static let security: Set<String> = [
        "credential.alarm", "owner_check.locked", "owner_check.failed", "owner_check.hold_changed",
        "credential.password_failed", "credential.reset", "device.replaced", "device.transferred",
        "device.signer_changed",
    ]
    static let priorityLow = "low"

    /// The category [item] notifies in; nil when it does not notify.
    public static func category(_ item: FeedItem) -> NotifyCategory? {
        if item.priority == priorityLow || item.kind == "guide" { return nil }
        // IOS-PLAN §4.1 "Event titles": one notification per recovery; a PIN change is History only.
        if FeedKinds.isHistoryOnly(item.kind) { return nil }
        if messages.contains(item.kind) { return .messages }
        if requests.contains(item.kind) { return .requests }
        if missedCalls.contains(item.kind) { return .missedCalls }
        if security.contains(item.kind) || urgentRecovery(item) { return .security }
        // Connections, grants, shares, items, devices, the credential renewed, agents, location, wallet, votes; and a
        // newer vault's kinds (priority normal and above, never low: above).
        return .activity
    }

    /// The urgent recovery notifications (owner decision of 2026-10-19): a failed `recovery.attempt` (urgent and
    /// `not_success`, or urgent with a `ref` that does not read), `recovery.counter_unavailable`,
    /// `recovery.change_required`, and (VAULT-MESSAGING 0.50.0) a `rollback` closure. A successful or not urgent attempt
    /// stays on Vault activity.
    private static func urgentRecovery(_ item: FeedItem) -> Bool {
        switch item.kind {
        case "recovery.counter_unavailable", "recovery.change_required": true
        case "recovery.attempt": item.priority == FeedManager.priorityUrgent && RecoveryRefs.attempt(item.ref)?.success != true
        case RecoveryRefs.kindClosed: true
        default: false
        }
    }

    /// Request kinds whose screens come later: the notification says to open a newer VettID.
    public static func needsNewerApp(_ item: FeedItem) -> Bool {
        requests.contains(item.kind) && FeedKinds.classify(item.kind) == .later
    }
}
