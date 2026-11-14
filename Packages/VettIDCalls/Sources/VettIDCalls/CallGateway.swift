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

    func start(connectionId: String, pinnedFingerprint: String, sdp: String, suites: [MediaSuite]) async throws -> OutgoingCall

    /// Verifies an offer against the connection's identity and this device's suites, or throws.
    func incoming(_ event: VaultMessage, pinnedFingerprint: String, suites: [MediaSuite]) async throws -> IncomingCall

    func answer(_ call: IncomingCall, sdp: String) async throws -> CallKeys

    /// Verifies an answer against the identity the call was placed to, or throws.
    func accept(_ call: OutgoingCall, event: VaultMessage) async throws -> AcceptedCall

    func ringing(_ callId: String) async throws

    func ice(_ callId: String, _ candidates: [CallCandidate]) async throws

    func end(_ callId: String, reason: String) async throws

    func list(limit: Int) async throws -> CallList
}

/// ``CallGateway`` on the vault: nothing but the calls. [api] is asked each time (it throws while the vault is locked on this
/// phone).
package final class VaultCallGateway: CallGateway {
    private let api: @MainActor () throws -> VaultApi

    package init(api: @escaping @MainActor () throws -> VaultApi) { self.api = api }

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

    package func start(connectionId: String, pinnedFingerprint: String, sdp: String, suites: [MediaSuite]) async throws -> OutgoingCall {
        try await api().callStart(connectionId, pinnedFingerprint: pinnedFingerprint, sdp: sdp, suites: suites)
    }

    package func incoming(_ event: VaultMessage, pinnedFingerprint: String, suites: [MediaSuite]) async throws -> IncomingCall {
        try api().callIncoming(event, pinnedFingerprint: pinnedFingerprint, suites: suites)
    }

    package func answer(_ call: IncomingCall, sdp: String) async throws -> CallKeys { try await api().callAnswer(call, sdp: sdp) }

    package func accept(_ call: OutgoingCall, event: VaultMessage) async throws -> AcceptedCall {
        try api().callAccept(call, event: event)
    }

    package func ringing(_ callId: String) async throws { try await api().callRinging(callId) }

    package func ice(_ callId: String, _ candidates: [CallCandidate]) async throws { try await api().callIce(callId, candidates) }

    package func end(_ callId: String, reason: String) async throws { try await api().callEnd(callId, reason: reason) }

    package func list(limit: Int) async throws -> CallList { try await api().callList(limit: limit) }
}
