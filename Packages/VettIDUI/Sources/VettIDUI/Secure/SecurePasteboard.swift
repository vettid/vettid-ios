import UIKit

/// The only way the app copies a secret, where vettid-android allows it (IOS-PLAN §6.5): local to this device (never on
/// Universal Clipboard) and gone after [lifetime].
@MainActor
public enum SecurePasteboard {
    public static let defaultLifetime: TimeInterval = 60

    public static func copy(_ text: String, lifetime: TimeInterval = defaultLifetime, pasteboard: UIPasteboard = .general) {
        pasteboard.setItems(
            [[UIPasteboard.typeAutomatic: text]],
            options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(lifetime)]
        )
    }
}
