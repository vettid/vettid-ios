import Foundation

/// Client for communicating with the vault via OwnerSpace NATS topics
///
/// Topic structure:
/// - Publish: OwnerSpace.{guid}.forVault.{topic}
/// - Subscribe: OwnerSpace.{guid}.forApp.{topic}
final class OwnerSpaceClient {

    // MARK: - Properties

    private let connectionManager: NatsConnectionManager
    /// The owner-space identifier (UUID) this client routes through. Exposed
    /// so callers like `AppState` can decide whether to rebuild clients
    /// after credential rotation.
    let ownerSpaceId: String

    // Topic prefixes
    private var forVaultPrefix: String { "\(ownerSpaceId).forVault" }
    private var forAppPrefix: String { "\(ownerSpaceId).forApp" }
    private var eventTypesSubject: String { "\(ownerSpaceId).eventTypes" }

    // MARK: - Initialization

    init(connectionManager: NatsConnectionManager, ownerSpaceId: String) {
        self.connectionManager = connectionManager
        self.ownerSpaceId = ownerSpaceId
    }

    // MARK: - Send to Vault

    /// Send a message to the vault
    func sendToVault<T: Encodable>(_ message: T, topic: String) async throws {
        let fullTopic = "\(forVaultPrefix).\(topic)"
        try await connectionManager.publish(message, to: fullTopic)
    }

    /// Send raw data to the vault
    func sendToVault(_ data: Data, topic: String) async throws {
        let fullTopic = "\(forVaultPrefix).\(topic)"
        try await connectionManager.publish(data, to: fullTopic)
    }

    /// Execute a handler in the vault
    func executeHandler(handlerId: String, payload: [String: Any]) async throws -> String {
        let id = UUID().uuidString
        let message = ExecuteHandlerRequest(
            id: id,
            handlerId: handlerId,
            payload: payload
        )

        try await sendToVault(message, topic: "execute")
        return id
    }

    /// Request vault status
    func requestStatus() async throws -> String {
        let id = UUID().uuidString
        let message = StatusRequest(id: id)

        try await sendToVault(message, topic: "status")
        return id
    }

    // MARK: - Subscribe from Vault

    /// Subscribe to messages from the vault on a specific topic
    func subscribeToVault<T: Decodable>(topic: String, type: T.Type) async throws -> AsyncStream<T> {
        let fullTopic = "\(forAppPrefix).\(topic)"
        return try await connectionManager.subscribe(to: fullTopic, type: type)
    }

    /// Subscribe to all vault responses
    func subscribeToAllVaultResponses() async throws -> AsyncStream<VaultResponse> {
        let fullTopic = "\(forAppPrefix).>"
        return try await connectionManager.subscribe(to: fullTopic, type: VaultResponse.self)
    }

    /// Subscribe to handler results
    func subscribeToHandlerResults() async throws -> AsyncStream<HandlerResultResponse> {
        return try await subscribeToVault(topic: "result", type: HandlerResultResponse.self)
    }

    /// Subscribe to status responses
    func subscribeToStatusResponses() async throws -> AsyncStream<StatusResponse> {
        return try await subscribeToVault(topic: "status", type: StatusResponse.self)
    }

    /// Subscribe to vault events (legacy)
    func subscribeToEvents() async throws -> AsyncStream<VaultEvent> {
        return try await subscribeToVault(topic: "events", type: VaultEvent.self)
    }

    // MARK: - Security Events (Issue #17)

    /// Subscribe to security events from the vault
    /// Topics: forApp.recovery.>, forApp.transfer.>, forApp.security.>
    func subscribeToSecurityEvents() async throws -> AsyncStream<VaultSecurityEvent> {
        // Subscribe to all security-related topics using wildcards
        let topics = [
            "\(forAppPrefix).recovery.>",
            "\(forAppPrefix).transfer.>",
            "\(forAppPrefix).security.>"
        ]

        return AsyncStream { continuation in
            Task {
                // Create a task group to handle multiple subscriptions
                await withTaskGroup(of: Void.self) { group in
                    for topic in topics {
                        group.addTask { [weak self] in
                            guard let self = self else { return }

                            do {
                                let stream = try await self.connectionManager.subscribe(
                                    to: topic,
                                    type: SecurityEventMessage.self
                                )

                                for await message in stream {
                                    if let event = VaultSecurityEvent.parse(from: message) {
                                        continuation.yield(event)
                                    }
                                }
                            } catch {
                                #if DEBUG
                                print("[OwnerSpaceClient] Failed to subscribe to \(topic): \(error)")
                                #endif
                            }
                        }
                    }
                }

                continuation.finish()
            }
        }
    }

    /// Subscribe to recovery events only
    func subscribeToRecoveryEvents() async throws -> AsyncStream<VaultSecurityEvent> {
        let topic = "\(forAppPrefix).recovery.>"
        return try await subscribeToSecurityTopic(topic)
    }

    /// Subscribe to transfer events only
    func subscribeToTransferEvents() async throws -> AsyncStream<VaultSecurityEvent> {
        let topic = "\(forAppPrefix).transfer.>"
        return try await subscribeToSecurityTopic(topic)
    }

    /// Subscribe to fraud detection events only
    func subscribeToFraudEvents() async throws -> AsyncStream<VaultSecurityEvent> {
        let topic = "\(forAppPrefix).security.>"
        return try await subscribeToSecurityTopic(topic)
    }

    /// Helper to subscribe to a single security topic
    private func subscribeToSecurityTopic(_ topic: String) async throws -> AsyncStream<VaultSecurityEvent> {
        let stream = try await connectionManager.subscribe(to: topic, type: SecurityEventMessage.self)

        return AsyncStream { continuation in
            Task {
                for await message in stream {
                    if let event = VaultSecurityEvent.parse(from: message) {
                        continuation.yield(event)
                    }
                }
                continuation.finish()
            }
        }
    }

    // MARK: - Request/Response Pattern

    /// Send a request and wait for a response with timeout (legacy subscription-based)
    func request<Request: Encodable, Response: Decodable>(
        _ request: Request,
        topic: String,
        responseType: Response.Type,
        timeout: TimeInterval = 30
    ) async throws -> Response {
        // Subscribe to response topic first
        let responseTopic = "\(forAppPrefix).\(topic).response"
        let responseStream = try await connectionManager.subscribe(to: responseTopic, type: Response.self)

        // Send the request
        try await sendToVault(request, topic: topic)

        // Wait for response with timeout
        return try await withThrowingTaskGroup(of: Response.self) { group in
            // Response listener task
            group.addTask {
                for await response in responseStream {
                    return response
                }
                throw OwnerSpaceError.noResponse
            }

            // Timeout task
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw OwnerSpaceError.timeout
            }

            // Return first result (response or timeout)
            guard let result = try await group.next() else {
                throw OwnerSpaceError.noResponse
            }

            group.cancelAll()
            return result
        }
    }

    // MARK: - JetStream Request/Response (event_id correlation)

    /// Send a message to the vault and await the response via JetStream.
    ///
    /// Uses JetStreamHelper to create an ephemeral consumer for reliable
    /// response delivery with event_id correlation. This avoids race conditions
    /// that occur with regular NATS subscriptions.
    ///
    /// - Parameters:
    ///   - messageType: The message type/action (e.g., "profile.get", "feed.sync")
    ///   - payload: The message payload as dictionary
    ///   - timeout: Timeout in seconds (default 30)
    /// - Returns: The parsed vault response, or nil if timeout
    func sendAndAwaitResponse(
        _ messageType: String,
        payload: [String: AnyCodableValue] = [:],
        timeout: TimeInterval = 30
    ) async throws -> VaultHandlerResponse {
        // Area D (Android 20ccbb9 + bc715b8): coalesce a burst of
        // identical read-only ops into one vault round-trip. Screen-
        // loads, the 30s periodic refresh, and event handlers
        // routinely fire the same feed.sync / connection.list /
        // wallet.list within the same second — this collapses each
        // burst to a single op.
        //
        // The freshness window is load-bearing: a request arriving
        // well after the leader started is a RETRY (the caller's
        // previous attempt is failing/slow). It must NOT coalesce —
        // if the leader is doomed (its response was lost to a NATS
        // resubscribe), coalescing every retry into it turns one
        // missed response into a 30s hang.
        guard Self.dedupSafeOps.contains(messageType) else {
            return try await dispatchVaultOp(
                messageType: messageType,
                payload: payload,
                timeout: timeout
            )
        }

        let key = Self.dedupKey(messageType: messageType, payload: payload)
        let now = Date()

        let leaderTask: Task<VaultHandlerResponse, Error>? = inflightLock.withLock {
            if let existing = inflight[key] {
                let age = now.timeIntervalSince(existing.startedAt)
                if age <= Self.dedupCoalesceWindow {
                    return existing.task
                }
                // Stale leader — caller is a deliberate retry. Bypass.
                return nil
            }
            return nil
        }
        if let task = leaderTask {
            #if DEBUG
            print("[OwnerSpaceClient] Coalesced \(messageType) into in-flight request")
            #endif
            do {
                return try await task.value
            } catch {
                // Leader failed — fall back to our own op.
                return try await dispatchVaultOp(
                    messageType: messageType,
                    payload: payload,
                    timeout: timeout
                )
            }
        }

        // We're the leader. Launch the dispatch in a child task so
        // followers awaiting via `task.value` get the result.
        let myTask = Task<VaultHandlerResponse, Error> {
            try await dispatchVaultOp(
                messageType: messageType,
                payload: payload,
                timeout: timeout
            )
        }
        let myToken = UUID()
        inflightLock.withLock {
            inflight[key] = InflightOp(task: myTask, startedAt: now, token: myToken)
        }
        defer {
            inflightLock.withLock {
                // Only clear if it's still ours — a stale-retry path
                // may have already overwritten the slot.
                if inflight[key]?.token == myToken {
                    inflight.removeValue(forKey: key)
                }
            }
        }
        return try await myTask.value
    }

    /// Single-flight dispatch — the unconditional one-vault-op path.
    /// `sendAndAwaitResponse` wraps this with burst-dedup; both safe
    /// reads and any mutation flow through here.
    private func dispatchVaultOp(
        messageType: String,
        payload: [String: AnyCodableValue],
        timeout: TimeInterval
    ) async throws -> VaultHandlerResponse {
        let requestId = UUID().uuidString
        let requestSubject = "\(forVaultPrefix).\(messageType)"
        let responseSubject = "\(forAppPrefix).\(messageType).response"

        let message = VaultEventMessage(
            id: requestId,
            type: messageType,
            payload: payload
        )

        let requestPayload = try JSONEncoder().encode(message)

        let responseData = try await JetStreamHelper.sendAndFetchResponse(
            connectionManager: connectionManager,
            requestSubject: requestSubject,
            responseSubject: responseSubject,
            requestPayload: requestPayload,
            expectedEventId: requestId,
            timeoutSeconds: timeout
        )

        // Parse response
        let response = try parseVaultResponse(requestId: requestId, data: responseData)

        // Detect vault_locked error and emit event for PIN re-entry
        if !response.success && response.errorCode == "vault_locked" {
            emitVaultLockedEvent(VaultLockedEvent(
                reason: response.error ?? "DEK unavailable",
                messageType: messageType
            ))
        }

        return response
    }

    // MARK: - In-flight dedup (Area D — Android 20ccbb9 / bc715b8)

    private struct InflightOp {
        let task: Task<VaultHandlerResponse, Error>
        let startedAt: Date
        /// Identity token so the leader's `defer` can clear the slot
        /// only if a stale-retry hasn't already overwritten it.
        /// Swift `Task` is a struct so we can't compare by `===`.
        let token: UUID
    }
    private var inflight: [String: InflightOp] = [:]
    private let inflightLock = NSLock()

    /// How long after a read op becomes the in-flight leader that a
    /// later identical request still coalesces onto it. Sized to a
    /// screen-load burst (sub-second). A request arriving past this
    /// window is a deliberate retry and is issued fresh — so a retry
    /// can recover from a leader whose response was lost (e.g. to a
    /// NATS resubscribe) instead of joining its timeout.
    private static let dedupCoalesceWindow: TimeInterval = 2.0

    /// Idempotent read ops safe to coalesce. Strict allowlist: a
    /// mutation must never be deduped, or two intentionally-identical
    /// writes would collapse into one. These are the read ops that
    /// screen-loads + the periodic refresh fire in bursts.
    private static let dedupSafeOps: Set<String> = [
        "feed.sync",
        "location.peer.get",
        "connection.list",
        "wallet.list",
        "personal-data.get",
        "secret.list",
        "device.list",
        "audit.query",
        "connection.audit.list",
        "profile.get"
    ]

    /// Stable string key over messageType + payload shape. Equal
    /// payloads must hash to equal keys; we serialise with sorted
    /// keys to make that robust against dict-iteration order.
    private static func dedupKey(messageType: String, payload: [String: AnyCodableValue]) -> String {
        // AnyCodableValue is Codable; use JSONEncoder with sortedKeys
        // so the same payload always produces the same string.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let payloadStr = (try? encoder.encode(payload)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return "\(messageType) \(payloadStr)"
    }

    /// Parse vault response data into a VaultHandlerResponse
    private func parseVaultResponse(requestId: String, data: Data) throws -> VaultHandlerResponse {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OwnerSpaceError.invalidResponse
        }

        let success = json["success"] as? Bool ?? (json["error"] == nil)
        let error = json["error"] as? String
        let errorCode = json["error_code"] as? String

        // Extract result object
        var result: [String: Any]?
        if let resultDict = json["result"] as? [String: Any] {
            result = resultDict
        } else if success {
            // Some responses put data at the top level
            result = json
        }

        return VaultHandlerResponse(
            requestId: json["event_id"] as? String ?? json["id"] as? String ?? requestId,
            success: success,
            result: result,
            error: error,
            errorCode: errorCode,
            raw: json
        )
    }

    // MARK: - Agent Events

    /// Publisher for agent approval requests
    private var agentApprovalContinuation: AsyncStream<AgentApprovalRequest>.Continuation?
    private var _agentApprovalStream: AsyncStream<AgentApprovalRequest>?

    /// Stream of agent approval requests from vault
    var agentApprovalRequests: AsyncStream<AgentApprovalRequest> {
        if let stream = _agentApprovalStream {
            return stream
        }
        let stream = AsyncStream<AgentApprovalRequest> { continuation in
            self.agentApprovalContinuation = continuation
            continuation.onTermination = { [weak self] _ in
                self?.agentApprovalContinuation = nil
                self?._agentApprovalStream = nil
            }
        }
        _agentApprovalStream = stream
        return stream
    }

    /// Emit an agent approval request (called from message handler)
    func emitAgentApprovalRequest(_ request: AgentApprovalRequest) {
        agentApprovalContinuation?.yield(request)
    }

    /// Stage-2 agent pairing: a vettid-agent has completed Stage-1
    /// (resolved invite, generated ephemeral X25519 keypair, posted
    /// agent.request-session) and is waiting on the phone's
    /// authorize-session decision. Carries the agent's identity card +
    /// requested scope hints. Mirrors Android
    /// `OwnerSpaceClient.agentPendingAuth`.
    private var agentPendingAuthContinuation: AsyncStream<AgentPendingAuthNotification>.Continuation?
    private var _agentPendingAuthStream: AsyncStream<AgentPendingAuthNotification>?

    var agentPendingAuth: AsyncStream<AgentPendingAuthNotification> {
        if let stream = _agentPendingAuthStream { return stream }
        let stream = AsyncStream<AgentPendingAuthNotification> { continuation in
            self.agentPendingAuthContinuation = continuation
            continuation.onTermination = { [weak self] _ in
                self?.agentPendingAuthContinuation = nil
                self?._agentPendingAuthStream = nil
            }
        }
        _agentPendingAuthStream = stream
        return stream
    }

    /// Subscribe to the `forApp.agent.>` family and pump decoded
    /// events into `agentApprovalRequests` (per-operation approvals)
    /// and `agentPendingAuth` (Stage-2 agent pairing). Idempotent;
    /// call once after PIN unlock from `AppState.syncProfileFromVault`
    /// alongside `startDeviceEventSubscription`. Mirrors Android
    /// `handleAgentPendingAuth` dispatch (Phase 4, commit 830ba5f).
    ///
    /// Subjects:
    ///   - forApp.agent.pending-authorization          → AgentPendingAuthNotification
    ///   - forApp.agent.approval.request.<requestId>   → AgentApprovalRequest
    private var agentSubscriptionTask: Task<Void, Never>?
    func startAgentEventSubscription() {
        guard agentSubscriptionTask == nil else { return }
        let prefix = forAppPrefix
        agentSubscriptionTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                let stream = try await self.connectionManager.subscribe(
                    to: "\(prefix).agent.>"
                )
                for await raw in stream {
                    if Task.isCancelled { return }
                    let subject = raw.topic
                    // Specific match BEFORE the catch-all approval path
                    // (Android 830ba5f: pending-authorization payload
                    // lacks the request_id field that approval parsers
                    // expect, so misrouting silently loses the event).
                    if subject.hasSuffix(".forApp.agent.pending-authorization") {
                        if let notif = Self.parseAgentPendingAuth(raw: raw) {
                            self.agentPendingAuthContinuation?.yield(notif)
                        }
                    } else if subject.contains(".forApp.agent.approval.request.") {
                        if let request = Self.parseAgentApprovalRequest(raw: raw) {
                            self.agentApprovalContinuation?.yield(request)
                        }
                    }
                }
            } catch {
                #if DEBUG
                print("[OwnerSpaceClient] agent.> subscription failed: \(error)")
                #endif
            }
        }
    }

    /// Decode a `forApp.agent.pending-authorization` message. Tolerates
    /// either flat or `{ "payload": {...} }` envelope wraps. Maps the
    /// 9-token `requested_scope` array straight through so the
    /// AuthorizeAgentView's scope picker can render unknown tokens
    /// rather than silently dropping them.
    private static func parseAgentPendingAuth(raw: NatsMessage) -> AgentPendingAuthNotification? {
        guard let json = (try? JSONSerialization.jsonObject(with: raw.data)) as? [String: Any] else {
            return nil
        }
        let outer = (json["payload"] as? [String: Any]) ?? json
        guard let connectionId = outer["connection_id"] as? String, !connectionId.isEmpty else {
            return nil
        }
        let metaDict = outer["agent_metadata"] as? [String: Any]
        let metadata = metaDict.map { dict in
            AgentMetadataSummary(
                agentType: dict["agent_type"] as? String ?? "",
                binaryFingerprint: dict["binary_fingerprint"] as? String ?? "",
                machineFingerprint: dict["machine_fingerprint"] as? String ?? "",
                hostname: dict["hostname"] as? String ?? "",
                platform: dict["platform"] as? String ?? "",
                osName: dict["os_name"] as? String ?? "",
                osVersion: dict["os_version"] as? String ?? "",
                appVersion: dict["app_version"] as? String ?? ""
            )
        }
        let requestedScope = (outer["requested_scope"] as? [String]) ?? []
        let intOrDouble: (Any?, Int) -> Int = { value, fallback in
            if let i = value as? Int { return i }
            if let d = value as? Double { return Int(d) }
            return fallback
        }
        return AgentPendingAuthNotification(
            connectionId: connectionId,
            approvalToken: outer["approval_token"] as? String ?? "",
            agentPubKey: outer["agent_pubkey"] as? String ?? "",
            agentMetadata: metadata,
            binaryFpPrefix: outer["binary_fp_prefix"] as? String ?? "",
            expiresAt: intOrDouble(outer["expires_at"], 0),
            requestedScope: requestedScope,
            requestedApprovalMode: outer["requested_approval_mode"] as? String ?? "always_ask",
            requestedDurationSeconds: intOrDouble(outer["requested_duration_s"], 0),
            defaultDurationSeconds: intOrDouble(outer["default_duration_s"], 3600),
            maxDurationSeconds: intOrDouble(outer["max_duration_s"], 24 * 3600)
        )
    }

    /// Decode a `forApp.agent.approval.request.<id>` message into an
    /// `AgentApprovalRequest`. Wires the previously-dead
    /// `agentApprovalRequests` stream (mirrors the device fix from
    /// Area B).
    private static func parseAgentApprovalRequest(raw: NatsMessage) -> AgentApprovalRequest? {
        guard let json = (try? JSONSerialization.jsonObject(with: raw.data)) as? [String: Any] else {
            return nil
        }
        guard let requestId = json["request_id"] as? String, !requestId.isEmpty else {
            return nil
        }
        let timestamp: String? = {
            if let s = json["timestamp"] as? String { return s }
            if let n = json["timestamp"] as? Double {
                return ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: n))
            }
            return nil
        }()
        let payloadDict = json["payload"] as? [String: Any]
        return AgentApprovalRequest(
            requestId: requestId,
            agentName: (json["agent_name"] as? String) ?? "Agent",
            agentType: json["agent_type"] as? String,
            operation: json["operation"] as? String,
            secretCategory: (payloadDict?["id"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            timestamp: timestamp
        )
    }

    // MARK: - Device Events

    /// Publisher for device approval requests
    private var deviceApprovalContinuation: AsyncStream<DeviceApprovalRequest>.Continuation?
    private var _deviceApprovalStream: AsyncStream<DeviceApprovalRequest>?

    /// Stream of device approval requests from vault
    var deviceApprovalRequests: AsyncStream<DeviceApprovalRequest> {
        if let stream = _deviceApprovalStream {
            return stream
        }
        let stream = AsyncStream<DeviceApprovalRequest> { continuation in
            self.deviceApprovalContinuation = continuation
            continuation.onTermination = { [weak self] _ in
                self?.deviceApprovalContinuation = nil
                self?._deviceApprovalStream = nil
            }
        }
        _deviceApprovalStream = stream
        return stream
    }

    /// Emit a device approval request (called from message handler)
    func emitDeviceApprovalRequest(_ request: DeviceApprovalRequest) {
        deviceApprovalContinuation?.yield(request)
    }

    /// Stage-2 pairing: a paired desktop has completed Stage-1 and is
    /// waiting on the phone's authorize-session decision. Carries the
    /// desktop's full identity for the AuthorizeDeviceView's fingerprint
    /// card. Mirrors Android `OwnerSpaceClient.devicePendingAuth`.
    private var devicePendingAuthContinuation: AsyncStream<DevicePendingAuthNotification>.Continuation?
    private var _devicePendingAuthStream: AsyncStream<DevicePendingAuthNotification>?

    var devicePendingAuth: AsyncStream<DevicePendingAuthNotification> {
        if let stream = _devicePendingAuthStream { return stream }
        let stream = AsyncStream<DevicePendingAuthNotification> { continuation in
            self.devicePendingAuthContinuation = continuation
            continuation.onTermination = { [weak self] _ in
                self?.devicePendingAuthContinuation = nil
                self?._devicePendingAuthStream = nil
            }
        }
        _devicePendingAuthStream = stream
        return stream
    }

    /// Subscribe to the `forApp.device.>` family and pump decoded
    /// events into `deviceApprovalRequests` (per-operation approvals)
    /// and `devicePendingAuth` (Stage-2 desktop pairing). Idempotent;
    /// call once after PIN unlock from `AppState.syncProfileFromVault`
    /// alongside the other warm-up wires.
    ///
    /// Subjects:
    ///   - forApp.device.approval.request.<requestId>   → DeviceApprovalRequest
    ///   - forApp.device.pending-authorization          → DevicePendingAuthNotification
    private var deviceSubscriptionTask: Task<Void, Never>?
    func startDeviceEventSubscription() {
        guard deviceSubscriptionTask == nil else { return }
        let prefix = forAppPrefix
        deviceSubscriptionTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                let stream = try await self.connectionManager.subscribe(
                    to: "\(prefix).device.>"
                )
                for await raw in stream {
                    if Task.isCancelled { return }
                    let subject = raw.topic
                    if subject.contains(".forApp.device.approval.request.") {
                        if let request = Self.parseDeviceApprovalRequest(raw: raw) {
                            self.deviceApprovalContinuation?.yield(request)
                        }
                    } else if subject.hasSuffix(".forApp.device.pending-authorization") {
                        if let notif = Self.parseDevicePendingAuth(raw: raw) {
                            self.devicePendingAuthContinuation?.yield(notif)
                        }
                    }
                }
            } catch {
                #if DEBUG
                print("[OwnerSpaceClient] device.> subscription failed: \(error)")
                #endif
            }
        }
    }

    /// Pull device-operation approvals still awaiting this owner's
    /// decision and surface each one onto `deviceApprovalRequests`
    /// (same flow a live request uses). Mirrors Android
    /// `OwnerSpaceClient.fetchPendingDeviceApprovals`.
    ///
    /// The live approval request reaches the phone over a core-NATS
    /// forApp.* subject with no replay — a phone that was killed or
    /// offline when a desktop made the request never sees it. Pulling
    /// on every post-unlock rebuilds the pending set from the vault,
    /// the durable source of truth, so the user can still act on a
    /// request that arrived while the app was down. Best-effort: a
    /// transport error or timeout is logged and ignored.
    func fetchPendingDeviceApprovals() async {
        do {
            let response = try await sendAndAwaitResponse(
                "device.approval-pending",
                timeout: 15
            )
            guard response.success else { return }
            let pending = response.getArray("pending") ?? []
            var surfaced = 0
            for entry in pending {
                guard let requestId = entry["request_id"] as? String, !requestId.isEmpty else {
                    continue
                }
                let payloadDict = entry["payload"] as? [String: Any]
                let request = DeviceApprovalRequest(
                    requestId: requestId,
                    connectionId: entry["connection_id"] as? String ?? "",
                    deviceName: (entry["device_name"] as? String) ?? "Desktop",
                    operation: entry["operation"] as? String ?? "unknown",
                    secretCategory: (payloadDict?["id"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                    timestamp: entry["timestamp"] as? String
                )
                deviceApprovalContinuation?.yield(request)
                surfaced += 1
            }
            #if DEBUG
            if surfaced > 0 {
                print("[OwnerSpaceClient] Pending-approvals pull: surfaced \(surfaced) device approval(s)")
            }
            #endif
        } catch {
            #if DEBUG
            print("[OwnerSpaceClient] fetchPendingDeviceApprovals failed: \(error)")
            #endif
        }
    }

    /// Decode a `forApp.device.approval.request.<id>` message into a
    /// `DeviceApprovalRequest`. Tolerates a null `payload` field — for
    /// ops that carry no inner data (e.g. `secret.unlock-session`) the
    /// vault serialises it as JSON null. Mirrors Android
    /// `handleDeviceApprovalRequest` (commit bd5b681).
    private static func parseDeviceApprovalRequest(raw: NatsMessage) -> DeviceApprovalRequest? {
        guard let json = (try? JSONSerialization.jsonObject(with: raw.data)) as? [String: Any] else {
            return nil
        }
        guard let requestId = json["request_id"] as? String, !requestId.isEmpty else {
            return nil
        }
        // `payload` may be JSON null when the op carries no inner data;
        // cast-to-dict naturally yields nil there.
        let payloadDict = json["payload"] as? [String: Any]
        return DeviceApprovalRequest(
            requestId: requestId,
            connectionId: json["connection_id"] as? String ?? "",
            deviceName: (json["device_name"] as? String) ?? "Desktop",
            operation: json["operation"] as? String ?? "unknown",
            secretCategory: (payloadDict?["id"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            timestamp: json["timestamp"] as? String
        )
    }

    /// Decode a `forApp.device.pending-authorization` message into a
    /// `DevicePendingAuthNotification`. The desktop's identity card
    /// (hostname / fingerprints / app version) is inlined under
    /// `device_metadata`; the vault's session-duration policy under
    /// `default_duration_seconds` + `max_duration_seconds`.
    private static func parseDevicePendingAuth(raw: NatsMessage) -> DevicePendingAuthNotification? {
        guard let json = (try? JSONSerialization.jsonObject(with: raw.data)) as? [String: Any] else {
            return nil
        }
        // Allow either flat or nested `payload` shape — same tolerance
        // we use for presence heartbeats.
        let outer = (json["payload"] as? [String: Any]) ?? json
        guard let connectionId = outer["connection_id"] as? String, !connectionId.isEmpty else {
            return nil
        }
        let metaDict = outer["device_metadata"] as? [String: Any]
        let metadata = metaDict.map { dict in
            DevicePendingAuthMetadata(
                hostname: dict["hostname"] as? String ?? "",
                platform: dict["platform"] as? String ?? "",
                osName: dict["os_name"] as? String ?? "",
                osVersion: dict["os_version"] as? String ?? "",
                appVersion: dict["app_version"] as? String ?? "",
                clientIp: dict["client_ip"] as? String ?? "",
                binaryFingerprint: dict["binary_fingerprint"] as? String ?? "",
                machineFingerprint: dict["machine_fingerprint"] as? String ?? ""
            )
        }
        let defaultSec = (outer["default_duration_seconds"] as? Int)
            ?? (outer["default_duration_seconds"] as? Double).map(Int.init)
            ?? 24 * 60 * 60
        let maxSec = (outer["max_duration_seconds"] as? Int)
            ?? (outer["max_duration_seconds"] as? Double).map(Int.init)
            ?? 30 * 24 * 60 * 60
        return DevicePendingAuthNotification(
            connectionId: connectionId,
            deviceMetadata: metadata,
            defaultDurationSeconds: defaultSec,
            maxDurationSeconds: maxSec
        )
    }

    // MARK: - Connection Events

    /// Publisher for connection acceptance notifications
    private var connectionAcceptanceContinuation: AsyncStream<ConnectionPeerAccepted>.Continuation?
    private var _connectionAcceptanceStream: AsyncStream<ConnectionPeerAccepted>?

    var connectionAcceptances: AsyncStream<ConnectionPeerAccepted> {
        if let stream = _connectionAcceptanceStream {
            return stream
        }
        let stream = AsyncStream<ConnectionPeerAccepted> { continuation in
            self.connectionAcceptanceContinuation = continuation
            continuation.onTermination = { [weak self] _ in
                self?.connectionAcceptanceContinuation = nil
                self?._connectionAcceptanceStream = nil
            }
        }
        _connectionAcceptanceStream = stream
        return stream
    }

    func emitConnectionAcceptance(_ acceptance: ConnectionPeerAccepted) {
        connectionAcceptanceContinuation?.yield(acceptance)
    }

    /// Publisher for connection status updates
    private var connectionStatusContinuation: AsyncStream<ConnectionStatusUpdate>.Continuation?
    private var _connectionStatusStream: AsyncStream<ConnectionStatusUpdate>?

    var connectionStatusUpdates: AsyncStream<ConnectionStatusUpdate> {
        if let stream = _connectionStatusStream {
            return stream
        }
        let stream = AsyncStream<ConnectionStatusUpdate> { continuation in
            self.connectionStatusContinuation = continuation
            continuation.onTermination = { [weak self] _ in
                self?.connectionStatusContinuation = nil
                self?._connectionStatusStream = nil
            }
        }
        _connectionStatusStream = stream
        return stream
    }

    func emitConnectionStatusUpdate(_ update: ConnectionStatusUpdate) {
        connectionStatusContinuation?.yield(update)
    }

    // MARK: - Feed Events

    /// Publisher for feed notifications
    private var feedNotificationContinuation: AsyncStream<FeedNotification>.Continuation?
    private var _feedNotificationStream: AsyncStream<FeedNotification>?

    var feedNotifications: AsyncStream<FeedNotification> {
        if let stream = _feedNotificationStream {
            return stream
        }
        let stream = AsyncStream<FeedNotification> { continuation in
            self.feedNotificationContinuation = continuation
            continuation.onTermination = { [weak self] _ in
                self?.feedNotificationContinuation = nil
                self?._feedNotificationStream = nil
            }
        }
        _feedNotificationStream = stream
        return stream
    }

    func emitFeedNotification(_ notification: FeedNotification) {
        feedNotificationContinuation?.yield(notification)
    }

    // MARK: - Own-profile snapshot ticks (forApp.profile.public.>)

    /// Tick stream for "the vault just published a fresh snapshot of *my*
    /// profile" — fires on every `forApp.profile.public.*` message so the
    /// data-cache layer can re-hydrate after a multi-device edit or any
    /// out-of-band catalog change the local ViewModels didn't drive.
    /// Mirrors Android `OwnerSpaceClient.ownProfileSnapshotTick`. Payload
    /// is deliberately not surfaced — re-hydrate is the only sensible
    /// reaction, and consumers should always go back to `profile.get-
    /// published` for the authoritative state.
    private var ownProfileSnapshotContinuation: AsyncStream<Void>.Continuation?
    private var _ownProfileSnapshotStream: AsyncStream<Void>?
    private var ownProfileSnapshotTask: Task<Void, Never>?

    var ownProfileSnapshotTicks: AsyncStream<Void> {
        if let stream = _ownProfileSnapshotStream { return stream }
        let stream = AsyncStream<Void> { continuation in
            self.ownProfileSnapshotContinuation = continuation
            continuation.onTermination = { [weak self] _ in
                self?.ownProfileSnapshotContinuation = nil
                self?._ownProfileSnapshotStream = nil
            }
        }
        _ownProfileSnapshotStream = stream
        return stream
    }

    /// Start the `forApp.profile.public.>` subscription that drives
    /// `ownProfileSnapshotTicks`. Idempotent; the first call wires the
    /// subscription, subsequent calls are no-ops. Call this once after
    /// PIN unlock (after `OwnerSpaceClient` has its space configured).
    func startOwnProfileSnapshotSubscription() {
        guard ownProfileSnapshotTask == nil else { return }
        let prefix = forAppPrefix
        ownProfileSnapshotTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                let stream = try await self.connectionManager.subscribe(
                    to: "\(prefix).profile.public.>",
                    type: ProfilePublicSnapshotMessage.self
                )
                for await _ in stream {
                    if Task.isCancelled { return }
                    self.ownProfileSnapshotContinuation?.yield(())
                }
            } catch {
                #if DEBUG
                print("[OwnerSpaceClient] profile.public subscription failed: \(error)")
                #endif
            }
        }
    }

    // MARK: - Presence heartbeats (forApp.presence.heartbeat.>)

    /// Peer presence heartbeats re-emitted by our vault. Each beat
    /// carries `connection_id`, `status`, and an `at` unix-seconds
    /// timestamp. Consumers (`PresenceAggregator`) own the retention
    /// logic — this stream is fire-and-forget. Mirrors Android
    /// `OwnerSpaceClient.presenceHeartbeats`.
    private var presenceHeartbeatContinuation: AsyncStream<PresenceHeartbeat>.Continuation?
    private var _presenceHeartbeatStream: AsyncStream<PresenceHeartbeat>?
    private var presenceTask: Task<Void, Never>?

    var presenceHeartbeats: AsyncStream<PresenceHeartbeat> {
        if let stream = _presenceHeartbeatStream { return stream }
        let stream = AsyncStream<PresenceHeartbeat> { continuation in
            self.presenceHeartbeatContinuation = continuation
            continuation.onTermination = { [weak self] _ in
                self?.presenceHeartbeatContinuation = nil
                self?._presenceHeartbeatStream = nil
            }
        }
        _presenceHeartbeatStream = stream
        return stream
    }

    /// Start the `forApp.presence.heartbeat.>` subscription that drives
    /// `presenceHeartbeats`. Idempotent. Call from `PresenceAggregator.
    /// attach` after the vault is warm.
    func startPresenceHeartbeatSubscription() {
        guard presenceTask == nil else { return }
        let prefix = forAppPrefix
        presenceTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                let stream = try await self.connectionManager.subscribe(
                    to: "\(prefix).presence.heartbeat.>",
                    type: PresenceHeartbeatMessage.self
                )
                for await msg in stream {
                    if Task.isCancelled { return }
                    // Wire layout: { payload: { connection_id, status, at } }
                    // but some vaults flatten the payload at the top level.
                    let cid = msg.payload?.connectionId ?? msg.connectionId ?? ""
                    if cid.isEmpty { continue }
                    let status = msg.payload?.status ?? msg.status ?? "online"
                    let at: TimeInterval = msg.payload?.at
                        ?? msg.at
                        ?? Date().timeIntervalSince1970
                    self.presenceHeartbeatContinuation?.yield(
                        PresenceHeartbeat(connectionId: cid, status: status, at: at)
                    )
                }
            } catch {
                #if DEBUG
                print("[OwnerSpaceClient] presence.heartbeat subscription failed: \(error)")
                #endif
            }
        }
    }

    // MARK: - Grant events (forApp.grant.* / .critical-secret-use.* / .verify.*)

    /// Live stream of Grants-subsystem events. Feeds `GrantsRepository`'s
    /// hydrate-on-event path so the inbox stays current without the
    /// user pulling-to-refresh, and feeds `FeedViewModel`'s pending-row
    /// synthesis so a fresh inbound request shows up on the requester's
    /// connection card the moment it lands.
    ///
    /// Phase 3.9 — backs all three approval flows
    /// (DataGrant / CriticalUseApproval / IdentityVerifyApproval) plus
    /// the receiver-side `forApp.grant.fetch-result` notification when
    /// the owner approves a value request.
    private var grantEventContinuation: AsyncStream<GrantEvent>.Continuation?
    private var _grantEventStream: AsyncStream<GrantEvent>?
    private var grantSubscriptionTask: Task<Void, Never>?

    var grantEvents: AsyncStream<GrantEvent> {
        if let s = _grantEventStream { return s }
        let stream = AsyncStream<GrantEvent> { continuation in
            self.grantEventContinuation = continuation
            continuation.onTermination = { [weak self] _ in
                self?.grantEventContinuation = nil
                self?._grantEventStream = nil
            }
        }
        _grantEventStream = stream
        return stream
    }

    /// Subscribe to the three Grants-subsystem topic families and pump
    /// decoded `GrantEvent`s into `grantEvents`. Idempotent — call from
    /// AppState.syncProfileFromVault alongside the other warm-up wires.
    ///
    /// Uses the raw `NatsMessage` subscription (rather than the typed
    /// overload) so we keep access to the topic — the subject suffix
    /// drives event routing (`request-arrived` vs `approved` etc.).
    func startGrantEventSubscription() {
        guard grantSubscriptionTask == nil else { return }
        let prefix = forAppPrefix
        grantSubscriptionTask = Task { [weak self] in
            guard let self = self else { return }
            for family in ["grant", "critical-secret-use", "verify"] {
                Task { [weak self] in
                    guard let self = self else { return }
                    do {
                        let stream = try await self.connectionManager.subscribe(
                            to: "\(prefix).\(family).>"
                        )
                        for await raw in stream {
                            if Task.isCancelled { return }
                            if let event = Self.parseGrantEvent(rawMessage: raw) {
                                self.grantEventContinuation?.yield(event)
                            }
                        }
                    } catch {
                        #if DEBUG
                        print("[OwnerSpaceClient] \(family) subscription failed: \(error)")
                        #endif
                    }
                }
            }
        }
    }

    /// Parse a `forApp.{grant,critical-secret-use,verify}.*` message
    /// into a domain event. Subject suffix drives case selection;
    /// payload fields fill in the data. Tolerates both hyphen and
    /// underscore separators in the suffix.
    private static func parseGrantEvent(rawMessage: NatsMessage) -> GrantEvent? {
        let subject = rawMessage.topic
        let suffix = subject.split(separator: ".").last.map(String.init) ?? ""

        // Permissive JSON decode — payload shape varies by event type.
        let json = (try? JSONSerialization.jsonObject(with: rawMessage.data)) as? [String: Any] ?? [:]
        let inner = (json["payload"] as? [String: Any]) ?? json
        let connectionId = (inner["connection_id"] as? String) ?? ""
        let requestId    = inner["request_id"] as? String
        let grantId      = inner["grant_id"] as? String
        let value        = inner["value"] as? String

        switch suffix {
        case "request-arrived", "request_arrived":
            guard let rid = requestId else { return nil }
            return .requestArrived(connectionId: connectionId, requestId: rid)
        case "approved":
            guard let gid = grantId else { return nil }
            return .approved(grantId: gid, connectionId: connectionId)
        case "denied":
            guard let rid = requestId else { return nil }
            return .denied(requestId: rid)
        case "revoked":
            guard let gid = grantId else { return nil }
            return .revoked(grantId: gid)
        case "fetch-result", "fetch_result":
            guard let gid = grantId else { return nil }
            let error = (inner["error"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return .fetchResult(grantId: gid, valueBase64: value, error: error)
        default:
            return nil
        }
    }

    // MARK: - Peer-location transitions (forApp.connection.peer-location-*)

    /// V6: events emitted when a peer starts sharing their location with
    /// us, stops sharing, or pings us with a one-shot
    /// `peer-location-requested`. The prompt VM observes this stream so
    /// the UX is global — a request that arrives while the user is on
    /// the feed still surfaces a dialog. Mirrors Android
    /// `OwnerSpaceClient.peerLocationTransitions`.
    private var peerLocationContinuation: AsyncStream<PeerLocationShareTransition>.Continuation?
    private var _peerLocationStream: AsyncStream<PeerLocationShareTransition>?
    private var peerLocationTask: Task<Void, Never>?

    var peerLocationTransitions: AsyncStream<PeerLocationShareTransition> {
        if let s = _peerLocationStream { return s }
        let stream = AsyncStream<PeerLocationShareTransition> { continuation in
            self.peerLocationContinuation = continuation
            continuation.onTermination = { [weak self] _ in
                self?.peerLocationContinuation = nil
                self?._peerLocationStream = nil
            }
        }
        _peerLocationStream = stream
        return stream
    }

    /// Subscribe to the three `forApp.connection.peer-location-*` subject
    /// suffixes and pump decoded `PeerLocationShareTransition`s into
    /// `peerLocationTransitions`. Idempotent — call once per warm-up.
    func startPeerLocationSubscription() {
        guard peerLocationTask == nil else { return }
        let prefix = forAppPrefix
        peerLocationTask = Task { [weak self] in
            guard let self = self else { return }
            let suffixes: [(String, PeerLocationShareTransition.Transition)] = [
                ("connection.peer-location-shared-started", .started),
                ("connection.peer-location-shared-stopped", .stopped),
                ("connection.peer-location-requested",      .requested),
            ]
            for (suffix, transition) in suffixes {
                Task { [weak self] in
                    guard let self = self else { return }
                    do {
                        let stream = try await self.connectionManager.subscribe(
                            to: "\(prefix).\(suffix)"
                        )
                        for await raw in stream {
                            if Task.isCancelled { return }
                            if let event = Self.parsePeerLocation(raw: raw, transition: transition) {
                                self.peerLocationContinuation?.yield(event)
                            }
                        }
                    } catch {
                        #if DEBUG
                        print("[OwnerSpaceClient] peer-location \(suffix) subscription failed: \(error)")
                        #endif
                    }
                }
            }
        }
    }

    private static func parsePeerLocation(
        raw: NatsMessage,
        transition: PeerLocationShareTransition.Transition
    ) -> PeerLocationShareTransition? {
        let json = (try? JSONSerialization.jsonObject(with: raw.data)) as? [String: Any] ?? [:]
        let payload = (json["payload"] as? [String: Any]) ?? json
        guard let connectionId = payload["connection_id"] as? String, !connectionId.isEmpty else {
            return nil
        }
        let fromOwnerSpace = payload["from_owner_space"] as? String ?? ""
        let at: String = {
            switch transition {
            case .started:   return payload["started_at"]   as? String ?? ""
            case .stopped:   return payload["stopped_at"]   as? String ?? ""
            case .requested: return payload["requested_at"] as? String ?? ""
            }
        }()
        return PeerLocationShareTransition(
            connectionId: connectionId,
            fromOwnerSpace: fromOwnerSpace,
            transition: transition,
            at: at
        )
    }

    /// V6: send a one-shot location-request ping to a peer. The peer's
    /// app sees a `forApp.connection.peer-location-requested` event and
    /// may respond by calling `sendLocationOnce` from the prompt.
    func requestPeerLocation(connectionId: String) async throws {
        _ = try await sendAndAwaitResponse(
            "location.request",
            payload: ["connection_id": AnyCodableValue(connectionId)],
            timeout: 10
        )
    }

    /// V6: fulfill a peer's request by sending the owner's latest cached
    /// location once, without touching the sharing index.
    func sendLocationOnce(connectionId: String) async throws {
        _ = try await sendAndAwaitResponse(
            "location.send-once",
            payload: ["connection_id": AnyCodableValue(connectionId)],
            timeout: 10
        )
    }

    // MARK: - Vault Locked Events

    /// Publisher for vault locked events (DEK unavailable after enclave refresh)
    private var vaultLockedContinuation: AsyncStream<VaultLockedEvent>.Continuation?
    private var _vaultLockedStream: AsyncStream<VaultLockedEvent>?

    /// Stream of vault locked events — triggers PIN re-entry
    var vaultLockedEvents: AsyncStream<VaultLockedEvent> {
        if let stream = _vaultLockedStream {
            return stream
        }
        let stream = AsyncStream<VaultLockedEvent> { continuation in
            self.vaultLockedContinuation = continuation
            continuation.onTermination = { [weak self] _ in
                self?.vaultLockedContinuation = nil
                self?._vaultLockedStream = nil
            }
        }
        _vaultLockedStream = stream
        return stream
    }

    func emitVaultLockedEvent(_ event: VaultLockedEvent) {
        vaultLockedContinuation?.yield(event)
    }

    // MARK: - Wallet Events

    /// Publisher for wallet notifications (balance changes, incoming payments)
    private var walletNotificationContinuation: AsyncStream<WalletNotification>.Continuation?
    private var _walletNotificationStream: AsyncStream<WalletNotification>?

    var walletNotifications: AsyncStream<WalletNotification> {
        if let stream = _walletNotificationStream {
            return stream
        }
        let stream = AsyncStream<WalletNotification> { continuation in
            self.walletNotificationContinuation = continuation
            continuation.onTermination = { [weak self] _ in
                self?.walletNotificationContinuation = nil
                self?._walletNotificationStream = nil
            }
        }
        _walletNotificationStream = stream
        return stream
    }

    func emitWalletNotification(_ notification: WalletNotification) {
        walletNotificationContinuation?.yield(notification)
    }

    // MARK: - Migration Events

    /// Publisher for vault migration events
    private var migrationEventContinuation: AsyncStream<MigrationEvent>.Continuation?
    private var _migrationEventStream: AsyncStream<MigrationEvent>?

    var migrationEvents: AsyncStream<MigrationEvent> {
        if let stream = _migrationEventStream {
            return stream
        }
        let stream = AsyncStream<MigrationEvent> { continuation in
            self.migrationEventContinuation = continuation
            continuation.onTermination = { [weak self] _ in
                self?.migrationEventContinuation = nil
                self?._migrationEventStream = nil
            }
        }
        _migrationEventStream = stream
        return stream
    }

    func emitMigrationEvent(_ event: MigrationEvent) {
        migrationEventContinuation?.yield(event)
    }

    // MARK: - Event Types

    /// Get available event types from the vault
    func getEventTypes() async throws -> [EventTypeInfo] {
        return []
    }
}

// MARK: - Vault Handler Response

/// Parsed response from a vault handler via sendAndAwaitResponse
struct VaultHandlerResponse {
    let requestId: String
    let success: Bool
    let result: [String: Any]?
    let error: String?
    let errorCode: String?
    /// Whole top-level dict. Lets callers reach error-body fields that
    /// don't fit `result` — `existing_devices` on an
    /// existing_session_active rejection, for example.
    let raw: [String: Any]

    /// Get a string value from the result
    func getString(_ key: String) -> String? {
        result?[key] as? String
    }

    /// Get an int value from the result
    func getInt(_ key: String) -> Int? {
        result?[key] as? Int
    }

    /// Get a bool value from the result
    func getBool(_ key: String) -> Bool? {
        result?[key] as? Bool
    }

    /// Get a dictionary from the result
    func getObject(_ key: String) -> [String: Any]? {
        result?[key] as? [String: Any]
    }

    /// Get an array from the result
    func getArray(_ key: String) -> [[String: Any]]? {
        result?[key] as? [[String: Any]]
    }
}

// MARK: - Event Models

/// Agent approval request from vault
struct AgentApprovalRequest: Codable {
    let requestId: String
    let agentName: String
    let agentType: String?
    let operation: String?
    let secretCategory: String?
    let timestamp: String?

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case agentName = "agent_name"
        case agentType = "agent_type"
        case operation
        case secretCategory = "secret_category"
        case timestamp
    }
}

/// Device approval request from vault
struct DeviceApprovalRequest: Codable, Identifiable {
    let requestId: String
    let connectionId: String
    let deviceName: String
    let operation: String?
    let secretCategory: String?
    let timestamp: String?

    var id: String { requestId }

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case connectionId = "connection_id"
        case deviceName = "device_name"
        case operation
        case secretCategory = "secret_category"
        case timestamp
    }
}

/// Stage-2 pairing handshake: paired desktop is waiting on the phone's
/// `device.authorize-session` decision. Mirrors Android
/// `DevicePendingAuthNotification`.
struct DevicePendingAuthNotification: Equatable {
    let connectionId: String
    let deviceMetadata: DevicePendingAuthMetadata?
    /// Vault's recommended session length. Surfaced as the default
    /// chip selection in AuthorizeDeviceView's duration row.
    let defaultDurationSeconds: Int
    /// Vault's policy ceiling. Caps the chip row and the in-VM
    /// `updateDuration` clamp.
    let maxDurationSeconds: Int
}

/// Desktop identity card inlined under `device_metadata` of a
/// `forApp.device.pending-authorization` message. Surfaced verbatim
/// in AuthorizeDeviceView's fingerprint card so the user can compare
/// bit-for-bit against the desktop's Settings → Device tab.
struct DevicePendingAuthMetadata: Equatable {
    let hostname: String
    let platform: String
    let osName: String
    let osVersion: String
    let appVersion: String
    let clientIp: String
    /// SHA-256 of the desktop binary, full 64-char hex.
    let binaryFingerprint: String
    /// HMAC-SHA256 over stable machine attributes. May be empty on
    /// first-generation desktop builds.
    let machineFingerprint: String
}

/// Connection peer accepted notification
struct ConnectionPeerAccepted: Codable {
    let connectionId: String
    let peerGuid: String
    let peerAlias: String?
    let peerProfile: [String: String]?

    enum CodingKeys: String, CodingKey {
        case connectionId = "connection_id"
        case peerGuid = "peer_guid"
        case peerAlias = "peer_alias"
        case peerProfile = "peer_profile"
    }
}

/// Connection status update from vault
struct ConnectionStatusUpdate: Codable {
    let type: String
    let connectionId: String
    let peerGuid: String?
    let peerAlias: String?

    enum CodingKeys: String, CodingKey {
        case type
        case connectionId = "connection_id"
        case peerGuid = "peer_guid"
        case peerAlias = "peer_alias"
    }
}

/// Feed notification from vault
struct FeedNotification: Codable {
    let type: String
    let eventId: String?
    let eventType: String?
    let title: String?
    let message: String?

    enum CodingKeys: String, CodingKey {
        case type
        case eventId = "event_id"
        case eventType = "event_type"
        case title
        case message
    }
}

// MARK: - Request Types

struct ExecuteHandlerRequest: Encodable {
    let id: String
    let handlerId: String
    let payload: [String: Any]

    enum CodingKeys: String, CodingKey {
        case id
        case handlerId = "handler_id"
        case payload
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(handlerId, forKey: .handlerId)
        // Encode payload as JSON string for simplicity
        if let jsonData = try? JSONSerialization.data(withJSONObject: payload),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            try container.encode(jsonString, forKey: .payload)
        }
    }
}

struct StatusRequest: Encodable {
    let id: String

    // No CodingKeys needed - field name matches JSON directly
}

// MARK: - Response Types

enum VaultResponse: Decodable {
    case handlerResult(HandlerResultResponse)
    case status(StatusResponse)
    case event(VaultEvent)
    case unknown

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let type = try? container.decode(String.self, forKey: .type) {
            switch type {
            case "handler_result":
                let result = try HandlerResultResponse(from: decoder)
                self = .handlerResult(result)
            case "status":
                let status = try StatusResponse(from: decoder)
                self = .status(status)
            case "event":
                let event = try VaultEvent(from: decoder)
                self = .event(event)
            default:
                self = .unknown
            }
        } else {
            self = .unknown
        }
    }

    enum CodingKeys: String, CodingKey {
        case type
    }
}

struct HandlerResultResponse: Decodable {
    let id: String
    let success: Bool
    let result: [String: String]?
    let error: String?

    // No CodingKeys needed for id - matches JSON directly
    enum CodingKeys: String, CodingKey {
        case id
        case success
        case result
        case error
    }
}

struct StatusResponse: Decodable {
    let id: String
    let vaultStatus: String
    let health: String
    let activeHandlers: Int
    let lastActivity: String?

    enum CodingKeys: String, CodingKey {
        case id
        case vaultStatus = "vault_status"
        case health
        case activeHandlers = "active_handlers"
        case lastActivity = "last_activity"
    }
}

struct VaultEvent: Decodable {
    let eventId: String
    let eventType: String
    let timestamp: String
    let data: [String: String]?

    enum CodingKeys: String, CodingKey {
        case eventId = "event_id"
        case eventType = "event_type"
        case timestamp
        case data
    }
}

struct EventTypeInfo: Decodable {
    let id: String
    let name: String
    let description: String
}

// MARK: - Errors

/// Vault locked event — DEK is unavailable, requires PIN re-entry
struct VaultLockedEvent {
    let reason: String
    let messageType: String
}

/// Catch-all for `forApp.profile.public.*` snapshot messages. We don't
/// consume the payload — the only sensible reaction is to re-fetch
/// `profile.get-published` for the authoritative state — so the message
/// type stays empty; receiving any decodable JSON ticks the stream.
struct ProfilePublicSnapshotMessage: Decodable {}

/// Domain event for the Grants subsystem (Phase 3.9). Decoded from
/// `forApp.grant.*` topic messages; consumers (`GrantsRepository`,
/// `FeedViewModel`) react by re-hydrating or synthesizing pending rows.
enum GrantEvent {
    case requestArrived(connectionId: String, requestId: String)
    case approved(grantId: String, connectionId: String)
    case denied(requestId: String)
    case revoked(grantId: String)
    /// Value-grant fetch result landed (receiver-side). `valueBase64` is
    /// nil for non-value grants (e.g. critical-use / verify) and for
    /// denials. Area F (Android 29a51e0): when the vault refuses to
    /// produce a value (item_not_found, max_uses_exhausted,
    /// grant_revoked, grant_expired, requester_mismatch, …) it
    /// includes a non-nil `error` so the receiver-side UI can surface
    /// a visible signal instead of failing silently.
    case fetchResult(grantId: String, valueBase64: String?, error: String?)
}

/// On-wire payload of `forApp.presence.heartbeat.*`. Some vaults nest the
/// fields under `payload`; others put them at the top level. We accept
/// both via two sets of CodingKeys.
struct PresenceHeartbeatMessage: Decodable {
    let connectionId: String?
    let status: String?
    let at: TimeInterval?
    let payload: Inner?

    struct Inner: Decodable {
        let connectionId: String?
        let status: String?
        let at: TimeInterval?

        enum CodingKeys: String, CodingKey {
            case connectionId = "connection_id"
            case status
            case at
        }
    }

    enum CodingKeys: String, CodingKey {
        case connectionId = "connection_id"
        case status
        case at
        case payload
    }
}

/// Wallet notification from vault (balance update, incoming payment, etc.)
struct WalletNotification: Codable {
    let type: String
    let walletId: String?
    let message: String?

    enum CodingKeys: String, CodingKey {
        case type
        case walletId = "wallet_id"
        case message
    }
}

/// Migration event from vault
struct MigrationEvent: Codable {
    let type: String
    let version: String?
    let message: String?

    enum CodingKeys: String, CodingKey {
        case type
        case version
        case message
    }
}

// MARK: - Errors

enum OwnerSpaceError: LocalizedError {
    case notConnected
    case timeout
    case noResponse
    case invalidResponse
    case handlerError(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected to NATS"
        case .timeout:
            return "Request timed out"
        case .noResponse:
            return "No response received"
        case .invalidResponse:
            return "Invalid response format"
        case .handlerError(let message):
            return "Handler error: \(message)"
        }
    }
}
