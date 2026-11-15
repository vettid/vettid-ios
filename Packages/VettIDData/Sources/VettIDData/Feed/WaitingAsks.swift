import Foundation
import VettIDVault

/// The asks notified once when a passed check ends the held or due state in an open session (owner decisions of
/// 2026-11-15; ANDROID-PLAN 0.1.132 Notifications 7, IOS-PLAN §6.7): nothing missed while held or due is replayed, except
/// an ask still waiting of exactly these three kinds, which would otherwise go by unseen. Mirrors vettid-android
/// `WaitingAsks`.
enum WaitingAsks {
    /// `connection.authenticate.requested` of any purpose (sign-in, approval, none), `device.session.pending` and
    /// `approval.pending`. Pairings are left out: the vault does not list them in `pending.list` yet, so there is no way to
    /// know one is still waiting.
    static let kinds: Set<String> = ["connection.authenticate.requested", "device.session.pending", "approval.pending"]

    /// Of [items], the asks still waiting at [now], in `seq` order: active (not read, archived or deleted), and listed in
    /// [approvals] (as read after the check) with no `exp` or one not passed. An item without a `ref` matches nothing.
    static func of(_ items: some Collection<FeedItem>, approvals: [PendingApproval], now: Date) -> [FeedItem] {
        var byKey: [String: PendingApproval] = [:]
        for a in approvals where byKey[a.key] == nil { byKey[a.key] = a }
        return items.filter { kinds.contains($0.kind) && $0.status == FeedManager.statusActive && waiting($0, byKey, now) }
            .sorted { $0.seq < $1.seq }
    }

    private static func waiting(_ item: FeedItem, _ byKey: [String: PendingApproval], _ now: Date) -> Bool {
        guard let key = FeedAsks.approvalKey(item.kind, ref: item.ref), let ask = byKey[key] else { return false }
        return ask.exp.map { $0 > now } ?? true
    }
}
