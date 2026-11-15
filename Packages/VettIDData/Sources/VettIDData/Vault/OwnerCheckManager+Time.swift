import Foundation

// The vault's instants (RFC 3339) as the owner check reads and writes them.
extension OwnerCheckManager {
    /// An RFC 3339 instant of the vault (with or without fractional seconds); nil when absent or unreadable.
    public nonisolated static func instant(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    nonisolated static func format(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }
}
