import Foundation
import os
import VettIDCalls
@preconcurrency import WebRTC

/// Something read and written from more than one thread (the stack calls back on its own threads).
final class Guarded<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    /// Changes the value and returns what [body] says, under the lock.
    func update<Result>(_ body: (inout Value) -> Result) -> Result { lock.withLock { body(&stored) } }
}

/// The media stack's process-wide plumbing: the one serial queue every stack call of every engine runs on, and the one peer
/// connection factory with its one audio device module (the factory owns it), made on first use and kept.
///
/// Why one of each: no factory churn per call, and no two audio modules competing for the microphone while an old call
/// closes and a new one starts. Neither is ever disposed (they live as long as the process); an engine's ``close()``
/// lets go of everything else of its call. The audio module opens the microphone and the speaker only while a track is live.
///
/// The stack's network monitor starts and stops with each gathering, not with the factory, so a kept factory can still be
/// asked to gather before the phone's addresses are reported. That is fixed by gathering continually
/// (``WebRtcMediaCore/configuration(servers:relayOnly:)``); keep it, whatever happens to this type.
enum WebRtcRuntime {
    /// Every call into the stack, from any engine. Serial.
    static let queue = DispatchQueue(label: "org.vettid.call-media")

    /// The stack's field trial for a post-quantum DTLS key exchange (X25519MLKEM768 first, DTLS 1.3). Debug builds only.
    static let dtlsPqcTrialName = "WebRTC-EnableDtlsPqc/Enabled/"

    private static let trial = OSAllocatedUnfairLock<Bool?>(initialState: nil)

    /// Nil until the stack has been started; then whether the trial is on in this process (the first engine decides).
    static var dtlsPqcTrial: Bool? { trial.withLock { $0 } }

    /// Before the first factory exists: asks the logging guard, and fixes the process-wide option. Returns whether the DTLS
    /// trial is on in this process.
    static func start(_ config: MediaConfig) throws -> Bool {
        try MediaLogGuard.check()
        // The backstop: a process that no ``RtcCallAudioSession`` has configured (it sets both switches when it is made) does not
        // get its audio unit started by the stack. If one has, the switches are its own: CallKit's activation may already have
        // turned the audio on, and an engine that opens after it must not turn it off again.
        #if os(iOS)
        let rtc = RTCAudioSession.sharedInstance()
        if !rtc.useManualAudio {
            rtc.useManualAudio = true
            rtc.isAudioEnabled = false
        }
        #endif
        return trial.withLock { state in
            if let state { return state }
            if config.dtlsPqcTrial { RTCPeerConnectionFactory.configureFieldTrials(dtlsPqcTrialName) }
            state = config.dtlsPqcTrial
            return config.dtlsPqcTrial
        }
    }

    // Touched on ``queue`` only.
    nonisolated(unsafe) private static var shared: RTCPeerConnectionFactory?

#if DEBUG
    /// FOR THE TESTS ONLY (`@testable`, Debug builds only: a device that is set sees the decrypted audio): an audio device of the test's own (one that makes and swallows sound without hardware),
    /// set before the first engine of the process. Nothing in the app sets it; the app's engines use the platform's module.
    nonisolated(unsafe) static var testAudioDevice: (any RTCAudioDevice)?

    /// FOR THE TESTS ONLY (`@testable`): factory options of the test's own (a loopback test lets the stack gather on the
    /// loopback interface, which it ignores by default).
    nonisolated(unsafe) static var testFactoryOptions: RTCPeerConnectionFactoryOptions?
#endif

    /// The process's factory. On ``queue`` only.
    static func factory() -> RTCPeerConnectionFactory {
        dispatchPrecondition(condition: .onQueue(queue))
        if let shared { return shared }
#if DEBUG
        if let testAudioDevice {
            let made = RTCPeerConnectionFactory(encoderFactory: nil, decoderFactory: nil, audioDevice: testAudioDevice)
            if let testFactoryOptions { made.setOptions(testFactoryOptions) }
            shared = made
            return made
        }
#endif
        // Audio only: no video encoder or decoder factory, the platform's default audio device module.
        let made = RTCPeerConnectionFactory(
            audioDeviceModuleType: .platformDefault, bypassVoiceProcessing: false, encoderFactory: nil, decoderFactory: nil,
            audioProcessingModule: nil
        )
        shared = made
        return made
    }
}
