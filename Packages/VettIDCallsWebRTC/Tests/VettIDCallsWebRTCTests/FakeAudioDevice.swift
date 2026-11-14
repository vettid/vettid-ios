import AudioToolbox
import Foundation
@preconcurrency import WebRTC
@testable import VettIDCallsWebRTC

/// An audio device with no hardware: while recording it hands the stack a tone every 10 ms, and while playing it pulls
/// (and drops) what the stack wants played. This is what lets two engines in one process exchange real Opus frames on a
/// machine with no microphone (or none this test may open).
final class FakeAudioDevice: NSObject, RTCAudioDevice, @unchecked Sendable {
    static let sampleRate = 48_000.0
    private static let framesPer10ms: UInt32 = 480

    let deviceInputSampleRate = FakeAudioDevice.sampleRate
    let inputIOBufferDuration = 0.01
    let inputNumberOfChannels = 1
    let inputLatency = 0.0
    let deviceOutputSampleRate = FakeAudioDevice.sampleRate
    let outputIOBufferDuration = 0.01
    let outputNumberOfChannels = 1
    let outputLatency = 0.0

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "test.fake-audio")
    private var delegate: RTCAudioDeviceDelegate?
    private var recorder: DispatchSourceTimer?
    private var player: DispatchSourceTimer?
    private var flags = (initialized: false, playoutInitialized: false, playing: false, recordingInitialized: false, recording: false)
    /// How many 10 ms chunks of tone were delivered, and how many were pulled for playout.
    private(set) var delivered = 0
    private(set) var pulled = 0

    var isInitialized: Bool { lock.withLock { flags.initialized } }
    var isPlayoutInitialized: Bool { lock.withLock { flags.playoutInitialized } }
    var isPlaying: Bool { lock.withLock { flags.playing } }
    var isRecordingInitialized: Bool { lock.withLock { flags.recordingInitialized } }
    var isRecording: Bool { lock.withLock { flags.recording } }

    func initialize(with delegate: RTCAudioDeviceDelegate) -> Bool {
        lock.withLock {
            self.delegate = delegate
            flags.initialized = true
        }
        return true
    }

    func terminateDevice() -> Bool {
        _ = stopPlayout()
        _ = stopRecording()
        lock.withLock {
            delegate = nil
            flags = (false, false, false, false, false)
        }
        return true
    }

    func initializePlayout() -> Bool { lock.withLock { flags.playoutInitialized = true }; return true }

    func initializeRecording() -> Bool { lock.withLock { flags.recordingInitialized = true }; return true }

    func startPlayout() -> Bool {
        lock.withLock { flags.playing = true }
        player = timer { [weak self] in self?.pullPlayout() }
        return true
    }

    func stopPlayout() -> Bool {
        player?.cancel()
        player = nil
        lock.withLock { flags.playing = false }
        return true
    }

    func startRecording() -> Bool {
        lock.withLock { flags.recording = true }
        recorder = timer { [weak self] in self?.deliverTone() }
        return true
    }

    func stopRecording() -> Bool {
        recorder?.cancel()
        recorder = nil
        lock.withLock { flags.recording = false }
        return true
    }

    private func timer(_ tick: @escaping @Sendable () -> Void) -> DispatchSourceTimer {
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + .milliseconds(10), repeating: .milliseconds(10))
        source.setEventHandler(handler: tick)
        source.resume()
        return source
    }

    private var phase = 0.0

    private func deliverTone() {
        guard let delegate = lock.withLock({ self.delegate }) else { return }
        var samples = [Int16](repeating: 0, count: Int(Self.framesPer10ms))
        for index in samples.indices {
            samples[index] = Int16(8_000 * sin(phase))
            phase += 2 * .pi * 440 / Self.sampleRate
        }
        var flagsOut = AudioUnitRenderActionFlags()
        var stamp = AudioTimeStamp()
        stamp.mSampleTime = Double(delivered) * Double(Self.framesPer10ms)
        stamp.mFlags = .sampleTimeValid
        samples.withUnsafeMutableBytes { raw in
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress)
            )
            _ = delegate.deliverRecordedData(&flagsOut, &stamp, 0, Self.framesPer10ms, &list, nil, nil)
        }
        lock.withLock { delivered += 1 }
    }

    private func pullPlayout() {
        guard let delegate = lock.withLock({ self.delegate }) else { return }
        var samples = [Int16](repeating: 0, count: Int(Self.framesPer10ms))
        var flagsOut = AudioUnitRenderActionFlags()
        var stamp = AudioTimeStamp()
        stamp.mFlags = .sampleTimeValid
        samples.withUnsafeMutableBytes { raw in
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress)
            )
            _ = delegate.getPlayoutData(&flagsOut, &stamp, 0, Self.framesPer10ms, &list)
        }
        lock.withLock { pulled += 1 }
    }
}
