#if os(iOS)
import SwiftUI
import UIKit
import VettIDData
import VettIDOnboarding
import VettIDUI

/// The owner-check screen for [mode], driven by an ``OwnerCheckViewModel`` made when it first appears. [onDone] after a
/// passed check; [onCancel] for a voluntary check and the hold-off only (a gated check is never dismissible, §3.6.5).
/// Mirrors vettid-android `OwnerCheckRoute`.
public struct OwnerCheckFlow: View {
    private let mode: OwnerCheckMode
    private let repo: any OwnerCheckRepository
    private let vault: any VaultRepository
    private let onDone: @MainActor () -> Void
    private let onCancel: @MainActor () -> Void
    private let onOut: @MainActor (Bool, OwnerCheckMessage?) -> Void
    private let onGone: @MainActor () -> Void
    private let carried: OwnerCheckMessage?
    /// The model to use instead of one made on appear (tests).
    private let given: OwnerCheckViewModel?
    @State private var model: OwnerCheckViewModel?
    @Environment(\.vettIDColors) private var colors

    public init(
        mode: OwnerCheckMode,
        repo: any OwnerCheckRepository,
        vault: any VaultRepository,
        onDone: @escaping @MainActor () -> Void = {},
        onCancel: @escaping @MainActor () -> Void = {},
        carried: OwnerCheckMessage? = nil,
        onOut: @escaping @MainActor (Bool, OwnerCheckMessage?) -> Void = { _, _ in },
        onGone: @escaping @MainActor () -> Void = {}
    ) {
        self.init(
            mode: mode, repo: repo, vault: vault, model: nil, onDone: onDone, onCancel: onCancel, carried: carried, onOut: onOut,
            onGone: onGone
        )
    }

    /// [carried]: the last answer of an asked check this gated one replaced (``OwnerCheckViewModel/start(_:carried:)``).
    /// [onOut]: whether a check is out or its tick shows, as it changes, with the message when none is out
    /// (``OwnerCheckViewModel/onOut``). [onGone]: the screen went; nothing more is told of it, a check answered after it
    /// included.
    init(
        mode: OwnerCheckMode,
        repo: any OwnerCheckRepository,
        vault: any VaultRepository,
        model: OwnerCheckViewModel?,
        onDone: @escaping @MainActor () -> Void = {},
        onCancel: @escaping @MainActor () -> Void = {},
        carried: OwnerCheckMessage? = nil,
        onOut: @escaping @MainActor (Bool, OwnerCheckMessage?) -> Void = { _, _ in },
        onGone: @escaping @MainActor () -> Void = {}
    ) {
        self.mode = mode
        self.repo = repo
        self.vault = vault
        self.given = model
        self.onDone = onDone
        self.onCancel = onCancel
        self.carried = carried
        self.onOut = onOut
        self.onGone = onGone
    }

    public var body: some View {
        Group {
            if let model {
                OwnerCheckScreen(state: model.state, actions: model, onCancel: {
                    model.cancel()
                    onCancel()
                })
                .onChange(of: model.state.passed) { _, passed in
                    guard passed else { return }
                    // Nothing of this check stays for the next one.
                    model.cancel()
                    onDone()
                }
                // (IOS-PLAN §4.17) A pass: the success haptic, the tick held 1 s (3 s with VoiceOver), then the screen closes.
                .task(id: model.state.passedTick) {
                    guard model.state.passedTick else { return }
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    try? await Task.sleep(for: passedTickHold(voiceOver: UIAccessibility.isVoiceOverRunning))
                    guard !Task.isCancelled else { return }
                    model.tickShown()
                }
                // (ANDROID-PLAN 0.1.124) No longer out once the screen went, and nothing told of it after: a check that
                // comes back later (the vault locked meanwhile, say) leaves no failure for a later gated check.
                .onDisappear {
                    model.onOut = nil
                    onGone()
                }
            } else {
                colors.background.color.ignoresSafeArea()
            }
        }
        .onAppear {
            if let model {
                // Shown again: told again (``onDisappear`` took the wiring).
                wire(model)
                return
            }
            let m = given ?? OwnerCheckViewModel(repo: repo, vault: vault)
            wire(m)
            m.start(mode, carried: carried)
            model = m
        }
    }

    /// (ANDROID-PLAN 0.1.124) A check coming due waits while this one is out, so that no second check goes alongside it and
    /// its tick is not cut short; told in the change that sends it, and with its answer's message.
    private func wire(_ m: OwnerCheckViewModel) {
        let onOut = onOut
        m.onOut = { [weak m] out in onOut(out, out ? nil : m?.state.message) }
    }
}
#endif
