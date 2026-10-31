import SwiftUI

public extension EnvironmentValues {
    /// A full screen covers the app (IOS-PLAN §4.4 (1), "This phone can't use your vault"): every sheet and alert closes,
    /// since a presentation would stay above the cover and usable (``View/closesWhenCovered(_:)``).
    @Entry var vettIDCovered: Bool = false

    /// The app lock covers the app (the app's `AppLockGate`): the content underneath stays, its sheets included, but says nothing
    /// by itself (no announcement of what arrives meanwhile). Unlike ``vettIDCovered``, it closes nothing.
    @Entry var vettIDLocked: Bool = false
}

public extension View {
    /// Runs [close] when the app is covered (``EnvironmentValues/vettIDCovered``), and at once if it already is: the
    /// presenter of a sheet or an alert closes it there.
    func closesWhenCovered(_ close: @escaping @MainActor () -> Void) -> some View {
        modifier(CoverCloses(close: close))
    }
}

/// [presented] while the app is not covered: a presentation's binding, closed at once by a cover.
public func uncovered(_ presented: Binding<Bool>, covered: Bool) -> Binding<Bool> {
    Binding(get: { presented.wrappedValue && !covered }, set: { presented.wrappedValue = $0 })
}

private struct CoverCloses: ViewModifier {
    @Environment(\.vettIDCovered) private var covered
    let close: @MainActor () -> Void

    func body(content: Content) -> some View {
        content
            .onAppear { if covered { close() } }
            .onChange(of: covered) { _, now in if now { close() } }
    }
}
