#if DEBUG
import SwiftUI
import VettIDItems
import VettIDItemsUI
import VettIDOnboarding
import VettIDOnboardingUI
import VettIDUI

/// Debug only: the screens whose secret fields the screen catalog had no entry for (the recovery code typed in, the
/// transfer code pasted, the recovery's open password, a vault item on the Login template), and a control: an ordinary
/// password field, which iOS may offer AutoFill on. `AutofillUITests` focuses each field and checks that no AutoFill
/// shows on the app's own fields (IOS-PLAN §6.5), and that it does show on the control, so that the check itself works.
enum SecretFieldsCatalog {
    struct Entry: Identifiable {
        let id: String
        let title: String
    }

    static let entries = [
        Entry(id: "recover_type", title: "Recovery: type the code"),
        Entry(id: "transfer_paste", title: "Move here: paste the code"),
        Entry(id: "recovery_open", title: "Recovery: open with the PIN and password"),
        Entry(id: "item_login", title: "Vault item: Login template"),
        Entry(id: "control", title: "Control: an ordinary password field"),
    ]

    /// The screen for [entry], with actions that do nothing.
    @MainActor @ViewBuilder
    static func screen(_ entry: Entry) -> some View {
        switch entry.id {
        case "recover_type": RecoverContent(state: RecoverState(step: .type))
        case "transfer_paste": TransferInContent(state: TransferInState(step: .paste))
        case "recovery_open": RecoveryOpenContent(state: RecoveryOpenState(step: .enter))
        case "item_login": ItemEditScreen(state: loginItem, actions: ItemEditActions())
        default: ControlFields()
        }
    }

    private static var loginItem: ItemEditState {
        var s = ItemEditState()
        if let login = ItemTemplates.template("login") { s.draft = login.draft() }
        return s
    }
}

/// An ordinary login form, as any app would have one: iOS may offer saved passwords on it.
private struct ControlFields: View {
    @State private var username = ""
    @State private var password = ""

    var body: some View {
        VStack(spacing: Spacing.l) {
            TextField("Username", text: $username)
                .textContentType(.username)
                .accessibilityIdentifier("control_username")
            SecureField("Password", text: $password)
                .textContentType(.password)
                .accessibilityIdentifier("control_password")
        }
        .padding(Spacing.l)
    }
}

/// Debug only: the list of ``SecretFieldsCatalog``. Opened from the screen catalog, or at launch with
/// `-vettid.start secrets`.
struct SecretFieldsCatalogScreen: View {
    let onBack: @MainActor () -> Void
    @State private var shown: String?

    var body: some View {
        DetailScaffold(onBack: onBack) {
            ScrollView {
                VStack(spacing: 0) {
                    LargeTitle("Secret fields")
                    SettingsGroup {
                        ForEach(SecretFieldsCatalog.entries) { entry in
                            SettingsRow(entry.title) { shown = entry.id }
                                .accessibilityIdentifier("catalog_secrets_\(entry.id)")
                        }
                    }
                }
            }
        }
        .navigationDestination(item: $shown) { id in
            if let entry = SecretFieldsCatalog.entries.first(where: { $0.id == id }) {
                SecretFieldsCatalog.screen(entry)
                    .overlay(alignment: .topTrailing) {
                        IconButton(.close, label: "Close") { shown = nil }.padding(.horizontal, Spacing.xs)
                    }
                    .toolbar(.hidden, for: .navigationBar)
            }
        }
    }
}
#endif
