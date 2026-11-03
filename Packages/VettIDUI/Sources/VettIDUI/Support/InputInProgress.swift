import Observation
import SwiftUI

/// The screens that hold input the member has not saved or sent (an item or rule being edited, a message being written, a
/// form with typed fields), registered while they do. The daily owner check reads it to wait for the member to leave such a
/// screen instead of covering it at once (VAULT-MESSAGING §3.6.5; vettid-android `AppShell`); any other screen is
/// covered at the deadline.
@MainActor
@Observable
public final class InputInProgress {
    private var holders: Set<UUID> = []

    public init() {}

    /// Whether any screen holds input now. (VAULT-MESSAGING §3.6.5 says the check does
    /// not interrupt a call, and iOS has no calls yet. When calls land, the call's own UI stays up while the shell is
    /// covered by the check as usual (chosen; not in the spec yet), so a call does not count here.)
    public var active: Bool { !holders.isEmpty }

    func set(_ id: UUID, _ on: Bool) {
        if on { holders.insert(id) } else { holders.remove(id) }
    }

    /// Registers [id] directly (tests, and views that manage their own identity).
    public func hold(_ id: UUID, _ on: Bool) { set(id, on) }
}

public extension EnvironmentValues {
    /// Where input screens register (``View/holdsInput(_:)``); set by the daily owner check's gate, nil elsewhere.
    @Entry var vettIDInput: InputInProgress?
}

public extension View {
    /// Registers this screen as holding unsaved input while [active] (a draft with text, an edited form, a typed field); it
    /// is dropped when the screen goes. Read-only screens do not call it.
    func holdsInput(_ active: Bool) -> some View {
        modifier(HoldsInput(active: active))
    }
}

private struct HoldsInput: ViewModifier {
    let active: Bool
    @Environment(\.vettIDInput) private var registry
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .onChange(of: active, initial: true) { _, now in registry?.set(id, now) }
            // A screen come back to (the one over it closed) counts again.
            .onAppear { registry?.set(id, active) }
            .onDisappear { registry?.set(id, false) }
    }
}
