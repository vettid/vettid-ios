import Foundation
import VettIDCalls
import VettIDCrypto
@preconcurrency import WebRTC

// The frame cryptors of a call (CALL-MEDIA §4, §7): their making, their keys, and the checks that no media exists outside
// them. All on the stack's queue.
extension WebRtcMediaCore {
    /// A frame cryptor on the sender and on the receiver of [transceiver], both enabled at once (a new cryptor is created
    /// disabled, and a disabled cryptor passes frames through in the clear). Without a key the sender sends nothing and the
    /// receiver plays nothing. Made when the SDP is made and before any SDP is applied, and never remade by ``setKeys``.
    func encrypt(_ transceiver: RTCRtpTransceiver, suite: MediaSuite) throws {
        guard suite.frameCipher == .aesGcm, WebRtcMediaEngine.supportedSuites.contains(suite) else {
            throw MediaEngineError("suite \(suite.id)")
        }
        senderCryptor = nil
        receiverCryptor = nil
        provider = nil
        let keys = try FrameKeyOptions.options(for: suite).makeProvider()
        provider = keys
        senderId = transceiver.sender.senderId
        installed = suite
        let changed: @Sendable (MediaDirection, CryptorState) -> Void = { [sendState, receiveState, everFailed, emit] direction, state in
            if direction == .send { sendState.value = state } else { receiveState.value = state }
            if direction == .receive, state == .decryptionFailed { everFailed.value = true }
            emit(.cryptor(direction, state))
        }
        let sendObserver = CryptorObserver(.send, changed: changed)
        let receiveObserver = CryptorObserver(.receive, changed: changed)
        guard let sender = RTCFrameCryptor(
            factory: WebRtcRuntime.factory(), rtpSender: transceiver.sender, participantId: Self.sendId, algorithm: .aesGcm,
            keyProvider: keys
        ), let receiver = RTCFrameCryptor(
            factory: WebRtcRuntime.factory(), rtpReceiver: transceiver.receiver, participantId: Self.receiveId, algorithm: .aesGcm,
            keyProvider: keys
        ) else { throw MediaEngineError("the frame encryption could not be made") }
        sender.delegate = sendObserver
        sender.enabled = !faults.sendUnencrypted
        guard sender.enabled || faults.sendUnencrypted else { throw MediaEngineError("the sender's frame encryption is off") }
        receiver.delegate = receiveObserver
        receiver.enabled = true
        guard receiver.enabled else { throw MediaEngineError("the receiver's frame encryption is off") }
        senderObserver = sendObserver
        receiverObserver = receiveObserver
        senderCryptor = sender
        receiverCryptor = receiver
    }

    /// Both directions' keys at index 0. Throws ``MediaNotEncryptedError`` for keys of a suite other than the cryptors'
    /// (the cryptors are never remade; the call ends), and never sets a key after the receiver has failed to decrypt.
    func takeKeys(_ suite: MediaSuite, send: SecretBytes, receive: SecretBytes) throws {
        try MediaLogGuard.check(switches)
        guard let made = installed, let keys = provider else { throw MediaEngineError("no media yet") }
        guard suite == made else {
            throw MediaNotEncryptedError("keys for suite \(suite.id), cryptors made for suite \(made.id)")
        }
        // A key set after a decryption failure would make the receiver try again: it plays nothing from now on instead. Sticky:
        // the state may have moved on by the time of the next key.
        guard !everFailed.value else { throw MediaEngineError("keys after a decryption failure") }
        defer {
            send.wipe()
            receive.wipe()
        }
        if faults.wrongSendKey { send.invert() }
        let index = Int32(CallFrames.keyIndex)
        keys.setKey(send.data, with: index, forParticipant: Self.sendId)
        keys.setKey(receive.data, with: index, forParticipant: Self.receiveId)
    }

    /// The offer's audio section should have taken the transceiver that already carries the cryptors. If the stack gave it
    /// another one, the track and the cryptors move there, still before the answer exists and before any media.
    func adoptOfferedSection() throws {
        guard let pc = connection else { throw MediaEngineError("no offer") }
        let all = pc.transceivers
        // `mid` is nil until the offer is applied, which the header does not say: read it as an optional.
        guard let offered = all.first(where: { $0.mediaType == .audio && Self.mid(of: $0) != nil }) else {
            throw MediaEngineError("the offer has no audio")
        }
        if offered.sender.senderId == senderId { return }
        let stale = all.first { $0.sender.senderId == senderId }
        offered.sender.track = track
        var failure: NSError?
        offered.setDirection(.sendRecv, error: &failure)
        guard failure == nil else { throw MediaEngineError("the audio track was refused") }
        guard let suite = installed else { throw MediaEngineError("no cryptors yet") }
        try encrypt(offered, suite: suite)
        stale?.stopInternal()
        moved = true
    }

    private static func mid(of transceiver: RTCRtpTransceiver) -> String? {
        transceiver.value(forKey: "mid") as? String
    }

    /// After the other side's SDP has been applied: the connection has exactly one live transceiver, and it is the one whose
    /// sender and receiver carry the frame cryptors, both enabled. An SDP with another media section (the signalling refuses
    /// those before they get here: this is the second lock) would have given the stack a receiver with no cryptor, whose
    /// audio would play under DTLS-SRTP alone.
    func requireAllMediaEncrypted() throws {
        guard let pc = connection else { throw MediaEngineError("no offer") }
        let live = pc.transceivers.filter { !$0.isStopped }
        guard live.count == 1, let mine = senderId, live[0].sender.senderId == mine else {
            throw MediaNotEncryptedError("\(live.count) media sections")
        }
        guard senderCryptor?.enabled == true || faults.sendUnencrypted, receiverCryptor?.enabled == true else {
            throw MediaNotEncryptedError("frame encryption is off")
        }
    }
}
