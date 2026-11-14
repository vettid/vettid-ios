import Foundation

/// SDP changes for ``MediaFaults``: two-phone tests only (vettid-android `MediaFaultSdp`).
enum MediaFaultSdp {
    private static let announce = "a=ssrc:"

    /// [sdp] with every announced SSRC replaced by the number after it: the audio then arrives on an SSRC nobody announced.
    static func misstateSsrc(_ sdp: String) -> String {
        var lines = sdp.components(separatedBy: "\n")
        for index in lines.indices where lines[index].hasPrefix(announce) {
            let rest = lines[index].dropFirst(announce.count)
            let number = rest.prefix { $0.isASCII && $0.isNumber }
            guard let value = UInt64(number) else { continue }
            lines[index] = announce + String((value + 1) & 0xFFFF_FFFF) + rest.dropFirst(number.count)
        }
        return lines.joined(separator: "\n")
    }
}
