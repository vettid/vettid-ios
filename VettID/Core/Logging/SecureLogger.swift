import Foundation
import os.log

/// Secure logging utility that only outputs in DEBUG builds
/// Prevents sensitive information from appearing in production logs
///
/// Usage:
///   SecureLogger.debug("User logged in")
///   SecureLogger.info("Processing request")
///   SecureLogger.warning("Deprecated API called")
///   SecureLogger.error("Failed to connect")
///   SecureLogger.security("Suspicious activity detected")
///
/// All logging is completely disabled in RELEASE builds.
enum SecureLogger {

    // MARK: - Log Categories

    /// Debug-level logging (verbose, development only)
    static func debug(_ message: @autoclosure () -> String, file: String = #file, function: String = #function, line: Int = #line) {
        #if DEBUG
        log(level: .debug, category: "Debug", message: message(), file: file, function: function, line: line)
        #endif
    }

    /// Info-level logging (general information)
    static func info(_ message: @autoclosure () -> String, file: String = #file, function: String = #function, line: Int = #line) {
        #if DEBUG
        log(level: .info, category: "Info", message: message(), file: file, function: function, line: line)
        #endif
    }

    /// Warning-level logging (potential issues)
    static func warning(_ message: @autoclosure () -> String, file: String = #file, function: String = #function, line: Int = #line) {
        #if DEBUG
        log(level: .warning, category: "Warning", message: message(), file: file, function: function, line: line)
        #endif
    }

    /// Error-level logging (errors and failures)
    static func error(_ message: @autoclosure () -> String, file: String = #file, function: String = #function, line: Int = #line) {
        #if DEBUG
        log(level: .error, category: "Error", message: message(), file: file, function: function, line: line)
        #endif
    }

    /// Security-related logging (authentication, authorization, threats)
    static func security(_ message: @autoclosure () -> String, file: String = #file, function: String = #function, line: Int = #line) {
        #if DEBUG
        log(level: .warning, category: "Security", message: message(), file: file, function: function, line: line)
        #endif
    }

    /// Network-related logging (API calls, NATS, etc.)
    static func network(_ message: @autoclosure () -> String, file: String = #file, function: String = #function, line: Int = #line) {
        #if DEBUG
        log(level: .debug, category: "Network", message: message(), file: file, function: function, line: line)
        #endif
    }

    /// Crypto-related logging (encryption, signing, etc.)
    static func crypto(_ message: @autoclosure () -> String, file: String = #file, function: String = #function, line: Int = #line) {
        #if DEBUG
        log(level: .debug, category: "Crypto", message: message(), file: file, function: function, line: line)
        #endif
    }

    /// NATS messaging logging
    static func nats(_ message: @autoclosure () -> String, file: String = #file, function: String = #function, line: Int = #line) {
        #if DEBUG
        log(level: .debug, category: "NATS", message: message(), file: file, function: function, line: line)
        #endif
    }

    // MARK: - Log Levels

    enum LogLevel: String {
        case debug = "🔍"
        case info = "ℹ️"
        case warning = "⚠️"
        case error = "❌"
    }

    // MARK: - Private Implementation

    private static func log(
        level: LogLevel,
        category: String,
        message: String,
        file: String,
        function: String,
        line: Int
    ) {
        #if DEBUG
        let fileName = (file as NSString).lastPathComponent
        let timestamp = ISO8601DateFormatter().string(from: Date())

        // Format: [timestamp] [level] [category] filename:line - message
        let logMessage = "[\(timestamp)] \(level.rawValue) [\(category)] \(fileName):\(line) - \(message)"
        print(logMessage)
        #endif
    }

    // MARK: - Sensitive Data Redaction

    /// Redact sensitive data for logging (use when you must log something that might contain PII)
    /// Only shows first and last 4 characters with asterisks in between
    static func redact(_ value: String) -> String {
        guard value.count > 8 else {
            return String(repeating: "*", count: value.count)
        }
        let prefix = String(value.prefix(4))
        let suffix = String(value.suffix(4))
        let middle = String(repeating: "*", count: min(value.count - 8, 8))
        return "\(prefix)\(middle)\(suffix)"
    }

    /// Completely mask a value (for highly sensitive data)
    static func mask(_ value: String) -> String {
        return "[REDACTED:\(value.count) chars]"
    }
}

// MARK: - Convenience Extensions

extension SecureLogger {
    /// Log an error with its localized description
    static func error(_ error: Error, context: String = "", file: String = #file, function: String = #function, line: Int = #line) {
        #if DEBUG
        let message = context.isEmpty ? error.localizedDescription : "\(context): \(error.localizedDescription)"
        log(level: .error, category: "Error", message: message, file: file, function: function, line: line)
        #endif
    }
}
