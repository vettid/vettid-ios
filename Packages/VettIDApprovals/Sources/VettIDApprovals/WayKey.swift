import Foundation
import VettIDCrypto
import VettIDData

/// The gate's re-arm key (AA8): a SHA-256 of everything a run or a proxy shows, each part length-prefixed, so any change of what
/// is shown (and nothing else) gives another key. Not `hashValue`, which can collide. Pure. Mirrors vettid-android `WayKey`.
public enum WayKey {
    public static func of(_ held: HeldShow) -> String {
        var parts: [String?]
        switch held {
        case .run(let r, let item, let field):
            parts = ["run", item, field, r.itemID, r.fieldID, r.program, r.sha256, r.cwd, r.how.rawValue, r.name, r.previousSha256,
                     r.previousPath, r.replaces]
            parts += r.argv.map { "argv:\($0)" }
            parts += r.env.flatMap { ["env:\($0.name)", $0.value] }
            parts += r.flags.map { "flag:\($0.rawValue)" }.sorted()
        case .proxy(let p, let item, let field):
            parts = ["proxy", item, field, p.itemID, p.fieldID, p.host, p.header, p.prefix, String(p.seconds), p.replaces]
        default:
            parts = ["other"]
        }
        var bytes: [UInt8] = []
        for part in parts {
            let b = Array((part ?? "\u{0}null").utf8)
            bytes += Array(String(b.count).utf8) + [0x3A] + b
        }
        return Bytes.sha256(bytes).map { String(format: "%02x", $0) }.joined()
    }
}
