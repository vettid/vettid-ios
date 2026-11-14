import Foundation
import VettIDCalls

// Mirrors vettid-android `MediaLogGuard.kt`: keeps key material out of logs. Up to 150.7871.01 the media stack's key
// derivation logged its input key, its salt and the derived key at severity INFO (CALL-MEDIA §7.1); 150.7871.04 logs sizes
// only, but a stack's logging is still nothing a call wants, so nothing in this app ever switches it on.

/// The stack's logging switches, behind a protocol so that a test can stand in for them.
public protocol MediaLoggingSwitches: Sendable {
    /// Whether the stack's logging is shown to be off. False: it is on, or cannot be shown to be off.
    func isOff() -> Bool
}

/// The real switches. Unlike the Android stack, the iOS stack's debug output level has a setter only (nothing to read, no
/// injected logger to look for), and the setter cannot be used to make sure of it either: in 150.7871.04 the setter
/// (`RTCSetMinDebugLogLevel`) with any level, `.none` and `.error` included, switches the stack's INFO output to stderr on
/// (measured; it is why the call is forbidden everywhere). The build is silent as shipped, so "off" is a fact about the
/// binary and about this app: the binary prints nothing in its default configuration (`LoopbackTests` captures stderr), and
/// no source file calls the setter or any other way to log, trace or record (``MediaLogGuard/forbidden``, read from every
/// source file by `MediaLogGuardTests`). A call of the setter by other code in the same process is not seen.
public struct LiveLoggingSwitches: MediaLoggingSwitches {
    public init() {}

    public func isOff() -> Bool { true }
}

public enum MediaLogGuard {
    /// Names no source file outside this one and its tests may contain: every way the pinned stack's headers offer to log,
    /// trace, dump or record (read from the 150.7871.04 iOS and macOS headers): debug output (its setter switches the output
    /// on, whatever the level), its callback and file sinks, the log macros, the internal tracer, the event log, the
    /// echo-canceller dump and the metrics.
    public static let forbidden: [String] = [
        "RTCSetMinDebugLogLevel", "RTCLogEx", "RTCLogInfo", "RTCLogVerbose", "RTCLogWarning", "RTCLogError", "RTCLogDebug",
        "RTCLogFormat", "RTCLogString", "RTCLog(", "RTCCallbackLogger", "RTCFileLogger", "turnLoggingId",
        // Raw audio: a tap on the decoded (played) or captured sound, or on the processing of it. `addRenderer:` is `add(_:)` in
        // Swift, so the type a renderer has to conform to is what the scan can see.
        "addRenderer", "RTCAudioRenderer", "RTCAudioCustomProcessingDelegate",
        // Tracing.
        "RTCSetupInternalTracer", "RTCStartInternalCapture", "RTCStopInternalCapture", "RTCShutdownInternalTracer",
        // Records of a call: its packet metadata, its raw audio, its measurements.
        "startRtcEventLog", "startAecDump", "RTCEnableMetrics", "RTCGetAndResetMetrics",
    ]

    /// Names that only the one file that makes the process's factory may contain (a custom audio device sees the decrypted,
    /// played audio): see ``offencesOutsideTests(in:)``.
    public static let forbiddenOutsideTests: [String] = ["RTCAudioDevice"]

    /// [text] without the lines from each `#if DEBUG` to its matching `#endif` (nesting counted): what a Release build compiles
    /// of a file. A `#if` of another condition counts for nesting only.
    public static func withoutDebugBlocks(_ text: String) -> String {
        var depth = 0
        var debugDepth: Int?
        var kept: [Substring] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#if") {
                depth += 1
                if debugDepth == nil, trimmed == "#if DEBUG" { debugDepth = depth }
                continue
            }
            if trimmed.hasPrefix("#endif") {
                if debugDepth == depth { debugDepth = nil }
                depth -= 1
                continue
            }
            if debugDepth == nil { kept.append(line) }
        }
        return kept.joined(separator: "\n")
    }

    /// The names of ``forbiddenOutsideTests`` in [text], a source file that is not a test.
    public static func offencesOutsideTests(in text: String) -> [String] { forbiddenOutsideTests.filter { text.contains($0) } }

    /// The forbidden names that [text] (a source file) contains. A name inside a string is a name: a lookup by name
    /// (`dlsym`, `NSClassFromString`, `NSSelectorFromString`, `perform` with a string) cannot get around this unless it
    /// builds the name from pieces, which no scan of text can refuse (the limit; the symbol scan of the archive in
    /// `scripts/release-check.sh` sees the imports and the selector strings that end up in the binary, not a name built at run
    /// time).
    public static func offences(in text: String) -> [String] { forbidden.filter { text.contains($0) } }

    /// Throws unless the stack's logging is shown to be off.
    public static func check(_ switches: some MediaLoggingSwitches = LiveLoggingSwitches()) throws {
        guard switches.isOff() else { throw MediaLoggingError("debug output is on, or cannot be shown to be off") }
    }
}
