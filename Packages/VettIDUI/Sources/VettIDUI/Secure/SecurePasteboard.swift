import UIKit

/// The only way the app copies a secret, where vettid-android allows it (IOS-PLAN §6.5): local to this device (never on
/// Universal Clipboard) and gone after [lifetime].
@MainActor
public enum SecurePasteboard {
    public static let defaultLifetime: TimeInterval = 60

    /// [clearAtLock]: a secret item's value, which ``clearIfOwn(pasteboard:)`` removes when the vault is no longer open (other copies,
    /// such as a link or a reference, are not secrets of the vault and only expire).
    public static func copy(
        _ text: String, lifetime: TimeInterval = defaultLifetime, clearAtLock: Bool = false, pasteboard: UIPasteboard = .general
    ) {
        pasteboard.setItems(
            [[UIPasteboard.typeAutomatic: text]],
            options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(lifetime)]
        )
        ownCopy = clearAtLock ? (pasteboard.name, pasteboard.changeCount) : nil
    }

    /// The pasteboard and its `changeCount` right after the app's last copy; nil once cleared or taken over.
    private static var ownCopy: (name: UIPasteboard.Name, changeCount: Int)?

    /// Empties the pasteboard when it still holds what the app copied last, and only then: if anything else has been
    /// copied since (`changeCount` moved), it is the member's and stays. Called when the vault is no longer open
    /// (IOS-PLAN §6.5, §6.9). [pasteboard]: tests give a named one; it must be the one that was copied to.
    public static func clearIfOwn(pasteboard: UIPasteboard = .general) {
        guard let own = ownCopy, own.name == pasteboard.name else { return }
        ownCopy = nil
        if pasteboard.changeCount == own.changeCount { pasteboard.items = [] }
    }
}
