import Foundation
import VettIDVault

/// Where a feed item leads (ANDROID-PLAN §4 Notifications, 4); the app maps each to its screen. ``sheet`` is the detail
/// sheet: kinds with no screen, and a target that is gone (the screen checks that). Mirrors vettid-android `FeedTarget`.
public enum FeedTarget: Equatable, Sendable {
    case approval(key: String)
    case connection(String)
    case connections
    case conversation(String)
    case sharedWithYou(String)
    case shareRule(connectionID: String, ruleID: String)
    case item(String)
    /// Settings → Vault (the devices).
    case devices
    /// The clone alarm's screen.
    case alarm
    /// History (its Security entries).
    case history
    /// Settings → Security → Credential.
    case credential
    /// Settings → Security (the daily check and the hold).
    case security
    case sheet
}

/// How the app treats a feed kind (VAULT-MESSAGING §10.9 as of 0.50.0; ANDROID-PLAN §4 Notifications, 4). Only the
/// History-only kinds (``FeedKinds/historyOnly``) are left out of the list: one this app does not know (a newer vault's)
/// is listed and opens the detail sheet.
public enum FeedKindClass: Equatable, Sendable {
    /// A kind of §10.9 whose screen this app has.
    case shown
    /// A kind whose screens come later (agents, shared actions, introductions, location, wallet): listed, and its sheet
    /// says that it is not available in this version of the app.
    case later
    /// A kind this app does not know: listed with the kind itself and a generic icon.
    case unknown
}

/// The feed kinds in the app: the classification, the target and the asks; the titles are in ``FeedKinds`` `+Titles`
/// (IOS-PLAN §4.1). The screens look a title up from ``FeedItem/kind`` and the raw members; ``classify(_:)`` and
/// ``target(_:)`` decide the rest. Mirrors vettid-android `FeedKinds`.
public enum FeedKinds {
    /// Every kind §10.9 names (0.50.0), `leash.*` included.
    public static let known: Set<String> = [
        "connection.request", "connection.request.peer_declined", "connection.added", "connection.removed",
        "connection.stale", "connection.asks_paused", "connection.authenticate.requested",
        "message.received", "call.missed", "message.attachment_failed", "message.attachment_refused",
        "grant.request", "grant.shared", "grant.revoked", "share.pending", "share.rate_limited",
        "critical-secret.use.request", "item.revealed",
        "device.pair.pending", "device.paired", "device.unlinked", "device.transferred", "device.replaced",
        "device.signer_changed", "device.session.pending", "approval.pending",
        "credential.alarm", "credential.password_failed", "credential.rotated", "credential.reset",
        "owner_check.failed", "owner_check.locked", "owner_check.hold_changed",
        "guide",
        "leash.rate_limited", "leash.item.read", "leash.item.run", "leash.item.proxy", "leash.agent.suspended",
        "leash.referrals_limited",
        "action.request", "intro.request", "location.shared", "location.request", "wallet.signed",
        // Release R (VAULT-MESSAGING 0.49.1, as built), IOS-PLAN §4.1 "Event titles".
        "vault.pin_changed", "device.secret_renewed", "credential.recovered", "recovery.device_paired",
        "recovery.completed", "recovery.attempt", "recovery.change_required", "recovery.counter_unavailable",
        "identity.rotation_failed", "identity.rotate_conflict",
        // VAULT-MESSAGING 0.50.0 (owner decision of 2026-10-20): a `rollback` closure's urgent item.
        "recovery.generation_closed",
    ]

    /// Feed kinds the app neither lists nor notifies (IOS-PLAN §4.1, de-duplication): one recovery raises one
    /// notification, `recovery.completed`, and a PIN change is History only. Their audit entries show in History; the feed
    /// items stay as the vault keeps them (no `feed.update` is sent for them).
    public static let historyOnly: Set<String> = ["vault.pin_changed", "credential.recovered", "recovery.device_paired"]

    public static func isHistoryOnly(_ kind: String) -> Bool { historyOnly.contains(kind) }

    /// Neither listed, counted nor notified: the History-only kinds, and a `recovery.generation_closed` item whose `ref`
    /// is not a `rollback` closure (the vault makes the item only for `rollback`; a `stale` one is hidden, IOS-PLAN §4.1),
    /// so that no other `ref` can raise the alarm.
    public static func isHidden(_ item: FeedItem) -> Bool {
        isHistoryOnly(item.kind) || (item.kind == RecoveryRefs.kindClosed && !RecoveryRefs.rollback(item.kind, ref: item.ref))
    }

    /// A kind of §10.9 (`leash.*` included); one this app does not know shows its kind on the detail sheet.
    public static func isKnown(_ kind: String) -> Bool { known.contains(kind) || kind.hasPrefix("leash.") }

    /// Kinds whose screens come later (ANDROID-PLAN §6).
    static let later: Set<String> = ["action.request", "intro.request", "location.shared", "location.request", "wallet.signed"]

    public static func classify(_ kind: String) -> FeedKindClass {
        if kind.hasPrefix("leash.") || later.contains(kind) { return .later }
        return known.contains(kind) ? .shown : .unknown
    }

    /// An ask (a decision waits in Approvals): "no longer waiting" when its entry is gone.
    public static func isAsk(_ kind: String) -> Bool { FeedAsks.approvalKey(kind, ref: "x") != nil }

    /// `urgent` (the clone alarm, the ten-failure lock): it stays unread until tapped or marked read, and turns the
    /// badge red.
    public static func urgent(_ item: FeedItem) -> Bool { item.priority == FeedManager.priorityUrgent }

    /// `high`: an amber tile and "Important" for screen readers.
    public static func important(_ item: FeedItem) -> Bool { item.priority == FeedManager.priorityHigh }

    /// Where [item] leads, before checking that it still exists (the screen does that).
    public static func target(_ item: FeedItem) -> FeedTarget { // swiftlint:disable:this cyclomatic_complexity
        if let key = FeedAsks.approvalKey(item.kind, ref: item.ref) { return .approval(key: key) }
        let c = item.connectionID
        let ref = item.ref
        switch item.kind {
        case "connection.request.peer_declined": return c.map { .connection($0) } ?? .connections
        case "connection.added", "connection.stale", "connection.asks_paused": return c.map { .connection($0) } ?? .sheet
        case "message.received", "call.missed", "message.attachment_failed", "message.attachment_refused":
            return c.map { .conversation($0) } ?? .sheet
        case "grant.shared", "grant.revoked": return c.map { .sharedWithYou($0) } ?? .sheet
        case "share.rate_limited":
            guard let c, let ref else { return .sheet }
            return .shareRule(connectionID: c, ruleID: ref)
        case "item.revealed": return ref.map { .item($0) } ?? .sheet
        case "device.pair.pending", "device.paired", "device.unlinked", "device.transferred", "device.replaced",
             "device.signer_changed":
            return .devices
        case "credential.alarm": return .alarm
        case "credential.password_failed": return .history
        case "credential.rotated", "credential.reset": return .credential
        case "owner_check.failed", "owner_check.locked", "owner_check.hold_changed": return .security
        default: return .sheet
        }
    }

    /// `owner_check.hold_changed`'s `ref` (§3.6.7): `on`, `off`, `off_until:<ts>` or `on:expired`, as data.
    public static func holdChange(_ ref: String?) -> HoldChange {
        let prefix = "off_until:"
        if let ref, ref.hasPrefix(prefix) {
            return .offUntil(OwnerCheckManager.instant(String(ref.dropFirst(prefix.count))))
        }
        switch ref {
        case "off": return .off
        case "on:expired": return .backOn
        default: return .on
        }
    }

    /// `device.signer_changed`'s `ref` (§11.7.1): `<old class>:<new class>`; nil when it does not read.
    public static func signerChange(_ ref: String?) -> (old: String, new: String)? {
        guard let parts = ref?.split(separator: ":", omittingEmptySubsequences: false), parts.count == 2 else { return nil }
        return (String(parts[0]), String(parts[1]))
    }
}

/// A change of the owner-check hold (§3.6.7), as `owner_check.hold_changed` names it.
public enum HoldChange: Equatable, Sendable {
    case on
    case off
    /// Off until the time (nil when it does not parse: the hold is off all the same).
    case offUntil(Date?)
    /// Back on after an "off until" ended.
    case backOn
}
