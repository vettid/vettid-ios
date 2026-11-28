import SwiftUI

/// The approvals indicator (ANDROID-PLAN §4 "The approvals indicator", D9; IOS-PLAN §4.12, ID19): [count] open approvals
/// (above 0: the shell provides none at 0), and while one is time-critical ([critical]) the countdown to [deadline] (nil:
/// the clock alone), in the urgency colors when [urgent], else neutral. [label] names the soonest time-critical entry for
/// VoiceOver, cleaned and bidi-isolated. Mirrors vettid-android `ApprovalsIndicator`.
public struct ApprovalsIndicator: Sendable {
    public let count: Int
    public let critical: Bool
    public let urgent: Bool
    public let deadline: Date?
    public let label: String?
    public let onTap: @MainActor @Sendable () -> Void

    public init(
        count: Int, critical: Bool = false, urgent: Bool = false, deadline: Date? = nil, label: String? = nil,
        onTap: @escaping @MainActor @Sendable () -> Void
    ) {
        self.count = count
        self.critical = critical
        self.urgent = urgent
        self.deadline = deadline
        self.label = label
        self.onTap = onTap
    }

    /// The whole seconds left to [deadline] at [now], rounded up and never below 0 (80.4 s reads "1:21").
    public static func secondsUntil(_ deadline: Date, _ now: Date) -> Int64 {
        max(0, Int64(deadline.timeIntervalSince(now).rounded(.up)))
    }

    /// The countdown's face, `M:SS`.
    public static func face(_ seconds: Int64) -> String { UIStrings.approvalsIndicatorTime(seconds / 60, seconds % 60) }

    /// What VoiceOver says: the count, and with [secondsLeft] known (above 0) and a name, which entry expires in how long.
    public func description(_ secondsLeft: Int64?) -> String {
        // [label] comes cleaned and bidi-isolated from the shell (VAULT-MESSAGING §10.8).
        if let secondsLeft, secondsLeft > 0, let label, !label.isEmpty {
            return UIStrings.approvalsIndicatorUrgent(count, label: label, time: spokenDuration(secondsLeft))
        }
        return UIStrings.approvalsIndicator(count)
    }

    /// The width below which the capsule collapses to the icon with a clock badge (vettid-android `PILL_MIN_WIDTH_DP`).
    public static let capsuleMinWidth: CGFloat = 360

    /// Whether it is drawn as the capsule: time-critical, room allowing (not [compact], not at an accessibility size, the
    /// bar at least ``capsuleMinWidth`` wide). Otherwise the icon, with a clock badge while time-critical.
    public func capsule(compact: Bool, typeSize: DynamicTypeSize, width: CGFloat) -> Bool {
        critical && !(compact || typeSize.isAccessibilitySize || width < Self.capsuleMinWidth)
    }

    /// The capsule's and the clock badge's colors: the urgency colors while an entry is urgent, else the neutral surface;
    /// background first. Never the count badge's: that stays gold.
    public static func timeColors(urgent: Bool, _ c: VettIDColors) -> (ThemeColor, ThemeColor) {
        urgent ? (c.errorContainer, c.onErrorContainer) : (c.surfaceVariant, c.onSurfaceVariant)
    }
}

public extension EnvironmentValues {
    /// The indicator the top bars show (before the bell; on the detail screens before their actions). The shell provides it
    /// inside the unlocked shell only, and nil on Approvals, on a request's screen, while held or the check is due, and at 0.
    /// vettid-android `LocalApprovalsIndicator`.
    @Entry var vettIDApprovalsIndicator: ApprovalsIndicator?
}

public extension View {
    /// This content without the approvals indicator (vettid-android `WithoutApprovalsIndicator`).
    func withoutApprovalsIndicator() -> some View { environment(\.vettIDApprovalsIndicator, nil) }
}

/// The indicator as one control: the Approvals glyph with its count badge, or (time-critical, room allowing) the capsule with
/// a clock and `M:SS`. [compact] (a detail screen with its own actions) keeps it to the icon. [typeSize]: the screen's own
/// size, which the top bar caps. Mirrors vettid-android `ApprovalsIndicatorButton`.
public struct ApprovalsIndicatorButton: View {
    @Environment(\.vettIDColors) private var colors
    @Environment(\.vettIDCovered) private var covered
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    let indicator: ApprovalsIndicator
    let compact: Bool
    let typeSize: DynamicTypeSize
    let width: CGFloat

    public init(_ indicator: ApprovalsIndicator, compact: Bool = false, typeSize: DynamicTypeSize = .large, width: CGFloat = 390) {
        self.indicator = indicator
        self.compact = compact
        self.typeSize = typeSize
        self.width = width
    }

    var capsule: Bool { indicator.capsule(compact: compact, typeSize: typeSize, width: width) }

    /// The one-second tick runs only while shown and not under the daily check: for the capsule, or while VoiceOver is on for
    /// the icon's label to name the time left (it needs the entry's name). It announces nothing.
    func ticks(voiceOver: Bool) -> Bool {
        !covered && indicator.critical && indicator.deadline != nil && (capsule || (indicator.label != nil && voiceOver))
    }

    public var body: some View {
        if ticks(voiceOver: voiceOver), let deadline = indicator.deadline {
            // Ticks on the deadline's whole seconds.
            let anchor = deadline.addingTimeInterval(-(deadline.timeIntervalSinceNow.rounded(.up) + 1))
            TimelineView(.periodic(from: anchor, by: 1)) { context in
                face(ApprovalsIndicator.secondsUntil(deadline, context.date), ticking: true)
            }
        } else {
            face(nil, ticking: false)
        }
    }

    @ViewBuilder
    func face(_ left: Int64?, ticking: Bool) -> some View {
        let description = indicator.description(left)
        Group {
            if capsule {
                capsuleFace(left)
            } else {
                iconFace
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(description)
        .accessibilityAddTraits(ticking ? [.isButton, .updatesFrequently] : .isButton)
        .accessibilityShowsLargeContentViewer { Label { Text(description) } icon: { VettIDSymbol.approvals.image } }
        .accessibilityIdentifier(capsule ? (indicator.urgent ? "approvals_pill_urgent" : "approvals_pill") : "top_bar_approvals")
    }

    private func capsuleFace(_ left: Int64?) -> some View {
        let (background, content) = ApprovalsIndicator.timeColors(urgent: indicator.urgent, colors)
        return Button(action: indicator.onTap) {
            HStack(spacing: Spacing.xs) {
                VettIDSymbol.schedule.image.scaledIcon(size: 18, weight: .regular)
                if let left {
                    Text(verbatim: ApprovalsIndicator.face(left))
                        .vettIDFont(.labelLarge, weight: .bold)
                        .monospacedDigit()
                        .accessibilityIdentifier("approvals_pill_time")
                }
            }
            .foregroundStyle(content)
            .padding(.horizontal, Spacing.s)
            .padding(.vertical, Spacing.xs)
            .background(background, in: VettIDShape.pill)
            .frame(minWidth: Spacing.touchTarget, minHeight: Spacing.touchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var iconFace: some View {
        Button(action: indicator.onTap) {
            VettIDSymbol.approvals.image
                .scaledIcon(size: 20, weight: .regular)
                .foregroundStyle(colors.onSurface)
                .frame(width: Spacing.touchTarget, height: Spacing.touchTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            Group {
                if indicator.critical {
                    let (background, content) = ApprovalsIndicator.timeColors(urgent: indicator.urgent, colors)
                    VettIDSymbol.schedule.image
                        .font(.system(size: 12))
                        .foregroundStyle(content)
                        .frame(width: 18, height: 18)
                        .background(background, in: VettIDShape.pill)
                        .accessibilityIdentifier(indicator.urgent ? "approvals_clock_badge_urgent" : "approvals_clock_badge")
                } else {
                    Text(verbatim: badgeText(indicator.count))
                        .vettIDFont(.labelSmall, weight: .bold)
                        .foregroundStyle(colors.onPrimaryContainer)
                        .padding(.horizontal, Spacing.xs)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(colors.primaryContainer, in: VettIDShape.pill)
                        .accessibilityIdentifier("approvals_badge")
                }
            }
            .offset(y: 4)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
        }
    }
}
