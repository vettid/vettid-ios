import SwiftUI
import UIKit

/// How a spoken change ranks against what VoiceOver is already saying. Mirrors vettid-android's `LiveRegionMode`:
/// [polite] waits its turn, [assertive] (the result of an attempt, a failure) interrupts; [queued] is said after what
/// VoiceOver is reading (a line that appears with a new screen, which VoiceOver is reading then).
public enum Announce: Sendable, Equatable {
    case polite, assertive, queued
}

/// Everything the app tells VoiceOver by itself: a text that appeared or changed without the member's focus on it, and a
/// step change inside a flow. `updatesFrequently` is no substitute: it only re-reads the element VoiceOver is on.
@MainActor
public enum Announcer {
    /// What was posted, for tests.
    public enum Event: Sendable, Equatable {
        case announcement(String, Announce)
        case screenChanged
    }

    /// Where events go: VoiceOver, or a test's recorder.
    static var sink: @MainActor (Event) -> Void = post

    /// Speaks [text] now.
    public static func announce(_ text: String, _ priority: Announce = .polite) {
        guard !text.isEmpty else { return }
        sink(.announcement(text, priority))
    }

    /// Tells VoiceOver that the screen changed: it moves to the first element of the new step and reads it.
    public static func screenChanged() {
        sink(.screenChanged)
    }

    private static func post(_ event: Event) {
        // On the next turn of the main run loop: after the view that changed is in the accessibility tree.
        DispatchQueue.main.async {
            switch event {
            case let .announcement(text, priority):
                var spoken = AttributedString(text)
                spoken.accessibilitySpeechAnnouncementPriority = switch priority {
                case .assertive: .high
                case .polite: .default
                case .queued: .low
                }
                AccessibilityNotification.Announcement(spoken).post()
            case .screenChanged:
                UIAccessibility.post(notification: .screenChanged, argument: nil)
            }
        }
    }
}

public extension View {
    /// Android's live region: [text] is spoken when this view appears with it and each time it changes to another text,
    /// wherever VoiceOver is. For a result or a notice that comes by itself, never for a countdown that ticks. The same
    /// text twice in a row is said again only if it went in between (nil, or the view gone): the models clear a failure
    /// when the next attempt starts.
    func announced(_ text: String?, _ priority: Announce = .polite) -> some View {
        modifier(Announced(text: text, priority: priority))
    }

    /// [text] spoken once, when this view appears, and not when it changes: a wait that counts down.
    func announcedOnce(_ text: String, _ priority: Announce = .polite) -> some View {
        onAppear { Announcer.announce(text, priority) }
    }

    /// A flow that swaps its whole screen in place (no navigation push, which UIKit announces itself): VoiceOver is told
    /// the screen changed each time [step] does.
    func announcesStepChanges(of step: some Equatable) -> some View {
        onChange(of: step) { _, _ in Announcer.screenChanged() }
    }

    /// A layer that comes up by itself over the app (the owner check, the app lock): VoiceOver moves into it when it
    /// appears and back when it goes.
    func announcesAsLayer() -> some View {
        onAppear { Announcer.screenChanged() }
            .onDisappear { Announcer.screenChanged() }
    }
}

private struct Announced: ViewModifier {
    let text: String?
    let priority: Announce

    func body(content: Content) -> some View {
        content
            .onAppear { if let text { Announcer.announce(text, priority) } }
            .onChange(of: text) { _, now in if let now { Announcer.announce(now, priority) } }
    }
}
