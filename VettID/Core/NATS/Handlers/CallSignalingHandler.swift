import Foundation

/// Handler for vault-routed call signaling via NATS
///
/// All call events route through the user's vault for security verification,
/// block list enforcement, and audit logging.
///
/// NATS Topics (App → Target Vault):
/// - `OwnerSpace.{targetGuid}.forVault.call.initiate` - Initiate a call
/// - `OwnerSpace.{targetGuid}.forVault.call.offer` - Send WebRTC SDP offer
/// - `OwnerSpace.{targetGuid}.forVault.call.answer` - Send WebRTC SDP answer
/// - `OwnerSpace.{targetGuid}.forVault.call.candidate` - Send ICE candidate
/// - `OwnerSpace.{targetGuid}.forVault.call.accept` - Accept incoming call
/// - `OwnerSpace.{targetGuid}.forVault.call.reject` - Reject incoming call
/// - `OwnerSpace.{targetGuid}.forVault.call.end` - End call
///
/// NATS Topics (Own Vault → App on forApp.call.*):
/// - `call.incoming` - Incoming call notification
/// - `call.offer` - WebRTC SDP offer from caller
/// - `call.answer` - WebRTC SDP answer from callee
/// - `call.candidate` - ICE candidate from peer
/// - `call.accepted` - Call was accepted
/// - `call.rejected` - Call was rejected
/// - `call.ended` - Call ended
/// - `call.missed` - Call timed out (missed)
/// - `call.blocked` - You are blocked by callee
/// - `call.busy` - Callee is busy
///
/// Block List Topics (App → Own Vault):
/// - `OwnerSpace.{ownGuid}.forVault.block.add` - Block a user
/// - `OwnerSpace.{ownGuid}.forVault.block.remove` - Unblock a user
actor CallSignalingHandler {

    // MARK: - Dependencies

    private let vaultResponseHandler: VaultResponseHandler
    private let connectionManager: NatsConnectionManager
    private let ownUserGuid: String

    // MARK: - Configuration

    private let defaultTimeout: TimeInterval = 30

    // MARK: - Initialization

    init(
        vaultResponseHandler: VaultResponseHandler,
        connectionManager: NatsConnectionManager,
        ownUserGuid: String
    ) {
        self.vaultResponseHandler = vaultResponseHandler
        self.connectionManager = connectionManager
        self.ownUserGuid = ownUserGuid
    }

    // MARK: - Call Initiation

    /// Initiate a call to a target user
    /// - Parameters:
    ///   - targetUserGuid: The target user's GUID
    ///   - displayName: Caller's display name
    ///   - callType: Type of call ("video" or "audio")
    /// - Returns: Call initiation result with call ID
    func initiateCall(
        targetUserGuid: String,
        displayName: String,
        callType: CallType = .video
    ) async throws -> CallInitiationResult {
        let callId = UUID().uuidString
        let payload: [String: AnyCodableValue] = [
            "call_id": AnyCodableValue(callId),
            "caller_id": AnyCodableValue(ownUserGuid),
            "caller_display_name": AnyCodableValue(displayName),
            "call_type": AnyCodableValue(callType.rawValue),
            "timestamp": AnyCodableValue(Date().timeIntervalSince1970 * 1000)
        ]

        #if DEBUG
        print("[CallSignalingHandler] Initiating \(callType.rawValue) call to: \(targetUserGuid)")
        #endif

        // Publish to target user's vault
        let topic = "OwnerSpace.\(targetUserGuid).forVault.call.initiate"
        try await connectionManager.publish(payload, to: topic)

        return CallInitiationResult(
            callId: callId,
            targetUserGuid: targetUserGuid,
            callType: callType,
            timestamp: Date()
        )
    }

    // MARK: - WebRTC Signaling

    /// Send WebRTC SDP offer to target
    func sendOffer(
        targetUserGuid: String,
        callId: String,
        sdp: String
    ) async throws {
        let payload: [String: AnyCodableValue] = [
            "call_id": AnyCodableValue(callId),
            "caller_id": AnyCodableValue(ownUserGuid),
            "sdp": AnyCodableValue(sdp),
            "type": AnyCodableValue("offer"),
            "timestamp": AnyCodableValue(Date().timeIntervalSince1970 * 1000)
        ]

        #if DEBUG
        print("[CallSignalingHandler] Sending SDP offer for call: \(callId)")
        #endif

        let topic = "OwnerSpace.\(targetUserGuid).forVault.call.offer"
        try await connectionManager.publish(payload, to: topic)
    }

    /// Send WebRTC SDP answer to target
    func sendAnswer(
        targetUserGuid: String,
        callId: String,
        sdp: String
    ) async throws {
        let payload: [String: AnyCodableValue] = [
            "call_id": AnyCodableValue(callId),
            "caller_id": AnyCodableValue(ownUserGuid),
            "sdp": AnyCodableValue(sdp),
            "type": AnyCodableValue("answer"),
            "timestamp": AnyCodableValue(Date().timeIntervalSince1970 * 1000)
        ]

        #if DEBUG
        print("[CallSignalingHandler] Sending SDP answer for call: \(callId)")
        #endif

        let topic = "OwnerSpace.\(targetUserGuid).forVault.call.answer"
        try await connectionManager.publish(payload, to: topic)
    }

    /// Send ICE candidate to target
    func sendCandidate(
        targetUserGuid: String,
        callId: String,
        candidate: String,
        sdpMid: String?,
        sdpMLineIndex: Int?
    ) async throws {
        var payload: [String: AnyCodableValue] = [
            "call_id": AnyCodableValue(callId),
            "caller_id": AnyCodableValue(ownUserGuid),
            "candidate": AnyCodableValue(candidate),
            "timestamp": AnyCodableValue(Date().timeIntervalSince1970 * 1000)
        ]

        if let sdpMid = sdpMid {
            payload["sdp_mid"] = AnyCodableValue(sdpMid)
        }
        if let sdpMLineIndex = sdpMLineIndex {
            payload["sdp_m_line_index"] = AnyCodableValue(sdpMLineIndex)
        }

        #if DEBUG
        print("[CallSignalingHandler] Sending ICE candidate for call: \(callId)")
        #endif

        let topic = "OwnerSpace.\(targetUserGuid).forVault.call.candidate"
        try await connectionManager.publish(payload, to: topic)
    }

    // MARK: - Call Control

    /// Accept an incoming call
    func acceptCall(
        callerUserGuid: String,
        callId: String
    ) async throws {
        let payload: [String: AnyCodableValue] = [
            "call_id": AnyCodableValue(callId),
            "responder_id": AnyCodableValue(ownUserGuid),
            "timestamp": AnyCodableValue(Date().timeIntervalSince1970 * 1000)
        ]

        #if DEBUG
        print("[CallSignalingHandler] Accepting call: \(callId)")
        #endif

        let topic = "OwnerSpace.\(callerUserGuid).forVault.call.accept"
        try await connectionManager.publish(payload, to: topic)
    }

    /// Reject an incoming call
    func rejectCall(
        callerUserGuid: String,
        callId: String,
        reason: CallRejectReason = .declined
    ) async throws {
        let payload: [String: AnyCodableValue] = [
            "call_id": AnyCodableValue(callId),
            "responder_id": AnyCodableValue(ownUserGuid),
            "reason": AnyCodableValue(reason.rawValue),
            "timestamp": AnyCodableValue(Date().timeIntervalSince1970 * 1000)
        ]

        #if DEBUG
        print("[CallSignalingHandler] Rejecting call: \(callId) reason: \(reason.rawValue)")
        #endif

        let topic = "OwnerSpace.\(callerUserGuid).forVault.call.reject"
        try await connectionManager.publish(payload, to: topic)
    }

    /// End an active call
    func endCall(
        peerUserGuid: String,
        callId: String
    ) async throws {
        let payload: [String: AnyCodableValue] = [
            "call_id": AnyCodableValue(callId),
            "ended_by": AnyCodableValue(ownUserGuid),
            "timestamp": AnyCodableValue(Date().timeIntervalSince1970 * 1000)
        ]

        #if DEBUG
        print("[CallSignalingHandler] Ending call: \(callId)")
        #endif

        let topic = "OwnerSpace.\(peerUserGuid).forVault.call.end"
        try await connectionManager.publish(payload, to: topic)
    }

    // MARK: - Block List Management

    /// Block a user from calling
    /// - Parameters:
    ///   - userGuid: The user to block
    ///   - reason: Reason for blocking (optional)
    ///   - durationSeconds: Block duration in seconds (0 = permanent)
    func blockUser(
        userGuid: String,
        reason: String? = nil,
        durationSeconds: Int = 0
    ) async throws -> BlockResult {
        var payload: [String: AnyCodableValue] = [
            "target_id": AnyCodableValue(userGuid),
            "duration_secs": AnyCodableValue(durationSeconds)
        ]

        if let reason = reason {
            payload["reason"] = AnyCodableValue(reason)
        }

        #if DEBUG
        print("[CallSignalingHandler] Blocking user: \(userGuid)")
        #endif

        let response = try await vaultResponseHandler.submitRawAndAwait(
            type: "block.add",
            payload: payload,
            timeout: defaultTimeout
        )

        guard response.isSuccess else {
            throw CallSignalingError.blockFailed(response.error ?? "Unknown error")
        }

        return BlockResult(
            targetId: userGuid,
            blockedAt: response.result?["blocked_at"]?.value as? String ?? "",
            expiresAt: response.result?["expires_at"]?.value as? String
        )
    }

    /// Unblock a user
    func unblockUser(userGuid: String) async throws -> Bool {
        let payload: [String: AnyCodableValue] = [
            "target_id": AnyCodableValue(userGuid)
        ]

        #if DEBUG
        print("[CallSignalingHandler] Unblocking user: \(userGuid)")
        #endif

        let response = try await vaultResponseHandler.submitRawAndAwait(
            type: "block.remove",
            payload: payload,
            timeout: defaultTimeout
        )

        guard response.isSuccess else {
            throw CallSignalingError.unblockFailed(response.error ?? "Unknown error")
        }

        return response.result?["success"]?.value as? Bool ?? true
    }

    /// Get the current block list
    func getBlockList() async throws -> [BlockedUser] {
        let response = try await vaultResponseHandler.submitRawAndAwait(
            type: "block.list",
            payload: [:],
            timeout: defaultTimeout
        )

        guard response.isSuccess else {
            throw CallSignalingError.blockListFailed(response.error ?? "Unknown error")
        }

        // Parse blocked users from response
        guard let blockedArray = response.result?["blocked"]?.value as? [[String: Any]] else {
            return []
        }

        return blockedArray.compactMap { dict in
            guard let targetId = dict["target_id"] as? String else { return nil }
            return BlockedUser(
                targetId: targetId,
                reason: dict["reason"] as? String,
                blockedAt: dict["blocked_at"] as? String ?? "",
                expiresAt: dict["expires_at"] as? String
            )
        }
    }
}

// MARK: - Call Types

enum CallType: String, Codable {
    case video = "video"
    case audio = "audio"
}

enum CallRejectReason: String, Codable {
    case declined = "declined"
    case busy = "busy"
    case unavailable = "unavailable"
}

// MARK: - Result Types

struct CallInitiationResult {
    let callId: String
    let targetUserGuid: String
    let callType: CallType
    let timestamp: Date
}

struct BlockResult {
    let targetId: String
    let blockedAt: String
    let expiresAt: String?
}

struct BlockedUser {
    let targetId: String
    let reason: String?
    let blockedAt: String
    let expiresAt: String?
}

// MARK: - Incoming Call Events

/// Incoming call notification (received on forApp.call.incoming)
struct IncomingCall: Decodable {
    let callId: String
    let callerId: String
    let callerDisplayName: String
    let callType: CallType
    let timestamp: Double

    enum CodingKeys: String, CodingKey {
        case callId = "call_id"
        case callerId = "caller_id"
        case callerDisplayName = "caller_display_name"
        case callType = "call_type"
        case timestamp
    }
}

/// WebRTC SDP offer/answer (received on forApp.call.offer or forApp.call.answer)
struct CallSdp: Decodable {
    let callId: String
    let callerId: String
    let sdp: String
    let type: String // "offer" or "answer"
    let timestamp: Double

    enum CodingKeys: String, CodingKey {
        case callId = "call_id"
        case callerId = "caller_id"
        case sdp
        case type
        case timestamp
    }
}

/// ICE candidate (received on forApp.call.candidate)
struct CallCandidate: Decodable {
    let callId: String
    let callerId: String
    let candidate: String
    let sdpMid: String?
    let sdpMLineIndex: Int?
    let timestamp: Double

    enum CodingKeys: String, CodingKey {
        case callId = "call_id"
        case callerId = "caller_id"
        case candidate
        case sdpMid = "sdp_mid"
        case sdpMLineIndex = "sdp_m_line_index"
        case timestamp
    }
}

/// Call accepted notification (received on forApp.call.accepted)
struct CallAccepted: Decodable {
    let callId: String
    let responderId: String
    let timestamp: Double

    enum CodingKeys: String, CodingKey {
        case callId = "call_id"
        case responderId = "responder_id"
        case timestamp
    }
}

/// Call rejected notification (received on forApp.call.rejected)
struct CallRejected: Decodable {
    let callId: String
    let responderId: String
    let reason: String
    let timestamp: Double

    enum CodingKeys: String, CodingKey {
        case callId = "call_id"
        case responderId = "responder_id"
        case reason
        case timestamp
    }
}

/// Call ended notification (received on forApp.call.ended)
struct CallEnded: Decodable {
    let callId: String
    let endedBy: String
    let timestamp: Double
    let duration: Double?

    enum CodingKeys: String, CodingKey {
        case callId = "call_id"
        case endedBy = "ended_by"
        case timestamp
        case duration
    }
}

/// Call missed notification (received on forApp.call.missed)
struct CallMissed: Decodable {
    let callId: String
    let callerId: String
    let callerDisplayName: String
    let callType: CallType
    let timestamp: Double

    enum CodingKeys: String, CodingKey {
        case callId = "call_id"
        case callerId = "caller_id"
        case callerDisplayName = "caller_display_name"
        case callType = "call_type"
        case timestamp
    }
}

/// Blocked notification (received on forApp.call.blocked)
struct CallBlocked: Decodable {
    let callId: String
    let targetId: String
    let timestamp: Double

    enum CodingKeys: String, CodingKey {
        case callId = "call_id"
        case targetId = "target_id"
        case timestamp
    }
}

/// Busy notification (received on forApp.call.busy)
struct CallBusy: Decodable {
    let callId: String
    let targetId: String
    let timestamp: Double

    enum CodingKeys: String, CodingKey {
        case callId = "call_id"
        case targetId = "target_id"
        case timestamp
    }
}

// MARK: - Call Event Envelope

/// Wrapper for all incoming call events
enum CallEvent {
    case incoming(IncomingCall)
    case offer(CallSdp)
    case answer(CallSdp)
    case candidate(CallCandidate)
    case accepted(CallAccepted)
    case rejected(CallRejected)
    case ended(CallEnded)
    case missed(CallMissed)
    case blocked(CallBlocked)
    case busy(CallBusy)
}

// MARK: - Errors

enum CallSignalingError: LocalizedError {
    case notConnected
    case callInitiationFailed(String)
    case signalingFailed(String)
    case blockFailed(String)
    case unblockFailed(String)
    case blockListFailed(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected to NATS"
        case .callInitiationFailed(let reason):
            return "Failed to initiate call: \(reason)"
        case .signalingFailed(let reason):
            return "Call signaling failed: \(reason)"
        case .blockFailed(let reason):
            return "Failed to block user: \(reason)"
        case .unblockFailed(let reason):
            return "Failed to unblock user: \(reason)"
        case .blockListFailed(let reason):
            return "Failed to get block list: \(reason)"
        case .invalidResponse:
            return "Invalid response from vault"
        }
    }
}
