import Foundation
import VettIDCalls
import VettIDVault
@preconcurrency import WebRTC

/// The peer connection's delegate (the stack calls it on its own thread; the connection holds it weakly, so the core keeps
/// it). Turns what the stack says into ``MediaEvent``s; nothing of an address goes anywhere but into the candidate event.
final class PeerObserver: NSObject, RTCPeerConnectionDelegate, @unchecked Sendable {
    private let emit: @Sendable (MediaEvent) -> Void
    private let found = Guarded(0)

    init(emit: @escaping @Sendable (MediaEvent) -> Void) { self.emit = emit }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}

    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        if newState == .complete { emit(.gatheringDone(found: found.value)) }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        found.update { $0 += 1 }
        emit(.localCandidate(CallCandidate(candidate.sdp, sdpMid: candidate.sdpMid, sdpMLineIndex: Int(candidate.sdpMLineIndex))))
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        let mapped: MediaConnection = switch newState {
        case .new: .new
        case .connecting: .connecting
        case .connected: .connected
        case .disconnected: .disconnected
        case .failed: .failed
        case .closed: .closed
        @unknown default: .failed
        }
        emit(.connection(mapped))
    }
}

/// One frame cryptor's delegate (held weakly by the cryptor).
final class CryptorObserver: NSObject, RTCFrameCryptorDelegate, @unchecked Sendable {
    private let direction: MediaDirection
    private let changed: @Sendable (MediaDirection, CryptorState) -> Void

    init(_ direction: MediaDirection, changed: @escaping @Sendable (MediaDirection, CryptorState) -> Void) {
        self.direction = direction
        self.changed = changed
    }

    func frameCryptor(
        _ frameCryptor: RTCFrameCryptor, didStateChangeWithParticipantId participantId: String, with state: RTCFrameCryptorState
    ) {
        changed(direction, Self.map(state))
    }

    static func map(_ state: RTCFrameCryptorState) -> CryptorState {
        switch state {
        case .new: .new
        case .ok: .ok
        case .missingKey: .missingKey
        case .decryptionFailed: .decryptionFailed
        case .encryptionFailed: .encryptionFailed
        case .internalError: .internalError
        // No ratchet is configured: a ratcheted key is not something this call can have.
        case .keyRatcheted: .unknown
        @unknown default: .unknown
        }
    }
}
