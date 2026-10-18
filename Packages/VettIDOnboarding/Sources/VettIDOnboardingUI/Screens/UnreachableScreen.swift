#if os(iOS)
import SwiftUI
import VettIDData
import VettIDOnboarding
import VettIDUI

/// The phase could not be read (``AppPhase/unreachable(_:longUnreachable:)``): why, and "Try again". The phone's clock,
/// an account service that says the account has no vault, and stored keys that cannot be read say so in the title; the
/// last two also offer a confirmed way out. The account service no longer accepting this phone, or a vault unreachable
/// for 7 days ([longUnreachable]), offers recover-or-erase: "Recover your vault" first, the erase second, "Try again"
/// below them. Nothing is forgotten or erased by itself. Mirrors vettid-android `UnreachableScreen` (its "Erase VettID's
/// data on this phone" after a wipe that did not finish comes with I1.7b).
public struct UnreachableScreen: View {
    let kind: FailureKind?
    let longUnreachable: Bool
    let busy: Bool
    let onRetry: @MainActor () -> Void
    let onStartOver: @MainActor (WayOut) -> Void
    let onRecover: @MainActor () -> Void
    @State private var confirm: Bool
    @Environment(\.vettIDColors) private var colors

    /// [confirming]: the confirmation shows from the start (the debug screen catalog).
    public init(
        kind: FailureKind?,
        longUnreachable: Bool = false,
        busy: Bool,
        confirming: Bool = false,
        onRetry: @escaping @MainActor () -> Void,
        onStartOver: @escaping @MainActor (WayOut) -> Void,
        onRecover: @escaping @MainActor () -> Void
    ) {
        self.kind = kind
        self.longUnreachable = longUnreachable
        self.busy = busy
        self.onRetry = onRetry
        self.onStartOver = onStartOver
        self.onRecover = onRecover
        _confirm = State(initialValue: confirming)
    }

    static func title(_ kind: FailureKind?) -> String {
        switch kind {
        case .clock: OnboardingStrings.rootClockTitle
        case .noVault: OnboardingStrings.rootNoVaultTitle
        case .localState: OnboardingStrings.rootLocalStateTitle
        case .eraseFailed: OnboardingStrings.rootEraseFailedTitle
        default: OnboardingStrings.rootUnreachableTitle
        }
    }

    public var body: some View {
        let way = WayOut.of(kind, longUnreachable: longUnreachable)
        let eraseOrRecover = way == .eraseOrRecover
        FormScaffold(
            title: Self.title(kind),
            message: kind?.message,
            primaryLabel: eraseOrRecover ? OnboardingStrings.rootRecover : OnboardingStrings.rootRetry,
            busy: busy,
            secondaryLabel: way.map(Self.label),
            onPrimary: eraseOrRecover ? onRecover : onRetry,
            onSecondary: { confirm = true }
        ) {
            if eraseOrRecover {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    if longUnreachable {
                        Text(OnboardingStrings.rootLongUnreachable).vettIDFont(.bodyLarge).accessibilityIdentifier("long_unreachable")
                    }
                    Text(OnboardingStrings.rootRecoverLine).vettIDFont(.bodyMedium).foregroundStyle(colors.onSurfaceVariant)
                    TextLink(OnboardingStrings.rootRetry, identifier: "retry_button", action: onRetry).disabled(busy)
                }
            }
        }
        .confirmDialog(
            isPresented: Binding(get: { confirm && way != nil }, set: { confirm = $0 }),
            title: way.map(Self.confirmTitle) ?? "",
            message: way.map(Self.confirmBody) ?? "",
            confirmLabel: way.map(Self.label) ?? "",
            destructive: true,
            onConfirm: {
                confirm = false
                if let way { onStartOver(way) }
            }
        )
        .accessibilityIdentifier("unreachable")
    }

    static func label(_ way: WayOut) -> String {
        way == .startOver ? OnboardingStrings.rootStartOver : OnboardingStrings.rootErase
    }

    static func confirmTitle(_ way: WayOut) -> String {
        way == .startOver ? OnboardingStrings.rootStartOverTitle : OnboardingStrings.rootEraseTitle
    }

    static func confirmBody(_ way: WayOut) -> String {
        way == .startOver ? OnboardingStrings.rootStartOverBody : OnboardingStrings.erasePhoneBody
    }
}

/// The root screen of a phase that could not be read, driven by an ``UnreachableViewModel``.
public struct UnreachableFlow: View {
    private let account: any AccountRepository
    private let onRecover: @MainActor () -> Void
    @State private var model: UnreachableViewModel?

    public init(account: any AccountRepository, onRecover: @escaping @MainActor () -> Void) {
        self.account = account
        self.onRecover = onRecover
    }

    public var body: some View {
        let (kind, long): (FailureKind?, Bool) = if case .unreachable(let k, let l) = account.phase { (k, l) } else { (nil, false) }
        UnreachableScreen(
            kind: kind, longUnreachable: long, busy: model?.retrying ?? false,
            onRetry: { model?.retry() }, onStartOver: { model?.startOver($0) }, onRecover: onRecover
        )
        .onAppear {
            if model == nil { model = UnreachableViewModel(account: account) }
        }
    }
}

/// The start, while the phase is read ("Opening VettID").
public struct StartingScreen: View {
    public init() {}

    public var body: some View { FullScreenProgress(OnboardingStrings.rootStarting) }
}
#endif
