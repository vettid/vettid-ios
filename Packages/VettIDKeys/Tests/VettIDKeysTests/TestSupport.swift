import Foundation
import VettIDKeys

/// A fresh directory under the test's temporary directory (never Caches: the store refuses nothing there, but the
/// tests stay out of the user's data).
func scratchDirectory(_ name: String = #function) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("vettid-keys-tests", isDirectory: true)
        .appendingPathComponent("\(name.filter(\.isLetter))-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Protected data that is available for the first [availableReads] reads and then goes away: a lookup during which the
/// iPhone locks.
final class FadingProtectedData: ProtectedData, @unchecked Sendable {
    private let lock = NSLock()
    private var left: Int

    init(availableReads: Int) {
        left = availableReads
    }

    var isAvailable: Bool {
        lock.withLock {
            left -= 1
            return left >= 0
        }
    }
}
