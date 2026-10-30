import Foundation
import Observation
import VettIDData
import VettIDVault

/// TEST ONLY. An in-memory feed for view-model tests, like ``FakeConnections``: every call is recorded in ``calls``
/// (`refresh`, `setStatus:<id>:<status>`, `markReadQuietly:<id>`, `markViewed:<ids>`, `delete:<id>`, `markAllRead`);
/// ``fail`` makes the next call of a name throw. Observable, as ``FeedManager`` is. Mirrors vettid-android `FakeFeed`.
@MainActor
@Observable
public final class FakeFeed: FeedRepository {
    public var calls: [String] = []
    public var fail: [String: VaultFailure] = [:]
    public var items: [FeedItem] = []
    public var load: FeedLoad = .loaded

    public init() {}

    public var badge: FeedBadge {
        let unread = items.filter { $0.status == FeedManager.statusActive }
        return FeedBadge(unread: unread.count, urgent: unread.contains { $0.priority == FeedManager.priorityUrgent })
    }

    private func call(_ name: String, _ detail: String = "") throws {
        calls.append(detail.isEmpty ? name : "\(name):\(detail)")
        if let f = fail.removeValue(forKey: name) { throw f }
    }

    private func set(_ id: String, _ status: String) {
        guard let i = items.firstIndex(where: { $0.itemID == id }) else { return }
        items[i].status = status
        items[i].seq += 1
    }

    public func refresh() async throws {
        do {
            try call("refresh")
            load = .loaded
        } catch {
            load = .failed
            throw error
        }
    }

    public func setStatus(_ itemID: String, status: String) async throws {
        try call("setStatus", "\(itemID):\(status)")
        set(itemID, status)
    }

    public func markReadQuietly(_ itemID: String) {
        calls.append("markReadQuietly:\(itemID)")
        if items.first(where: { $0.itemID == itemID })?.status == FeedManager.statusActive { set(itemID, FeedManager.statusRead) }
    }

    public func markViewed(_ itemIDs: [String]) {
        calls.append("markViewed:\(itemIDs.sorted().joined(separator: ","))")
        for id in itemIDs where items.first(where: { $0.itemID == id })?.status == FeedManager.statusActive {
            set(id, FeedManager.statusRead)
        }
    }

    public func delete(_ itemID: String) async throws {
        try call("delete", itemID)
        items.removeAll { $0.itemID == itemID }
    }

    public func markAllRead() async throws {
        try call("markAllRead")
        for i in items where i.status == FeedManager.statusActive { set(i.itemID, FeedManager.statusRead) }
    }
}

/// TEST ONLY. In-memory approvals for view-model tests: [listed] the approvals other than the connection requests, which
/// are [connections]' (``FakeConnections``), listed with them as ``ApprovalsManager`` lists them. Every call is recorded
/// in ``calls`` (with the request's id); ``fail`` makes the next call of a name throw; a decided approval leaves the list.
/// Mirrors the approvals part of vettid-android `FakeSocial`.
@MainActor
@Observable
public final class FakeApprovals: ApprovalsRepository {
    public var calls: [String] = []
    public var fail: [String: VaultFailure] = [:]
    public var listed: [PendingApproval] = [] {
        didSet { arrived.formUnion(listed.map(\.key)) }
    }
    public let connections: FakeConnections
    public private(set) var forgetCount = 0
    /// The approvals listed since the last ``forgetOpenVault()``.
    private var arrived: Set<String> = []

    /// What a lock or a hold does to ``ApprovalsManager``: every approval dropped from memory.
    public func forgetOpenVault() {
        listed = []
        arrived = []
        pendingListAnswered = false
        deviceSessions = [:]
        deviceSessionsKnown = false
        forgetCount += 1
    }

    /// `pending.list` has been read through since the last drop (VAULT-MESSAGING 0.70.0 §10.4.2): a test sets it.
    public var pendingListAnswered = false
    /// Why the last `pending.list` read failed (VAULT-MESSAGING 0.70.0 §10.4.2); a test sets it.
    public var openAsksError: FailureKind?

    public func mayHaveBeenDropped(_ key: String) -> Bool {
        PendingApproval.eventOnly(key: key) && !arrived.contains(key) && !pendingListAnswered
    }

    /// The asks withdrawn by their challenger (VAULT-MESSAGING 0.80.0 §10.4); ``withdraw(_:)`` adds one.
    public var withdrawn: Set<String> = []

    public func wasWithdrawn(_ key: String) -> Bool { withdrawn.contains(key) }

    /// What `sync.event{connection.authenticate.decided, withdrawn: true}` does to ``ApprovalsManager``: the ask closes
    /// and is noted as withdrawn.
    public func withdraw(_ key: String) {
        withdrawn.insert(key)
        drop(key)
    }
    /// What ``approveCriticalUse(_:password:)`` returns.
    public var criticalStatus: String? = "ok"
    /// The payload ``loadCriticalUse(_:)`` fills in (standard base64).
    public var criticalPayload = ""
    /// The last password a decision received (tests check that it is passed, never that it is kept).
    public private(set) var lastPassword: String?
    public private(set) var lastGrantDecision: GrantDecision?
    public private(set) var lastShare: (include: [String], decline: [String])?

    public init(connections: FakeConnections = FakeConnections()) { self.connections = connections }

    public var approvals: [PendingApproval] {
        (listed + connections.requests.map(PendingApproval.connection)).sorted { $0.receivedAt > $1.receivedAt }
    }

    private func call(_ name: String, _ id: String) throws {
        calls.append("\(name):\(id)")
        if let f = fail.removeValue(forKey: name) { throw f }
    }

    private func drop(_ key: String) { listed.removeAll { $0.key == key } }

    public func refreshApprovals() async throws { try call("refreshApprovals", "") }

    public func loadCriticalUse(_ requestID: String) async throws {
        try call("loadCriticalUse", requestID)
        guard let i = listed.firstIndex(where: { $0.key == "critical:\(requestID)" }), case .critical(var c) = listed[i] else { return }
        c.payload = criticalPayload
        listed[i] = .critical(c)
    }

    public func approveAuthentication(_ requestID: String, password: String) async throws {
        lastPassword = password
        try decided("approveAuthentication", "auth:\(requestID)", requestID)
    }

    public func denyAuthentication(_ requestID: String) async throws {
        try decided("denyAuthentication", "auth:\(requestID)", requestID)
    }

    /// A decision of [key]: like ``ApprovalsManager``, a request the vault no longer knows (`not_found`) leaves the list too.
    private func decided(_ name: String, _ key: String, _ id: String) throws {
        do {
            try call(name, id)
        } catch let f as VaultFailure where f.kind == .notFound {
            drop(key)
            throw f
        }
        drop(key)
    }

    public func decideGrant(_ requestID: String, approve: Bool) async throws {
        try call(approve ? "approveGrant" : "denyGrant", requestID)
        drop("grant:\(requestID)")
    }

    public func decideGrant(_ requestID: String, decision: GrantDecision) async throws {
        lastGrantDecision = decision
        try call("decideGrant", requestID)
        drop("grant:\(requestID)")
    }

    public func approveCriticalUse(_ requestID: String, password: String) async throws -> String? {
        lastPassword = password
        try call("approveCriticalUse", requestID)
        drop("critical:\(requestID)")
        return criticalStatus
    }

    public func denyCriticalUse(_ requestID: String) async throws {
        try call("denyCriticalUse", requestID)
        drop("critical:\(requestID)")
    }

    public func decideShare(_ ruleID: String, include: [String], decline: [String]) async throws {
        lastShare = (include, decline)
        try call("decideShare", ruleID)
        drop("share:\(ruleID)")
    }

    public func declineDeviceRequest(_ key: String) async throws {
        try call("declineDeviceRequest", key)
        drop(key)
    }

    /// The sessions' ends, by device; a test sets them and ``deviceSessionsKnown`` (or lets ``readDeviceSessions()`` set it).
    public var deviceSessions: [String: Date] = [:] {
        didSet { deviceSessionsVersion += 1 }
    }
    public var deviceSessionsKnown = false
    public private(set) var deviceSessionReads = 0
    public private(set) var deviceSessionsVersion = 0
    public var vaultHeld = false
    /// When set, ``readDeviceSessions()`` waits for it (a read on its way).
    public var sessionsGate: (@MainActor () async -> Void)?

    public func readDeviceSessions() async throws {
        try call("readDeviceSessions", "")
        if let sessionsGate { await sessionsGate() }
        deviceSessionsKnown = true
        deviceSessionReads += 1
    }

    /// What a `sync.event` `device.session` does: the device's session ends at [expiresAt], or it has none.
    public func sessionEvent(_ deviceID: String, expiresAt: Date?) { deviceSessions[deviceID] = expiresAt }

    /// What a read that answers does: the sessions as the vault lists them now.
    public func sessionsRead(_ sessions: [String: Date]) {
        deviceSessions = sessions
        deviceSessionsKnown = true
        deviceSessionReads += 1
    }

    /// When set, ``endDeviceAccess(_:)`` waits for it (an end on its way).
    public var endGate: (@MainActor () async -> Void)?
    /// When set, a failed end reads the sessions again with these, as ``ApprovalsManager`` does.
    public var sessionsAfterFailedEnd: [String: Date]?
    /// The screens asking for the sessions (``askDeviceSessions()``).
    public private(set) var sessionAskers = 0

    public func askDeviceSessions() -> DeviceSessionsAsk {
        sessionAskers += 1
        return DeviceSessionsAsk { [weak self] in Task { @MainActor in self?.sessionAskers -= 1 } }
    }

    public func endDeviceAccess(_ deviceID: String) async throws {
        if let endGate { await endGate() }
        do {
            try call("endDeviceAccess", deviceID)
        } catch {
            if let again = sessionsAfterFailedEnd { sessionsRead(again) }
            throw error
        }
        deviceSessions[deviceID] = nil
        listed.removeAll { if case .device(let d) = $0 { d.deviceID == deviceID } else { false } }
    }

    // MARK: - ConnectionRequestsRepository, through the connections

    public var requests: [PendingConnection] { connections.requests }
    public var requestEnds: [String: RequestEnd] { connections.requestEnds }
    public var peerDeclines: [PeerDecline] { connections.peerDeclines }
    public func dismissPeerDecline(_ requestID: String) { connections.dismissPeerDecline(requestID) }
    public func refreshRequests() async throws { try await connections.refreshRequests() }
    public func approveConnection(_ pendingID: String) async throws { try await connections.approveConnection(pendingID) }
    public func declineConnection(_ pendingID: String) async throws { try await connections.declineConnection(pendingID) }
    public func blockConnectionRequest(_ pendingID: String) async throws { try await connections.blockConnectionRequest(pendingID) }
    public func approveOutgoing(_ connectionID: String) async throws { try await connections.approveOutgoing(connectionID) }
    public func declineOutgoing(_ connectionID: String) async throws { try await connections.declineOutgoing(connectionID) }
}
