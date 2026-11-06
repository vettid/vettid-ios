#if os(iOS)
import SwiftUI
import VettIDData
import VettIDShell
import VettIDUI

/// The lasting notice of a relay key the relay refused (VAULT-MESSAGING 0.84.0 §3.4 "What the member sees"): shown while the
/// latest `vault.status` has `relay: "refused"`, gone when a later one has no `relay`. An urgent banner, as the clone alarm:
/// the vault may not receive messages and only the member can fix it. Title and body are two lines of its text. It cannot
/// be dismissed, because it lasts while the field is present. The action is the existing `credential.rotate` screen
/// ("Replace your vault's keys"). Mirrors vettid-android `RelayRefusedNotice`.
enum RelayRefusedNotice {
    /// Shown while the vault says so, except on the screens where the member replaces the keys or changes the credential:
    /// the notice would sit over them.
    static func shown(refused: Bool, path last: ShellRoute?) -> Bool {
        guard refused else { return false }
        switch last {
        case .rotate, .alarm, .newCredential, .changePassword: return false
        default: return true
        }
    }

    /// The action: the existing `credential.rotate` screen.
    @MainActor static func replaceKeys(_ model: ShellModel) { model.push(.rotate) }

    /// Title and body, two lines.
    static var text: String { ShellStrings.relayRefusedTitle + "\n" + ShellStrings.relayRefusedBody }

    @ViewBuilder static func banner(onReplaceKeys: @escaping @MainActor () -> Void) -> some View {
        UrgentBanner(text, actionLabel: ShellStrings.relayRefusedAction, action: onReplaceKeys)
            .accessibilityIdentifier("relay_refused_notice")
    }
}

/// The shell's place of the notice: shown while the vault says so, its action opens the rotation.
struct RelayRefusedBanner: View {
    let vault: any VaultRepository
    let model: ShellModel

    var body: some View {
        if RelayRefusedNotice.shown(refused: vault.relayRefused, path: model.path.last) {
            RelayRefusedNotice.banner { RelayRefusedNotice.replaceKeys(model) }
        }
    }
}
#endif
