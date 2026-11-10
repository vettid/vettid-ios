#if os(iOS)
import Foundation
import SwiftUI
import Testing
import UIKit
import VettIDData
import VettIDSettings
@testable import VettIDSettingsUI
import VettIDUI

/// Vault status's Credential key row (ANDROID-PLAN 0.1.119 §4 "Owner check and status"): what it says in each state, and
/// where Copy and Try again go.
@MainActor
@Suite(.serialized) struct CredentialKeyRowScreenTests {
    let fp = "e939 754d 09aa a93a"

    @Test func eachStateSaysItsLine() {
        typealias Line = VaultStatusContent.CredentialKeyLine
        let line = VaultStatusContent.credentialKeyLine
        #expect(line(.shown(fp)) == Line(label: SettingsStrings.statusCredentialKey, value: fp, code: true))
        #expect(line(.loading) == Line(label: SettingsStrings.statusCredentialKey, value: SettingsStrings.loading, code: false))
        #expect(line(.none) == Line(label: SettingsStrings.statusCredentialKeyNone, value: "", code: false))
        #expect(line(.unknown) == Line(label: SettingsStrings.statusCredentialKeyUnknown, value: "", code: false))
    }

    @Test func copyGetsTheFingerprintShown() {
        var copied: [String] = []
        let content = VaultStatusContent(state: LoadState(), installedFrom: .apple, credentialKey: .shown(fp), copy: { copied.append($0) })
        content.copyCredentialKey(.shown(fp))
        for other in [CredentialKeyRow.loading, .none, .unknown] { content.copyCredentialKey(other) }
        #expect(copied == [fp])
    }

    @Test func tryAgainAsksAgain() {
        var asked = 0
        let content = VaultStatusContent(
            state: LoadState(), installedFrom: .apple, credentialKey: .unknown, retryCredentialKey: { asked += 1 }
        )
        content.retryCredentialKey()
        #expect(asked == 1)
    }

    /// By default Copy goes to the app's secure pasteboard, whose copy expires (an expired one is gone at once; its
    /// local-only option cannot be read back, and is ``SecurePasteboard``'s own).
    @Test func theDefaultCopyIsTheSecurePasteboard() throws {
        #expect(VaultStatusContent(state: LoadState(), installedFrom: .apple, credentialKey: .shown(fp)).copy == nil)
        let pb = try #require(UIPasteboard(name: UIPasteboard.Name("vettid.test.\(UUID().uuidString)"), create: true))
        defer { UIPasteboard.remove(withName: pb.name) }
        VaultStatusContent.secureCopy(fp, pasteboard: pb)
        #expect(pb.string == fp)
        VaultStatusContent.secureCopy(fp, lifetime: -1, pasteboard: pb)
        #expect(pb.string == nil, "it expires")
    }

    /// Asked again only on a return from the background, not after an `.inactive` alone (Control Center, a notification,
    /// the Face ID sheet).
    @Test func onlyAReturnFromTheBackgroundAsksAgain() {
        var f = ForegroundReturn()
        #expect([ScenePhase.inactive, .active].map { f.returned($0) } == [false, false])
        #expect([ScenePhase.inactive, .background, .inactive, .active].map { f.returned($0) } == [false, false, false, true])
        #expect(!f.returned(.inactive) && !f.returned(.active), "once per return")
    }
}
#endif
