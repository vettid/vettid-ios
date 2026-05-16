import Foundation

// MARK: - Presence Aggregator

/// Collects peer presence heartbeats from `OwnerSpaceClient` and maintains
/// a per-connection "is this peer online?" signal.
///
/// A connection is considered online if a heartbeat arrived within the
/// last `timeoutSeconds` (~2× the peer's publish interval). Absence of
/// heartbeats is **not** itself a signal — connections we've never heard
/// from stay neutral (not online, not explicitly offline). The avatar
/// ring is rendered only for explicitly-online peers.
///
/// Parity with Android `PresenceAggregator`. Implemented as an `actor` so
/// concurrent reads from FeedViewModel and the sweeper can't race on the
/// internal map.
actor PresenceAggregator {

    static let shared = PresenceAggregator()

    /// Heartbeats older than this drop out of the online set. Android
    /// uses 90s (forgiving of one missed ~30s beat). Matches.
    static let timeoutSeconds: TimeInterval = 90

    /// 15-second sweeper cadence — same as Android.
    private static let sweepInterval: TimeInterval = 15

    /// connectionId → unix-seconds timestamp of most recent heartbeat.
    private var online: [String: TimeInterval] = [:]

    /// Token consumers wait on; bumped whenever the map changes so a
    /// snapshot reader can poll cheaply for "did anything change?".
    private(set) var changeToken: Int = 0

    private var collectorTask: Task<Void, Never>?
    private var sweeperTask: Task<Void, Never>?

    private init() {}

    // MARK: - Lifecycle

    /// Start the heartbeat collector and the sweeper. Idempotent. Call
    /// once after `OwnerSpaceClient` is ready (after vault warm).
    func attach(to ownerSpaceClient: OwnerSpaceClient) {
        guard collectorTask == nil else { return }

        // Tell OwnerSpaceClient to wire the underlying subscription.
        ownerSpaceClient.startPresenceHeartbeatSubscription()

        collectorTask = Task { [weak self] in
            let stream = await ownerSpaceClient.presenceHeartbeats
            for await hb in stream {
                if Task.isCancelled { return }
                await self?.record(hb)
            }
        }
        sweeperTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.sweepInterval * 1_000_000_000))
                await self?.sweep()
            }
        }
    }

    /// Stop collecting (e.g. on logout). Online map is cleared.
    func detach() {
        collectorTask?.cancel(); collectorTask = nil
        sweeperTask?.cancel();   sweeperTask = nil
        online.removeAll()
        changeToken &+= 1
    }

    // MARK: - Reads

    /// Has a heartbeat from this connection landed within the timeout?
    func isOnline(connectionId: String) -> Bool {
        guard let lastAt = online[connectionId] else { return false }
        let cutoff = Date().timeIntervalSince1970 - Self.timeoutSeconds
        return lastAt > cutoff
    }

    /// Last-seen `Date` for a connection, or nil if no heartbeat has
    /// landed within the timeout. Convenience for the card builder which
    /// stamps `presenceLastSeen` straight into `ConnectionCardData`.
    func lastSeen(connectionId: String) -> Date? {
        guard let at = online[connectionId] else { return nil }
        let cutoff = Date().timeIntervalSince1970 - Self.timeoutSeconds
        return at > cutoff ? Date(timeIntervalSince1970: at) : nil
    }

    /// Snapshot of the online map (connectionId → last-seen).
    func snapshot() -> [String: Date] {
        let cutoff = Date().timeIntervalSince1970 - Self.timeoutSeconds
        var out: [String: Date] = [:]
        for (cid, at) in online where at > cutoff {
            out[cid] = Date(timeIntervalSince1970: at)
        }
        return out
    }

    // MARK: - Writes (internal)

    private func record(_ hb: PresenceHeartbeat) {
        online[hb.connectionId] = hb.at
        changeToken &+= 1
    }

    private func sweep() {
        let cutoff = Date().timeIntervalSince1970 - Self.timeoutSeconds
        let before = online.count
        online = online.filter { $0.value > cutoff }
        if online.count != before {
            changeToken &+= 1
        }
    }
}

// MARK: - Heartbeat domain event

/// Decoded peer presence heartbeat. Matches Android `PresenceHeartbeat`
/// and the `forApp.presence.heartbeat` wire payload
/// (`{ connection_id, status, at }`, where `at` is unix seconds).
struct PresenceHeartbeat {
    let connectionId: String
    let status: String     // "online" / "offline" / "away"
    let at: TimeInterval   // unix seconds
}
