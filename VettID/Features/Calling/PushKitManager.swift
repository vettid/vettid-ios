import Foundation
import PushKit
import CallKit
import UIKit

/// Manages VoIP push notifications via PushKit
///
/// PushKit enables the app to receive VoIP push notifications even when:
/// - The app is in the background
/// - The app has been terminated
/// - The device is locked
///
/// ## Required Setup
///
/// 1. Enable "Voice over IP" background mode in Xcode:
///    - Target → Signing & Capabilities → Background Modes → Voice over IP
///
/// 2. Enable Push Notifications capability:
///    - Target → Signing & Capabilities → Push Notifications
///
/// 3. Server must send VoIP pushes with:
///    - Topic: `{bundle_id}.voip` (e.g., `dev.vettid.app.voip`)
///    - Priority: 10 (immediate)
///    - Push type: `voip`
///
/// ## Important Notes
///
/// - VoIP pushes MUST report a call to CallKit within the push handler
/// - Failure to report a call will cause iOS to terminate the app
/// - VoIP pushes should only be used for actual incoming calls
@MainActor
final class PushKitManager: NSObject, ObservableObject {

    // MARK: - Singleton

    static let shared = PushKitManager()

    // MARK: - Published State

    /// The current VoIP push token (hex-encoded)
    @Published private(set) var pushToken: String?

    /// Whether VoIP push is registered
    @Published private(set) var isRegistered: Bool = false

    /// Last registration error
    @Published private(set) var registrationError: Error?

    // MARK: - Dependencies

    private let pushRegistry: PKPushRegistry
    private var callKitManager: CallKitManager?

    // MARK: - Callbacks

    /// Called when a new push token is received
    var onTokenReceived: ((String) -> Void)?

    /// Called when token registration fails
    var onRegistrationFailed: ((Error) -> Void)?

    // MARK: - Initialization

    private override init() {
        self.pushRegistry = PKPushRegistry(queue: .main)
        super.init()
    }

    // MARK: - Configuration

    /// Configure the PushKit manager with CallKit integration
    /// - Parameter callKitManager: The CallKit manager to report incoming calls to
    func configure(callKitManager: CallKitManager) {
        self.callKitManager = callKitManager
    }

    // MARK: - Registration

    /// Register for VoIP push notifications
    ///
    /// This should be called early in app launch (e.g., in `application(_:didFinishLaunchingWithOptions:)`)
    func registerForVoIPPushes() {
        pushRegistry.delegate = self
        pushRegistry.desiredPushTypes = [.voIP]

        #if DEBUG
        print("[PushKitManager] Registering for VoIP pushes...")
        #endif
    }

    /// Unregister from VoIP push notifications
    func unregisterForVoIPPushes() {
        pushRegistry.desiredPushTypes = []
        pushToken = nil
        isRegistered = false

        #if DEBUG
        print("[PushKitManager] Unregistered from VoIP pushes")
        #endif
    }

    // MARK: - Token Management

    /// Get the current push token for server registration
    /// - Returns: Hex-encoded push token, or nil if not registered
    func getPushToken() -> String? {
        return pushToken
    }

    /// Convert push token data to hex string
    private func tokenToHexString(_ token: Data) -> String {
        return token.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - PKPushRegistryDelegate

extension PushKitManager: PKPushRegistryDelegate {

    nonisolated func pushRegistry(
        _ registry: PKPushRegistry,
        didUpdate pushCredentials: PKPushCredentials,
        for type: PKPushType
    ) {
        guard type == .voIP else { return }

        let token = pushCredentials.token
        let tokenString = token.map { String(format: "%02x", $0) }.joined()

        Task { @MainActor in
            self.pushToken = tokenString
            self.isRegistered = true
            self.registrationError = nil

            #if DEBUG
            print("[PushKitManager] VoIP push token received: \(tokenString.prefix(16))...")
            #endif

            // Notify callback
            onTokenReceived?(tokenString)
        }
    }

    nonisolated func pushRegistry(
        _ registry: PKPushRegistry,
        didInvalidatePushTokenFor type: PKPushType
    ) {
        guard type == .voIP else { return }

        Task { @MainActor in
            self.pushToken = nil
            self.isRegistered = false

            #if DEBUG
            print("[PushKitManager] VoIP push token invalidated")
            #endif
        }
    }

    nonisolated func pushRegistry(
        _ registry: PKPushRegistry,
        didReceiveIncomingPushWith payload: PKPushPayload,
        for type: PKPushType,
        completion: @escaping () -> Void
    ) {
        guard type == .voIP else {
            completion()
            return
        }

        #if DEBUG
        print("[PushKitManager] Received VoIP push: \(payload.dictionaryPayload)")
        #endif

        Task { @MainActor in
            await handleIncomingVoIPPush(payload: payload.dictionaryPayload)
            completion()
        }
    }
}

// MARK: - Push Handling

extension PushKitManager {

    /// Handle an incoming VoIP push notification
    ///
    /// - Important: This MUST report a call to CallKit or iOS will terminate the app
    private func handleIncomingVoIPPush(payload: [AnyHashable: Any]) async {
        // Parse the push payload
        guard let callInfo = parseCallPayload(payload) else {
            // If we can't parse the call, we still need to report something to CallKit
            // Report a "missed call" to satisfy iOS requirements
            await reportUnknownCall(payload: payload)
            return
        }

        // Report to CallKit
        guard let callKitManager = callKitManager else {
            print("[PushKitManager] Error: CallKitManager not configured")
            await reportUnknownCall(payload: payload)
            return
        }

        do {
            let incomingCall = IncomingCall(
                callId: callInfo.callId,
                callerId: callInfo.callerId,
                callerDisplayName: callInfo.callerDisplayName,
                callType: callInfo.callType,
                timestamp: Date().timeIntervalSince1970 * 1000
            )

            _ = try await callKitManager.reportIncomingCall(incomingCall)

            #if DEBUG
            print("[PushKitManager] Reported incoming call: \(callInfo.callId)")
            #endif
        } catch {
            print("[PushKitManager] Failed to report incoming call: \(error)")
            // CallKit will still show something due to the attempt
        }
    }

    /// Parse call information from push payload
    private func parseCallPayload(_ payload: [AnyHashable: Any]) -> VoIPCallInfo? {
        // Expected payload structure:
        // {
        //   "call_id": "uuid-string",
        //   "caller_id": "user-guid",
        //   "caller_display_name": "John Doe",
        //   "call_type": "video" or "audio"
        // }

        guard let callId = payload["call_id"] as? String,
              let callerId = payload["caller_id"] as? String else {
            return nil
        }

        let callerDisplayName = payload["caller_display_name"] as? String ?? "Unknown Caller"
        let callTypeString = payload["call_type"] as? String ?? "audio"
        let callType: CallType = callTypeString == "video" ? .video : .audio

        return VoIPCallInfo(
            callId: callId,
            callerId: callerId,
            callerDisplayName: callerDisplayName,
            callType: callType
        )
    }

    /// Report an unknown/invalid call to satisfy iOS requirements
    ///
    /// iOS requires that every VoIP push results in a CallKit report.
    /// If we receive an invalid push, we report it as an immediately-ended call.
    private func reportUnknownCall(payload: [AnyHashable: Any]) async {
        guard let callKitManager = callKitManager else { return }

        // Create a minimal call to satisfy iOS
        let unknownCall = IncomingCall(
            callId: UUID().uuidString,
            callerId: "unknown",
            callerDisplayName: "Unknown",
            callType: .audio,
            timestamp: Date().timeIntervalSince1970 * 1000
        )

        do {
            let uuid = try await callKitManager.reportIncomingCall(unknownCall)
            // Immediately end it as a failed call
            callKitManager.reportCallEnded(uuid: uuid, reason: .failed)
        } catch {
            print("[PushKitManager] Failed to report unknown call: \(error)")
        }
    }
}

// MARK: - Supporting Types

/// Information extracted from a VoIP push payload
struct VoIPCallInfo {
    let callId: String
    let callerId: String
    let callerDisplayName: String
    let callType: CallType
}

// MARK: - Server Integration

extension PushKitManager {

    /// Send the VoIP push token to the server
    ///
    /// Call this after receiving a new token to register it with your backend
    /// - Parameters:
    ///   - apiClient: The API client to use
    ///   - authToken: Authentication token for the API
    func registerTokenWithServer(
        apiClient: APIClient,
        authToken: @escaping () async throws -> String
    ) async throws {
        guard let token = pushToken else {
            throw PushKitError.noToken
        }

        // Get device ID for unique identification
        let deviceId = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString

        #if DEBUG
        print("[PushKitManager] Registering VoIP token with server: \(token.prefix(16))...")
        #endif

        // TODO: Implement when API endpoint is available
        // Register with server - the actual API endpoint should be implemented in APIClient
        _ = (apiClient, authToken, token, deviceId) // Suppress unused warnings until implemented

        #if DEBUG
        print("[PushKitManager] VoIP token registration: API endpoint not yet implemented")
        #endif
    }
}

// MARK: - Errors

enum PushKitError: LocalizedError {
    case noToken
    case registrationFailed(String)
    case invalidPayload
    case callKitNotConfigured

    var errorDescription: String? {
        switch self {
        case .noToken:
            return "No VoIP push token available"
        case .registrationFailed(let reason):
            return "Push registration failed: \(reason)"
        case .invalidPayload:
            return "Invalid VoIP push payload"
        case .callKitNotConfigured:
            return "CallKit manager not configured"
        }
    }
}

// MARK: - App Delegate Integration

/// Extension with helper methods for AppDelegate integration
extension PushKitManager {

    /// Call this from `application(_:didFinishLaunchingWithOptions:)`
    func applicationDidFinishLaunching() {
        registerForVoIPPushes()
    }

    /// Call this when the user signs out
    func userDidSignOut() {
        unregisterForVoIPPushes()
    }
}
