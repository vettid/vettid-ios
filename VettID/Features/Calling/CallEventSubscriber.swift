import Foundation

/// Subscribes to call events from the vault via NATS and routes them to CallKit
///
/// Listens on: OwnerSpace.{guid}.forApp.call.*
/// Events handled:
/// - call.incoming - New incoming call
/// - call.offer - WebRTC SDP offer
/// - call.answer - WebRTC SDP answer
/// - call.candidate - ICE candidate
/// - call.accepted - Call was accepted
/// - call.rejected - Call was rejected
/// - call.ended - Call ended
/// - call.missed - Call timed out
/// - call.blocked - You are blocked
/// - call.busy - Callee is busy
actor CallEventSubscriber {

    // MARK: - Dependencies

    private let connectionManager: NatsConnectionManager
    private let callKitManager: CallKitManager
    private let ownerSpaceId: String

    // MARK: - State

    private var subscriptionTask: Task<Void, Never>?
    private var isSubscribed = false

    // MARK: - Callbacks

    /// Called when an SDP offer is received (for WebRTC)
    var onSdpOffer: ((CallSdp) async -> Void)?

    /// Called when an SDP answer is received (for WebRTC)
    var onSdpAnswer: ((CallSdp) async -> Void)?

    /// Called when an ICE candidate is received (for WebRTC)
    var onIceCandidate: ((CallCandidate) async -> Void)?

    // MARK: - Initialization

    init(
        connectionManager: NatsConnectionManager,
        callKitManager: CallKitManager,
        ownerSpaceId: String
    ) {
        self.connectionManager = connectionManager
        self.callKitManager = callKitManager
        self.ownerSpaceId = ownerSpaceId
    }

    // MARK: - Callback Configuration

    /// Configure the SDP offer callback
    func setOnSdpOffer(_ callback: @escaping @Sendable (CallSdp) async -> Void) {
        self.onSdpOffer = callback
    }

    /// Configure the SDP answer callback
    func setOnSdpAnswer(_ callback: @escaping @Sendable (CallSdp) async -> Void) {
        self.onSdpAnswer = callback
    }

    /// Configure the ICE candidate callback
    func setOnIceCandidate(_ callback: @escaping @Sendable (CallCandidate) async -> Void) {
        self.onIceCandidate = callback
    }

    // MARK: - Subscription Management

    /// Start listening for call events
    func startListening() async {
        guard !isSubscribed else { return }

        isSubscribed = true

        subscriptionTask = Task {
            await subscribeToCallEvents()
        }
    }

    /// Stop listening for call events
    func stopListening() {
        subscriptionTask?.cancel()
        subscriptionTask = nil
        isSubscribed = false
    }

    // MARK: - Private Methods

    private func subscribeToCallEvents() async {
        let topic = "\(ownerSpaceId).forApp.call.>"

        do {
            let stream = try await connectionManager.subscribe(to: topic, type: CallEventEnvelope.self)

            for await envelope in stream {
                await handleCallEvent(envelope)
            }
        } catch {
            print("[CallEventSubscriber] Failed to subscribe: \(error)")
        }
    }

    private func handleCallEvent(_ envelope: CallEventEnvelope) async {
        #if DEBUG
        print("[CallEventSubscriber] Received event: \(envelope.type)")
        #endif

        do {
            switch envelope.type {
            case "call.incoming":
                try await handleIncomingCall(envelope)

            case "call.offer":
                try await handleOffer(envelope)

            case "call.answer":
                try await handleAnswer(envelope)

            case "call.candidate":
                try await handleCandidate(envelope)

            case "call.accepted":
                try await handleAccepted(envelope)

            case "call.rejected":
                try await handleRejected(envelope)

            case "call.ended":
                try await handleEnded(envelope)

            case "call.missed":
                try await handleMissed(envelope)

            case "call.blocked":
                try await handleBlocked(envelope)

            case "call.busy":
                try await handleBusy(envelope)

            default:
                print("[CallEventSubscriber] Unknown event type: \(envelope.type)")
            }
        } catch {
            print("[CallEventSubscriber] Error handling event: \(error)")
        }
    }

    // MARK: - Event Handlers

    private func handleIncomingCall(_ envelope: CallEventEnvelope) async throws {
        guard let data = envelope.data else { return }

        let jsonData = try JSONSerialization.data(withJSONObject: data)
        let incomingCall = try JSONDecoder().decode(IncomingCall.self, from: jsonData)

        // Report to CallKit
        _ = try await callKitManager.reportIncomingCall(incomingCall)
    }

    private func handleOffer(_ envelope: CallEventEnvelope) async throws {
        guard let data = envelope.data else { return }

        let jsonData = try JSONSerialization.data(withJSONObject: data)
        let sdp = try JSONDecoder().decode(CallSdp.self, from: jsonData)

        // Forward to WebRTC handler
        await onSdpOffer?(sdp)
    }

    private func handleAnswer(_ envelope: CallEventEnvelope) async throws {
        guard let data = envelope.data else { return }

        let jsonData = try JSONSerialization.data(withJSONObject: data)
        let sdp = try JSONDecoder().decode(CallSdp.self, from: jsonData)

        // Forward to WebRTC handler
        await onSdpAnswer?(sdp)
    }

    private func handleCandidate(_ envelope: CallEventEnvelope) async throws {
        guard let data = envelope.data else { return }

        let jsonData = try JSONSerialization.data(withJSONObject: data)
        let candidate = try JSONDecoder().decode(CallCandidate.self, from: jsonData)

        // Forward to WebRTC handler
        await onIceCandidate?(candidate)
    }

    private func handleAccepted(_ envelope: CallEventEnvelope) async throws {
        guard let data = envelope.data else { return }

        let jsonData = try JSONSerialization.data(withJSONObject: data)
        let accepted = try JSONDecoder().decode(CallAccepted.self, from: jsonData)

        // Notify CallKit
        await callKitManager.handleCallAccepted(callId: accepted.callId)
    }

    private func handleRejected(_ envelope: CallEventEnvelope) async throws {
        guard let data = envelope.data else { return }

        let jsonData = try JSONSerialization.data(withJSONObject: data)
        let rejected = try JSONDecoder().decode(CallRejected.self, from: jsonData)

        // Notify CallKit
        await callKitManager.handleCallRejected(callId: rejected.callId, reason: rejected.reason)
    }

    private func handleEnded(_ envelope: CallEventEnvelope) async throws {
        guard let data = envelope.data else { return }

        let jsonData = try JSONSerialization.data(withJSONObject: data)
        let ended = try JSONDecoder().decode(CallEnded.self, from: jsonData)

        // Notify CallKit
        await callKitManager.handleCallEnded(callId: ended.callId)
    }

    private func handleMissed(_ envelope: CallEventEnvelope) async throws {
        guard let data = envelope.data else { return }

        let jsonData = try JSONSerialization.data(withJSONObject: data)
        let missed = try JSONDecoder().decode(CallMissed.self, from: jsonData)

        // Notify CallKit
        await callKitManager.handleCallMissed(callId: missed.callId)
    }

    private func handleBlocked(_ envelope: CallEventEnvelope) async throws {
        guard let data = envelope.data else { return }

        let jsonData = try JSONSerialization.data(withJSONObject: data)
        let blocked = try JSONDecoder().decode(CallBlocked.self, from: jsonData)

        // Notify CallKit
        await callKitManager.handleCallBlocked(callId: blocked.callId)
    }

    private func handleBusy(_ envelope: CallEventEnvelope) async throws {
        guard let data = envelope.data else { return }

        let jsonData = try JSONSerialization.data(withJSONObject: data)
        let busy = try JSONDecoder().decode(CallBusy.self, from: jsonData)

        // Notify CallKit
        await callKitManager.handleCallBusy(callId: busy.callId)
    }
}

// MARK: - Call Event Envelope

/// Generic envelope for call events from the vault
struct CallEventEnvelope: Decodable {
    let type: String
    let timestamp: Double?
    let data: [String: Any]?

    enum CodingKeys: String, CodingKey {
        case type
        case timestamp
        case data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        timestamp = try container.decodeIfPresent(Double.self, forKey: .timestamp)

        // Decode data as generic dictionary
        if let dataContainer = try? container.nestedContainer(keyedBy: DynamicCodingKey.self, forKey: .data) {
            var dict: [String: Any] = [:]
            for key in dataContainer.allKeys {
                if let stringValue = try? dataContainer.decode(String.self, forKey: key) {
                    dict[key.stringValue] = stringValue
                } else if let intValue = try? dataContainer.decode(Int.self, forKey: key) {
                    dict[key.stringValue] = intValue
                } else if let doubleValue = try? dataContainer.decode(Double.self, forKey: key) {
                    dict[key.stringValue] = doubleValue
                } else if let boolValue = try? dataContainer.decode(Bool.self, forKey: key) {
                    dict[key.stringValue] = boolValue
                }
            }
            data = dict.isEmpty ? nil : dict
        } else {
            data = nil
        }
    }
}

/// Dynamic coding key for decoding arbitrary JSON keys
private struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}
