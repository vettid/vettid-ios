import Foundation
import os

private let replayLog = Logger(subsystem: "com.vettid.app", category: "nats-replay")

/// NATS message replay protection (Android #47, ported to iOS).
///
/// Client-side defences against message replay attacks:
///  1. Event-ID deduplication — every processed `event_id` is cached
///     (max 1000 entries, 10-minute TTL) and re-seen IDs are rejected.
///  2. Timestamp validation — rejects ISO8601 timestamps older than
///     5 minutes or more than 1 minute in the future (clock skew).
///  3. Per-session sequence tracking — detects gaps (warn) and
///     replays (reject) when callers supply monotonic sequence numbers.
///
/// Mirrors `core/nats/NatsReplayProtection.kt` exactly so the two
/// platforms apply the same rejection rules.
final class NatsReplayProtection {

    static let shared = NatsReplayProtection()

    // MARK: - Tunables (match Android constants)

    /// Maximum age for valid messages.
    static let maxMessageAge: TimeInterval = 5 * 60        // 5 minutes
    /// Tolerance for clock-skew (future timestamps).
    static let futureClockSkew: TimeInterval = 60          // 1 minute
    /// How long to retain processed event IDs in the dedup cache.
    static let eventCacheTTL: TimeInterval = 10 * 60       // 10 minutes
    /// Maximum dedup cache size before opportunistic trim.
    static let maxCacheSize = 1000

    // MARK: - State

    private let queue = DispatchQueue(label: "com.vettid.nats.replay", attributes: .concurrent)
    private var processedEvents: [String: Date] = [:]
    private var sequenceTrackers: [String: Int64] = [:]

    /// ISO 8601 parsers — the supervisor emits BOTH
    /// `"2026-05-27T15:42:34.046Z"` (PCR manifest) and
    /// `"2026-05-27T13:37:24Z"` (attestation response) depending on
    /// the producer, so we try the fractional-seconds parser first
    /// and fall back to the plain RFC 3339 parser. `ISO8601DateFormatter`
    /// with `.withFractionalSeconds` *requires* fractional seconds in
    /// the input — without the fallback every attestation response
    /// was failing replay validation as "Invalid timestamp format"
    /// and the response loop waited forever for a retry that never
    /// came (the supervisor only publishes once).
    private static let timestampParserFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let timestampParserPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func parseISO8601(_ ts: String) -> Date? {
        if let d = timestampParserFractional.date(from: ts) { return d }
        return timestampParserPlain.date(from: ts)
    }

    private init() {}

    // MARK: - Public API

    /// Validate an incoming message. `eventId` is required; if the
    /// caller can't extract one from the message they should generate
    /// a random UUID (matches Android's fallback) so the message still
    /// passes through the cache TTL machinery.
    func validateMessage(
        eventId: String,
        timestamp: String? = nil,
        sequence: Int64? = nil,
        sessionKey: String? = nil
    ) -> ValidationResult {
        cleanExpiredEntries()

        // 1. Duplicate?
        if isDuplicate(eventId) {
            replayLog.warning("duplicate eventId=\(eventId, privacy: .public)")
            return .duplicate(eventId: eventId)
        }

        // 2. Timestamp window.
        if let ts = timestamp {
            switch validateTimestamp(ts) {
            case .valid:
                break
            case .invalid(let reason):
                replayLog.warning("invalid timestamp=\(ts, privacy: .public) reason=\(reason, privacy: .public)")
                return .invalidTimestamp(timestamp: ts, reason: reason)
            }
        }

        // 3. Sequence-number gap detection. Gaps log a warning but
        //    don't reject — only outright replays (seq <= last) do.
        if let seq = sequence, let key = sessionKey {
            switch validateSequence(sessionKey: key, sequence: seq) {
            case .valid:
                break
            case .gap(let expected, let received):
                replayLog.warning("sequence gap session=\(key, privacy: .public) expected=\(expected, privacy: .public) got=\(received, privacy: .public)")
            case .replay(let expected, let received):
                replayLog.warning("sequence replay session=\(key, privacy: .public) expected=\(expected, privacy: .public) got=\(received, privacy: .public)")
                return .sequenceReplay(expected: expected, received: received)
            }
        }

        markProcessed(eventId)
        return .valid
    }

    func isDuplicate(_ eventId: String) -> Bool {
        queue.sync { processedEvents[eventId] != nil }
    }

    func markProcessed(_ eventId: String) {
        queue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            // Bound cache size — trim the oldest quarter when at the cap.
            if self.processedEvents.count >= Self.maxCacheSize {
                self.cleanExpiredEntriesLocked()
                if self.processedEvents.count >= Self.maxCacheSize {
                    let trimCount = Self.maxCacheSize / 4
                    let oldest = self.processedEvents
                        .sorted { $0.value < $1.value }
                        .prefix(trimCount)
                        .map { $0.key }
                    for key in oldest { self.processedEvents.removeValue(forKey: key) }
                }
            }
            self.processedEvents[eventId] = Date()
        }
    }

    /// Reset all in-memory state (tests + session teardown).
    func reset() {
        queue.async(flags: .barrier) { [weak self] in
            self?.processedEvents.removeAll()
            self?.sequenceTrackers.removeAll()
        }
    }

    /// Monitoring hook — mirrors Android's `getStats()`.
    func stats() -> Stats {
        queue.sync {
            Stats(
                processedEventCount: processedEvents.count,
                trackedSessions: sequenceTrackers.count
            )
        }
    }

    // MARK: - Internals

    private func validateTimestamp(_ timestamp: String) -> TimestampOutcome {
        guard let messageTime = Self.parseISO8601(timestamp) else {
            return .invalid("Invalid timestamp format")
        }
        let now = Date()
        let age = now.timeIntervalSince(messageTime)
        if age < -Self.futureClockSkew {
            return .invalid("Message timestamp is in the future")
        }
        if age > Self.maxMessageAge {
            let minutes = Int(age / 60)
            return .invalid("Message is \(minutes) minutes old (max: 5)")
        }
        return .valid
    }

    private func validateSequence(sessionKey: String, sequence: Int64) -> SequenceOutcome {
        queue.sync(flags: .barrier) {
            guard let last = sequenceTrackers[sessionKey] else {
                sequenceTrackers[sessionKey] = sequence
                return .valid
            }
            if sequence <= last {
                return .replay(expected: last + 1, received: sequence)
            }
            if sequence > last + 1 {
                sequenceTrackers[sessionKey] = sequence
                return .gap(expected: last + 1, received: sequence)
            }
            sequenceTrackers[sessionKey] = sequence
            return .valid
        }
    }

    private func cleanExpiredEntries() {
        queue.async(flags: .barrier) { [weak self] in
            self?.cleanExpiredEntriesLocked()
        }
    }

    /// Must be called inside the barrier queue.
    private func cleanExpiredEntriesLocked() {
        let cutoff = Date().addingTimeInterval(-Self.eventCacheTTL)
        processedEvents = processedEvents.filter { $0.value > cutoff }
    }

    // MARK: - Result Types

    enum ValidationResult: Equatable {
        case valid
        case duplicate(eventId: String)
        case invalidTimestamp(timestamp: String, reason: String)
        case sequenceReplay(expected: Int64, received: Int64)

        var isValid: Bool {
            if case .valid = self { return true }
            return false
        }
    }

    private enum TimestampOutcome {
        case valid
        case invalid(String)
    }

    private enum SequenceOutcome {
        case valid
        case gap(expected: Int64, received: Int64)
        case replay(expected: Int64, received: Int64)
    }

    struct Stats {
        let processedEventCount: Int
        let trackedSessions: Int
    }
}
