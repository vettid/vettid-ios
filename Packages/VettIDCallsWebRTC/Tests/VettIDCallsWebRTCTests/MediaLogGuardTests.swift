import Foundation
import Testing
import VettIDCalls
@preconcurrency import WebRTC
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
        // Exempt by path from the repository root: another file of the same name is not exempt.
        let allowed: Set = [
            "Packages/VettIDCallsWebRTC/Sources/VettIDCallsWebRTC/MediaLogGuard.swift",
            "Packages/VettIDCallsWebRTC/Tests/VettIDCallsWebRTCTests/MediaLogGuardTests.swift",
        ]
        let sources = Self.sourceFiles(under: root, extensions: Self.scanned).filter { !allowed.contains(Self.relative($0, to: root)) }
        #expect(sources.count > 200)
        #expect(sources.contains { $0.lastPathComponent == "WebRtcMediaEngine.swift" })
        #expect(Set(sources.map(\.pathExtension)).isSuperset(of: ["swift", "h", "c", "plist"]))
        var offenders: [String] = []
        for file in sources {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for name in MediaLogGuard.offences(in: text) { offenders.append("\(Self.relative(file, to: root)): \(name)") }
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

    /// Looking a logging name up by name is a use of the name: the scan refuses the string.
    @Test func aLookupByNameOfTheStacksLoggingIsRefused() {
        let lines = [
            #"let f = dlsym(handle, "RTCSetMinDebugLogLevel")"#,
            #"let c = NSClassFromString("RTCFileLogger")"#,
            #"let c = NSClassFromString("RTCCallbackLogger")"#,
            #"object.perform(NSSelectorFromString("startAecDumpWithFilePath:maxSizeInBytes:"))"#,
            #"object.perform(NSSelectorFromString("startRtcEventLogWithFilePath:outputFile:"))"#,
        ]
        for line in lines { #expect(!MediaLogGuard.offences(in: line).isEmpty, "\(line)") }
        #expect(MediaLogGuard.offences(in: #"let c = NSClassFromString("RTCPeerConnection")"#).isEmpty)
        // The limit: a name built from pieces is not seen by a scan of text.
        #expect(MediaLogGuard.offences(in: #"dlsym(h, "RTCSetMin" + "DebugLogLevel")"#).isEmpty)
    }

#if os(macOS)
    /// THE MEASUREMENT behind the guard, as a test that has to be run on its own: in 150.7871.04 (macOS slice, SwiftPM debug
    /// test build) the debug-output setter with `.none` switches the stack's output to stderr on. It is off by default
    /// because the setting is process-wide and cannot be undone: run in the suite it would make every later test noisy, and
    /// the quiet test (iOS) meaningless. Run it alone:
    /// `VETTID_STACK_LOGGING_MEASUREMENT=1 swift test --package-path Packages/VettIDCallsWebRTC --filter theSetterSwitches`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VETTID_STACK_LOGGING_MEASUREMENT"] == "1")) @MainActor
    func theSetterSwitchesTheStacksOutputOn() async throws {
        let capture = try StderrCapture()
        RTCSetMinDebugLogLevel(.none)
        let call = try LoopbackCall()
        defer { call.close() }
        try await call.connect(suiteA: .aes128Gcm, suiteB: .aes128Gcm, kCaller: randomKey(), kCallee: randomKey())
        _ = await call.wait(seconds: 5) { call.heardA.states(.receive).contains(.ok) && call.heardB.states(.receive).contains(.ok) }
        let lines = capture.finish().components(separatedBy: "\n")
        let stack = lines.filter { $0.contains(".cc:") || $0.contains(".mm:") }
        let keyLike = lines.filter { $0.lowercased().contains("key") }.map { String($0.prefix(110)) }
        print("MEASUREMENT: \(lines.count) lines, \(stack.count) of the stack's own; lines naming a key: \(keyLike.count)")
        for line in Set(keyLike).sorted().prefix(12) { print("MEASUREMENT key line: \(line)") }
        #expect(!stack.isEmpty)
    }
#endif

    /// The test switch that turns the transport's encryption off exists for nothing but a wire-reading test, and no
    /// source an app is built from may name it.
    @Test func noSourceSwitchesTheStacksTransportEncryptionOff() throws {
        let root = try Self.repositoryRoot()
        let sources = Self.sourceFiles(under: root, extensions: ["swift"]).filter { !$0.path.contains("/Tests/") }
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

    /// Every kind of file that can call the stack: Swift, Objective-C and C sources and headers, and property lists.
    static let scanned: Set = ["swift", "m", "mm", "c", "h", "plist"]

    static func relative(_ url: URL, to root: URL) -> String {
        String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
    }

    static func sourceFiles(under root: URL, extensions: Set<String>) -> [URL] {
        let skip: Set = [".build", ".git", "build", "DerivedData", ".swiftpm"]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        var found: [URL] = []
        for case let url as URL in walker {
            if skip.contains(url.lastPathComponent) {
                walker.skipDescendants()
            } else if extensions.contains(url.pathExtension) {
                found.append(url)
            }
        }
        return found
    }
}
