import Foundation
import Combine

/// Per-desktop detail screen state. Mirrors Android
/// `DesktopConnectionDetailViewModel`.
@MainActor
final class DesktopConnectionDetailViewModel: ObservableObject {

    // MARK: - Published State

    @Published private(set) var state: DesktopDetailState = .loading
    @Published private(set) var isWorking: Bool = false
    @Published var toast: String?
    @Published private(set) var activity: DesktopActivityState = .loading

    /// Area C (Android 2150404): per-row chain-verification map keyed
    /// by entry_id, plus the screen-level aggregate. Set by
    /// `loadActivity`; consumed by the view to stamp badges and the
    /// section pill.
    @Published private(set) var verificationByEntryId: [String: AuditChainVerifier.RowState] = [:]
    @Published private(set) var chainStatus: AuditChainVerifier.ChainStatus = .empty

    // MARK: - Dependencies

    private var ownerSpaceClient: OwnerSpaceClient?

    init(ownerSpaceClient: OwnerSpaceClient? = nil) {
        self.ownerSpaceClient = ownerSpaceClient
    }

    func configure(with client: OwnerSpaceClient) {
        self.ownerSpaceClient = client
    }

    // MARK: - Load

    /// Pull this connection's row out of the latest list and load
    /// its recent audit-history in the background.
    ///
    /// Area G (Android 79ab9b2): one screen now renders both
    /// desktops and agents. We resolve the connection_type via
    /// `connection.list`, then dispatch:
    ///   - device → `device.list` (existing path)
    ///   - agent  → `agent.list`  (new path; loads Contract + scope)
    func load(connectionId: String) async {
        guard let client = ownerSpaceClient else {
            state = .error("Not connected to vault")
            return
        }

        state = .loading

        // Resolve connection_type from the connections list. Falls
        // back to "device" on any failure to preserve legacy behavior.
        let connectionType = await resolveConnectionType(connectionId: connectionId, client: client) ?? "device"

        do {
            if connectionType == "agent" {
                try await loadAgent(connectionId: connectionId, client: client)
            } else {
                try await loadDevice(connectionId: connectionId, client: client)
            }
            // Fire activity load in the background so the card
            // renders without waiting on audit.
            Task { await loadActivity(connectionId: connectionId) }
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    private func resolveConnectionType(connectionId: String, client: OwnerSpaceClient) async -> String? {
        let connections = ConnectionsClient(ownerSpaceClient: client)
        guard let list = try? await connections.list() else { return nil }
        return list.items.first { $0.connectionId == connectionId }?.connectionType
    }

    private func loadDevice(connectionId: String, client: OwnerSpaceClient) async throws {
        let response = try await client.sendAndAwaitResponse(
            "device.list",
            timeout: 15
        )
        guard response.success else {
            state = .error(response.error ?? "Failed to load desktop")
            return
        }
        let devices = response.getArray("devices") ?? []
        guard let dict = devices.first(where: { ($0["connection_id"] as? String) == connectionId }) else {
            state = .error("Desktop not found")
            return
        }
        state = .loaded(DesktopDetailLoaded.from(dict: dict))
    }

    /// Area G — agent variant. Loads from `agent.list` and maps the
    /// agent-shaped fields onto `DesktopDetailLoaded` so the existing
    /// detail UI works without a per-type branch. The Contract lives
    /// on the loaded struct as `contract: AgentContract?`.
    private func loadAgent(connectionId: String, client: OwnerSpaceClient) async throws {
        let response = try await client.sendAndAwaitResponse(
            "agent.list",
            timeout: 15
        )
        guard response.success else {
            state = .error(response.error ?? "Failed to load agent")
            return
        }
        let agents = response.getArray("agents") ?? []
        guard let dict = agents.first(where: { ($0["connection_id"] as? String) == connectionId }) else {
            state = .error("Agent not found")
            return
        }

        let agentName = (dict["agent_name"] as? String) ?? "Agent"
        let agentType = dict["agent_type"] as? String
        let scope = (dict["scope"] as? [String]) ?? []
        let approvalMode = (dict["approval_mode"] as? String) ?? "always_ask"
        let rateLimit = dict["rate_limit"] as? [String: Any]
        let rateLimitMax = (rateLimit?["max"] as? Int) ?? 0
        let rateLimitPer = (rateLimit?["per"] as? String) ?? "hour"

        func parseISO(_ value: Any?) -> Date? {
            guard let s = value as? String else { return nil }
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return iso.date(from: s) ?? ISO8601DateFormatter().date(from: s)
        }

        var loaded = DesktopDetailLoaded(
            connectionId: connectionId,
            deviceName: agentName,
            status: (dict["status"] as? String) ?? "paired",
            hostname: dict["hostname"] as? String,
            platform: dict["platform"] as? String,
            osName: nil,
            osVersion: nil,
            // Surface agent_type as "App version" so the existing
            // detail card shows "what kind of agent" prominently.
            appVersion: agentType,
            clientIp: nil,
            binaryFingerprint: nil,
            machineFingerprint: nil,
            firstSeenAt: parseISO(dict["paired_at"]) ?? parseISO(dict["connected_at"]),
            sessionStatus: nil,
            sessionStartedAt: nil,
            sessionExpiresAt: nil,
            sessionLastActiveAt: parseISO(dict["last_active_at"]),
            sessionKeyRotations: 0
        )
        loaded.connectionType = "agent"
        loaded.contract = AgentContract(
            scope: scope,
            approvalMode: approvalMode,
            rateLimitMax: rateLimitMax,
            rateLimitPer: rateLimitPer
        )
        state = .loaded(loaded)
    }

    /// Area C (Android 2150404): the activity load now goes through
    /// `ConnectionAuditClient` (which returns the chain anchor +
    /// per-row hash/sig fields) and runs `AuditChainVerifier` over
    /// the page. Per-row verdicts land in `verificationByEntryId` so
    /// the view can stamp Verified / Tampered / Unsigned badges.
    private func loadActivity(connectionId: String) async {
        guard let client = ownerSpaceClient else {
            activity = .error("Not connected to vault")
            return
        }
        activity = .loading

        let auditClient = ConnectionAuditClient(ownerSpaceClient: client)
        do {
            let result = try await auditClient.list(
                connectionId: connectionId,
                limit: 20
            )

            // Walk the verifier over the page (newest-first). The
            // verifier reverses internally to keep prev_hash linkage
            // checkable.
            let (perRow, status) = AuditChainVerifier.verifyChain(
                rows: result.entries,
                anchor: result.chainAnchor,
                entryHashOf: { ($0.entryHash, $0.previousHash, $0.entrySig) }
            )
            var verdicts: [String: AuditChainVerifier.RowState] = [:]
            verdicts.reserveCapacity(result.entries.count)
            for (i, entry) in result.entries.enumerated() {
                verdicts[entry.entryId] = perRow[i].state
            }
            verificationByEntryId = verdicts
            chainStatus = status
            activity = .loaded(result.entries.map { DesktopActivityEntry.from(audit: $0) })
        } catch {
            activity = .error(error.localizedDescription)
        }
    }

    // MARK: - End session (without revoking the pairing)

    /// Force-end the current session vault-side without revoking the
    /// pairing. The desktop drops into its Start-New-Session view, so
    /// the user can start a fresh session without a full re-pair.
    /// Mirrors Android `endSession`.
    func endSession(connectionId: String) async {
        guard let client = ownerSpaceClient else { return }
        isWorking = true
        defer { isWorking = false }

        do {
            let response = try await client.sendAndAwaitResponse(
                "device.end-session",
                payload: [
                    "connection_id": AnyCodableValue(connectionId),
                    "reason": AnyCodableValue("phone_locked")
                ],
                timeout: 15
            )

            if response.success {
                toast = "Session ended."
                await load(connectionId: connectionId)
            } else {
                toast = response.error ?? "Failed to end session"
            }
        } catch {
            toast = error.localizedDescription
        }
    }

    // MARK: - Remove (revoke the desktop entirely)

    /// Revoke the desktop session AND retire the pairing. The desktop
    /// will need to re-pair to reconnect. Mirrors Android `remove`.
    ///
    /// Area G (Android 78e0ea9): agents go through `agent.revoke`
    /// instead of `device.revoke`. The subject is picked off the
    /// loaded state's connectionType so the same Remove button does
    /// the right thing on both surfaces.
    func remove(connectionId: String, onRemoved: @escaping () -> Void) async {
        guard let client = ownerSpaceClient else { return }
        let messageType: String = {
            if case .loaded(let loaded) = state, loaded.connectionType == "agent" {
                return "agent.revoke"
            }
            return "device.revoke"
        }()
        isWorking = true
        defer { isWorking = false }

        do {
            let response = try await client.sendAndAwaitResponse(
                messageType,
                payload: [
                    "connection_id": AnyCodableValue(connectionId),
                    "reason": AnyCodableValue("user_removed")
                ],
                timeout: 15
            )

            if response.success {
                onRemoved()
            } else {
                toast = response.error ?? "Failed to remove"
            }
        } catch {
            toast = error.localizedDescription
        }
    }
}

// MARK: - Models

/// Snapshot of one desktop pulled out of `device.list`. Mirrors
/// Android `DesktopDetailState.Loaded`.
struct DesktopDetailLoaded: Equatable {
    let connectionId: String
    let deviceName: String
    let status: String
    let hostname: String?
    let platform: String?
    let osName: String?
    let osVersion: String?
    let appVersion: String?
    let clientIp: String?
    let binaryFingerprint: String?
    let machineFingerprint: String?
    let firstSeenAt: Date?
    let sessionStatus: String?
    let sessionStartedAt: Date?
    let sessionExpiresAt: Date?
    let sessionLastActiveAt: Date?
    let sessionKeyRotations: Int
    /// Area G (Android 79ab9b2): "device" | "agent" | other. Drives
    /// agent-specific UI: Contract section, paired/revoked pill,
    /// agent.revoke instead of device.revoke.
    var connectionType: String = "device"
    /// Area G: the Contract — what scope/approval-mode/rate-limit was
    /// authorized for this agent. Nil for desktops.
    var contract: AgentContract? = nil

    static func from(dict: [String: Any]) -> DesktopDetailLoaded {
        let metadata = (dict["device_metadata"] as? [String: Any]) ?? dict
        let session = dict["device_session"] as? [String: Any]

        func parseDate(_ value: Any?) -> Date? {
            if let s = value as? String {
                let iso = ISO8601DateFormatter()
                iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let fb = ISO8601DateFormatter()
                return iso.date(from: s) ?? fb.date(from: s)
            }
            if let n = value as? TimeInterval {
                return Date(timeIntervalSince1970: n)
            }
            if let n = value as? Int {
                return Date(timeIntervalSince1970: TimeInterval(n))
            }
            return nil
        }

        return DesktopDetailLoaded(
            connectionId: dict["connection_id"] as? String ?? "",
            deviceName: (dict["device_name"] as? String) ?? (metadata["hostname"] as? String) ?? "Desktop",
            status: (dict["status"] as? String) ?? "unknown",
            hostname: metadata["hostname"] as? String,
            platform: metadata["platform"] as? String,
            osName: metadata["os_name"] as? String,
            osVersion: metadata["os_version"] as? String,
            appVersion: metadata["app_version"] as? String,
            clientIp: metadata["client_ip"] as? String,
            binaryFingerprint: metadata["binary_fingerprint"] as? String,
            machineFingerprint: metadata["machine_fingerprint"] as? String,
            firstSeenAt: parseDate(metadata["first_seen_at"]) ?? parseDate(dict["connected_at"]),
            sessionStatus: session?["status"] as? String ?? dict["session_status"] as? String,
            sessionStartedAt: parseDate(session?["created_at"] ?? session?["started_at"]),
            sessionExpiresAt: parseDate(session?["expires_at"] ?? dict["session_expires"]),
            sessionLastActiveAt: parseDate(session?["last_active_at"] ?? dict["last_active_at"]),
            sessionKeyRotations: (session?["key_rotation_count"] as? Int) ?? 0
        )
    }
}

enum DesktopDetailState: Equatable {
    case loading
    case loaded(DesktopDetailLoaded)
    case error(String)
}

/// Contract that defines what a paired agent is allowed to do. The
/// vault stores the authoritative copy. Mirrors Android `AgentContract`
/// (commit 79ab9b2).
struct AgentContract: Equatable {
    let scope: [String]
    let approvalMode: String       // "always_ask" | "auto_within_contract"
    let rateLimitMax: Int
    let rateLimitPer: String       // "minute" | "hour"
}

struct DesktopActivityEntry: Equatable, Identifiable {
    let id: String
    let title: String
    let body: String?
    let createdAt: Date?
    /// Event type — drives the lifecycle icon/label mapping below.
    /// Empty for legacy rows that pre-date the connection.audit
    /// surface.
    let eventType: String

    static func from(dict: [String: Any]) -> DesktopActivityEntry? {
        guard let id = dict["id"] as? String ?? dict["event_id"] as? String else { return nil }
        let createdAt: Date? = {
            if let s = dict["created_at"] as? String {
                let iso = ISO8601DateFormatter()
                iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                return iso.date(from: s) ?? ISO8601DateFormatter().date(from: s)
            }
            if let n = dict["created_at"] as? TimeInterval {
                return Date(timeIntervalSince1970: n)
            }
            if let n = dict["created_at"] as? Int {
                return Date(timeIntervalSince1970: TimeInterval(n))
            }
            return nil
        }()
        let rawTitle = (dict["title"] as? String) ?? ""
        let title = rawTitle.isEmpty ? ((dict["event_type"] as? String) ?? "Activity") : rawTitle
        return DesktopActivityEntry(
            id: id,
            title: title,
            body: dict["body"] as? String,
            createdAt: createdAt,
            eventType: (dict["event_type"] as? String) ?? ""
        )
    }

    /// Adapter from the typed `AuditEntry` returned by
    /// `ConnectionAuditClient`. The activity row UI uses the simpler
    /// `DesktopActivityEntry` shape; the per-row verification verdict
    /// lives on the view-model in `verificationByEntryId`.
    static func from(audit: AuditEntry) -> DesktopActivityEntry {
        DesktopActivityEntry(
            id: audit.entryId,
            title: audit.title,
            body: audit.body,
            createdAt: audit.createdAtDate,
            eventType: audit.eventType
        )
    }
}

enum DesktopActivityState: Equatable {
    case loading
    case loaded([DesktopActivityEntry])
    case error(String)
}
