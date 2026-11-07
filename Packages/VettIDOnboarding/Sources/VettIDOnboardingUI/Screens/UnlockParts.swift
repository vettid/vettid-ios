#if os(iOS)
import SwiftUI
import VettIDData
import VettIDOnboarding
import VettIDUI

// The unlock screen's notices with a way forward. Mirrors the private composables of vettid-android `UnlockScreen.kt`.

/// The release check's notices before the PIN (§11.10.6): an older release (the PIN is not sent), a newer one to
/// acknowledge, and a deprecated or retired release. The newest active release to approve with this unlock is not here:
/// it is ``ReleaseOfferNotice``, under the PIN (RELEASE-UPDATES §2 step 2).
struct PreflightNotices: View {
    let preflight: PreflightInfo
    let state: UnlockState
    let actions: any UnlockActions

    var body: some View {
        let p = preflight
        if p.rollback {
            NoticeCard(
                .urgent, title: OnboardingStrings.unlockRollbackTitle,
                message: OnboardingStrings.unlockRollbackBody(Int(p.routed.number), Int(p.lastNumber))
            )
        } else if p.softwareUpdated {
            NoticeCard(
                .warning, title: OnboardingStrings.unlockUpdatedTitle,
                message: OnboardingStrings.unlockUpdatedBody(Int(p.routed.number), p.routed.fingerprint, Int(p.lastNumber))
            ) {
                if !state.updateAcknowledged {
                    TextLink(OnboardingStrings.unlockUpdatedAck, identifier: "software_updated_ack") { actions.acknowledgeUpdate() }
                }
            }
            .accessibilityIdentifier("software_updated")
        }
        if p.routed.status == "deprecated" || p.routed.status == "retired" {
            NoticeCard(
                p.routed.status == "retired" ? .urgent : .warning,
                title: OnboardingStrings.unlockStatusTitle(Int(p.routed.number), p.routed.status),
                message: p.routed.endsAt.map { OnboardingStrings.unlockStatusBodyEnds($0.formatted(date: .abbreviated, time: .omitted)) }
                    ?? OnboardingStrings.unlockStatusBody
            )
        }
    }
}

/// What the compact offer's security line says (RELEASE-UPDATES §2 step 2): from the release log like the rest of What's
/// new, so a progress line while it loads and "Release notes unavailable" when it can't be had.
enum OfferSecurityLine: Equatable {
    case loading
    case unavailable
    case line(String, urgent: Bool)

    init(_ notes: ReleaseNotes?) {
        switch notes {
        case nil: self = .loading
        case .unavailable: self = .unavailable
        case .available(_, let entry, _):
            switch entry.security {
            case .none: self = .line(OnboardingStrings.releaseNotesSecurityNone, urgent: false)
            case .recommended: self = .line(OnboardingStrings.releaseNotesSecurityRecommended, urgent: false)
            case .urgent: self = .line(OnboardingStrings.releaseNotesSecurityUrgent, urgent: true)
            }
        }
    }
}

extension OfferSecurityLine {
    /// What VoiceOver is told when the line arrives or changes; nothing for the progress line.
    var spoken: String? {
        switch self {
        case .loading: nil
        case .unavailable: OnboardingStrings.releaseNotesUnavailable
        case .line(let text, _): text
        }
    }
}

/// The release offer at unlock, under the PIN (RELEASE-UPDATES §2 step 2; ANDROID-PLAN "What's new"): "Update available:
/// release N", the security line, the fingerprint and "Approve the update with this unlock" (never gated on the notes),
/// with "What's new in release N" one tap away in a sheet. Mirrors vettid-android's unlock offer notice.
struct ReleaseOfferNotice: View {
    @Environment(\.vettIDColors) private var colors
    @Environment(\.vettIDCovered) private var covered
    let preflight: PreflightInfo
    let offer: ReleaseView
    let state: UnlockState
    let actions: any UnlockActions
    /// The release whose notes are open: another offer (release or PCR0) never shows these notes.
    @State private var notesOpenFor: ReleaseView?

    /// The sheet is open only for the offer it was opened on (release and PCR0).
    static func isOpen(_ openFor: ReleaseView?, offer: ReleaseView) -> Bool { openFor == offer }

    /// What stays open when the offer changes to [offer]: the same offer's sheet, nothing else.
    static func stillOpen(_ openFor: ReleaseView?, offer: ReleaseView) -> ReleaseView? { openFor == offer ? openFor : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                // The title is a heading of its own; the line and the fingerprint are separate elements, so that the
                // line's identifiers (one per state) are found by the UI tests.
                Text(OnboardingStrings.unlockOfferTitle(Int(offer.number)))
                    .vettIDFont(.titleSmall, weight: .semibold)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("release_offer_title")
                securityLine
                Text(OnboardingStrings.unlockOfferBody(Int(preflight.routed.number), Int(offer.number), offer.fingerprint))
                    .vettIDFont(.bodyMedium)
                    .foregroundStyle(colors.onSurfaceVariant)
                    .accessibilityIdentifier("release_offer")
            }
            // (§11.14.9) Not while a PIN or password change is undecided.
            if !state.updateHeld {
                Toggle(isOn: Binding(get: { state.approveOffer }, set: { actions.setApproveOffer($0) })) {
                    Text(OnboardingStrings.unlockOfferApprove).vettIDFont(.bodyMedium)
                }
                .frame(minHeight: Spacing.touchTarget)
                .accessibilityIdentifier("approve_offer")
            }
            TextLink(OnboardingStrings.releaseNotesTitle(Int(offer.number)), identifier: "whats_new_open") { notesOpenFor = offer }
        }
        .padding(Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(colors.surfaceContainer, in: VettIDShape.card)
        .onChange(of: offer) { _, now in notesOpenFor = Self.stillOpen(notesOpenFor, offer: now) }
        .sheet(isPresented: uncovered(
            Binding(get: { Self.isOpen(notesOpenFor, offer: offer) }, set: { notesOpenFor = $0 ? offer : nil }), covered: covered
        )) {
            WhatsNewSheet(
                offer: offer, routed: preflight.routed.number, notes: state.notes, onClose: { notesOpenFor = nil }
            )
            .presentationDetents([.medium, .large])
        }
    }

    /// The one release-log line. Its height is reserved for the tallest of the progress line, "Release notes unavailable"
    /// and the security lines (hidden copies, out of VoiceOver), so the approval and the link below never move when the
    /// notes arrive. The line, once there, is announced politely; the progress line is not.
    private var securityLine: some View {
        let line = OfferSecurityLine(state.notes)
        return ZStack(alignment: .topLeading) {
            Group {
                loadingLine
                unavailableLine
                securityText(OnboardingStrings.releaseNotesSecurityNone, urgent: false)
                securityText(OnboardingStrings.releaseNotesSecurityRecommended, urgent: false)
                securityText(OnboardingStrings.releaseNotesSecurityUrgent, urgent: true)
            }
            .hidden()
            .accessibilityHidden(true)
            switch line {
            case .loading: loadingLine.accessibilityIdentifier("offer_security_loading")
            case .unavailable: unavailableLine.accessibilityIdentifier("offer_security_unavailable")
            case .line(let text, let urgent): securityText(text, urgent: urgent).accessibilityIdentifier("offer_security")
            }
        }
        .announcedOnChange(line.spoken, .polite)
    }

    private var loadingLine: some View {
        HStack(spacing: Spacing.s) {
            ProgressView().controlSize(.small)
            Text(OnboardingStrings.releaseNotesLoading).vettIDFont(.bodyMedium)
        }
        .accessibilityElement(children: .combine)
    }

    private var unavailableLine: some View {
        Text(OnboardingStrings.releaseNotesUnavailable).vettIDFont(.bodyMedium).foregroundStyle(colors.onSurfaceVariant)
    }

    private func securityText(_ text: String, urgent: Bool) -> some View {
        Text(text).vettIDFont(.bodyMedium).fontWeight(.semibold).foregroundStyle(urgent ? colors.error : colors.onSurface)
    }
}

/// What's new in the offered release, in a sheet from the unlock screen: the full notes (with `security_text`), the
/// earlier releases, "Full release notes" and the fingerprint. It scrolls, so it holds at the largest text sizes.
struct WhatsNewSheet: View {
    @Environment(\.vettIDColors) private var colors
    let offer: ReleaseView
    let routed: UInt64
    let notes: ReleaseNotes?
    let onClose: @MainActor () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.m) {
                WhatsNew(
                    release: offer.number, notes: notes, notesURL: offer.notes,
                    offerText: OnboardingStrings.unlockOfferBody(Int(routed), Int(offer.number), offer.fingerprint)
                )
                TextLink(OnboardingStrings.unlockLockOk, identifier: "whats_new_close", action: onClose)
            }
            .padding(Spacing.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(colors.surface)
        .accessibilityIdentifier("whats_new_sheet")
    }
}

/// The vault's release does not accept this installation of VettID (`signer_refused`, §11.7.1). Not a wrong PIN.
struct SignerRefusedNotice: View {
    let help: Bool
    /// The recovery's delay at the vault's time scale, and the staging note.
    var recovery: String = TimeScales.text(TimeScales.recoveryDelay, by: 1)
    var stagingNote: String?
    let actions: any UnlockActions

    var body: some View {
        NoticeCard(
            .urgent, title: OnboardingStrings.unlockSignerRefusedTitle, message: OnboardingStrings.unlockSignerRefusedBody,
            announce: .assertive
        ) {
            TextLink(
                help ? OnboardingStrings.unlockSignerRefusedHelpHide : OnboardingStrings.unlockSignerRefusedHelp,
                identifier: "signer_refused_help"
            ) { actions.showSignerHelp(!help) }
        }
        .accessibilityIdentifier("unlock_signer_refused")
        if help {
            NoticeCard(
                .info,
                title: OnboardingStrings.unlockSignerRefusedHelpTitle,
                message: OnboardingStrings.unlockSignerRefusedHelpBody(recovery)
            )
            .accessibilityIdentifier("signer_refused_help_text")
            SmallNote(stagingNote)
        }
    }
}

/// A destructive text action ("Erase VettID from this phone").
struct DestructiveLink: View {
    @Environment(\.vettIDColors) private var colors
    let label: String
    let identifier: String
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            Text(label).vettIDFont(.labelLarge).foregroundStyle(colors.error).multilineTextAlignment(.leading)
                .textButtonTarget()
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}

/// "Erasing VettID from this phone…" while the erase runs.
struct ErasingLine: View {
    var body: some View {
        HStack(spacing: Spacing.m) {
            ProgressView()
            Text(OnboardingStrings.unlockErasing).vettIDFont(.bodyMedium)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The vault did not recognise this phone at unlock (an unreadable result): the erase is offered (owner decision,
/// 2026-10-05).
struct NotRecognisedNotice: View {
    let erasing: Bool
    let onErase: @MainActor () -> Void

    var body: some View {
        NoticeCard(
            .urgent, title: OnboardingStrings.unlockNotRecognisedTitle, message: OnboardingStrings.unlockNotRecognisedBody,
            announce: .assertive
        ) {
            DestructiveLink(label: OnboardingStrings.unlockErase, identifier: "erase_phone", action: onErase).disabled(erasing)
        }
        .accessibilityIdentifier("unlock_not_recognised")
        if erasing { ErasingLine() }
    }
}

/// This phone no longer holds the vault's keys: "Recover your vault" first, then the erase (confirmed). (iPhone, IOS-PLAN
/// §6.3 item 5) With a replaced phone-secret record, "Try this phone's earlier keys" with the PIN on the keypad.
struct StuckNotice: View {
    let erasing: Bool
    let earlierSecret: Bool
    let pinReady: Bool
    let onErase: @MainActor () -> Void
    let onRecover: @MainActor () -> Void
    let onEarlierSecret: @MainActor () -> Void

    var body: some View {
        NoticeCard(.urgent, title: OnboardingStrings.unlockStuckTitle, message: OnboardingStrings.unlockStuckBody, announce: .polite) {
            VStack(alignment: .leading, spacing: 0) {
                TextLink(OnboardingStrings.unlockRecover, identifier: "recover_vault", action: onRecover)
                if earlierSecret {
                    TextLink(OnboardingStrings.unlockEarlierSecret, identifier: "earlier_secret", action: onEarlierSecret)
                        .disabled(!pinReady)
                }
                DestructiveLink(label: OnboardingStrings.unlockErase, identifier: "erase_phone", action: onErase).disabled(erasing)
            }
        }
        .accessibilityIdentifier("unlock_stuck")
        if erasing { ErasingLine() }
    }
}

/// The vault cannot be opened and erasing this phone would not help (an ended release, a rollback): "Recover your vault"
/// first, "Contact support" second (without a mail app the address is shown to copy). No erase.
struct RecoverOnlyNotice: View {
    let onRecover: @MainActor () -> Void
    let contactSupport: @MainActor (_ done: @escaping @MainActor (Bool) -> Void) -> Void
    @State private var noMailApp = false

    var body: some View {
        NoticeCard(
            .urgent, title: OnboardingStrings.unlockStuckTitle, message: OnboardingStrings.unlockRecoverOnlyBody,
            announce: .polite
        ) {
            VStack(alignment: .leading, spacing: 0) {
                TextLink(OnboardingStrings.unlockRecover, identifier: "recover_vault", action: onRecover)
                TextLink(OnboardingStrings.unlockContactSupport, identifier: "contact_support") {
                    contactSupport { accepted in noMailApp = !accepted }
                }
            }
        }
        .accessibilityIdentifier("unlock_recover_only")
        if noMailApp {
            Text(SupportMail.address).vettIDFont(.bodyLarge).textSelection(.enabled).accessibilityIdentifier("support_address")
        }
    }
}
#endif
