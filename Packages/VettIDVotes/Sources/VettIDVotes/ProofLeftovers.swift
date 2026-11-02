import Foundation

/// The proof's temporary directories (IOS-PLAN §4.16): each "Save the proof" writes the evidence to a directory of its own
/// in the app's temporary directory, named with [prefix], and removes it on every path. One can be left only by an app
/// that was killed while the system's document picker was up; [remove] clears those, at launch and when a vote opens.
public enum ProofLeftovers {
    public static let prefix = "vettid-proof-"

    /// Removes the proof directories left in [root] (best effort) and returns how many there were. Nothing else in [root]
    /// is touched, and nothing is read or logged.
    @discardableResult
    public static func remove(in root: URL = FileManager.default.temporaryDirectory) -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        let mine = names.filter { $0.hasPrefix(prefix) }
        for n in mine { try? FileManager.default.removeItem(at: root.appendingPathComponent(n)) }
        return mine.count
    }
}
