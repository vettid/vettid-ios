import Foundation
import VettIDData

/// A run's size in its summary line (ANDROID-PLAN 0.1.137 AA8): the bytes of all of `argv` and of `env`'s names and values,
/// 1,024-based. Pure. Mirrors vettid-android `WaySizes`.
public enum WaySizes {
    public enum Size: Equatable, Sendable {
        case bytes(Int)
        case kb(String)
        case mb(String)
    }

    private static let k = 1_024.0

    public static func runBytes(_ r: ItemRun) -> Int {
        r.argv.reduce(0) { $0 + $1.utf8.count } + r.env.reduce(0) { $0 + $1.name.utf8.count + $1.value.utf8.count }
    }

    /// Bytes below 1 KB; else KB below 1 MB; else MB. One decimal below 10 of the unit, else whole.
    public static func unit(_ bytes: Int) -> Size {
        if Double(bytes) < k { return .bytes(bytes) }
        let kb = rounded(Double(bytes) / k)
        // Judged after rounding, so 1,048,000 bytes is "1.0 MB", not "1024 KB".
        return kb < k ? .kb(number(kb)) : .mb(number(rounded(Double(bytes) / (k * k))))
    }

    /// One decimal below 10, whole from 10.
    private static func rounded(_ x: Double) -> Double {
        x < 10 - 0.05 ? (x * 10).rounded(.toNearestOrAwayFromZero) / 10 : x.rounded(.toNearestOrAwayFromZero)
    }

    private static func number(_ x: Double) -> String {
        String(format: x < 10 ? "%.1f" : "%.0f", locale: Locale.current, x)
    }
}
