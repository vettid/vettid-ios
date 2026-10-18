import SwiftUI
import UIKit

/// The layer iOS leaves out of screenshots and screen recordings (IOS-PLAN §6.4 protection 3, ID10): the layout canvas
/// inside a `UITextField` with `isSecureTextEntry` (the exclusion is a property of the canvas's own layer, so it holds
/// once the canvas is moved out of the field). **Undocumented behaviour** that may change with any iOS release, so it
/// is reached only here, behind a self-check (the canvas exists and is the text-layout canvas): when it fails,
/// ``SecureContainer`` shows its content unprotected and the app relies on the app-switcher cover and capture hiding
/// (protections 1 and 2). Nothing is logged. The self-check cannot see whether captures really leave the layer out:
/// that is checked by hand on the iPhone per iOS release.
@MainActor
public enum SecureLayer {
    /// Whether this iOS still has the layer (checked once per launch).
    public static let isAvailable = make() != nil

    /// A view on the secure layer, emptied of the field's own content, with the text field that owns it; nil when this
    /// iOS has no such layer.
    static func make() -> (canvas: UIView, field: UITextField)? {
        let field = UITextField()
        field.isSecureTextEntry = true
        field.isUserInteractionEnabled = false
        guard let canvas = field.subviews.first(where: { String(describing: type(of: $0)).contains("Canvas") }) else { return nil }
        for v in canvas.subviews { v.removeFromSuperview() }
        canvas.isUserInteractionEnabled = true
        return (canvas, field)
    }
}

/// Keeps [content] out of screenshots and screen recordings while [isSecure] (IOS-PLAN §6.4, ID10), on the screens
/// vettid-android holds secure individually (`SecureWindow`: the typed recovery code, a received photo, the recovery
/// open). Callers pass `!allowance.allowed` ("Allow screenshots", Settings → App), except the typed recovery code's
/// screen, which stays protected whatever the allowance says, as vettid-android's does. Falls back to plain content
/// when ``SecureLayer`` is not available.
public struct SecureContainer<Content: View>: View {
    private let isSecure: Bool
    private let content: Content

    public init(isSecure: Bool = true, @ViewBuilder content: () -> Content) {
        self.isSecure = isSecure
        self.content = content()
    }

    public var body: some View {
        if isSecure, SecureLayer.isAvailable {
            SecureHost(content: content)
        } else {
            content
        }
    }
}

/// Hosts SwiftUI content on the secure layer, with the surrounding SwiftUI environment (theme, observable models).
private struct SecureHost<Content: View>: UIViewRepresentable {
    let content: Content

    @MainActor
    final class Coordinator {
        let hosting = UIHostingController(rootView: AnyView(EmptyView()))
        var field: UITextField?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        let h = context.coordinator.hosting
        h.safeAreaRegions = []
        h.sizingOptions = .intrinsicContentSize
        h.rootView = rooted(context)
        let hosted = h.view!
        hosted.backgroundColor = .clear
        hosted.translatesAutoresizingMaskIntoConstraints = false
        let parent: UIView
        if let layer = SecureLayer.make() {
            context.coordinator.field = layer.field // keeps the owner of the secure layer alive
            parent = layer.canvas
            layer.canvas.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(layer.canvas)
            NSLayoutConstraint.activate(pin(layer.canvas, to: container))
        } else {
            parent = container
        }
        parent.addSubview(hosted)
        NSLayoutConstraint.activate(pin(hosted, to: parent))
        return container
    }

    func updateUIView(_ view: UIView, context: Context) { context.coordinator.hosting.rootView = rooted(context) }

    /// The content with the environment it would have had in place (a separate hosting controller does not inherit it).
    private func rooted(_ context: Context) -> AnyView { AnyView(content.environment(\.self, context.environment)) }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIView, context: Context) -> CGSize? {
        context.coordinator.hosting.sizeThatFits(in: CGSize(
            width: proposal.width ?? UIView.layoutFittingExpandedSize.width,
            height: proposal.height ?? UIView.layoutFittingExpandedSize.height
        ))
    }

    private func pin(_ v: UIView, to p: UIView) -> [NSLayoutConstraint] {
        [v.leadingAnchor.constraint(equalTo: p.leadingAnchor), v.trailingAnchor.constraint(equalTo: p.trailingAnchor),
         v.topAnchor.constraint(equalTo: p.topAnchor), v.bottomAnchor.constraint(equalTo: p.bottomAnchor)]
    }
}
