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

    /// No source file of the repository calls the stack's logging, tracing or recording, or taps its raw audio; a file that
    /// cannot be read as text is a failure, not a skip.
    @Test func noSourceFileTurnsTheMediaStacksLoggingOn() throws {
        let root = try Self.repositoryRoot()
        // Exempt by path from the repository root: another file of the same name is not exempt.
        let allowed: Set = [
            "Packages/VettIDCallsWebRTC/Sources/VettIDCallsWebRTC/MediaLogGuard.swift",
            "Packages/VettIDCallsWebRTC/Tests/VettIDCallsWebRTCTests/MediaLogGuardTests.swift",
        ]
        let everything = Self.sourceFiles(under: root)
        let sources = everything.filter { !allowed.contains(Self.relative($0, to: root)) }
        #expect(sources.count > 200)
        #expect(sources.contains { $0.lastPathComponent == "WebRtcMediaEngine.swift" })
        #expect(Set(sources.map(\.pathExtension)).isSuperset(of: ["swift", "h", "c", "plist", "xcconfig", "xcscheme"]))
        #expect(sources.contains { $0.lastPathComponent == "project.yml" })
        var offenders: [String] = []
        for file in sources {
            let path = Self.relative(file, to: root)
            guard let text = try? String(contentsOf: file, encoding: .utf8) else {
                offenders.append("\(path): not readable as UTF-8 text")
                continue
            }
            for name in MediaLogGuard.offences(in: text) { offenders.append("\(path): \(name)") }
            // A custom audio device sees the decrypted audio: only the factory's file (Debug-only code) and tests may name it.
            let isTest = path.contains("Tests/")
            let factoryFile = "Packages/VettIDCallsWebRTC/Sources/VettIDCallsWebRTC/WebRtcRuntime.swift"
            if !isTest {
                // The factory's file may name it only inside its `#if DEBUG` blocks, which a Release build does not compile.
                let compiled = path == factoryFile ? MediaLogGuard.withoutDebugBlocks(text) : text
                for name in MediaLogGuard.offencesOutsideTests(in: compiled) { offenders.append("\(path): \(name)") }
            }
        }
        #expect(offenders == [])
    }

    /// The raw-audio taps and the other added names are in the scan, each caught in the shape it has in source.
    @Test func theRawAudioTapsAreRefused() {
        let lines = [
            "track.add(renderer) // an RTCAudioRenderer",
            "final class Tap: NSObject, RTCAudioCustomProcessingDelegate {}",
            "[track addRenderer:self];",
            "config.turnLoggingId = id",
            "RTCLog(@\"x\");",
        ]
        for line in lines { #expect(!MediaLogGuard.offences(in: line).isEmpty, "\(line)") }
        // A custom device outside the tests' and the factory's files.
        #expect(!MediaLogGuard.offencesOutsideTests(in: "final class Mic: NSObject, RTCAudioDevice {}").isEmpty)
        #expect(MediaLogGuard.offencesOutsideTests(in: "let c = RTCConfiguration()").isEmpty)
    }

    /// The factory's file may name the audio device type only inside `#if DEBUG`.
    @Test func theAudioDeviceTypeIsAllowedOnlyInsideADebugBlock() {
        let inside = "let a = 1\n#if DEBUG\nvar d: (any RTCAudioDevice)?\n#if os(iOS)\nlet x = 1\n#endif\n#endif\nlet b = 2\n"
        #expect(MediaLogGuard.offencesOutsideTests(in: MediaLogGuard.withoutDebugBlocks(inside)).isEmpty)
        #expect(MediaLogGuard.withoutDebugBlocks(inside).contains("let b = 2"))
        let outside = "#if DEBUG\nlet x = 1\n#endif\nvar d: (any RTCAudioDevice)?\n"
        #expect(!MediaLogGuard.offencesOutsideTests(in: MediaLogGuard.withoutDebugBlocks(outside)).isEmpty)
        // A block of another condition is compiled in Release: the name there is refused.
        let release = "#if !DEBUG\nvar d: (any RTCAudioDevice)?\n#endif\n"
        #expect(!MediaLogGuard.offencesOutsideTests(in: MediaLogGuard.withoutDebugBlocks(release)).isEmpty)
    }

    /// The scan reads the files that carry settings and project wiring, and does not skip another directory called "build".
    @Test func theScanSkipsOnlyTheRepositorysOwnBuildOutput() throws {
        let root = try Self.repositoryRoot()
        let found = Self.sourceFiles(under: root).map { Self.relative($0, to: root) }
        #expect(!found.contains { $0.hasPrefix("build/") || $0.hasPrefix(".build/") || $0.contains("/.build/") })
        #expect(!found.contains { $0.hasPrefix("Packages/VettIDCallsWebRTC/build/") })
        #expect(found.contains("project.yml"))
        #expect(Self.skipped("Packages/Foo/build"))
        #expect(Self.skipped("Packages/Foo/.build"))
        #expect(Self.skipped("build"))
        #expect(!Self.skipped("Packages/Foo/Sources/build"))
        #expect(!Self.skipped("App/build"))
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
        let sources = Self.sourceFiles(under: root).filter { $0.pathExtension == "swift" }.filter { !$0.path.contains("/Tests/") }
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

    /// Every kind of file that can call the stack or switch it on: sources and headers of every language of the build, property
    /// lists and build settings. (`project.yml` and `Package.swift` are read by name.)
    static let scanned: Set = ["swift", "m", "mm", "c", "cc", "cpp", "h", "hpp", "plist", "xcconfig", "xcscheme"]

    static func relative(_ url: URL, to root: URL) -> String {
        String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
    }

    /// The repository's own output directories, by path from the root: version control, the root's `build`, and a package's
    /// `.build` and `build`. Any other directory with such a name is read.
    static func skipped(_ relativePath: String) -> Bool {
        let parts = relativePath.split(separator: "/").map(String.init)
        if parts == [".git"] || parts == ["build"] || parts == [".build"] || parts == ["DerivedData"] { return true }
        return parts.count == 3 && parts[0] == "Packages" && [".build", "build", ".swiftpm"].contains(parts[2])
    }

    static func sourceFiles(under root: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        var found: [URL] = []
        for case let url as URL in walker {
            let path = relative(url, to: root)
            if skipped(path) {
                walker.skipDescendants()
            } else if scanned.contains(url.pathExtension) || url.lastPathComponent == "project.yml" {
                found.append(url)
            }
        }
        return found
    }
}
