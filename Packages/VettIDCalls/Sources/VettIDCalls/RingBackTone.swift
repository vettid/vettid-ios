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

/// ``CallTones`` with `AVAudioPlayer`: the ring-back from ``RingBackTone`` and, when CallKit could not show an incoming call,
/// the app's own ringtone (`vettid_ringtone.caf` in the main bundle). The slots make a tone that plays never restart.
@MainActor
public final class SystemCallTones: CallTones {
    private let ringBackSlot: ToneSlot<AVAudioPlayer>
    private let ringtoneSlot: ToneSlot<AVAudioPlayer>

    public init(ringtoneName: String = "vettid_ringtone", ringtoneExtension: String = "caf", bundle: Bundle = .main) {
        ringBackSlot = ToneSlot(
            begin: { Self.play { try AVAudioPlayer(data: RingBackTone.wav()) } },
            end: { $0.stop() }
        )
        ringtoneSlot = ToneSlot(
            begin: {
                guard let url = bundle.url(forResource: ringtoneName, withExtension: ringtoneExtension) else { return nil }
                return Self.play { try AVAudioPlayer(contentsOf: url) }
            },
            end: { $0.stop() }
        )
    }

    public func ringBack(_ on: Bool) { ringBackSlot.set(on) }

    public func ringtone(_ on: Bool) { ringtoneSlot.set(on) }

    /// A started looping player, or nil if it could not start (nothing then counts as playing).
    private static func play(_ make: () throws -> AVAudioPlayer) -> AVAudioPlayer? {
        guard let p = try? make() else { return nil }
        p.numberOfLoops = -1
        return p.play() ? p : nil
    }
}
