import AVFoundation
import Testing

/// VettID's notification sounds (IOS-PLAN §6.7 "Sounds") are in the app's bundle, as CAF files iOS can play: mono 44.1 kHz,
/// each as long as its master, and short enough for a notification (iOS plays at most 30 s).
struct NotificationSoundsTests {
    static let lengths: [String: Double] = [
        "vettid_general": 1.36, "vettid_message": 1.66, "vettid_urgent": 2.16, "vettid_ringtone": 8.0,
    ]

    @Test(arguments: lengths.keys.sorted())
    func theSoundIsBundled(_ name: String) throws {
        let url = try #require(Bundle.main.url(forResource: name, withExtension: "caf"), "\(name).caf not in the bundle")
        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.channelCount == 1 && file.fileFormat.sampleRate == 44_100)
        let seconds = Double(file.length) / file.fileFormat.sampleRate
        #expect(abs(seconds - (Self.lengths[name] ?? 0)) < 0.01, "\(name): \(seconds) s")
        #expect(seconds < 30)
    }
}
