#if os(iOS)
import SwiftUI
import VettIDData
import VettIDOnboardingUI
import VettIDSettingsUI
import VettIDShell
import VettIDUI

/// Rule 3 (no release but the current one is used): the open vault is not on the newest `active` release, so instead of
/// the shell the member sees the update ("Approve and update", with no way back) and only the ways to leave the vault:
/// the account sheet (where "Lock vault" is), Help, and Delete vault (to enroll anew when the update cannot complete).
/// Messages, calls, approvals, items and the rest are not reachable, and their reads are held meanwhile
/// (``VaultManager/featuresGated()``). It goes once the vault is on the current release.
public struct ReleaseRequiredGate: View {
    private let updates: any ReleaseUpdateRepository
    private let ownerCheck: (any OwnerCheckRepository)?
    private let notes: any ReleaseNotesRepository
    private let vault: any VaultRepository
    private let account: any AccountRepository
    private let onOpenPortal: @MainActor () -> Void
    @State private var path: [Leave] = []
    @State private var showsAccount = false

    enum Leave: Hashable {
        case help
        case deleteVault
    }

    public init(
        updates: any ReleaseUpdateRepository, ownerCheck: (any OwnerCheckRepository)?, notes: any ReleaseNotesRepository,
        vault: any VaultRepository, account: any AccountRepository, onOpenPortal: @escaping @MainActor () -> Void
    ) {
        self.updates = updates
        self.ownerCheck = ownerCheck
        self.notes = notes
        self.vault = vault
        self.account = account
        self.onOpenPortal = onOpenPortal
    }

    public var body: some View {
        NavigationStack(path: $path) {
            ReleaseUpdateRoute(updates: updates, ownerCheck: ownerCheck, notes: notes, onBack: nil)
                .safeAreaInset(edge: .bottom) { leaveRow }
                .navigationDestination(for: Leave.self) { leave in
                    switch leave {
                    case .help: HelpScreen { pop() }
                    case .deleteVault: DeleteVaultRoute(vault: vault) { pop() }
                    }
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
                onOpenPortal: onOpenPortal
            )
        }
    }

    private func pop() { if !path.isEmpty { path.removeLast() } }

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
