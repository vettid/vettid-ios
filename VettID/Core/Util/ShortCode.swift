import Foundation

// MARK: - Short Code

/// Short-code formatting + parsing helpers (Phase 1.8).
///
/// The vault generates 12-character ambiguity-safe codes for every
/// short-lived pairing flow (peer invitations, device pairing, agent
/// registration). The same shape is reused across all three so users
/// never have to wonder "what kind of code is this?".
///
/// Display format: three 4-character blocks separated by hyphens
/// (`ABCD-EFGH-JKLM`). On manual entry we accept any whitespace or
/// hyphen layout and uppercase the result.
///
/// Parity with Android `core/util/ShortCode.kt`.
enum ShortCode {

    static let length = 12
    static let blockSize = 4

    /// Ambiguity-safe alphabet — Crockford-style: drop `I`, `O`, `0`, `1`.
    /// Matches Android exactly so codes generated on either platform
    /// validate on the other.
    private static let alphabet: Set<Character> = Set(
        "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
    )

    /// Insert hyphens every `blockSize` characters. If the input is
    /// empty or contains separators, normalize first.
    static func format(_ code: String) -> String {
        let raw = normalize(code)
        guard !raw.isEmpty else { return "" }
        return stride(from: 0, to: raw.count, by: blockSize).map { start in
            let s = raw.index(raw.startIndex, offsetBy: start)
            let e = raw.index(s, offsetBy: min(blockSize, raw.count - start))
            return String(raw[s..<e])
        }.joined(separator: "-")
    }

    /// Strip whitespace + hyphens + underscores + dots, uppercase
    /// everything. The Android implementation accepts `" \t\n-_."`; we
    /// match it character-for-character.
    static func normalize(_ input: String) -> String {
        let stripped = "\t\n -_.\r"
        return input
            .uppercased()
            .filter { !stripped.contains($0) }
    }

    /// Returns true if the (already-normalized or unformatted) input is
    /// a valid 12-character code drawn from the ambiguity-safe alphabet.
    static func isValid(_ input: String) -> Bool {
        let raw = normalize(input)
        guard raw.count == length else { return false }
        return raw.allSatisfy { alphabet.contains($0) }
    }
}

/// Convenience top-level alias for the common "just format this" use.
/// Matches the Android extension `fun formatShortCode(code:)`.
func formatShortCode(_ code: String) -> String { ShortCode.format(code) }
