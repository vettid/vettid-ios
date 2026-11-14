import Foundation
import Testing
import VettIDCalls
@testable import VettIDCallsWebRTC

/// Mirrors vettid-android `MediaGuardsTest`: no source file may touch the stack's logging, and keys are refused while it is
/// on or cannot be shown to be off.
struct MediaLogGuardTests {
    struct Switches: MediaLoggingSwitches {
        let off: Bool
        func isOff() -> Bool { off }
    }

    @Test func theGuardPassesOnlyWhileTheLoggingIsOff() throws {
        try MediaLogGuard.check(Switches(off: true))
        #expect(throws: MediaLoggingError.self) { try MediaLogGuard.check(Switches(off: false)) }
        try MediaLogGuard.check()
    }

    /// A key is refused, and wiped, while the logging cannot be shown to be off.
    @Test @MainActor func setKeysChecksTheGuardBeforeAnythingElse() async throws {
        let engine = WebRtcMediaEngine(config: MediaConfig(), switches: Switches(off: false))
        var send = [UInt8](repeating: 7, count: 16)
        var receive = [UInt8](repeating: 9, count: 16)
        await #expect(throws: MediaLoggingError.self) { try await engine.setKeys(.aes128Gcm, send: &send, receive: &receive) }
        #expect(send == [UInt8](repeating: 0, count: 16))
        #expect(receive == [UInt8](repeating: 0, count: 16))
        engine.close()
    }

    /// No source file of the repository calls the stack's logging, tracing or recording.
    @Test func noSourceFileTurnsTheMediaStacksLoggingOn() throws {
        let root = try Self.repositoryRoot()
        let allowed: Set = ["MediaLogGuard.swift", "MediaLogGuardTests.swift"]
        let sources = Self.swiftFiles(under: root).filter { !allowed.contains($0.lastPathComponent) }
        #expect(sources.count > 200)
        #expect(sources.contains { $0.lastPathComponent == "WebRtcMediaEngine.swift" })
        var offenders: [String] = []
        for file in sources {
            let text = try String(contentsOf: file, encoding: .utf8)
            for name in MediaLogGuard.forbidden where text.contains(name) {
                offenders.append("\(file.lastPathComponent): \(name)")
            }
        }
        #expect(offenders == [])
    }

    /// Not even the guard calls the stack's logging setter: its name is in the guard's list of what is forbidden, as a string.
    @Test func theGuardItselfCallsNothingOfTheStacksLogging() throws {
        let guardFile = try Self.repositoryRoot()
            .appending(path: "Packages/VettIDCallsWebRTC/Sources/VettIDCallsWebRTC/MediaLogGuard.swift")
        let text = try String(contentsOf: guardFile, encoding: .utf8)
        #expect(!text.contains("import WebRTC"))
        for name in MediaLogGuard.forbidden { #expect(!text.contains("\(name)(")) }
    }

    /// The test switch that turns the transport's encryption off exists for nothing but a wire-reading test, and no
    /// source an app is built from may name it.
    @Test func noSourceSwitchesTheStacksTransportEncryptionOff() throws {
        let root = try Self.repositoryRoot()
        let sources = Self.swiftFiles(under: root).filter { !$0.path.contains("/Tests/") && !$0.path.contains("Tests.swift") }
        #expect(sources.contains { $0.lastPathComponent == "WebRtcMediaEngine.swift" })
        let offenders = try sources.filter { try String(contentsOf: $0, encoding: .utf8).contains("disableEncryption") }
        #expect(offenders.map(\.lastPathComponent) == [])
    }

    static func repositoryRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            url.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appending(path: "project.yml").path) { return url }
        }
        throw MediaEngineError("repository root not found")
    }

    static func swiftFiles(under root: URL) -> [URL] {
        let skip: Set = [".build", ".git", "build", "DerivedData", ".swiftpm"]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        var found: [URL] = []
        for case let url as URL in walker {
            if skip.contains(url.lastPathComponent) {
                walker.skipDescendants()
            } else if url.pathExtension == "swift" {
                found.append(url)
            }
        }
        return found
    }
}
