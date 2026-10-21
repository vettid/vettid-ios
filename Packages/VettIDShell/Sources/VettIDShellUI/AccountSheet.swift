#if os(iOS)
import SwiftUI
import UIKit
import VettIDData
import VettIDSettingsUI
import VettIDShell
import VettIDUI

/// The avatar sheet (ANDROID-PLAN §4 "Screens"): "Lock vault" first, right under the name; the name on the member's VettID
/// account (read-only, from the vault's account snapshot: every connection sees it); the address; the membership and
/// subscription (read-only, VAULT-MESSAGING §11.13); vault status and the account portal, where the other changes are made. The app
/// never signs in: no sign-out. "Change name", the only place the names change, with the state of a requested change
/// (VAULT-MESSAGING §10.8), and "Shared profile"; the member's own profile photo in the header. Only while the vault is
/// open (IOS-PLAN §4.7): otherwise the initial tile, no name and no address (not even the masked hint). Mirrors
/// vettid-android `AccountSheet`.
public struct AccountSheet: View {
    let account: AccountInfo?
    let photo: UIImage?
    let now: Date
    let onLockVault: @MainActor () -> Void
    let onChangeName: @MainActor () -> Void
    let onSharedProfile: @MainActor () -> Void
    let onOpenPortal: @MainActor () -> Void

    public init(
        account: AccountInfo?,
        photo: UIImage? = nil,
        now: Date = Date(),
        onLockVault: @escaping @MainActor () -> Void,
        onChangeName: @escaping @MainActor () -> Void = {},
        onSharedProfile: @escaping @MainActor () -> Void = {},
        onOpenPortal: @escaping @MainActor () -> Void
    ) {
        self.account = account.shownInShell
        self.photo = photo
        self.now = now
        self.onLockVault = onLockVault
        self.onChangeName = onChangeName
        self.onSharedProfile = onSharedProfile
        self.onOpenPortal = onOpenPortal
    }

    public var body: some View {
        AvatarSheetContent(
            // First and last name and the full address (VAULT-MESSAGING §11.13 `email`; the masked `email_hint` from an
            // older vault).
            name: AccountHeader.name(account, placeholder: ShellStrings.accountPlaceholderName),
            detail: AccountHeader.detailEmail(account) ?? Self.membershipLine(MembershipLine.of(account)),
            optionsHeader: ShellStrings.accountOptions,
            photo: photo
        ) {
            AccountSheetOptions(
                account: account, now: now, onLockVault: onLockVault, onChangeName: onChangeName, onSharedProfile: onSharedProfile,
                onOpenPortal: onOpenPortal
            )
        }
    }

    /// The membership in one line, under the address when there are no names to show.
    static func membershipLine(_ m: MembershipLine) -> String {
        switch m {
        case .unknown: ShellStrings.accountMembershipUnknown
        case .canceled: ShellStrings.accountMembershipCanceled
        case .member: ShellStrings.accountMembershipMember
        case .registered: ShellStrings.accountMembershipRegistered
        }
    }
}

/// The avatar sheet's option groups, in order: lock, the names, the address, membership, vault and portal. Mirrors
/// vettid-android `AccountSheetOptions`.
struct AccountSheetOptions: View {
    @Environment(\.vettIDColors) private var colors
    let account: AccountInfo?
    let now: Date
    let onLockVault: @MainActor () -> Void
    let onChangeName: @MainActor () -> Void
    let onSharedProfile: @MainActor () -> Void
    let onOpenPortal: @MainActor () -> Void

    var body: some View {
        SettingsGroup {
            SettingsRow(
                ShellStrings.accountLockVault, icon: .lock, supporting: ShellStrings.accountLockVaultBody, showChevron: false,
                action: onLockVault
            )
            .accessibilityIdentifier("account_lock_vault")
        }
        // The account's names (VAULT-MESSAGING §10.8 "What the app shows"): read-only, "Your connections see this name",
        // the state of a requested change, and "Change name" (vettid-android `AccountNamesGroup`).
        SettingsGroup {
            SettingsInfoRow(ShellStrings.accountNames, value: account?.fullName ?? ShellStrings.accountNamesNone, icon: .person)
            note([ShellStrings.accountNamesNote, NameStatus.text(account, now: now)].compactMap { $0 }.joined(separator: "\n"))
                .accessibilityIdentifier("account_names_note")
            SettingsDivider()
            SettingsRow(ShellStrings.accountChangeName, icon: .edit, supporting: ShellStrings.accountChangeNameBody, action: onChangeName)
                .accessibilityIdentifier("account_change_name")
            SettingsDivider()
            SettingsRow(
                ShellStrings.accountSharedProfile, icon: sharedProfileSymbol, supporting: ShellStrings.accountSharedProfileBody,
                action: onSharedProfile
            )
            .accessibilityIdentifier("account_shared_profile")
        }
        .accessibilityIdentifier("account_names")
        // Only while the vault is open: never the masked hint of the account record (IOS-PLAN §4.7).
        if let email = account.shownInShell?.displayEmail {
            SettingsGroup {
                SettingsInfoRow(ShellStrings.accountEmail, value: email, icon: .email)
                note(ShellStrings.accountEmailNote)
            }
            .accessibilityIdentifier("account_email")
        }
        AccountDetails(account: account, now: now)
        SettingsGroup {
            SettingsInfoRow(ShellStrings.accountVaultStatus, value: ShellStrings.accountVaultStatusValue, icon: .storage)
            SettingsDivider()
            SettingsRow(
                ShellStrings.accountPortal, icon: .openInNew, supporting: ShellStrings.accountPortalBody, showChevron: false,
                action: onOpenPortal
            )
            .accessibilityIdentifier("account_portal")
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .vettIDFont(.bodySmall)
            .foregroundStyle(colors.onSurfaceVariant)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Spacing.gutter)
            .padding(.vertical, Spacing.s)
    }
}

/// Membership, terms, subscription and voting rights, read-only (VAULT-MESSAGING §11.13). Mirrors vettid-android `AccountDetails`.
struct AccountDetails: View {
    let account: AccountInfo?
    let now: Date

    var body: some View {
        SettingsGroup {
            if let a = account, a.hasSnapshot {
                SettingsInfoRow(ShellStrings.accountMembership, value: Self.membership(MembershipLine.of(a)), icon: .groups)
                SettingsDivider()
                SettingsInfoRow(
                    ShellStrings.accountSubscription, value: Self.subscription(.of(a.subscription, now: now)), icon: .cardMembership
                )
                if a.termsNeedAcceptance {
                    SettingsDivider()
                    SettingsInfoRow(ShellStrings.accountTerms, value: ShellStrings.accountTermsNeeded, icon: .gavel)
                        .accessibilityIdentifier("account_terms_needed")
                }
                SettingsDivider()
                SettingsInfoRow(
                    ShellStrings.accountVoting, value: a.votingRights ? ShellStrings.accountVotingYes : ShellStrings.accountVotingNo,
                    icon: .howToVote
                )
            } else {
                SettingsInfoRow(ShellStrings.accountMembership, value: ShellStrings.accountMembershipWaiting, icon: .groups)
            }
        }
        .accessibilityIdentifier("account_details")
    }

    static func membership(_ m: MembershipLine) -> String {
        switch m {
        case .canceled(let at?): ShellStrings.accountMembershipCanceledUntil(ShellTimes.full(at))
        case .canceled(nil): ShellStrings.accountMembershipCanceled
        case .member: ShellStrings.accountMembershipMember
        case .registered, .unknown: ShellStrings.accountMembershipRegistered
        }
    }

    static func subscription(_ s: SubscriptionLine) -> String {
        func named(_ n: String?) -> String { n ?? ShellStrings.accountSubscriptionDefaultName }
        switch s {
        case .none: return ShellStrings.accountSubscriptionNone
        case .trial(let n, let until?): return ShellStrings.accountSubscriptionTrialUntil(named(n), ShellTimes.full(until))
        case .trial(let n, nil): return ShellStrings.accountSubscriptionTrial(named(n))
        case .active(let n, let until?): return ShellStrings.accountSubscriptionActiveUntil(named(n), ShellTimes.full(until))
        case .active(let n, nil): return ShellStrings.accountSubscriptionActive(named(n))
        case .expired(let n): return ShellStrings.accountSubscriptionExpired(named(n))
        case .canceled(let n): return ShellStrings.accountSubscriptionCanceled(named(n))
        case .other(let n): return named(n)
        }
    }
}
#endif
