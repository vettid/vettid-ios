#if os(iOS)
import SwiftUI
import UIKit
import VettIDData
import VettIDOnboarding
import VettIDUI

/// The update screen with its view model: "Update available" in Settings → Vault. Mirrors vettid-android's
/// `releaseUpdateDestination`.
public struct ReleaseUpdateRoute: View {
    private let updates: any ReleaseUpdateRepository
    private let ownerCheck: (any OwnerCheckRepository)?
    private let notes: any ReleaseNotesRepository
    private let onBack: @MainActor () -> Void
    @State private var model: ReleaseUpdateViewModel?

    public init(
        updates: any ReleaseUpdateRepository,
        ownerCheck: (any OwnerCheckRepository)?,
        notes: any ReleaseNotesRepository,
        onBack: @escaping @MainActor () -> Void
    ) {
        self.updates = updates
        self.ownerCheck = ownerCheck
        self.notes = notes
        self.onBack = onBack
    }

    public var body: some View {
        ReleaseUpdateContent(
            state: model?.state ?? ReleaseUpdateState(loading: updates.offer == nil, offer: updates.offer),
            onApprove: { pin in model?.approve(pin: pin) ?? false },
            onBack: onBack
        )
        .onAppear { if model == nil { model = ReleaseUpdateViewModel(updates: updates, ownerCheck: ownerCheck, notes: notes) } }
    }
}

/// A release's end date for display (the unlock screen's format).
func releaseDate(_ d: Date) -> String { d.formatted(date: .abbreviated, time: .omitted) }

/// The update screen for [state] (stateless): the release offered, What's new, its fingerprint, and "Approve and update"
/// with the vault PIN on the in-app keypad (IOS-PLAN §6.5), handed over once. Mirrors vettid-android
/// `ReleaseUpdateContent`.
public struct ReleaseUpdateContent: View {
    @Environment(\.scenePhase) private var scenePhase
    let state: ReleaseUpdateState
    let onApprove: @MainActor (String) -> Bool
    let onBack: @MainActor () -> Void
    @State private var pin = PinBuffer()

    public init(state: ReleaseUpdateState, onApprove: @escaping @MainActor (String) -> Bool, onBack: @escaping @MainActor () -> Void) {
        self.state = state
        self.onApprove = onApprove
        self.onBack = onBack
    }

    private func approve() {
        guard state.submitAllowed(pinTyped: pin.count) else { return }
        _ = onApprove(pin.take())
    }

    public var body: some View {
        let offer = state.offer
        FormScaffold(
            title: OnboardingStrings.releaseUpdateTitle,
            message: offer.map { OnboardingStrings.releaseUpdateBody(Int($0.target.number)) },
            primaryLabel: offer != nil ? OnboardingStrings.releaseUpdateApprove : nil,
            primaryEnabled: state.submitAllowed(pinTyped: pin.count),
            busy: state.loading && offer == nil,
            onPrimary: approve,
            onBack: onBack,
            header: { UpdateGlyph() }
        ) {
            VStack(alignment: .leading, spacing: Spacing.m) {
                if let offer {
                    WhatsNew(release: offer.target.number, notes: state.notes, notesURL: offer.target.notes)
                    OfferNotices(offer: offer)
                    if state.checkDue {
                        NoticeCard(
                            .warning, title: OnboardingStrings.releaseUpdateCheckFirstTitle,
                            message: OnboardingStrings.releaseUpdateCheckFirstBody
                        )
                        .accessibilityIdentifier("release_update_check_first")
                    }
                    // VAULT-MESSAGING §11.14.9: no update while a PIN or password change is being decided.
                    if let why = state.changeHold {
                        NoticeCard(.warning, title: OnboardingStrings.releaseUpdateTitle, message: why.message)
                            .accessibilityIdentifier("release_update_change_unresolved")
                    }
                    PinEntry(label: OnboardingStrings.unlockPinLabel, buffer: pin, identifier: "release_update_pin")
                        .disabled(!state.pinAllowed)
                } else if state.loading {
                    CheckingLine(label: OnboardingStrings.unlockChecking)
                } else {
                    NoticeCard(
                        .success, title: OnboardingStrings.releaseUpdateNoneTitle, message: OnboardingStrings.releaseUpdateNoneBody
                    )
                    .accessibilityIdentifier("release_update_none")
                }
            }
        }
        .accessibilityIdentifier("release_update")
        .onDisappear { pin.clear() }
        .onChange(of: scenePhase) { _, now in
            // IOS-PLAN §6.3: typed secrets are dropped when the app leaves the foreground, and when the iPhone locks.
            if now == .background { pin.clear() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataWillBecomeUnavailableNotification)) { _ in
            pin.clear()
        }
    }
}

/// The update's icon over its screens (vettid-android `SystemUpdate`).
struct UpdateGlyph: View {
    @Environment(\.vettIDColors) private var colors

    var body: some View {
        VettIDSymbol.systemUpdate.image.font(.system(size: 36)).foregroundStyle(colors.primary).padding(.top, Spacing.l)
            .accessibilityHidden(true)
    }
}

/// A small progress line with its label.
struct CheckingLine: View {
    let label: String

    var body: some View {
        HStack(spacing: Spacing.m) {
            ProgressView().controlSize(.small)
            Text(label).vettIDFont(.bodyMedium)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The release offered (§11.10.3: number, fingerprint; the notes are What's new above) and, for an ending release, its
/// end.
private struct OfferNotices: View {
    @Environment(\.vettIDColors) private var colors
    let offer: ReleaseUpdateOffer

    var body: some View {
        let current = Int(offer.current.number)
        let target = Int(offer.target.number)
        switch offer.kind {
        case .ending:
            NoticeCard(
                .urgent, title: OnboardingStrings.unlockStatusTitle(current, offer.current.status),
                message: offer.endsAt.map { OnboardingStrings.unlockStatusBodyEnds(releaseDate($0)) } ?? OnboardingStrings.unlockStatusBody
            )
            .accessibilityIdentifier("release_update_ending")
        case .ended:
            NoticeCard(
                .urgent, title: OnboardingStrings.unlockStatusTitle(current, offer.current.status),
                message: OnboardingStrings.releaseUpdateEndedBody
            )
            .accessibilityIdentifier("release_update_ending")
        case .available:
            EmptyView()
        }
        NoticeCard(
            .info, title: OnboardingStrings.unlockOfferTitle(target),
            message: OnboardingStrings.unlockOfferBody(current, target, offer.target.fingerprint)
        )
        .accessibilityIdentifier("release_offer")
        Text(OnboardingStrings.releaseUpdateHow).vettIDFont(.bodyMedium).foregroundStyle(colors.onSurfaceVariant)
    }
}
#endif
