import Foundation
import SwiftUI

// MARK: - Audit Time Window

enum AuditTimeWindow: String, CaseIterable {
    case lastHour = "last_hour"
    case last24Hours = "last_24_hours"
    case last7Days = "last_7_days"
    case last30Days = "last_30_days"
    case all

    var displayName: String {
        switch self {
        case .lastHour: return "1 Hour"
        case .last24Hours: return "24 Hours"
        case .last7Days: return "7 Days"
        case .last30Days: return "30 Days"
        case .all: return "All"
        }
    }

    /// Start date for the time window, nil for all time
    var startDate: Date? {
        let now = Date()
        switch self {
        case .lastHour:
            return Calendar.current.date(byAdding: .hour, value: -1, to: now)
        case .last24Hours:
            return Calendar.current.date(byAdding: .hour, value: -24, to: now)
        case .last7Days:
            return Calendar.current.date(byAdding: .day, value: -7, to: now)
        case .last30Days:
            return Calendar.current.date(byAdding: .day, value: -30, to: now)
        case .all:
            return nil
        }
    }
}

// MARK: - EventPriorityLevel Extensions

extension EventPriorityLevel {

    var displayName: String {
        switch self {
        case .low: return "Low"
        case .normal: return "Normal"
        case .high: return "High"
        case .urgent: return "Urgent"
        }
    }

    var color: Color {
        switch self {
        case .low: return .secondary
        case .normal: return .blue
        case .high: return .orange
        case .urgent: return .red
        }
    }

    var icon: String {
        switch self {
        case .low: return "arrow.down"
        case .normal: return "minus"
        case .high: return "arrow.up"
        case .urgent: return "exclamationmark.2"
        }
    }
}

// MARK: - VaultFeedEvent Convenience

extension VaultFeedEvent {

    /// Created date from epoch millis
    var createdDate: Date {
        Date(timeIntervalSince1970: createdAt / 1000.0)
    }
}

// MARK: - Audit Log View Model

/// Verification-state filter chip (Phase 5.3). `all` is the default;
/// the others narrow to one of the AuditChainVerifier RowStates so a
/// user can quickly answer "are there any tampered rows on this page?"
enum AuditVerificationFilter: String, CaseIterable, Hashable {
    case all
    case verified
    case tampered
    case unsigned

    var displayName: String {
        switch self {
        case .all:       return "All"
        case .verified:  return "Verified"
        case .tampered:  return "Tampered"
        case .unsigned:  return "Unsigned"
        }
    }
}

@MainActor
final class FeedAuditLogViewModel: ObservableObject {

    // MARK: - Published State

    @Published var events: [VaultFeedEvent] = []
    @Published var isLoading = false
    @Published var searchText = ""
    @Published var selectedTimeWindow: AuditTimeWindow = .last24Hours
    @Published var selectedEventType: String? = nil
    @Published var verificationFilter: AuditVerificationFilter = .all
    @Published var integrityVerified: Bool? = nil
    @Published var errorMessage: String?

    /// Per-row verification result, keyed by event_id. Populated by
    /// `loadAudit()` after parsing the response and running the
    /// chain verifier. Defaults to `.unsigned` for any row not present
    /// in the map (e.g. mock data or pre-anchor responses).
    @Published var verificationByEventId: [String: AuditChainVerifier.RowState] = [:]

    /// Aggregate chain status — drives the top-of-list pill and the
    /// header-bar `integrityVerified` quick badge.
    @Published var chainStatus: AuditChainVerifier.ChainStatus = .empty

    // MARK: - Dependencies

    private let feedClient: FeedClient?

    // MARK: - Init

    init(feedClient: FeedClient? = nil) {
        self.feedClient = feedClient
    }

    // MARK: - Computed Properties

    /// Events filtered by search text, event type, and verification state.
    var filteredEvents: [VaultFeedEvent] {
        var result = events

        // Filter by event type
        if let eventType = selectedEventType {
            result = result.filter { $0.eventType == eventType }
        }

        // Filter by verification state (Phase 5.3)
        if verificationFilter != .all {
            result = result.filter { event in
                let state = verificationByEventId[event.eventId] ?? .unsigned
                switch verificationFilter {
                case .all:       return true
                case .verified:  return state == .verified
                case .tampered:  return state == .tampered
                case .unsigned:  return state == .unsigned
                }
            }
        }

        // Filter by search text
        if !searchText.isEmpty {
            let query = searchText.lowercased()
            result = result.filter { event in
                event.title.lowercased().contains(query) ||
                (event.message?.lowercased().contains(query) ?? false) ||
                event.eventType.lowercased().contains(query) ||
                (event.sourceType?.lowercased().contains(query) ?? false)
            }
        }

        return result
    }

    /// Unique event types from loaded events for filter dropdown
    var availableEventTypes: [String] {
        Array(Set(events.map { $0.eventType })).sorted()
    }

    /// Whether any filters are active
    var hasActiveFilters: Bool {
        selectedEventType != nil || !searchText.isEmpty || verificationFilter != .all
    }

    /// Verification verdict for a single row — used by AuditEventRow.
    func verificationState(for event: VaultFeedEvent) -> AuditChainVerifier.RowState {
        verificationByEventId[event.eventId] ?? .unsigned
    }

    // MARK: - Load Audit

    func loadAudit() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil

        // Convert time window to epoch millis
        let startDate: TimeInterval? = selectedTimeWindow.startDate.map { $0.timeIntervalSince1970 * 1000 }
        let endDate: TimeInterval = Date().timeIntervalSince1970 * 1000

        guard let client = feedClient else {
            // Load mock data when no client is available
            loadMockData()
            isLoading = false
            return
        }

        do {
            let result = try await client.queryAudit(
                eventTypes: nil,
                startDate: startDate,
                endDate: endDate,
                limit: 500
            )
            let sorted = result.events.sorted { $0.createdAt > $1.createdAt }
            events = sorted
            applyChainVerification(events: sorted, anchor: result.chainAnchor)
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    // MARK: - Verify Integrity

    /// Phase 5.3: real Ed25519 chain verification. Reads the per-row
    /// verification map already populated by `loadAudit()` and surfaces
    /// the top-of-screen pill state.
    func verifyIntegrity() {
        guard !events.isEmpty else {
            integrityVerified = nil
            return
        }
        switch chainStatus {
        case .verified:
            integrityVerified = true
        case .tampered:
            integrityVerified = false
        case .unsigned, .empty:
            // No anchor available — fall back to a sync_sequence
            // monotonicity check so users still see *some* signal on
            // pre-anchor servers. This is best-effort, not authoritative.
            let bySeq = events.sorted { $0.syncSequence < $1.syncSequence }
            var monotonic = true
            for i in 1..<bySeq.count where bySeq[i].syncSequence <= bySeq[i - 1].syncSequence {
                monotonic = false
                break
            }
            integrityVerified = monotonic
        }
    }

    /// Run the chain verifier and update the per-row map + chain status.
    /// Rows in `events` must already be in newest-first order — the
    /// verifier reverses internally to walk oldest → newest.
    private func applyChainVerification(events: [VaultFeedEvent], anchor: AuditChainVerifier.ChainAnchor) {
        let (perRow, chain) = AuditChainVerifier.verifyChain(
            rows: events,
            anchor: anchor,
            entryHashOf: { ($0.entryHash, $0.previousHash, $0.entrySig) }
        )
        var map: [String: AuditChainVerifier.RowState] = [:]
        map.reserveCapacity(events.count)
        for (i, event) in events.enumerated() {
            map[event.eventId] = perRow[i].state
        }
        self.verificationByEventId = map
        self.chainStatus = chain
        // Stamp the screen-level "Verified" / "Warning" badge so it
        // stays in sync with the chain state even without an explicit
        // Verify Integrity tap.
        switch chain {
        case .verified: integrityVerified = true
        case .tampered: integrityVerified = false
        case .unsigned, .empty: integrityVerified = nil
        }
    }

    // MARK: - Export JSON

    func exportJSON() -> String {
        let exportEvents = filteredEvents
        guard !exportEvents.isEmpty else { return "[]" }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        guard let data = try? encoder.encode(exportEvents),
              let jsonString = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return jsonString
    }

    // MARK: - Export CSV

    func exportCSV() -> String {
        let exportEvents = filteredEvents
        var csv = "Event ID,Event Type,Source Type,Source ID,Title,Message,Priority,Created At,Sync Sequence\n"

        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        for event in exportEvents {
            let createdDate = dateFormatter.string(from: event.createdDate)
            let escapedTitle = event.title.replacingOccurrences(of: "\"", with: "\"\"")
            let escapedMessage = (event.message ?? "").replacingOccurrences(of: "\"", with: "\"\"")
            let sourceType = event.sourceType ?? ""
            let sourceId = event.sourceId ?? ""

            csv += "\(event.eventId),\(event.eventType),\(sourceType),\(sourceId),"
            csv += "\"\(escapedTitle)\",\"\(escapedMessage)\","
            csv += "\(event.priority),\(createdDate),\(event.syncSequence)\n"
        }

        return csv
    }

    // MARK: - Clear Filters

    func clearFilters() {
        selectedEventType = nil
        searchText = ""
        verificationFilter = .all
    }

    // MARK: - Mock Data

    private func loadMockData() {
        let now = Date().timeIntervalSince1970 * 1000

        events = [
            VaultFeedEvent(
                eventId: "audit-001",
                eventType: "credential.verified",
                sourceType: "service",
                sourceId: "svc-bank-01",
                title: "Credential Verified",
                message: "Banking app verified your identity credential",
                metadata: ["service_name": "Example Bank"],
                feedStatus: "read",
                actionType: nil,
                priority: 0,
                createdAt: now - 600_000,
                readAt: now - 300_000,
                actionedAt: nil,
                archivedAt: nil,
                expiresAt: nil,
                syncSequence: 42,
                retentionClass: "audit",
                previousHash: nil,
                entryHash: nil,
                entrySig: nil
            ),
            VaultFeedEvent(
                eventId: "audit-002",
                eventType: "data.shared",
                sourceType: "service",
                sourceId: "svc-health-01",
                title: "Data Shared",
                message: "Shared email address with HealthFirst",
                metadata: ["field": "email"],
                feedStatus: "active",
                actionType: nil,
                priority: 0,
                createdAt: now - 1_800_000,
                readAt: nil,
                actionedAt: nil,
                archivedAt: nil,
                expiresAt: nil,
                syncSequence: 41,
                retentionClass: "audit",
                previousHash: nil,
                entryHash: nil,
                entrySig: nil
            ),
            VaultFeedEvent(
                eventId: "audit-003",
                eventType: "auth.login",
                sourceType: "vault",
                sourceId: "vault-01",
                title: "Vault Login",
                message: "Authenticated via biometric unlock",
                metadata: nil,
                feedStatus: "read",
                actionType: nil,
                priority: -1,
                createdAt: now - 3_600_000,
                readAt: now - 3_500_000,
                actionedAt: nil,
                archivedAt: nil,
                expiresAt: nil,
                syncSequence: 40,
                retentionClass: "audit",
                previousHash: nil,
                entryHash: nil,
                entrySig: nil
            ),
            VaultFeedEvent(
                eventId: "audit-004",
                eventType: "connection.established",
                sourceType: "peer",
                sourceId: "peer-jane-01",
                title: "Connection Established",
                message: "New connection with Jane Smith",
                metadata: ["peer_name": "Jane Smith"],
                feedStatus: "read",
                actionType: nil,
                priority: 1,
                createdAt: now - 86_400_000,
                readAt: now - 86_000_000,
                actionedAt: nil,
                archivedAt: nil,
                expiresAt: nil,
                syncSequence: 39,
                retentionClass: "audit",
                previousHash: nil,
                entryHash: nil,
                entrySig: nil
            ),
            VaultFeedEvent(
                eventId: "audit-005",
                eventType: "backup.completed",
                sourceType: "vault",
                sourceId: "vault-01",
                title: "Backup Completed",
                message: "Vault backup created successfully",
                metadata: ["backup_size": "2.4MB"],
                feedStatus: "read",
                actionType: nil,
                priority: -1,
                createdAt: now - 172_800_000,
                readAt: now - 172_000_000,
                actionedAt: nil,
                archivedAt: nil,
                expiresAt: nil,
                syncSequence: 38,
                retentionClass: "audit",
                previousHash: nil,
                entryHash: nil,
                entrySig: nil
            ),
            VaultFeedEvent(
                eventId: "audit-006",
                eventType: "security.alert",
                sourceType: "system",
                sourceId: "system-01",
                title: "Security Alert",
                message: "Unusual login attempt detected and blocked",
                metadata: ["ip": "192.168.1.100"],
                feedStatus: "active",
                actionType: "review",
                priority: 2,
                createdAt: now - 7_200_000,
                readAt: nil,
                actionedAt: nil,
                archivedAt: nil,
                expiresAt: nil,
                syncSequence: 43,
                retentionClass: "security",
                previousHash: nil,
                entryHash: nil,
                entrySig: nil
            )
        ].sorted { $0.createdAt > $1.createdAt }
        // Run the verifier so the mock data exercises the same code
        // path as live data. Without an anchor every row becomes
        // `.unsigned` (the expected pre-anchor display).
        applyChainVerification(events: events, anchor: .empty)
    }
}
