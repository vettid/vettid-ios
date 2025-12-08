import Foundation
import UIKit

/// Secure pasteboard handling to prevent sensitive data leakage
/// Implements automatic expiration and content type restrictions
final class SecurePasteboard {

    // MARK: - Configuration

    /// Default expiration time for sensitive content (30 seconds)
    static let defaultExpirationInterval: TimeInterval = 30

    /// Current sensitive content timer
    private static var expirationTimer: Timer?

    // MARK: - Secure Copy Operations

    /// Copy sensitive text to pasteboard with automatic expiration
    /// - Parameters:
    ///   - text: The sensitive text to copy
    ///   - expiresIn: Time interval after which the content is cleared (default: 30 seconds)
    ///   - localOnly: If true, prevents content from being shared via Handoff (default: true)
    static func copySecure(
        _ text: String,
        expiresIn: TimeInterval = defaultExpirationInterval,
        localOnly: Bool = true
    ) {
        let pasteboard = UIPasteboard.general

        // Cancel any existing expiration timer
        expirationTimer?.invalidate()

        if localOnly {
            // Use local-only pasteboard item options
            pasteboard.setItems(
                [[UIPasteboard.typeAutomatic: text]],
                options: [
                    .localOnly: true,
                    .expirationDate: Date().addingTimeInterval(expiresIn)
                ]
            )
        } else {
            // Standard copy with expiration
            pasteboard.setItems(
                [[UIPasteboard.typeAutomatic: text]],
                options: [
                    .expirationDate: Date().addingTimeInterval(expiresIn)
                ]
            )
        }

        // Set backup timer in case system expiration fails
        expirationTimer = Timer.scheduledTimer(withTimeInterval: expiresIn, repeats: false) { _ in
            clearIfMatches(text)
        }
    }

    /// Copy data to pasteboard with automatic expiration
    static func copySecure(
        data: Data,
        uti: String,
        expiresIn: TimeInterval = defaultExpirationInterval,
        localOnly: Bool = true
    ) {
        let pasteboard = UIPasteboard.general

        expirationTimer?.invalidate()

        var options: [UIPasteboard.OptionsKey: Any] = [
            .expirationDate: Date().addingTimeInterval(expiresIn)
        ]

        if localOnly {
            options[.localOnly] = true
        }

        pasteboard.setItems([[uti: data]], options: options)
    }

    // MARK: - Clear Operations

    /// Clear pasteboard if it contains the expected content
    /// This prevents clearing user's other clipboard content
    private static func clearIfMatches(_ expectedText: String) {
        let pasteboard = UIPasteboard.general
        if pasteboard.string == expectedText {
            pasteboard.items = []
        }
    }

    /// Forcefully clear the pasteboard
    static func clear() {
        UIPasteboard.general.items = []
        expirationTimer?.invalidate()
        expirationTimer = nil
    }

    // MARK: - Content Type Restrictions

    /// Sensitive content types that should never be copied
    static let restrictedContentTypes = [
        "private-key",
        "password",
        "seed-phrase",
        "recovery-key"
    ]

    /// Check if content type is restricted from clipboard
    static func isRestricted(contentType: String) -> Bool {
        return restrictedContentTypes.contains { contentType.lowercased().contains($0) }
    }
}

// MARK: - Pasteboard Monitoring

extension SecurePasteboard {

    /// Monitor for potential clipboard attacks
    /// Note: This is limited on iOS - mainly for detection/logging
    static func checkForSuspiciousContent() -> Bool {
        let pasteboard = UIPasteboard.general

        // Check for excessively long content (potential data exfiltration)
        if let string = pasteboard.string, string.count > 10_000 {
            return true
        }

        // Check for suspicious patterns
        if let string = pasteboard.string {
            // Check for cryptocurrency addresses being overwritten (clipboard hijacking)
            let cryptoPatterns = [
                "^(bc1|[13])[a-zA-HJ-NP-Z0-9]{25,39}$",  // Bitcoin
                "^0x[a-fA-F0-9]{40}$"                      // Ethereum
            ]

            for pattern in cryptoPatterns {
                if let regex = try? NSRegularExpression(pattern: pattern),
                   regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) != nil {
                    // Found crypto address - could be legitimate or clipboard hijacking
                    // Log for analysis
                    return true
                }
            }
        }

        return false
    }
}
