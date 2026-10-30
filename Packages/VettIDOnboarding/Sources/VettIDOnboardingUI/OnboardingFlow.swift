#if os(iOS)
import SwiftUI
import VettIDData
import VettIDOnboarding
import VettIDUI

/// The screens of later rows that the onboarding flow hands over to (IOS-PLAN §8): the recovery, the transfer from the
/// old phone and the move's last screen. The app wires them as they arrive; until then ``pending`` shows nothing for
/// them.
public struct OnboardingRoutes: Sendable {
    /// The recovery on this phone (§11.11): `onLeave` returns to the onboarding choice, `onNewVault` starts a new vault
    /// after a recovery deleted the old one.
    public var recover: @MainActor (
        _ onLeave: @escaping @MainActor () -> Void,
        _ onNewVault: @escaping @MainActor () -> Void,
        _ onOpenAccountSite: @escaping @MainActor () -> Void
    ) -> AnyView
    /// The direct transfer from the old phone (§6.7.1).
    public var transferIn: @MainActor (_ onLeave: @escaping @MainActor () -> Void) -> AnyView
    /// The last screen after a move to this phone (``OnboardingState/movedIn``): "Finish the move" while
    /// ``OnboardingState/finishMovePending``, otherwise the move's own "done" screen; `finish` leaves onboarding.
    public var movedIn: @MainActor (_ state: OnboardingState, _ finish: @escaping @MainActor () -> Void) -> AnyView

    public init(
        recover: @escaping @MainActor (
            _ onLeave: @escaping @MainActor () -> Void,
            _ onNewVault: @escaping @MainActor () -> Void,
            _ onOpenAccountSite: @escaping @MainActor () -> Void
        ) -> AnyView,
        transferIn: @escaping @MainActor (_ onLeave: @escaping @MainActor () -> Void) -> AnyView,
        movedIn: @escaping @MainActor (_ state: OnboardingState, _ finish: @escaping @MainActor () -> Void) -> AnyView
    ) {
        self.recover = recover
        self.transferIn = transferIn
        self.movedIn = movedIn
    }

    /// Nothing wired yet (previews, the screen catalog, and the app until those rows arrive).
    public static let pending = OnboardingRoutes(
        recover: { _, _, _ in AnyView(EmptyView()) },
        transferIn: { _ in AnyView(EmptyView()) },
        movedIn: { _, _ in AnyView(EmptyView()) }
    )
}

public extension OnboardingRoutes {
    /// The recovery, the transfer from the old phone and the move's last screen wired over [move], [vault] and [account]. Mirrors
    /// the defaults of vettid-android `OnboardingContent`.
    static func moves(move: any MoveRepository, vault: any VaultRepository, account: any AccountRepository) -> OnboardingRoutes {
        OnboardingRoutes(
            recover: { onLeave, onNewVault, onOpenAccountSite in
                AnyView(
                    RecoverRoute(
                        move: move, vault: vault, account: account, onLeave: onLeave, onNewVault: onNewVault,
                        onOpenAccountSite: onOpenAccountSite
                    )
                )
            },
            transferIn: { onLeave in AnyView(TransferInRoute(move: move, vault: vault, onLeave: onLeave)) },
            movedIn: { state, finish in AnyView(MovedInScreen(state: state, vault: vault, finish: finish)) }
        )
    }
}

/// The last screen after a direct transfer (also after a restart): "Finish the move" while it is pending, otherwise the
/// move's own "done" screen, never the enrollment's. Mirrors the `DONE` step of vettid-android `OnboardingContent`.
struct MovedInScreen: View {
    let state: OnboardingState
    let vault: any VaultRepository
    let finish: @MainActor () -> Void

    var body: some View {
        if state.finishMovePending {
            FinishMoveRoute(vault: vault, onDone: finish)
        } else {
            MovedScreen(
                body: state.phoneSecret ? MoveStrings.onboardingFinishMoveDone : MoveStrings.onboardingMovedTransferredBody,
                onGo: finish
            )
        }
    }
}

/// The onboarding flow, driven by an ``OnboardingViewModel`` over the app's repositories. [onOpenAccountSite] opens the
/// account portal. The model is made once, when the flow first appears, and lives as long as the flow.
public struct OnboardingFlow: View {
    private let account: any AccountRepository
    private let vault: any VaultRepository
    private let inbox: SetupLinkInbox
    private let routes: OnboardingRoutes
    private let onOpenAccountSite: @MainActor () -> Void
    @State private var model: OnboardingViewModel?
    @Environment(\.vettIDColors) private var colors

    public init(
        account: any AccountRepository,
        vault: any VaultRepository,
        inbox: SetupLinkInbox,
        routes: OnboardingRoutes,
        onOpenAccountSite: @escaping @MainActor () -> Void
    ) {
        self.account = account
        self.vault = vault
        self.inbox = inbox
        self.routes = routes
        self.onOpenAccountSite = onOpenAccountSite
    }

    public var body: some View {
        Group {
            if let model {
                OnboardingContent(state: model.state, actions: model, routes: routes, onOpenAccountSite: onOpenAccountSite)
            } else {
                colors.background.color.ignoresSafeArea()
            }
        }
        .onAppear {
            if model == nil { model = OnboardingViewModel(account: account, vault: vault, inbox: inbox) }
        }
    }
}

/// One onboarding step for [state] (stateless). [camera] replaces the camera preview (previews, the screen catalog).
/// Mirrors vettid-android `OnboardingContent`.
public struct OnboardingContent: View {
    let state: OnboardingState
    let actions: any OnboardingActions
    let routes: OnboardingRoutes
    let onOpenAccountSite: @MainActor () -> Void
    let camera: AnyView?

    public init(
        state: OnboardingState,
        actions: any OnboardingActions,
        routes: OnboardingRoutes,
        onOpenAccountSite: @escaping @MainActor () -> Void,
        camera: AnyView? = nil
    ) {
        self.state = state
        self.actions = actions
        self.routes = routes
        self.onOpenAccountSite = onOpenAccountSite
        self.camera = camera
    }

    private static let backable: Set<OnboardingStep> = [.setupScan, .setupType, .pinConfirm, .backup]

    public var body: some View {
        let canBack = Self.backable.contains(state.step) || (state.step == .password && !state.credentialOnly)
        let actions = actions
        let back: (@MainActor () -> Void)? = canBack ? { @MainActor in actions.back() } : nil
        screen(back: back)
            .announcesStepChanges(of: state.step)
    }

    @ViewBuilder
    private func screen(back: (@MainActor () -> Void)?) -> some View {
        switch state.step {
        case .welcome, .setupScan, .setupType, .confirmAccount, .vaultElsewhere:
            setupScreen(back: back)
        case .pinCreate, .pinConfirm, .password, .backup, .progress, .done:
            vaultScreen(back: back)
        case .recover:
            routes.recover({ [actions] in actions.leaveMove() }, { [actions] in actions.newVaultAfterMove() }, onOpenAccountSite)
        case .transferIn:
            routes.transferIn({ [actions] in actions.leaveMove() })
        }
    }

    /// The setup-code steps.
    @ViewBuilder
    private func setupScreen(back: (@MainActor () -> Void)?) -> some View {
        let actions = actions
        switch state.step {
        case .setupScan:
            SetupScanScreen(state: state, actions: actions, onBack: back, onOpenAccountSite: onOpenAccountSite, camera: camera)
        case .setupType:
            SetupTypeScreen(state: state, actions: actions, onBack: back)
        case .confirmAccount:
            ConfirmAccountScreen(state: state, actions: actions)
        case .vaultElsewhere:
            VaultElsewhereScreen(state: state, actions: actions, onOpenAccountSite: onOpenAccountSite)
        default:
            WelcomeScreen(
                onStart: { actions.start() }, onTransfer: { actions.startTransfer() }, onRecover: { actions.startRecovery() },
                deletedNotice: state.deletedNotice, onOpenAccountSite: onOpenAccountSite,
                onNoticeSeen: { actions.dismissDeletedNotice() }
            )
        }
    }

    /// The vault steps.
    @ViewBuilder
    private func vaultScreen(back: (@MainActor () -> Void)?) -> some View {
        let actions = actions
        switch state.step {
        case .pinConfirm:
            PinConfirmScreen(state: state, actions: actions, onBack: back)
        case .password:
            PasswordScreen(state: state, actions: actions, onBack: back)
        case .backup:
            BackupScreen(state: state, actions: actions, onBack: back)
        case .progress:
            ProgressScreen(state: state, actions: actions)
        case .done:
            // After a direct transfer (also after a restart): the move's own last screen, never the enrollment's.
            if state.movedIn {
                routes.movedIn(state, { actions.finish() })
            } else {
                DoneScreen(state: state, actions: actions)
            }
        default:
            PinCreateScreen(state: state, actions: actions)
        }
    }
}
#endif
