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

    /// [text] without the lines from each `#if DEBUG` to its matching `#else`, `#elseif` or `#endif` (nesting counted): what a
    /// Release build compiles of a file. A `#if` of another condition counts for nesting only. A directive is read only where
    /// the compiler reads one: not inside a block comment (nested ones counted) or a multi-line string. Fails closed: a file
    /// whose directives do not balance is returned whole, as if all of it were compiled in Release.
    public static func withoutDebugBlocks(_ text: String) -> String {
        var depth = 0
        var debugDepth: Int?
        var kept: [Substring] = []
        var lexer = DirectiveLexer()
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let atCode = lexer.atCode
            lexer.scan(line)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if atCode, trimmed.hasPrefix("#if") {
                depth += 1
                if debugDepth == nil, trimmed == "#if DEBUG" { debugDepth = depth }
                continue
            }
            if atCode, trimmed.hasPrefix("#else") {
                // `#else` and `#elseif`: what follows at the same depth is compiled in Release.
                if debugDepth == depth { debugDepth = nil }
                continue
            }
            if atCode, trimmed.hasPrefix("#endif") {
                if debugDepth == depth { debugDepth = nil }
                depth -= 1
                if depth < 0 { return text }
                continue
            }
            if debugDepth == nil { kept.append(line) }
        }
        guard depth == 0, !lexer.open else { return text }
        return kept.joined(separator: "\n")
    }

    /// Where a line of Swift starts: in code, or inside a block comment (Swift nests them) or a multi-line string. Enough for
    /// directives (which the compiler reads only in code); anything it gets wrong shows as unbalanced directives, which fail
    /// closed.
    struct DirectiveLexer {
        private var comments = 0
        private var multiline = false

        var atCode: Bool { comments == 0 && !multiline }
        /// A comment or a multi-line string not closed at the end of the file.
        var open: Bool { !atCode }

        mutating func scan(_ line: Substring) {
            let c = Array(line.utf8)
            var i = 0
            var inString = false
            while i < c.count {
                if multiline {
                    i = inMultiline(c, i)
                } else if comments > 0 {
                    i = inComment(c, i)
                } else if inString {
                    i = Self.inLiteral(c, i, &inString)
                } else {
                    guard let next = inCode(c, i, &inString) else { return }
                    i = next
                }
            }
        }

        private mutating func inMultiline(_ c: [UInt8], _ i: Int) -> Int {
            if Self.has(c, i, "\\") { return i + 2 }
            if Self.has(c, i, "\"\"\"") {
                multiline = false
                return i + 3
            }
            return i + 1
        }

        private mutating func inComment(_ c: [UInt8], _ i: Int) -> Int {
            if Self.has(c, i, "/*") {
                comments += 1
                return i + 2
            }
            if Self.has(c, i, "*/") {
                comments -= 1
                return i + 2
            }
            return i + 1
        }

        /// Nil: the rest of the line is a line comment.
        private mutating func inCode(_ c: [UInt8], _ i: Int, _ inString: inout Bool) -> Int? {
            if Self.has(c, i, "//") { return nil }
            if Self.has(c, i, "/*") {
                comments += 1
                return i + 2
            }
            if Self.has(c, i, "\"\"\"") {
                multiline = true
                return i + 3
            }
            if Self.has(c, i, "\"") { inString = true }
            return i + 1
        }

        /// Inside a one-line string literal: an escape is skipped, a quote ends it.
        private static func inLiteral(_ c: [UInt8], _ i: Int, _ inString: inout Bool) -> Int {
            if has(c, i, "\\") { return i + 2 }
            if has(c, i, "\"") { inString = false }
            return i + 1
        }

        private static func has(_ c: [UInt8], _ i: Int, _ s: String) -> Bool {
            let b = Array(s.utf8)
            return i >= 0 && i + b.count <= c.count && Array(c[i..<(i + b.count)]) == b
        }
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
