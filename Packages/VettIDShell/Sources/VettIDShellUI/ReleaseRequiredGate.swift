#if os(iOS)
import SwiftUI
import VettIDData
import VettIDOnboardingUI
import VettIDSettingsUI
import VettIDShell
import VettIDUI

/// No release but the current one is used (owner decision 2026-11-17): the open vault is not on the newest `active`
/// release, or that is being checked after the opening, so instead of the shell the member sees the update ("Approve and
/// update", with no way back; "Checking" while the manifest is read) and only the ways to leave the vault: the account
/// sheet (where "Lock vault" is), Help, and Delete vault (to enroll anew when the update cannot complete). The clone alarm
/// and the relay's refusal of the vault's key stay above it, with their screens. Nothing else of the shell is reachable,
/// no list takes the vault's events or is read, and no call starts or rings (``ReleaseUpdateManager/required``); the
/// lists are read again once the vault is on the current release.
public struct ReleaseRequiredGate: View {
    private let updates: any ReleaseUpdateRepository
    private let ownerCheck: (any OwnerCheckRepository)?
    private let notes: any ReleaseNotesRepository
    private let vault: any VaultRepository
    private let account: any AccountRepository
    private let credential: any CredentialRepository
    private let onOpenPortal: @MainActor () -> Void
    @State private var path: [Leave] = []
    @State private var showsAccount = false

    enum Leave: Hashable {
        case help
        case deleteVault
        case alarm
        case rotate
    }

    public init(
        updates: any ReleaseUpdateRepository, ownerCheck: (any OwnerCheckRepository)?, notes: any ReleaseNotesRepository,
        vault: any VaultRepository, account: any AccountRepository, credential: any CredentialRepository,
        onOpenPortal: @escaping @MainActor () -> Void
    ) {
        self.updates = updates
        self.ownerCheck = ownerCheck
        self.notes = notes
        self.vault = vault
        self.account = account
        self.credential = credential
        self.onOpenPortal = onOpenPortal
    }

    public var body: some View {
        NavigationStack(path: $path) {
            ReleaseUpdateRoute(updates: updates, ownerCheck: ownerCheck, notes: notes, onBack: nil)
                .safeAreaInset(edge: .top, spacing: 0) { banners }
                .safeAreaInset(edge: .bottom, spacing: 0) { leaveRow }
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: Leave.self) { leave in
                    destination(leave).toolbar(.hidden, for: .navigationBar)
                }
        }
        .accessibilityIdentifier("release_required")
        .sheet(isPresented: $showsAccount) {
            AccountSheet(
                account: account.account,
                onLockVault: {
                    showsAccount = false
                    Task {
                        // As the shell's own "Lock vault": a failure reads the account again and stays.
                        do { try await vault.lock() } catch { try? await account.refresh() }
                    }
                },
                onChangeName: nil,
                onSharedProfile: nil,
                onOpenPortal: onOpenPortal
            )
        }
    }

    @ViewBuilder private func destination(_ leave: Leave) -> some View {
        switch leave {
        case .help: HelpScreen { pop() }
        case .deleteVault: DeleteVaultRoute(vault: vault) { pop() }
        case .alarm: AlarmRoute(repo: credential) { pop() }
        case .rotate: RotateRoute(repo: credential) { pop() }
        }
    }

    private func pop() { if !path.isEmpty { path.removeLast() } }

    /// The clone alarm (VAULT-MESSAGING §3.5.9) and the relay's refusal of the vault's key (§3.4), as in the shell.
    @ViewBuilder private var banners: some View {
        VStack(spacing: 0) {
            if credential.alarm != nil {
                UrgentBanner(ShellStrings.alarmBanner, actionLabel: ShellStrings.alarmReview) { path.append(.alarm) }
                    .accessibilityIdentifier("alarm_banner")
            }
            if vault.relayRefused {
                RelayRefusedNotice.banner { path.append(.rotate) }
            }
        }
    }

    private var leaveRow: some View {
        HStack(spacing: Spacing.m) {
            Button(SettingsLabels.account) { showsAccount = true }
                .accessibilityIdentifier("release_required_account")
            Spacer()
            Button(ShellStrings.navHelp) { path.append(.help) }
                .accessibilityIdentifier("release_required_help")
            Spacer()
            Button(SettingsLabels.deleteVault, role: .destructive) { path.append(.deleteVault) }
                .accessibilityIdentifier("release_required_delete")
        }
        .font(.subheadline)
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.s)
        .background(.bar)
    }
}
#endif
