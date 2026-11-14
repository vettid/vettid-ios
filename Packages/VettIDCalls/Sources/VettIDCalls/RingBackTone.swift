import AVFoundation
import Foundation

/// The caller's ring-back tone: the North American ring tone (440 Hz and 480 Hz together, 2 s on and 4 s off), the same as
/// Android's `TONE_SUP_RINGTONE`, as a looping WAV made in memory. CallKit plays no ring-back for an outgoing call.
enum RingBackTone {
    static let sampleRate = 8000
    static let onSeconds = 2
    static let cycleSeconds = 6

    /// 16-bit mono PCM in a WAV container, one cycle (it loops).
    static func wav() -> Data {
        let frames = sampleRate * cycleSeconds
        var pcm = Data(capacity: frames * 2)
        for i in 0..<frames {
            var value: Int16 = 0
            if i < sampleRate * onSeconds {
                let t = Double(i) / Double(sampleRate)
                // Two tones at 0.2 each: a peak of 0.4 of full scale.
                value = Int16((0.2 * (sin(2 * .pi * 440 * t) + sin(2 * .pi * 480 * t)) * 32767).rounded())
            }
            withUnsafeBytes(of: value.littleEndian) { pcm.append(contentsOf: $0) }
        }
        var out = Data()
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { out.append(contentsOf: $0) } }
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { out.append(contentsOf: $0) } }
        out.append(contentsOf: Array("RIFF".utf8))
        u32(36 + pcm.count)
        out.append(contentsOf: Array("WAVEfmt ".utf8))
        u32(16)
        u16(1)
        u16(1)
        u32(sampleRate)
        u32(sampleRate * 2)
        u16(2)
        u16(16)
        out.append(contentsOf: Array("data".utf8))
        u32(pcm.count)
        out.append(pcm)
        return out
    }
}

/// ``CallTones`` with `AVAudioPlayer`: the ring-back from ``RingBackTone``. The slot makes a tone that plays never restart.
@MainActor
public final class SystemCallTones: CallTones {
    private let ringBackSlot = ToneSlot<AVAudioPlayer>(
        begin: {
            guard let p = try? AVAudioPlayer(data: RingBackTone.wav()) else { return nil }
            p.numberOfLoops = -1
            return p.play() ? p : nil
        },
        end: { $0.stop() }
    )

    public init() {}

    public func ringBack(_ on: Bool) { ringBackSlot.set(on) }
}
