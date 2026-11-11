#if os(iOS)
import UIKit
import VettIDUI

/// The pairing code on the pasteboard (ANDROID-PLAN 0.1.53 AA2, decision 1). The code goes there through ``SecurePasteboard``: local
/// to this iPhone (never on Universal Clipboard) and expiring at the code's own end, which iOS enforces even when the app is in the
/// background (vettid-android must wait for its next focus to clear the clip); it is also removed at the vault's lock. As soon as the
/// pairing ends, however it ends, or the screen is left, the app removes it, but only if it is still the app's own copy: whatever the
/// member copied since stays. It remembers only where the pasteboard stood after its copy (a change count), never the code, so
/// nothing of the code stays in memory after the pairing, and it never reads the pasteboard (that would show the paste prompt).
/// Mirrors vettid-android `PairingClipboard`.
@MainActor
enum PairingClipboard {
    /// The pasteboard and its change count right after the app's copy of the code; nil when nothing of ours is there to clear.
    private static var armed: (name: UIPasteboard.Name, changeCount: Int)?

    /// Puts [code] on the pasteboard until [exp] (at [now]), and remembers to clear it when the pairing ends.
    static func copy(_ code: String, exp: Date, now: Date = Date(), pasteboard: UIPasteboard = .general) {
        SecurePasteboard.copy(code, lifetime: max(0, exp.timeIntervalSince(now)), clearAtLock: true, pasteboard: pasteboard)
        armed = (pasteboard.name, pasteboard.changeCount)
    }

    /// The pairing ended (cancelled, rejected, paired, expired) or its screen was left: the code is worthless; it is cleared now if it
    /// is still the app's own copy.
    static func ended(pasteboard: UIPasteboard = .general) {
        guard let a = armed, a.name == pasteboard.name else { return }
        armed = nil
        // Anything copied since moved the change count: it is the member's, and stays.
        if pasteboard.changeCount == a.changeCount { SecurePasteboard.clearIfOwn(pasteboard: pasteboard) }
    }
}
#endif
