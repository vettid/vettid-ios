import SwiftUI

/// The gold primary action (filled), full width; [destructive] uses the error colour. Mirrors vettid-android
/// `PrimaryButton`.
public struct PrimaryButton: View {
    @Environment(\.vettIDColors) private var colors
    @Environment(\.isEnabled) private var isEnabled
    let label: String
    let busy: Bool
    let destructive: Bool
    let action: @MainActor () -> Void

    public init(_ label: String, busy: Bool = false, destructive: Bool = false, action: @escaping @MainActor () -> Void) {
        self.label = label
        self.busy = busy
        self.destructive = destructive
        self.action = action
    }

    public var body: some View {
        let fill = destructive ? colors.error : colors.primaryContainer
        let ink = destructive ? colors.onError : colors.onPrimaryContainer
        Button { if !busy { action() } } label: {
            HStack(spacing: Spacing.m) {
                if busy {
                    ProgressView().tint(ink.color).controlSize(.small)
                }
                Text(label).vettIDFont(.labelLarge, weight: .semibold)
            }
            .foregroundStyle(isEnabled ? ink : colors.onSurface.opacity(0.38))
            .padding(.horizontal, Spacing.xl)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(isEnabled ? fill : colors.onSurface.opacity(0.12), in: VettIDShape.pill)
            .contentShape(VettIDShape.pill)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("primary_button")
    }
}

/// A secondary (outlined) action, full width. Mirrors vettid-android `SecondaryButton`.
public struct SecondaryButton: View {
    @Environment(\.vettIDColors) private var colors
    @Environment(\.isEnabled) private var isEnabled
    let label: String
    let action: @MainActor () -> Void

    public init(_ label: String, action: @escaping @MainActor () -> Void) {
        self.label = label
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(label)
                .vettIDFont(.labelLarge)
                .foregroundStyle(isEnabled ? colors.onSurface : colors.onSurface.opacity(0.38))
                .padding(.horizontal, Spacing.xl)
                .frame(maxWidth: .infinity, minHeight: 52)
                .overlay(VettIDShape.pill.stroke(colors.outline, lineWidth: 1))
                .contentShape(VettIDShape.pill)
        }
        .buttonStyle(.plain)
    }
}

/// A password strength meter: [level] of 4 segments filled (0: too short), with [label] read out.
/// Mirrors vettid-android `StrengthMeter`.
public struct StrengthMeter: View {
    @Environment(\.vettIDColors) private var colors
    let level: Int
    let label: String

    public init(level: Int, label: String) {
        self.level = level
        self.label = label
    }

    public var body: some View {
        let fill: ThemeColor = switch level {
        case ...1: colors.error
        case 2: colors.warning
        case 3: colors.primary
        default: colors.success
        }
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.xs) {
                ForEach(0..<4, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(i < level ? fill : colors.surfaceContainerHigh)
                        .frame(height: 6)
                }
            }
            Text(label).vettIDFont(.labelMedium).foregroundStyle(colors.onSurfaceVariant)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(UIStrings.strength(label))
    }
}

/// The line under a new password (ANDROID-PLAN "Passwords", release R): the rule it breaks, in words, with [hint]
/// under it, or the positive line ([passes]). [refused]: the vault's own verdict (`weak_password`), shown as an error.
/// Mirrors vettid-android `PasswordRuleLine`.
public struct PasswordRuleLine: View {
    @Environment(\.vettIDColors) private var colors
    let text: String
    let passes: Bool
    let hint: String?
    let refused: Bool

    public init(_ text: String, passes: Bool, hint: String? = nil, refused: Bool = false) {
        self.text = text
        self.passes = passes
        self.hint = hint
        self.refused = refused
    }

    public var body: some View {
        let color = refused ? colors.error : passes ? colors.success : colors.onSurfaceVariant
        let icon: VettIDSymbol = refused ? .errorOutline : passes ? .checkCircle : .info
        HStack(alignment: .top, spacing: Spacing.s) {
            icon.image.font(.system(size: 16)).foregroundStyle(color).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(text).vettIDFont(.bodyMedium).foregroundStyle(color)
                if let hint { Text(hint).vettIDFont(.bodySmall).foregroundStyle(colors.onSurfaceVariant) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// How serious a ``NoticeCard`` is.
public enum NoticeKind: CaseIterable, Sendable { case info, success, warning, urgent }

/// A notice in a form or detail screen: release updates, warnings before an irreversible choice, the clone alarm.
/// [actions] go under the text. Mirrors vettid-android `NoticeCard`.
public struct NoticeCard<Actions: View>: View {
    @Environment(\.vettIDColors) private var colors
    let kind: NoticeKind
    let title: String
    let message: String
    let actions: Actions

    public init(_ kind: NoticeKind, title: String, message: String, @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.kind = kind
        self.title = title
        self.message = message
        self.actions = actions()
    }

    public var body: some View {
        let (accent, icon): (ThemeColor, VettIDSymbol) = switch kind {
        case .info: (colors.primary, .info)
        case .success: (colors.success, .checkCircle)
        case .warning: (colors.warning, .warning)
        case .urgent: (colors.error, .reportProblem)
        }
        HStack(alignment: .top, spacing: Spacing.m) {
            icon.image.font(.system(size: 20)).foregroundStyle(accent).frame(width: 24).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.s) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(title).vettIDFont(.titleSmall, weight: .semibold)
                    Text(message).vettIDFont(.bodyMedium).foregroundStyle(colors.onSurfaceVariant)
                }
                .accessibilityElement(children: .combine)
                HStack(spacing: Spacing.s) { actions }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Spacing.l)
        .background(colors.surfaceContainer, in: VettIDShape.card)
    }
}

/// A non-blocking information banner above every screen (the vault service paused for maintenance; the owner check's
/// early warning): one line and an optional action; nothing behind it is disabled. Mirrors vettid-android
/// `InfoBanner`.
public struct InfoBanner: View {
    @Environment(\.vettIDColors) private var colors
    @Environment(\.dynamicTypeSize) private var typeSize
    let text: String
    let actionLabel: String?
    let onAction: @MainActor () -> Void
    let onDismiss: (@MainActor () -> Void)?

    public init(
        _ text: String,
        actionLabel: String? = nil,
        onAction: @escaping @MainActor () -> Void = {},
        onDismiss: (@MainActor () -> Void)? = nil
    ) {
        self.text = text
        self.actionLabel = actionLabel
        self.onAction = onAction
        self.onDismiss = onDismiss
    }

    public var body: some View {
        // At accessibility text sizes the action goes under the text, so that neither breaks inside a word.
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading)) : AnyLayout(HStackLayout(spacing: 0))
        layout {
            HStack(spacing: Spacing.m) {
                VettIDSymbol.info.image.foregroundStyle(colors.warning).accessibilityHidden(true)
                Text(text).vettIDFont(.bodyMedium).frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
            HStack(spacing: 0) {
                if let actionLabel {
                    Button(action: onAction) {
                        Text(actionLabel)
                            .vettIDFont(.labelLarge, weight: .semibold)
                            .foregroundStyle(colors.primary)
                            .fixedSize()
                            .padding(.horizontal, Spacing.m)
                            .frame(minHeight: Spacing.touchTarget)
                    }
                    .buttonStyle(.plain)
                }
                if let onDismiss {
                    IconButton(.close, label: UIStrings.dismiss, tint: colors.onSurfaceVariant, action: onDismiss)
                        .accessibilityIdentifier("banner_dismiss")
                }
            }
        }
        .foregroundStyle(colors.onSurface)
        .padding(.leading, Spacing.l)
        .padding(.trailing, actionLabel != nil || onDismiss != nil ? Spacing.s : Spacing.l)
        .padding(.vertical, Spacing.s)
        .frame(minHeight: Spacing.touchTarget)
        .background(colors.surfaceContainerHigh)
    }
}

/// The urgent banner above every top-level screen (the clone alarm, VAULT-MESSAGING §3.5.9): error colour, one line
/// and an action, and a close button with [onDismiss]. Mirrors vettid-android `UrgentBanner`.
public struct UrgentBanner: View {
    @Environment(\.vettIDColors) private var colors
    @Environment(\.dynamicTypeSize) private var typeSize
    let text: String
    let actionLabel: String
    let action: @MainActor () -> Void
    let onDismiss: (@MainActor () -> Void)?

    public init(
        _ text: String,
        actionLabel: String,
        onDismiss: (@MainActor () -> Void)? = nil,
        action: @escaping @MainActor () -> Void
    ) {
        self.text = text
        self.actionLabel = actionLabel
        self.onDismiss = onDismiss
        self.action = action
    }

    public var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading)) : AnyLayout(HStackLayout(spacing: Spacing.m))
        layout {
            HStack(spacing: Spacing.m) {
                VettIDSymbol.errorOutline.image.accessibilityHidden(true)
                Text(text).vettIDFont(.bodyMedium, weight: .semibold).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 0) {
                Button(action: action) {
                    Text(actionLabel)
                        .vettIDFont(.labelLarge, weight: .bold)
                        .fixedSize()
                        .padding(.horizontal, Spacing.m)
                        .frame(minHeight: Spacing.touchTarget)
                }
                .buttonStyle(.plain)
                if let onDismiss {
                    IconButton(.close, label: UIStrings.dismiss, tint: colors.onError, action: onDismiss)
                        .accessibilityIdentifier("banner_dismiss")
                }
            }
        }
        .foregroundStyle(colors.onError)
        .padding(.leading, Spacing.l)
        .padding(.trailing, Spacing.s)
        .padding(.vertical, Spacing.s)
        .background(colors.error)
    }
}

/// The state of one ``StepList`` step.
public enum StepState: Sendable { case pending, active, done, failed }

/// A vertical list of steps with their state (the enrollment progress). Mirrors vettid-android `StepList`.
public struct StepList: View {
    @Environment(\.vettIDColors) private var colors
    let steps: [(String, StepState)]

    public init(_ steps: [(String, StepState)]) { self.steps = steps }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                HStack(spacing: Spacing.m) {
                    Group {
                        switch step.1 {
                        case .active: ProgressView().tint(colors.primary.color).controlSize(.small)
                        case .done: VettIDSymbol.checkCircle.image.foregroundStyle(colors.success)
                        case .failed: VettIDSymbol.errorOutline.image.foregroundStyle(colors.error)
                        case .pending: VettIDSymbol.radioUnchecked.image.foregroundStyle(colors.onSurfaceVariant)
                        }
                    }
                    .frame(width: 24, height: 24)
                    Text(step.0)
                        .vettIDFont(.bodyLarge)
                        .foregroundStyle(step.1 == .pending ? colors.onSurfaceVariant : colors.onSurface)
                }
                .frame(minHeight: 32)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(step.0): \(Self.stateLabel(step.1))")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func stateLabel(_ state: StepState) -> String {
        switch state {
        case .pending: UIStrings.stepPending
        case .active: UIStrings.stepActive
        case .done: UIStrings.stepDone
        case .failed: UIStrings.stepFailed
        }
    }
}

/// A centred busy indicator for a whole screen. Mirrors vettid-android `FullScreenProgress`.
public struct FullScreenProgress: View {
    @Environment(\.vettIDColors) private var colors
    let label: String

    public init(_ label: String) { self.label = label }

    public var body: some View {
        VStack(spacing: Spacing.xl) {
            RookLogo(height: 72)
            ProgressView().tint(colors.primary.color).accessibilityLabel(label)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(colors.background)
    }
}

/// A step of a form flow (onboarding, unlock, credential and settings forms): optional back arrow, a heading and
/// body, the [content], and the primary (and optional secondary) action at the bottom, above the keyboard. The
/// [header] (the hero glyph above the title) is centred; the title, body and [content] stay start-aligned.
/// Mirrors vettid-android `FormScaffold`.
public struct FormScaffold<Header: View, Content: View, TopActions: View>: View {
    @Environment(\.vettIDColors) private var colors
    let title: String
    let message: String?
    let primaryLabel: String?
    let primaryEnabled: Bool
    let busy: Bool
    let destructive: Bool
    let secondaryLabel: String?
    let onPrimary: @MainActor () -> Void
    let onSecondary: @MainActor () -> Void
    let onBack: (@MainActor () -> Void)?
    let header: Header
    let content: Content
    let topActions: TopActions

    public init(
        title: String,
        message: String? = nil,
        primaryLabel: String?,
        primaryEnabled: Bool = true,
        busy: Bool = false,
        destructive: Bool = false,
        secondaryLabel: String? = nil,
        onPrimary: @escaping @MainActor () -> Void,
        onSecondary: @escaping @MainActor () -> Void = {},
        onBack: (@MainActor () -> Void)? = nil,
        @ViewBuilder header: () -> Header = { EmptyView() },
        @ViewBuilder topActions: () -> TopActions = { EmptyView() },
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.message = message
        self.primaryLabel = primaryLabel
        self.primaryEnabled = primaryEnabled
        self.busy = busy
        self.destructive = destructive
        self.secondaryLabel = secondaryLabel
        self.onPrimary = onPrimary
        self.onSecondary = onSecondary
        self.onBack = onBack
        self.header = header()
        self.content = content()
        self.topActions = topActions()
    }

    public var body: some View {
        VStack(spacing: 0) {
            if let onBack {
                VettIDBackTopBar(onBack: onBack) { topActions }
            } else {
                Spacer().frame(height: Spacing.xl)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack { header }.frame(maxWidth: .infinity)
                    Text(title)
                        .vettIDFont(.headlineSmall)
                        .padding(.top, Spacing.s)
                        .padding(.bottom, Spacing.m)
                        .accessibilityAddTraits(.isHeader)
                    if let message {
                        Text(message).vettIDFont(.bodyLarge).foregroundStyle(colors.onSurfaceVariant)
                        Spacer().frame(height: Spacing.xl)
                    }
                    content
                    Spacer().frame(height: Spacing.xl)
                }
                .padding(.horizontal, Spacing.xl)
            }
            VStack(spacing: Spacing.s) {
                if let primaryLabel {
                    PrimaryButton(primaryLabel, busy: busy, destructive: destructive, action: onPrimary)
                        .disabled(!primaryEnabled || busy)
                        .accessibilityIdentifier("form_primary")
                }
                if let secondaryLabel {
                    Button(action: onSecondary) {
                        Text(secondaryLabel)
                            .vettIDFont(.labelLarge)
                            .foregroundStyle(colors.onSurface)
                            .frame(maxWidth: .infinity, minHeight: Spacing.touchTarget)
                    }
                    .buttonStyle(.plain)
                    .disabled(busy)
                    .accessibilityIdentifier("form_secondary")
                }
            }
            // A container, so that a screen's own identifier does not replace the buttons' (UI tests find them).
            .accessibilityElement(children: .contain)
            .padding(.horizontal, Spacing.xl)
            .padding(.vertical, Spacing.l)
        }
        .background(colors.background)
    }
}
