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

    // MARK: - Dependencies

    private var ownerSpaceClient: OwnerSpaceClient?

    init(ownerSpaceClient: OwnerSpaceClient? = nil) {
        self.ownerSpaceClient = ownerSpaceClient
    }

    func configure(with client: OwnerSpaceClient) {
        self.ownerSpaceClient = client
    }

    // MARK: - Load

    /// Pull this desktop's row out of the latest `device.list` and
    /// load its recent audit-history in the background. Mirrors
    /// Android's load() — call on first appear.
    func load(connectionId: String) async {
        guard let client = ownerSpaceClient else {
            state = .error("Not connected to vault")
            return
        }

        state = .loading

        do {
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

            let loaded = DesktopDetailLoaded.from(dict: dict)
            state = .loaded(loaded)

            // Fire activity load in the background so the device card
            // renders without waiting on audit.
            Task { await loadActivity(connectionId: connectionId) }
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    private func loadActivity(connectionId: String) async {
        guard let client = ownerSpaceClient else {
            activity = .error("Not connected to vault")
            return
        }
        activity = .loading

        do {
            let response = try await client.sendAndAwaitResponse(
                "connection.audit.list",
                payload: [
                    "connection_id": AnyCodableValue(connectionId),
                    "limit": AnyCodableValue(20)
                ],
                timeout: 15
            )

            guard response.success else {
                activity = .error(response.error ?? "Failed to load activity")
                return
            }

            let entries = (response.getArray("entries") ?? []).compactMap { DesktopActivityEntry.from(dict: $0) }
            activity = .loaded(entries)
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
    func remove(connectionId: String, onRemoved: @escaping () -> Void) async {
        guard let client = ownerSpaceClient else { return }
        isWorking = true
        defer { isWorking = false }

        do {
            let response = try await client.sendAndAwaitResponse(
                "device.revoke",
                payload: [
                    "connection_id": AnyCodableValue(connectionId),
                    "reason": AnyCodableValue("user_removed")
                ],
                timeout: 15
            )

            if response.success {
                onRemoved()
            } else {
                toast = response.error ?? "Failed to remove desktop"
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

struct DesktopActivityEntry: Equatable, Identifiable {
    let id: String
    let title: String
    let body: String?
    let createdAt: Date?

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
            createdAt: createdAt
        )
    }
}

enum DesktopActivityState: Equatable {
    case loading
    case loaded([DesktopActivityEntry])
    case error(String)
}
