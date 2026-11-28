import Foundation
import VettIDCrypto
import VettIDVault

/// `VaultApi`'s call functions as a protocol, one function for one function, so that ``VaultCallSignalling`` can be tested
/// without a vault. ``VaultCallGateway`` is the only implementation outside tests and adds nothing: every check is in
/// `VaultApi` (``VaultApi/callIncoming(_:pinnedFingerprint:suites:)``, ``VaultApi/callAccept(_:event:)``), and which checks are
/// asked for is decided in ``VaultCallSignalling``.
@MainActor
package protocol CallGateway: AnyObject {
    /// Every call event, in the vault's order; offers and answers unchecked.
    func events() -> AsyncStream<CallEvent>

    // swiftlint:disable function_parameter_count
    /// [peerIk]: (C2) the connection's identity key, for a form 2 start with `keepalive`; nil for form 1 only. [mayResend]:
    /// whether `call.start` may still be deposited again (the call still wanted). [callId]: the call's id, from ``newCallId()``.
    /// [timeout]: how long to wait for its answer (nil: ``CallLimits/startTimeout``).
    func start(
        connectionId: String, callId: String, pinnedFingerprint: String, sdp: String, suites: [MediaSuite], peerIk: [UInt8]?,
        timeout: TimeInterval?, mayResend: @escaping @Sendable () async -> Bool
    ) async throws -> OutgoingCall

    /// A new `call_id` for a `call.start` (the vault's request ids: their order is the glare's, VAULT-MESSAGING §10.10).
    func newCallId() throws -> String
    // swiftlint:enable function_parameter_count

    /// Verifies an offer against the connection's identity and this device's suites, or throws.
    func incoming(_ event: VaultMessage, pinnedFingerprint: String, suites: [MediaSuite]) async throws -> IncomingCall

    /// [keepalive]: (C2) the answer says this device sends `call.keepalive`.
    func answer(_ call: IncomingCall, sdp: String, keepalive: Bool) async throws -> CallKeys

    /// (C2) `call.keepalive` for the active call [callId].
    func keepalive(_ callId: String) async throws

    /// Verifies an answer against the identity the call was placed to, or throws.
    func accept(_ call: OutgoingCall, event: VaultMessage) async throws -> AcceptedCall

    func ringing(_ callId: String) async throws

    func ice(_ callId: String, _ candidates: [CallCandidate]) async throws

    func end(_ callId: String, reason: String) async throws

    func list(limit: Int) async throws -> CallList
}

/// `VaultApi.callStart` exactly, every argument named, so that what ``VaultCallGateway`` passes to it can be tested.
package protocol CallStartApi: Sendable {
    // swiftlint:disable:next function_parameter_count
    func callStart(
        _ connectionId: String, callId: String?, pinnedFingerprint: String, sdp: String, suites: [MediaSuite], media: String,
        timeout: TimeInterval, peerIk: [UInt8]?, resendAfter: [TimeInterval], mayResend: (@Sendable () async -> Bool)?
    ) async throws -> OutgoingCall
}

extension VaultApi: CallStartApi {}

/// ``CallGateway`` on the vault: nothing but the calls. [api] is asked each time (it throws while the vault is locked on this
/// phone).
package final class VaultCallGateway: CallGateway {
    private let api: @MainActor () throws -> VaultApi
    private let sendEnd: (@MainActor (String, String) async throws -> Void)?
    private let starts: @MainActor () throws -> any CallStartApi

    /// [end]: how `call.end` goes, when it must go where [api] is refused (the vault manager's, which also works while a lock is
    /// pending: the hang-up before a lock). By default through [api]. [starts]: where `call.start` goes, [api] but in tests.
    package init(
        api: @escaping @MainActor () throws -> VaultApi, end: (@MainActor (String, String) async throws -> Void)? = nil,
        starts: (@MainActor () throws -> any CallStartApi)? = nil
    ) {
        self.api = api
        sendEnd = end
        self.starts = starts ?? api
    }

    package func events() -> AsyncStream<CallEvent> {
        guard let source = try? api().callEvents() else { return AsyncStream { $0.finish() } }
        return AsyncStream { continuation in
            let pump = Task {
                for await e in source { continuation.yield(e) }
                continuation.finish()
            }
            continuation.onTermination = { _ in pump.cancel() }
        }
    }

    // swiftlint:disable:next function_parameter_count
    package func start(
        connectionId: String, callId: String, pinnedFingerprint: String, sdp: String, suites: [MediaSuite], peerIk: [UInt8]?,
        timeout: TimeInterval?, mayResend: @escaping @Sendable () async -> Bool
    ) async throws -> OutgoingCall {
        try await starts().callStart(
            connectionId, callId: callId, pinnedFingerprint: pinnedFingerprint, sdp: sdp, suites: suites, media: CallWire.mediaAudio,
            timeout: timeout ?? CallLimits.startTimeout, peerIk: peerIk, resendAfter: CallLimits.startResends, mayResend: mayResend
        )
    }

    package func newCallId() throws -> String { try api().device.newRequestID() }

    package func incoming(_ event: VaultMessage, pinnedFingerprint: String, suites: [MediaSuite]) async throws -> IncomingCall {
        try api().callIncoming(event, pinnedFingerprint: pinnedFingerprint, suites: suites)
    }

    package func answer(_ call: IncomingCall, sdp: String, keepalive: Bool) async throws -> CallKeys {
        try await api().callAnswer(call, sdp: sdp, keepalive: keepalive)
    }

    package func keepalive(_ callId: String) async throws { try await api().callKeepalive(callId) }

    package func accept(_ call: OutgoingCall, event: VaultMessage) async throws -> AcceptedCall {
        try api().callAccept(call, event: event)
    }

    package func ringing(_ callId: String) async throws { try await api().callRinging(callId) }

    package func ice(_ callId: String, _ candidates: [CallCandidate]) async throws { try await api().callIce(callId, candidates) }

    package func end(_ callId: String, reason: String) async throws {
        if let sendEnd { try await sendEnd(callId, reason) } else { try await api().callEnd(callId, reason: reason) }
    }

    package func list(limit: Int) async throws -> CallList { try await api().callList(limit: limit) }
}
