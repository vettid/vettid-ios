#if os(iOS)
import Foundation
import SwiftUI
import Testing
import UIKit
import VettIDData
import VettIDSettings
@testable import VettIDSettingsUI
import VettIDUI

/// New phone secret, Allow screenshots and Delete vault: their texts (vettid-android's, word for word; the `ios_` drafts
/// where an iPhone differs) and every state rendered. Mirrors vettid-android `ReleaseRSettingsTest`'s new phone secret,
/// `AllowScreenshotsScreenTest` and the deletion screen.
@MainActor
@Suite struct SecretsScreensTests {
    @Test func theTextsAreAndroids() {
        #expect(SecurityStrings.newSecretNotEnough == "If something ran as VettID on this phone, a new secret alone is not enough: "
            + "move your vault to another phone, or recover it.")
        #expect(SecurityStrings.newSecretBody == "Your vault gives this phone a new secret. Your PIN stays the same, and the old "
            + "secret opens nothing your vault stores from now on. Enter your PIN and your password.")
        #expect(SecurityStrings.screenshots == "Allow screenshots" && SecurityStrings.sectionApp == "App")
        #expect(SecurityStrings.screenshotsOn == "On. Turns itself off when the vault locks, and after 1 hour.")
        #expect(SecurityStrings.deleteAck
            == "I understand that my vault and everything in it will be erased and cannot be restored")
        #expect(SecurityStrings.deleteConfirm == "Delete forever" && SecurityStrings.deletePin == "Vault PIN")
        // IOS-PLAN §4: on an iPhone only the secure layer goes; the app switcher's cover and capture hiding stay.
        #expect(!SecurityStrings.screenshotsOff.contains("Recents") && !SecurityStrings.screenshotsConfirmBody.contains("Recents"))
        #expect(SecurityStrings.screenshotsConfirmBody.contains("\n\nThis turns itself off when the vault locks, and after 1 hour."))
    }

    /// vettid-android `AllowScreenshotsScreenTest`: off says so; on says when it ends, or that a development build keeps it.
    @Test func theScreenshotsRowSaysWhatItDoes() {
        #expect(AllowScreenshotsRow.supporting(SettingsState()) == SecurityStrings.screenshotsOff)
        #expect(AllowScreenshotsRow.supporting(SettingsState(screenshotsAllowed: true)) == SecurityStrings.screenshotsOn)
        let dev = SettingsState(screenshotsAllowed: true, screenshotsStayOn: true)
        #expect(AllowScreenshotsRow.supporting(dev) == SecurityStrings.screenshotsOnDevelopment)
    }

    @Test func everyStateRenders() {
        for s in [SettingsState(phoneSecret: true), SettingsState(screenshotsAllowed: true, screenshotsStayOn: true)] {
            #expect(height(SettingsContent(state: s)) > 0)
            #expect(height(SettingsContent(state: s, askScreenshots: true)) > 0)
        }
        var refused = NewPhoneSecretState(error: .badPassword)
        refused.busy = false
        var busy = NewPhoneSecretState()
        busy.busy = true
        for s in [NewPhoneSecretState(), refused, busy, NewPhoneSecretState(done: true)] {
            #expect(height(NewPhoneSecretContent(state: s)) > 0)
        }
        var filled = DeleteVaultState()
        filled.phrase = "delete my vault"
        filled.password = "pw"
        filled.acknowledged = true
        var wrong = DeleteVaultState()
        wrong.phraseWrong = true
        wrong.error = .badPin
        var unconfirmed = DeleteVaultState()
        unconfirmed.unconfirmed = true
        var confirming = filled
        confirming.pin = "402817"
        confirming.confirming = true
        for s in [DeleteVaultState(), filled, wrong, unconfirmed, confirming] {
            #expect(height(DeleteVaultContent(state: s)) > 0)
        }
    }

    private func height(_ view: some View) -> CGFloat {
        UIHostingController(rootView: view.vettIDTheme(.light)).sizeThatFits(in: CGSize(width: 390, height: 844)).height
    }
}
#endif
