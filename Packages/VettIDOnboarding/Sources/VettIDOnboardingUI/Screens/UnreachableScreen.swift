#if os(iOS)
import SwiftUI
import VettIDData
import VettIDOnboarding
import VettIDUI

/// The phase could not be read (``AppPhase/unreachable(_:longUnreachable:)``): why, and "Try again". The phone's clock,
/// an account service that says the account has no vault, and stored keys that cannot be read say so in the title; the
/// last two also offer a confirmed way out. The account service no longer accepting this phone, or a vault unreachable
/// for 7 days ([longUnreachable]), offers recover-or-erase: "Recover your vault" first, the erase second, "Try again"
/// below them. A wipe of this phone that did not finish offers "Erase VettID's data on this phone" ([clearFailed]: it could
/// not erase everything, and the member is told to remove the app). Nothing is forgotten or erased by itself. Mirrors
/// vettid-android `UnreachableScreen`.
public struct UnreachableScreen: View {
    let kind: FailureKind?
    let longUnreachable: Bool
    let busy: Bool
    let clearFailed: Bool
    /// (STAGING-TIME-SCALE §5.2) The vault's time scale: the long wait and a recovery's delay are shown divided by it.
    let timeScale: UInt64
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
        clearFailed: Bool = false,
        timeScale: UInt64 = 1,
        onRetry: @escaping @MainActor () -> Void,
        onStartOver: @escaping @MainActor (WayOut) -> Void,
        onRecover: @escaping @MainActor () -> Void
    ) {
        self.kind = kind
        self.longUnreachable = longUnreachable
        self.busy = busy
        self.clearFailed = clearFailed
        self.timeScale = timeScale
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
                        let wait = TimeScales.text(TimeInterval(TimeScales.longUnreachableMs / 1000), by: timeScale)
                        Text(OnboardingStrings.rootLongUnreachable(wait))
                            .vettIDFont(.bodyLarge)
                            .accessibilityIdentifier("long_unreachable")
                    }
                    Text(OnboardingStrings.rootRecoverLine).vettIDFont(.bodyMedium).foregroundStyle(colors.onSurfaceVariant)
                    TextLink(OnboardingStrings.rootRetry, identifier: "retry_button", action: onRetry).disabled(busy)
                }
            }
            if clearFailed && way == .clearData {
                Text(OnboardingStrings.rootClearDataFailed)
                    .vettIDFont(.bodyLarge)
                    .foregroundStyle(colors.error)
                    .accessibilityIdentifier("clear_data_failed")
            }
        }
        .confirmDialog(
            isPresented: Binding(get: { confirm && way != nil }, set: { confirm = $0 }),
            title: way.map(Self.confirmTitle) ?? "",
            message: way.map { Self.confirmBody($0, timeScale: timeScale) } ?? "",
            confirmLabel: way.map(Self.confirmLabel) ?? "",
            destructive: true,
            onConfirm: {
                confirm = false
                if let way { onStartOver(way) }
            }
        )
        .accessibilityIdentifier("unreachable")
    }

    static func label(_ way: WayOut) -> String {
        switch way {
        case .startOver: OnboardingStrings.rootStartOver
        case .clearData: OnboardingStrings.rootClearData
        case .erase, .eraseOrRecover: OnboardingStrings.rootErase
        }
    }

    static func confirmLabel(_ way: WayOut) -> String { way == .clearData ? OnboardingStrings.rootClearDataConfirm : label(way) }

    static func confirmTitle(_ way: WayOut) -> String {
        switch way {
        case .startOver: OnboardingStrings.rootStartOverTitle
        case .clearData: OnboardingStrings.rootClearDataTitle
        case .erase, .eraseOrRecover: OnboardingStrings.rootEraseTitle
        }
    }

    static func confirmBody(_ way: WayOut, timeScale: UInt64 = 1) -> String {
        switch way {
        case .startOver: OnboardingStrings.rootStartOverBody
        case .clearData: OnboardingStrings.rootClearDataBody
        case .erase, .eraseOrRecover: OnboardingStrings.erasePhoneBody(TimeScales.text(TimeScales.recoveryDelay, by: timeScale))
        }
    }
}

/// The root screen of a phase that could not be read, driven by an ``UnreachableViewModel``.
public struct UnreachableFlow: View {
    private let account: any AccountRepository
    private let timeScale: UInt64
    private let onRecover: @MainActor () -> Void
    @State private var model: UnreachableViewModel?

    /// [timeScale]: the vault's time scale (STAGING-TIME-SCALE §5.2).
    public init(account: any AccountRepository, timeScale: UInt64 = 1, onRecover: @escaping @MainActor () -> Void) {
        self.account = account
        self.timeScale = timeScale
        self.onRecover = onRecover
    }

    public var body: some View {
        let (kind, long): (FailureKind?, Bool) = if case .unreachable(let k, let l) = account.phase { (k, l) } else { (nil, false) }
        UnreachableScreen(
            kind: kind, longUnreachable: long, busy: model?.retrying ?? false, clearFailed: model?.clearDataFailed ?? false,
            timeScale: timeScale, onRetry: { model?.retry() }, onStartOver: { model?.startOver($0) }, onRecover: onRecover
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
