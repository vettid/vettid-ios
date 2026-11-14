import Foundation
import VettIDCallsWebRTC

/// stderr into a file for a while.
final class StderrCapture {
    private let saved: Int32
    private let url = FileManager.default.temporaryDirectory.appending(path: "stderr-\(UUID().uuidString)")
    private let file: Int32

    init() throws {
        fflush(stderr)
        file = open(url.path, O_CREAT | O_RDWR, 0o600)
        guard file >= 0 else { throw MediaEngineError("no capture file") }
        saved = dup(2)
        dup2(file, 2)
    }

    func finish() -> String {
        fflush(stderr)
        dup2(saved, 2)
        close(saved)
        close(file)
        defer { try? FileManager.default.removeItem(at: url) }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
}
