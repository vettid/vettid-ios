#if DEBUG
import SwiftUI
import VettIDData
import VettIDOnboarding
import VettIDOnboardingUI
import VettIDUI

/// Debug only: every state of the owner-check screen (the held screen among them), the app lock's screen and the way out
/// of a wipe that did not finish, with sample data, for the screen catalog and the previews. Fixed states with actions that
/// do nothing. The release check refuses its strings.
enum OwnerCheckCatalog {
    struct Entry: Identifiable, Sendable {
        let id: String
        let title: String
        let screen: Screen
    }

    enum Screen: Sendable {
        case check(OwnerCheckScreenState)
        case appLock(passcodeOnly: Bool, lockedOut: Bool = false)
        case eraseFailed(confirming: Bool, clearFailed: Bool)
    }

    static let now = Date(timeIntervalSince1970: 1_791_384_000)

    static let entries: [Entry] = {
        var all: [Entry] = []
        func add(_ id: String, _ title: String, mode: OwnerCheckMode = .gated, _ edit: (inout OwnerCheckScreenState) -> Void = { _ in }) {
            var s = OwnerCheckScreenState(
                mode: mode, view: OwnerCheckView(state: .held, deadline: now.addingTimeInterval(-3_600), waiting: WaitingCounts())
            )
            edit(&s)
            all.append(Entry(id: id, title: title, screen: .check(s)))
        }
        add("held_nothing", "Held: nothing new")
        add("held_waiting", "Held: messages and a call waiting") {
            $0.view?.waiting = WaitingCounts(messages: 3, requests: 1, calls: 1, other: 2)
        }
        add("held_unknown", "Held: not known yet") { $0.view?.waiting = nil }
        add("due", "Due: the hold is off") { s in
            s.view?.state = .due
            s.view?.hold = false
        }
        add("bad_pin", "Wrong PIN, 9 checks left") { s in
            s.view?.failures = 1
            s.message = .badPin(checksLeft: 9)
        }
        add("bad_password", "Wrong password, 2 checks left") { s in
            s.view?.failures = 8
            s.password = "correct horse"
            s.message = .badPassword(checksLeft: 2)
        }
        add("backoff", "Too many wrong entries") { s in
            s.message = .backoff
            s.waitSeconds = 272
        }
        add("failed", "No connection") { $0.message = .failed(.network, code: nil) }
        add("locking", "Locking the vault") { $0.locking = true }
        add("presence", "Presence not recorded") { $0.presenceUnrecorded = true }
        add("passed_unrecorded", "Passed, presence not recorded") { $0.passedUnrecorded = true }
        add("voluntary", "Check now", mode: .voluntary) { $0.view?.state = .ok }
        add("hold_off", "Turn the hold off", mode: .holdOff) { $0.view?.state = .ok }
        all.append(Entry(id: "app_lock", title: "App lock: Face ID or passcode", screen: .appLock(passcodeOnly: false)))
        all.append(Entry(id: "app_lock_passcode", title: "App lock: passcode", screen: .appLock(passcodeOnly: true)))
        all.append(Entry(
            id: "app_lock_locked_out", title: "App lock: Face ID locked out", screen: .appLock(passcodeOnly: false, lockedOut: true)
        ))
        func failed(_ id: String, _ title: String, confirming: Bool = false, clearFailed: Bool = false) {
            all.append(Entry(id: id, title: title, screen: .eraseFailed(confirming: confirming, clearFailed: clearFailed)))
        }
        failed("erase_failed", "The erase did not finish")
        failed("erase_failed_confirm", "Erase VettID's data: confirm", confirming: true)
        failed("erase_failed_again", "VettID's data not erased", clearFailed: true)
        return all
    }()

    /// The screen for [entry], with actions that do nothing.
    @MainActor @ViewBuilder
    static func screen(_ entry: Entry) -> some View {
        switch entry.screen {
        case .check(let state):
            OwnerCheckScreen(state: state, actions: NoOwnerCheckActions(), now: now)
        case .appLock(let passcodeOnly, let lockedOut):
            AppLockScreen(passcodeOnly: passcodeOnly, lockedOut: lockedOut) {}
        case .eraseFailed(let confirming, let clearFailed):
            UnreachableScreen(
                kind: .eraseFailed, busy: false, confirming: confirming, clearFailed: clearFailed, onRetry: {}, onStartOver: { _ in },
                onRecover: {}
            )
        }
    }
}

/// Debug-only: the owner check, the app lock and the failed erase in each of their states (``OwnerCheckCatalog``). Opened
/// from the screen catalog, or at launch with `-vettid.start ownerCheck`.
struct OwnerCheckCatalogScreen: View {
    let onBack: @MainActor () -> Void
    @State private var shown: String?

    var body: some View {
        DetailScaffold(onBack: onBack) {
            ScrollView {
                VStack(spacing: 0) {
                    LargeTitle("Owner check and app lock")
                    SettingsGroup {
                        ForEach(OwnerCheckCatalog.entries) { entry in
                            SettingsRow(entry.title) { shown = entry.id }
                                .accessibilityIdentifier("catalog_owner_check_\(entry.id)")
                        }
                    }
                }
            }
        }
        .navigationDestination(item: $shown) { id in
            if let entry = OwnerCheckCatalog.entries.first(where: { $0.id == id }) {
                OwnerCheckCatalog.screen(entry)
                    .overlay(alignment: .topTrailing) {
                        IconButton(.close, label: "Close") { shown = nil }.padding(.horizontal, Spacing.xs)
                    }
                    .toolbar(.hidden, for: .navigationBar)
            }
        }
    }
}

#Preview("Owner check states") {
    TabView {
        ForEach(OwnerCheckCatalog.entries) { entry in
            OwnerCheckCatalog.screen(entry).tabItem { Text(verbatim: entry.title) }
        }
    }
    .tabViewStyle(.page)
    .vettIDTheme(.dark)
}
#endif
