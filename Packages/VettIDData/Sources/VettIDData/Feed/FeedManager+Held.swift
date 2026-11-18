import Foundation
import VettIDVault

/// (Rule 3) An arrival held while the vault's release was checked: the item, and whether it is a waiting ask replayed after
/// a passed owner check (``FeedManager/onWaitingAsk``) rather than a new or changed item (``FeedManager/onArrival``).
struct HeldArrival: Equatable {
    var item: FeedItem
    var replayed: Bool
}

/// (Rule 3) The feed during the release check (``FeedManager/checking``): nothing notifies before the app knows the vault is
/// on the current release. `feed.event`s wait unapplied and arrivals wait as they came, in order, at most ``heldLimit``
/// each (the oldest go first). They come when the check is over with the vault not behind, or when the release gate lifts
/// (``releaseHeld()``), after the feed's reads under way: the arrivals as the feed has them now (not at all once read,
/// archived or deleted), then the events. Until they came, a later event or arrival waits behind them. While the gate pauses
/// the vault's work (``FeedManager/paused``) they are kept for the lift; while the owner check is due or held they are
/// dropped, as live ones are not notified then; a clear drops them. Mirrors vettid-android `FeedManager` (#392).
extension FeedManager {
    /// The most events, and the most arrivals, held (vettid-android's `ARRIVAL_BUFFER`).
    nonisolated static let heldLimit = 64

    /// The check is over but what it held has not come yet: a later event or arrival waits behind it.
    var queuesBehind: Bool { !heldEvents.isEmpty || !heldArrivals.isEmpty }

    /// While the release is checked, [m] waits; after the check, while what was held has not come yet, it waits behind it
    /// (only while the feed is not [gated]). Never while the owner check is due or held: what comes then is not notified
    /// later (stricter than vettid-android, which holds it during the check and notifies it at the lift). True when it was
    /// held.
    func holds(_ m: VaultMessage) -> Bool {
        guard !ownerGated(), checking() || (!gated() && queuesBehind) else { return false }
        heldEvents.append(m)
        if heldEvents.count > Self.heldLimit { heldEvents.removeFirst(heldEvents.count - Self.heldLimit) }
        releaseIfOver()
        return true
    }

    /// An arrival ([replayed]: a waiting ask) held as ``holds(_:)`` holds an event; one already held for the same item is
    /// replaced by it, at the end. True when it was held.
    func holdsArrival(_ item: FeedItem, replayed: Bool) -> Bool {
        guard !ownerGated(), checking() || (!gated() && queuesBehind) else { return false }
        heldArrivals.removeAll { $0.item.itemID == item.itemID }
        heldArrivals.append(HeldArrival(item: item, replayed: replayed))
        if heldArrivals.count > Self.heldLimit { heldArrivals.removeFirst(heldArrivals.count - Self.heldLimit) }
        releaseIfOver()
        return true
    }

    /// The release check is over with the vault not behind, or the release gate lifted: what it held comes once the feed's
    /// reads under way are done (at once when none is), from a loaded feed (a feed that is not loaded is read first).
    public func releaseHeld() { release(readIfNeeded: true) }

    /// After a read, or something held: released if the check is over and the feed not paused, else kept.
    func releaseIfOver() { release(readIfNeeded: false) }

    private func release(readIfNeeded: Bool) {
        guard queuesBehind, !checking(), !paused() else { return }
        // The owner check due or held: as live ones, they are not notified.
        guard !gated() else {
            heldEvents = []
            heldArrivals = []
            return
        }
        guard readsRunning == 0 else { return }
        guard load == .loaded else {
            if readIfNeeded { catchUp() }
            return
        }
        releaseNow()
    }

    /// The arrivals first, as the feed has them now, then the events: one the feed's read already covers notifies the item
    /// as listed (if still unread); one it does not is applied as a live one. An item notified here is not notified again
    /// for a change no newer than the one notified.
    private func releaseNow() {
        let arrivals = heldArrivals
        let events = heldEvents
        heldArrivals = []
        heldEvents = []
        var notified: [String: Int64] = [:]
        for a in arrivals {
            guard let now = byID[a.item.itemID], now.status == Self.statusActive else { continue }
            notified[now.itemID] = now.seq
            if a.replayed {
                guard let onWaitingAsk else { assertionFailure("onWaitingAsk is not set"); continue }
                onWaitingAsk(now)
            } else {
                onArrival(now)
            }
        }
        for m in events {
            guard let item = FeedItem.of(m.object) else { continue }
            let notify = notified[item.itemID].map { item.seq > $0 } ?? true
            if item.seq > cursor {
                onItem(item, notify: notify)
            } else if notify, let listed = byID[item.itemID], listed.status == Self.statusActive {
                arrived(listed)
            }
            if let listed = byID[item.itemID] { notified[item.itemID] = max(notified[item.itemID] ?? 0, listed.seq) }
        }
    }
}
