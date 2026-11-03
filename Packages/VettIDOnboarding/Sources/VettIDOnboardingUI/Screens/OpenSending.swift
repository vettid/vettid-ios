import SwiftUI
import VettIDUI

struct OpenSending: View {
    let slow: Bool
    let onCancel: @MainActor () -> Void

    var body: some View {
        FormScaffold(title: RecoveryScreenStrings.recoverTitle, primaryLabel: nil, onPrimary: {}) {
            WaitingRow(text: RecoveryScreenStrings.iosRecoverOpenSending, identifier: "open_sending")
            if slow {
                // The vault may be starting (Android's text for the same wait of a recovery's registration).
                Text(RecoveryScreenStrings.recoverRegisteringStarting).vettIDFont(.bodyMedium)
                Button(MoveStrings.transferInCancel, action: onCancel).accessibilityIdentifier("open_cancel_wait")
            }
        }
    }
}
