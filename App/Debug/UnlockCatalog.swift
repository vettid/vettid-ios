#if DEBUG
import SwiftUI
import VettIDData
import VettIDOnboarding
import VettIDOnboardingUI
import VettIDUI

/// Debug only: every state of the unlock screen and of the root's stuck screens with sample data, for the screen catalog
/// and the previews (vettid-android's screen catalog entries for the unlock). Fixed states with actions that do nothing.
/// The release check refuses its strings.
enum UnlockCatalog {
    struct Entry: Identifiable, Sendable {
        let id: String
        let title: String
        let screen: UnlockCatalogScreenKind
    }

    /// One state of the root's stuck screen.
    private struct Stuck {
        let id: String
        let title: String
        let kind: FailureKind?
        var longUnreachable = false
        var confirming = false
    }

    private static func release(_ n: UInt64, _ status: String = "active", endsAt: Date? = nil) -> ReleaseView {
        ReleaseView(
            number: n, pcr0: String(repeating: "a3", count: 48), status: status, endsAt: endsAt, notes: "https://vettid.org/releases/\(n)"
        )
    }

    private static let ready = PreflightInfo(routed: release(3), lastNumber: 3, softwareUpdated: false, rollback: false, offer: nil)

    static let entries: [Entry] = {
        var all: [Entry] = []
        func add(_ id: String, _ title: String, _ edit: (inout UnlockState) -> Void = { _ in }) {
            var s = UnlockState(loading: false, email: "m***@example.com")
            s.preflight = ready
            edit(&s)
            all.append(Entry(id: id, title: title, screen: .unlock(s)))
        }
        add("checking", "Checking the vault's software") { s in
            s.loading = true
            s.preflight = nil
        }
        add("ready", "Enter the PIN")
        add("no_email", "Enter the PIN, no account yet") { $0.email = nil }
        add("bad_pin", "Wrong PIN") { $0.message = .badPin }
        add("backoff", "Too many wrong PINs") { s in
            s.message = .badPin
            s.waitSeconds = 272
        }
        add("updated", "Vault software was updated") {
            $0.preflight = PreflightInfo(routed: release(4), lastNumber: 3, softwareUpdated: true, rollback: false, offer: nil)
        }
        add("offer", "An update to approve, release deprecated") { s in
            s.preflight = PreflightInfo(
                routed: release(4, "deprecated", endsAt: Date(timeIntervalSince1970: 1_800_000_000)), lastNumber: 4, softwareUpdated: false,
                rollback: false, offer: release(5)
            )
            s.approveOffer = true
        }
        add("rollback", "Older vault software") {
            $0.preflight = PreflightInfo(routed: release(2), lastNumber: 3, softwareUpdated: false, rollback: true, offer: nil)
        }
        add("release_unknown", "Release not in the manifest") { s in
            s.preflight = nil
            s.preflightError = .releaseUnknown
        }
        add("enclave", "The software did not verify") { s in
            s.preflight = nil
            s.preflightError = .enclave
        }
        add("release_too_old", "Release too old for the iPhone") { s in
            s.preflight = nil
            s.preflightError = .releaseTooOld
        }
        add("release_ended", "Release ended: recover only") { s in
            s.preflight = nil
            s.preflightError = .releaseEnded
        }
        add("paused", "Service paused") { s in
            s.message = .failed(.servicePaused, code: "vault_unavailable")
            s.serviceWaitSeconds = 300
        }
        add("network", "No connection") { $0.message = .failed(.network, code: nil) }
        add("phone_locked", "Unlock your iPhone") { $0.message = .failed(.phoneLocked, code: "phone_locked") }
        add("locking", "Locking your vault") { $0.lock = .unconfirmed(askedAt: Date(timeIntervalSince1970: 1_791_000_000), attempts: 0) }
        add("lock_unconfirmed", "Your vault may still be open") {
            $0.lock = .unconfirmed(askedAt: Date(timeIntervalSince1970: 1_791_000_000), attempts: 3)
        }
        add("lock_confirmed", "Your vault is locked") { $0.lock = .confirmedLate }
        add("refused", "The vault refuses this phone") { $0.refused = true }
        add("check_due", "PIN and password (check due)") { s in
            s.checkDue = true
            s.password = "correct horse"
        }
        add("check_locked", "Locked after ten wrong checks") { s in
            s.checkDue = true
            s.lockedByOwnerCheck = true
        }
        add("recovery", "A recovery is in progress") { s in
            s.recoveryPending = true
            s.pin = "402817"
        }
        add("recovery_r", "A recovery is in progress, with the password") { s in
            s.recoveryPending = true
            s.phoneSecret = true
            s.pin = "402817"
            s.password = "correct horse"
        }
        add("state_rollback", "The vault's state is older") { $0.stateRollback = true }
        add("signer_refused", "This installation is not accepted") { s in
            s.signerRefused = true
            s.signerHelp = true
        }
        add("update_refused", "The update was refused") { $0.message = .updateRefused(code: "target") }
        add("previous_pin", "A PIN change got no answer: the previous PIN") { $0.pinStep = .previous }
        add("new_pin", "A PIN change got no answer: the new PIN") { $0.pinStep = .new }
        add("not_recognised", "Not recognised: erase offered") { s in
            s.notRecognised = true
            s.message = .failed(.other, code: UnlockState.codeUnreadable)
        }
        add("keys_gone", "This phone cannot open the vault") { s in
            s.keysGone = true
            s.message = .failed(.deviceSecret, code: "device_secret")
        }
        add("keys_gone_earlier", "Keys gone, earlier keys to try") { s in
            s.keysGone = true
            s.earlierSecret = true
        }
        add("erasing", "Erasing VettID from this phone") { s in
            s.notRecognised = true
            s.erasing = true
        }
        add("erase_confirm", "Erase: confirm") { s in
            s.keysGone = true
            s.eraseConfirm = true
        }
        add("kept_transfer", "The move didn't finish") { $0.keptTransfer = true }
        add("move_back_failed", "The move back failed") { s in
            s.keptTransfer = true
            s.message = .moveBackFailed
        }
        add("move_failure", "Finish the move did not finish") { $0.moveFailure = .transferIncomplete }
        add("no_user_guid", "Moved from an older release") { $0.message = .failed(.notSupported, code: UnlockAttempt.codeNoUserGuid) }
        all.append(Entry(id: "starting", title: "Opening VettID", screen: .starting))
        let stuck = [
            Stuck(id: "unreachable", title: "Cannot connect", kind: .network),
            Stuck(id: "unreachable_long", title: "Unreachable for 7 days", kind: .network, longUnreachable: true),
            Stuck(id: "unreachable_clock", title: "Check the date and time", kind: .clock),
            Stuck(id: "unreachable_no_vault", title: "The account has no vault", kind: .noVault),
            Stuck(id: "unreachable_no_vault_confirm", title: "Start over: confirm", kind: .noVault, confirming: true),
            Stuck(id: "unreachable_local_state", title: "Cannot read its keys", kind: .localState),
            Stuck(id: "unreachable_unauthorized", title: "No longer accepted: recover or erase", kind: .unauthorized),
            Stuck(id: "unreachable_erase_confirm", title: "Erase: confirm", kind: .unauthorized, confirming: true),
        ]
        for s in stuck {
            let screen = UnlockCatalogScreenKind.unreachable(s.kind, longUnreachable: s.longUnreachable, confirming: s.confirming)
            all.append(Entry(id: s.id, title: s.title, screen: screen))
        }
        return all
    }()

    /// The screen for [entry], with actions that do nothing.
    @MainActor @ViewBuilder
    static func screen(_ entry: Entry) -> some View {
        switch entry.screen {
        case .unlock(let state):
            UnlockScreen(state: state, actions: NoUnlockActions(), onContactSupport: { $0(false) })
        case .unreachable(let kind, let long, let confirming):
            UnreachableScreen(
                kind: kind, longUnreachable: long, busy: false, confirming: confirming, onRetry: {}, onStartOver: { _ in }, onRecover: {}
            )
        case .starting:
            StartingScreen()
        }
    }
}

/// Which screen a catalog entry shows.
enum UnlockCatalogScreenKind: Sendable {
    case unlock(UnlockState)
    case unreachable(FailureKind?, longUnreachable: Bool, confirming: Bool)
    case starting
}

/// Debug-only: the unlock and stuck screens in each of their states (``UnlockCatalog``). Opened from the screen catalog,
/// or at launch with `-vettid.start unlock`.
struct UnlockCatalogScreen: View {
    let onBack: @MainActor () -> Void
    @State private var shown: String?

    var body: some View {
        DetailScaffold(onBack: onBack) {
            ScrollView {
                VStack(spacing: 0) {
                    LargeTitle("Unlock")
                    SettingsGroup {
                        ForEach(UnlockCatalog.entries) { entry in
                            SettingsRow(entry.title) { shown = entry.id }
                                .accessibilityIdentifier("catalog_unlock_\(entry.id)")
                        }
                    }
                }
            }
        }
        .navigationDestination(item: $shown) { id in
            if let entry = UnlockCatalog.entries.first(where: { $0.id == id }) {
                UnlockCatalog.screen(entry)
                    .overlay(alignment: .topTrailing) {
                        IconButton(.close, label: "Close") { shown = nil }.padding(.horizontal, Spacing.xs)
                    }
                    .toolbar(.hidden, for: .navigationBar)
            }
        }
    }
}

#Preview("Unlock states") {
    TabView {
        ForEach(UnlockCatalog.entries) { entry in
            UnlockCatalog.screen(entry).tabItem { Text(verbatim: entry.title) }
        }
    }
    .tabViewStyle(.page)
    .vettIDTheme(.dark)
}
#endif
