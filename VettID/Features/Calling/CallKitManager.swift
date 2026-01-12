import Foundation
import CallKit
import AVFoundation
import UIKit

/// Manages CallKit integration for VoIP calls
///
/// This class handles:
/// - Reporting incoming calls to iOS
/// - Processing user actions (answer, end, mute, hold)
/// - Coordinating with CallSignalingHandler for NATS signaling
/// - Audio session configuration for calls
@MainActor
final class CallKitManager: NSObject, ObservableObject {

    // MARK: - Singleton

    static let shared = CallKitManager()

    // MARK: - Published State

    @Published private(set) var activeCall: ActiveCall?
    @Published private(set) var callState: CallState = .idle

    // MARK: - CallKit Components

    private let provider: CXProvider
    private let callController: CXCallController

    // MARK: - Dependencies

    private var callSignalingHandler: CallSignalingHandler?
    private var onCallAnswered: ((ActiveCall) async -> Void)?
    private var onCallEnded: ((ActiveCall) async -> Void)?

    // MARK: - Call Tracking

    private var pendingCalls: [UUID: PendingCall] = [:]

    // MARK: - Initialization

    private override init() {
        // Configure provider (use deprecated initializer to set localizedName)
        let configuration = CXProviderConfiguration(localizedName: "VettID")
        configuration.supportsVideo = true
        configuration.maximumCallsPerCallGroup = 1
        configuration.maximumCallGroups = 1
        configuration.supportedHandleTypes = [.generic]
        configuration.includesCallsInRecents = true

        // Set app icon for call UI
        if let iconImage = UIImage(named: "AppIcon") {
            configuration.iconTemplateImageData = iconImage.pngData()
        }

        self.provider = CXProvider(configuration: configuration)
        self.callController = CXCallController()

        super.init()

        provider.setDelegate(self, queue: .main)
    }

    // MARK: - Configuration

    /// Configure the CallKit manager with signaling handler
    func configure(
        callSignalingHandler: CallSignalingHandler,
        onCallAnswered: @escaping (ActiveCall) async -> Void,
        onCallEnded: @escaping (ActiveCall) async -> Void
    ) {
        self.callSignalingHandler = callSignalingHandler
        self.onCallAnswered = onCallAnswered
        self.onCallEnded = onCallEnded
    }

    // MARK: - Incoming Calls

    /// Report an incoming call to CallKit
    /// - Parameters:
    ///   - incomingCall: The incoming call details from NATS
    /// - Returns: The UUID assigned to this call
    func reportIncomingCall(_ incomingCall: IncomingCall) async throws -> UUID {
        let callUUID = UUID()

        // Store pending call info
        pendingCalls[callUUID] = PendingCall(
            uuid: callUUID,
            callId: incomingCall.callId,
            callerId: incomingCall.callerId,
            callerDisplayName: incomingCall.callerDisplayName,
            callType: incomingCall.callType,
            isOutgoing: false
        )

        // Create call update
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: incomingCall.callerId)
        update.localizedCallerName = incomingCall.callerDisplayName
        update.hasVideo = incomingCall.callType == .video
        update.supportsHolding = true
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = false

        // Report to CallKit
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                provider.reportNewIncomingCall(with: callUUID, update: update) { error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
            callState = .ringing
            return callUUID
        } catch {
            pendingCalls.removeValue(forKey: callUUID)
            throw error
        }
    }

    // MARK: - Outgoing Calls

    /// Start an outgoing call
    /// - Parameters:
    ///   - targetUserGuid: The target user's GUID
    ///   - displayName: Display name of the callee
    ///   - callType: Type of call (video/audio)
    /// - Returns: The call UUID and call ID
    func startOutgoingCall(
        targetUserGuid: String,
        displayName: String,
        callType: CallType
    ) async throws -> (uuid: UUID, callId: String) {
        guard let handler = callSignalingHandler else {
            throw CallKitError.notConfigured
        }

        let callUUID = UUID()

        // Create handle for the callee
        let handle = CXHandle(type: .generic, value: targetUserGuid)

        // Start call action
        let startCallAction = CXStartCallAction(call: callUUID, handle: handle)
        startCallAction.isVideo = callType == .video
        startCallAction.contactIdentifier = displayName

        let transaction = CXTransaction(action: startCallAction)

        do {
            try await callController.request(transaction)
        } catch {
            throw CallKitError.transactionFailed(error.localizedDescription)
        }

        // Initiate signaling
        let result = try await handler.initiateCall(
            targetUserGuid: targetUserGuid,
            displayName: displayName,
            callType: callType
        )

        // Store pending call
        pendingCalls[callUUID] = PendingCall(
            uuid: callUUID,
            callId: result.callId,
            callerId: targetUserGuid,
            callerDisplayName: displayName,
            callType: callType,
            isOutgoing: true
        )

        callState = .connecting

        // Update call as connecting
        let update = CXCallUpdate()
        update.remoteHandle = handle
        update.localizedCallerName = displayName
        update.hasVideo = callType == .video
        provider.reportCall(with: callUUID, updated: update)

        return (callUUID, result.callId)
    }

    // MARK: - Call State Updates

    /// Report that the outgoing call is connecting (ringing on remote end)
    func reportOutgoingCallConnecting(uuid: UUID) {
        provider.reportOutgoingCall(with: uuid, startedConnectingAt: Date())
        callState = .connecting
    }

    /// Report that the call has connected
    func reportCallConnected(uuid: UUID) {
        if let pending = pendingCalls.removeValue(forKey: uuid) {
            activeCall = ActiveCall(
                uuid: uuid,
                callId: pending.callId,
                peerId: pending.callerId,
                peerDisplayName: pending.callerDisplayName,
                callType: pending.callType,
                isOutgoing: pending.isOutgoing,
                connectedAt: Date()
            )
            callState = .connected
        }

        provider.reportOutgoingCall(with: uuid, connectedAt: Date())
    }

    /// Report that the call has ended
    func reportCallEnded(uuid: UUID, reason: CXCallEndedReason) {
        provider.reportCall(with: uuid, endedAt: Date(), reason: reason)

        pendingCalls.removeValue(forKey: uuid)
        activeCall = nil
        callState = .idle
    }

    // MARK: - Handle Incoming Events

    /// Handle call accepted event from remote
    func handleCallAccepted(callId: String) {
        guard let (uuid, _) = findCall(byCallId: callId) else { return }
        reportCallConnected(uuid: uuid)
    }

    /// Handle call rejected event from remote
    func handleCallRejected(callId: String, reason: String) {
        guard let (uuid, _) = findCall(byCallId: callId) else { return }

        let endReason: CXCallEndedReason = reason == "busy" ? .unanswered : .remoteEnded
        reportCallEnded(uuid: uuid, reason: endReason)
    }

    /// Handle call ended event from remote
    func handleCallEnded(callId: String) {
        guard let (uuid, _) = findCall(byCallId: callId) else { return }
        reportCallEnded(uuid: uuid, reason: .remoteEnded)
    }

    /// Handle call missed (timeout)
    func handleCallMissed(callId: String) {
        guard let (uuid, _) = findCall(byCallId: callId) else { return }
        reportCallEnded(uuid: uuid, reason: .unanswered)
    }

    /// Handle blocked notification
    func handleCallBlocked(callId: String) {
        guard let (uuid, _) = findCall(byCallId: callId) else { return }
        reportCallEnded(uuid: uuid, reason: .failed)
    }

    /// Handle busy notification
    func handleCallBusy(callId: String) {
        guard let (uuid, _) = findCall(byCallId: callId) else { return }
        reportCallEnded(uuid: uuid, reason: .unanswered)
    }

    // MARK: - End Call

    /// End the current call
    func endCall(uuid: UUID) async throws {
        let endCallAction = CXEndCallAction(call: uuid)
        let transaction = CXTransaction(action: endCallAction)

        try await callController.request(transaction)
    }

    /// End all active calls
    func endAllCalls() async {
        for uuid in pendingCalls.keys {
            try? await endCall(uuid: uuid)
        }
        if let call = activeCall {
            try? await endCall(uuid: call.uuid)
        }
    }

    // MARK: - Audio Session

    /// Configure audio session for a call
    private func configureAudioSession() {
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP, .allowBluetoothA2DP])
            try audioSession.setActive(true)
        } catch {
            #if DEBUG
            print("[CallKitManager] Failed to configure audio session: \(error)")
            #endif
        }
    }

    /// Deactivate audio session
    private func deactivateAudioSession() {
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            #if DEBUG
            print("[CallKitManager] Failed to deactivate audio session: \(error)")
            #endif
        }
    }

    // MARK: - Helpers

    private func findCall(byCallId callId: String) -> (UUID, PendingCall)? {
        for (uuid, pending) in pendingCalls {
            if pending.callId == callId {
                return (uuid, pending)
            }
        }
        if let active = activeCall, active.callId == callId {
            return (active.uuid, PendingCall(
                uuid: active.uuid,
                callId: active.callId,
                callerId: active.peerId,
                callerDisplayName: active.peerDisplayName,
                callType: active.callType,
                isOutgoing: active.isOutgoing
            ))
        }
        return nil
    }
}

// MARK: - CXProviderDelegate

extension CallKitManager: CXProviderDelegate {

    nonisolated func providerDidReset(_ provider: CXProvider) {
        Task { @MainActor in
            // Clean up all calls
            pendingCalls.removeAll()
            activeCall = nil
            callState = .idle
            deactivateAudioSession()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        Task { @MainActor in
            guard let pending = pendingCalls[action.callUUID] else {
                action.fail()
                return
            }

            // Configure audio
            configureAudioSession()

            // Send accept via signaling
            if let handler = callSignalingHandler {
                do {
                    try await handler.acceptCall(
                        callerUserGuid: pending.callerId,
                        callId: pending.callId
                    )

                    // Create active call
                    let active = ActiveCall(
                        uuid: action.callUUID,
                        callId: pending.callId,
                        peerId: pending.callerId,
                        peerDisplayName: pending.callerDisplayName,
                        callType: pending.callType,
                        isOutgoing: false,
                        connectedAt: Date()
                    )

                    pendingCalls.removeValue(forKey: action.callUUID)
                    activeCall = active
                    callState = .connected

                    // Notify callback
                    await onCallAnswered?(active)

                    action.fulfill()
                } catch {
                    #if DEBUG
                    print("[CallKitManager] Failed to accept call: \(error)")
                    #endif
                    action.fail()
                }
            } else {
                action.fail()
            }
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        Task { @MainActor in
            // Find the call
            let callInfo: (callId: String, peerId: String)?
            if let pending = pendingCalls[action.callUUID] {
                callInfo = (pending.callId, pending.callerId)
                pendingCalls.removeValue(forKey: action.callUUID)
            } else if let active = activeCall, active.uuid == action.callUUID {
                callInfo = (active.callId, active.peerId)

                // Notify callback before clearing
                await onCallEnded?(active)
                activeCall = nil
            } else {
                callInfo = nil
            }

            // Send end via signaling
            if let info = callInfo, let handler = callSignalingHandler {
                do {
                    try await handler.endCall(
                        peerUserGuid: info.peerId,
                        callId: info.callId
                    )
                } catch {
                    #if DEBUG
                    print("[CallKitManager] Failed to send end call: \(error)")
                    #endif
                }
            }

            callState = .idle
            deactivateAudioSession()

            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        Task { @MainActor in
            // Handle mute state
            // WebRTC mute handling would go here
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        Task { @MainActor in
            // Handle hold state
            if action.isOnHold {
                // Pause media
            } else {
                // Resume media
            }
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        Task { @MainActor in
            // Configure audio for outgoing call
            configureAudioSession()
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        // Audio session activated - start WebRTC audio
        #if DEBUG
        print("[CallKitManager] Audio session activated")
        #endif
    }

    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        // Audio session deactivated - stop WebRTC audio
        #if DEBUG
        print("[CallKitManager] Audio session deactivated")
        #endif
    }
}

// MARK: - Supporting Types

/// State of the current call
enum CallState: Equatable {
    case idle
    case ringing       // Incoming call ringing
    case connecting    // Outgoing call connecting
    case connected     // Call in progress
    case reconnecting  // Temporarily disconnected
}

/// Information about a pending (not yet connected) call
struct PendingCall {
    let uuid: UUID
    let callId: String
    let callerId: String
    let callerDisplayName: String
    let callType: CallType
    let isOutgoing: Bool
}

/// Information about an active (connected) call
struct ActiveCall: Identifiable {
    let uuid: UUID
    let callId: String
    let peerId: String
    let peerDisplayName: String
    let callType: CallType
    let isOutgoing: Bool
    let connectedAt: Date

    var id: UUID { uuid }

    var duration: TimeInterval {
        Date().timeIntervalSince(connectedAt)
    }
}

// MARK: - Errors

enum CallKitError: LocalizedError {
    case notConfigured
    case callNotFound
    case transactionFailed(String)
    case signalingFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "CallKit manager not configured"
        case .callNotFound:
            return "Call not found"
        case .transactionFailed(let reason):
            return "CallKit transaction failed: \(reason)"
        case .signalingFailed(let reason):
            return "Call signaling failed: \(reason)"
        }
    }
}
