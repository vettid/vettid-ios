#if os(iOS)
import SwiftUI
import VettIDData
import VettIDSettings
import VettIDUI

public extension View {
    /// The canary manifest dialog for [prompt] (stateless; nil: none): the verified document's serial, key and releases
    /// with "Use it", a refusal, or the installation. Mirrors vettid-android `CanaryManifestDialog`.
    func canaryManifestDialog(
        _ prompt: CanaryManifestPrompt?,
        onConfirm: @escaping @MainActor () -> Void,
        onDismiss: @escaping @MainActor () -> Void
    ) -> some View {
        modifier(CanaryManifestDialog(prompt: prompt, onConfirm: onConfirm, onDismiss: onDismiss))
    }
}

/// The canary manifest dialog: every button says what happens (the view model clears the prompt), so the presentation's
/// own dismissal changes nothing.
struct CanaryManifestDialog: ViewModifier {
    let prompt: CanaryManifestPrompt?
    let onConfirm: @MainActor () -> Void
    let onDismiss: @MainActor () -> Void

    func body(content: Content) -> some View {
        content.alert(
            prompt.map(Self.title) ?? "", isPresented: Binding(get: { prompt != nil }, set: { _ in }), presenting: prompt
        ) { p in
            switch p {
            case .confirm:
                Button(CanaryStrings.confirm, action: onConfirm).accessibilityIdentifier("canary_confirm")
                Button(SettingsStrings.cancel, role: .cancel, action: onDismiss)
            case .refused, .installed:
                Button(CanaryStrings.ok, action: onDismiss).accessibilityIdentifier("canary_ok")
            }
        } message: { p in
            Text(Self.message(p))
        }
    }

    static func title(_ p: CanaryManifestPrompt) -> String {
        switch p {
        case .confirm: CanaryStrings.confirmTitle
        case .refused: CanaryStrings.refusedTitle
        case .installed: CanaryStrings.installedTitle
        }
    }

    static func message(_ p: CanaryManifestPrompt) -> String {
        switch p {
        case .confirm(let v): CanaryStrings.confirmBody(Int(v.serial), v.keyID, CanaryStrings.releases(v))
        case .refused(let code): CanaryStrings.refused(code)
        case .installed(let v): CanaryStrings.installedBody(Int(v.serial))
        }
    }
}

/// The canary manifest dialog with its view model, over [content] (the root of the UI): a document handed to the app
/// (opened with VettID, or picked in Settings → Attestation) is taken from [inbox] while this view is shown, verified,
/// and installed only on the member's confirmation. Mirrors vettid-android `VettIdApp`'s canary dialog.
public struct CanaryManifestHost<Content: View>: View {
    private let inbox: CanaryManifestInbox
    private let repo: any CanaryManifestRepository
    private let content: Content
    @State private var model: CanaryManifestViewModel?

    public init(inbox: CanaryManifestInbox, repo: any CanaryManifestRepository, @ViewBuilder content: () -> Content) {
        self.inbox = inbox
        self.repo = repo
        self.content = content()
    }

    public var body: some View {
        content
            .canaryManifestDialog(model?.prompt, onConfirm: { model?.confirm() }, onDismiss: { model?.dismiss() })
            .onAppear {
                if model == nil { model = CanaryManifestViewModel(inbox: inbox, repo: repo) }
                model?.inboxChanged()
            }
            .onChange(of: inbox.document) { _, doc in if doc != nil { model?.inboxChanged() } }
            // A wipe of this phone: the dialog closes, and nothing it was asking about is installed.
            .onChange(of: inbox.resets) { _, _ in model?.inboxChanged() }
            .onChange(of: inbox.unreadable) { _, _ in model?.inboxChanged() }
    }
}
#endif
