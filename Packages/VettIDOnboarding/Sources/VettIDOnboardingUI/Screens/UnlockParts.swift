#if os(iOS)
import SwiftUI
import VettIDData
import VettIDOnboarding
import VettIDUI

// The unlock screen's notices with a way forward. Mirrors the private composables of vettid-android `UnlockScreen.kt`.

/// The release check's notices before the PIN (§11.10.6): an older release (the PIN is not sent), a newer one to
/// acknowledge, a deprecated or retired release, and the newest active release to approve with this unlock, What's new
/// first (ANDROID-PLAN "What's new"), then the fingerprint and the approval.
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
        if let offer = p.offer, !p.rollback {
            WhatsNew(release: offer.number, notes: state.notes, notesURL: offer.notes)
            NoticeCard(
                .info, title: OnboardingStrings.unlockOfferTitle(Int(offer.number)),
                message: OnboardingStrings.unlockOfferBody(Int(p.routed.number), Int(offer.number), offer.fingerprint)
            )
            .accessibilityIdentifier("release_offer")
            // (§11.14.9) Not while a PIN or password change is undecided.
            if !state.updateHeld {
                Toggle(isOn: Binding(get: { state.approveOffer }, set: { actions.setApproveOffer($0) })) {
                    Text(OnboardingStrings.unlockOfferApprove).vettIDFont(.bodyMedium)
                }
                .frame(minHeight: Spacing.touchTarget)
                .accessibilityIdentifier("approve_offer")
            }
        }
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
        Button(action: action) { Text(label).vettIDFont(.labelLarge).foregroundStyle(colors.error).multilineTextAlignment(.leading) }
            .buttonStyle(.plain)
            .frame(minHeight: Spacing.touchTarget)
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
